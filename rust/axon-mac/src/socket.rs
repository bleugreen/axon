//! Production Unix-socket daemon and MCP stdio facade for the Rust macOS backend.
use crate::{
    MacBackend, Router, accessibility,
    automation::ConsentService,
    browser::BrowserService,
    parse_request,
    platform::{MacPermissions, capability_report},
};
use axon_core::{
    CapabilityState, DaemonProvenance, DaemonReport, HealthPlatform, JsonRpcError, JsonRpcId,
    JsonRpcRequest, JsonRpcResponse, PermissionState, SHELL_CONTRACT_VERSION, SessionHealth,
    ToolBackend, backend_tools, health::reason, validate_tools_call,
};
use serde_json::{Value, json};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, BufRead, BufReader, Write},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{FileTypeExt, MetadataExt, PermissionsExt},
            net::{UnixListener, UnixStream},
        },
    },
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::Duration,
};

pub const SOCKET_ENV: &str = "AXON_SOCKET_PATH";
pub const PRIVATE_SOCKET_ENV: &str = "AXON_MAC_SOCKET";
pub const DEFAULT_SOCKET_PATH: &str = "/tmp/axon.sock";
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
pub const LONG_REQUEST_TIMEOUT: Duration = Duration::from_secs(300);

unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}

struct RouterRequest {
    request: JsonRpcRequest,
    response: mpsc::SyncSender<Option<JsonRpcResponse>>,
}
const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn CGSessionCopyCurrentDictionary() -> *const std::ffi::c_void;
}
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: *const std::ffi::c_void);
}
unsafe extern "C" {
    fn getuid() -> u32;
}

fn session_health() -> SessionHealth {
    let session = unsafe { CGSessionCopyCurrentDictionary() };
    let graphical = !session.is_null();
    if graphical {
        unsafe { CFRelease(session) };
    }
    let interactive = unsafe { getuid() } != 0 && graphical;
    if interactive && graphical {
        SessionHealth::usable(None)
    } else if !interactive {
        SessionHealth::degraded(false, graphical, reason::NOT_INTERACTIVE_SESSION, None)
    } else {
        SessionHealth::degraded(true, false, reason::NO_GRAPHICAL_SESSION, None)
    }
}

fn acquire_lock(path: &std::path::Path) -> io::Result<File> {
    let lock_path = PathBuf::from(format!("{}.lock", path.display()));
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(lock_path)?;
    if unsafe { flock(lock.as_raw_fd(), LOCK_EX | LOCK_NB) } != 0 {
        return Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            "socket ownership lock is held",
        ));
    }
    Ok(lock)
}

pub fn path() -> io::Result<PathBuf> {
    Ok(std::env::var_os(PRIVATE_SOCKET_ENV)
        .or_else(|| std::env::var_os(SOCKET_ENV))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_SOCKET_PATH)))
}
pub fn request(line: &str) -> io::Result<String> {
    let mut stream = UnixStream::connect(path()?)?;
    let method = serde_json::from_str::<Value>(line).ok().and_then(|value| {
        value
            .get("method")
            .and_then(Value::as_str)
            .map(str::to_owned)
    });
    let timeout = if matches!(
        method.as_deref(),
        Some("run" | "wait_for_value" | "wait_for_stability" | "automation.request")
    ) {
        LONG_REQUEST_TIMEOUT
    } else {
        REQUEST_TIMEOUT
    };
    stream.set_read_timeout(Some(timeout))?;
    stream.write_all(line.as_bytes())?;
    stream.write_all(b"\n")?;
    let mut response = String::new();
    BufReader::new(stream).read_line(&mut response)?;
    Ok(response)
}
pub fn serve() -> io::Result<()> {
    let path = path()?;
    let _ownership = acquire_lock(&path)?;
    if path.exists() {
        let metadata = fs::symlink_metadata(&path)?;
        if !metadata.file_type().is_socket() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "refusing to replace a non-socket endpoint",
            ));
        }
        if UnixStream::connect(&path).is_ok() {
            return Err(io::Error::new(
                io::ErrorKind::AddrInUse,
                "socket already has a listener",
            ));
        }
        fs::remove_file(&path)?;
    }
    let (router_tx, router_rx) = mpsc::channel::<RouterRequest>();
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    // One ledger for the whole daemon: the browser verbs on the worker record the answers macOS
    // gives their events, and the menu's `automation.*` methods on the connection threads read
    // them, so a refusal a verb met is the refusal the menu explains.
    let consent = Arc::new(ConsentService::system());
    let verb_consent = Arc::clone(&consent);
    thread::spawn(move || {
        let backend = MacBackend::new().map_err(|error| error.to_string());
        let _ = ready_tx.send(backend.as_ref().map(|_| ()).map_err(Clone::clone));
        let Ok(backend) = backend else {
            return;
        };
        // The verbs run here, on the serialized worker, because `windows` cross-checks against an
        // Accessibility capture and every answer belongs in the action history. They never
        // prompt, so nothing here waits on a person.
        let mut router =
            Router::new(backend).with_browser(Box::new(BrowserService::system(verb_consent)));
        for request in router_rx {
            let response = router.request(request.request);
            let _ = request.response.send(response);
        }
    });
    ready_rx
        .recv()
        .map_err(io::Error::other)?
        .map_err(io::Error::other)?;
    let stopping = Arc::new(AtomicBool::new(false));
    let listener = UnixListener::bind(&path)?;
    listener.set_nonblocking(true)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    let bound = fs::symlink_metadata(&path)?;
    while !stopping.load(Ordering::Acquire) {
        match listener.accept() {
            Ok((stream, _)) => {
                let router = router_tx.clone();
                let stopping = Arc::clone(&stopping);
                let consent = Arc::clone(&consent);
                let endpoint = path.clone();
                thread::spawn(move || {
                    if let Err(error) = answer(stream, &router, &consent, &endpoint, &stopping) {
                        eprintln!("axon-mac: dropped a client connection: {error}");
                    }
                });
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) => eprintln!("axon-mac: accept failed: {error}"),
        }
    }
    if let Ok(current) = fs::symlink_metadata(&path)
        && current.file_type().is_socket()
        && current.dev() == bound.dev()
        && current.ino() == bound.ino()
    {
        let _ = fs::remove_file(path);
    }
    Ok(())
}

fn answer(
    mut stream: UnixStream,
    router: &mpsc::Sender<RouterRequest>,
    consent: &ConsentService,
    endpoint: &std::path::Path,
    stopping: &AtomicBool,
) -> io::Result<()> {
    prepare_client_stream(&stream, REQUEST_TIMEOUT)?;
    let mut line = String::new();
    if BufReader::new(stream.try_clone()?).read_line(&mut line)? == 0 {
        return Ok(());
    }
    let (response, stop) = dispatch(line.trim(), router, consent, endpoint);
    write_response(&mut stream, &response)?;
    if stop {
        stopping.store(true, Ordering::Release);
    }
    Ok(())
}

fn prepare_client_stream(stream: &UnixStream, timeout: Duration) -> io::Result<()> {
    // The listener is nonblocking so the daemon can observe shutdown requests. On macOS, accepted
    // sockets inherit that state; leaving it in place makes a response larger than the socket
    // buffer fail with EAGAIN instead of waiting for the client to drain it.
    stream.set_nonblocking(false)?;
    // These are per-syscall bounds. They prevent a client that stops participating from parking a
    // connection thread forever while still allowing large observations to advance in partial
    // writes as buffer space becomes available.
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    Ok(())
}

fn write_response(stream: &mut UnixStream, response: &Value) -> io::Result<()> {
    stream.write_all(serde_json::to_string(response).unwrap().as_bytes())?;
    stream.write_all(b"\n")
}

/// The permission block health publishes, as a pure function of the two permissions.
///
/// One `PermissionState` per TCC row, each reporting only its own row.
fn permission_states(permissions: MacPermissions) -> Vec<PermissionState> {
    vec![
        if permissions.accessibility {
            PermissionState::granted("accessibility")
        } else {
            PermissionState::ungranted("accessibility", reason::ACCESSIBILITY_NOT_GRANTED, None)
        },
        if permissions.screen_recording {
            PermissionState::granted("screenRecording")
        } else {
            PermissionState::ungranted(
                "screenRecording",
                reason::SCREEN_RECORDING_NOT_GRANTED,
                None,
            )
        },
    ]
}

/// The `health` answer as a pure function of what the daemon observed, so the shared macOS health
/// fixtures can be produced by this code path rather than written by hand.
fn daemon_report(
    permissions: MacPermissions,
    session: SessionHealth,
    process_id: u32,
    endpoint: &str,
    executable_path: &str,
    version: &str,
) -> DaemonReport {
    DaemonReport {
        version: version.to_owned(),
        platform: HealthPlatform::Macos,
        ready: permissions.accessibility && session.interactive && session.graphical,
        process_id,
        endpoint: endpoint.to_owned(),
        provenance: Some(DaemonProvenance {
            backend: "rust-axon-mac".into(),
            process_id,
            executable_path: executable_path.to_owned(),
            version: version.to_owned(),
        }),
        shell_contract: Some(SHELL_CONTRACT_VERSION),
        session,
        permissions: permission_states(permissions),
        capabilities: CapabilityState::complete(&capability_report(permissions)),
    }
}

/// The menu shell's methods take no parameters; anything else is a caller bug worth naming.
fn no_params(request: &JsonRpcRequest) -> Result<(), JsonRpcError> {
    match &request.params {
        None | Some(Value::Null) => Ok(()),
        Some(Value::Object(params)) if params.is_empty() => Ok(()),
        Some(_) => Err(JsonRpcError {
            code: -32602,
            message: format!("Invalid params: {} accepts no fields", request.method),
            data: Some(json!({"path":"params","reason":"accepts no fields"})),
        }),
    }
}

fn reply<T: serde::Serialize>(id: JsonRpcId, outcome: Result<T, JsonRpcError>) -> Value {
    serde_json::to_value(match outcome {
        Ok(result) => JsonRpcResponse::success(id, serde_json::to_value(result).unwrap()),
        Err(error) => JsonRpcResponse::failure(id, error),
    })
    .unwrap()
}

fn dispatch(
    line: &str,
    router: &mpsc::Sender<RouterRequest>,
    consent: &ConsentService,
    endpoint: &std::path::Path,
) -> (Value, bool) {
    let request = match parse_request(line) {
        Ok(v) => v,
        Err(v) => return (serde_json::to_value(v).unwrap(), false),
    };
    let Some(id) = request.id.clone() else {
        return (Value::Null, false);
    };
    match request.method.as_str() {
        // The menu shell's permission methods are answered here, on the connection thread, for
        // the same reason `health` is: the backend worker is serialized and may be owned by a
        // replay for minutes, and `automation.request` blocks for as long as a consent dialog is
        // on screen. Neither touches backend state; the consent ledger has its own lock.
        "permit" => (
            reply(id, no_params(&request).map(|_| accessibility::permit())),
            false,
        ),
        "automation.status" => (
            reply(id, no_params(&request).map(|_| consent.status())),
            false,
        ),
        "automation.request" => (
            reply(id, no_params(&request).and_then(|_| consent.request())),
            false,
        ),
        "health" => {
            // Health deliberately does not take the mutable router lock. A replay or wait may own
            // backend state for minutes, but status must remain a truthful liveness probe.
            //
            // The permissions are read once, directly, and used for both the permission block and
            // the capability census. Reading them back out of the census is what made a
            // denied-Accessibility daemon report Screen Recording ungranted, and going through
            // `MacBackend::new()` here meant a construction failure would silently publish an
            // empty capability list.
            let report = daemon_report(
                MacPermissions::read(),
                session_health(),
                std::process::id(),
                &endpoint.display().to_string(),
                &std::env::current_exe()
                    .map(|path| path.display().to_string())
                    .unwrap_or_default(),
                env!("CARGO_PKG_VERSION"),
            );
            (
                serde_json::to_value(JsonRpcResponse::success(
                    id,
                    serde_json::to_value(report).unwrap(),
                ))
                .unwrap(),
                false,
            )
        }
        "shutdown" => (
            serde_json::to_value(JsonRpcResponse::success(
                id,
                json!({"shutdown":true,"processId":std::process::id()}),
            ))
            .unwrap(),
            true,
        ),
        _ => (
            {
                let (response_tx, response_rx) = mpsc::sync_channel(1);
                if router
                    .send(RouterRequest {
                        request,
                        response: response_tx,
                    })
                    .is_err()
                {
                    Value::Null
                } else {
                    response_rx
                        .recv()
                        .ok()
                        .flatten()
                        .map(|value| serde_json::to_value(value).unwrap())
                        .unwrap_or(Value::Null)
                }
            },
            false,
        ),
    }
}
pub fn mcp() -> io::Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    for line in stdin.lock().lines() {
        let value: Value = serde_json::from_str(&line?).map_err(io::Error::other)?;
        if value.get("id").is_none() {
            continue;
        }
        let response = mcp_response(&value, request);
        writeln!(stdout, "{}", serde_json::to_string(&response).unwrap())?;
        stdout.flush()?;
    }
    Ok(())
}
fn mcp_response<F>(value: &Value, mut forward: F) -> Value
where
    F: FnMut(&str) -> io::Result<String>,
{
    let id = value.get("id").cloned().unwrap_or(Value::Null);
    match value.get("method").and_then(Value::as_str) {
        Some("initialize") => {
            json!({"jsonrpc":"2.0","id":id,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"axon-mac","version":env!("CARGO_PKG_VERSION")}}})
        }
        Some("tools/list") => match backend_tools(ToolBackend::Mac) {
            Ok(tools) => json!({"jsonrpc":"2.0","id":id,"result":{"tools":tools}}),
            Err(error) => json!({"jsonrpc":"2.0","id":id,"error":error}),
        },
        Some("tools/call") => {
            let call = match validate_tools_call(ToolBackend::Mac, value.get("params").cloned()) {
                Ok(call) => call,
                Err(error) => return json!({"jsonrpc":"2.0","id":id,"error":error}),
            };
            let rpc = serde_json::to_string(&JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                call.socket_method,
                Some(call.arguments),
            ))
            .unwrap();
            match forward(&rpc) {
                Ok(body) => {
                    let response: Value = match serde_json::from_str(&body) {
                        Ok(response) => response,
                        Err(error) => {
                            return json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":error.to_string()}});
                        }
                    };
                    if let Some(error) = response.get("error") {
                        json!({"jsonrpc":"2.0","id":id,"result":{"content":[{"type":"text","text":error["message"].as_str().unwrap_or("Axon error")}],"structuredContent":error,"isError":true}})
                    } else {
                        let result = response.get("result").cloned().unwrap_or(Value::Null);
                        mcp_success_response(id, result)
                    }
                }
                Err(error) => {
                    json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":error.to_string()}})
                }
            }
        }
        _ => {
            json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"method not found"}})
        }
    }
}
fn mcp_success_response(id: Value, result: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"result":axon_core::mcp_tool_result(result, false)})
}
#[cfg(test)]
mod tests {
    use super::*;

    /// The shared macOS health fixtures are what this daemon publishes, composed the way the CLI
    /// composes `status --json`. Set `AXON_REGENERATE_HEALTH_FIXTURES=1` to rewrite them from this
    /// code path after a deliberate change; the semantic checks in
    /// `rust/axon-core/tests/health.rs` then say whether the change means what it should.
    #[test]
    fn macos_health_fixtures_are_what_this_daemon_publishes() {
        use axon_core::{HealthReport, JobState, RegistrationHealth, RegistrationMechanism};
        let main = "/Applications/Axon.app/Contents/MacOS/Axon";
        for (name, permissions) in [
            (
                "macos-healthy.json",
                MacPermissions {
                    accessibility: true,
                    screen_recording: true,
                },
            ),
            (
                "macos-accessibility-denied.json",
                MacPermissions {
                    accessibility: false,
                    screen_recording: true,
                },
            ),
        ] {
            let report = daemon_report(
                permissions,
                SessionHealth::usable(None),
                4210,
                DEFAULT_SOCKET_PATH,
                main,
                "0.4.0",
            );
            let menu = "/Applications/Axon.app/Contents/Library/Applications/Axon Menu.app/Contents/MacOS/AxonMenu";
            let mut registration =
                RegistrationHealth::present(RegistrationMechanism::Launchd, main);
            registration.jobs = Some(vec![
                JobState {
                    label: "dev.axon.daemon".into(),
                    loaded: true,
                    process_id: Some(4210),
                    path: Some(main.into()),
                },
                JobState {
                    label: "dev.axon.menu".into(),
                    loaded: true,
                    process_id: Some(4211),
                    path: Some(menu.into()),
                },
            ]);
            let produced =
                serde_json::to_value(HealthReport::running(report, registration)).unwrap();
            let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../schema/fixtures/health")
                .join(name);
            if std::env::var_os("AXON_REGENERATE_HEALTH_FIXTURES").is_some() {
                fs::write(
                    &path,
                    serde_json::to_string_pretty(&produced).unwrap() + "\n",
                )
                .unwrap();
            }
            let committed: Value =
                serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
            assert_eq!(
                produced, committed,
                "{name} is not what axon-mac publishes; regenerate it"
            );
        }
    }

    #[test]
    fn facade_matches_shared_observation_envelope() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../schema/fixtures/mcp-look-observation-envelope.json"
        ))
        .unwrap();
        assert_eq!(
            mcp_success_response(json!(1), fixture["structuredContent"].clone())["result"],
            fixture["result"]
        );
    }
    /// Each permission field reports its own TCC row and nothing else.
    ///
    /// The (false, true) case is the regression: a daemon with Accessibility denied and Screen
    /// Recording granted used to publish `screenRecording ungranted`, because the field was read
    /// out of the `screenshot` capability, which composes both. The `kTCCServiceScreenCapture` row
    /// was granted the whole time, and health said otherwise.
    #[test]
    fn each_permission_reports_only_its_own_grant() {
        let states = |accessibility, screen_recording| {
            permission_states(MacPermissions {
                accessibility,
                screen_recording,
            })
            .into_iter()
            .map(|state| (state.name, state.granted, state.reason))
            .collect::<Vec<_>>()
        };
        assert_eq!(
            states(false, true),
            vec![
                (
                    "accessibility".to_owned(),
                    false,
                    Some(reason::ACCESSIBILITY_NOT_GRANTED.to_owned())
                ),
                ("screenRecording".to_owned(), true, None),
            ]
        );
        assert_eq!(
            states(true, false),
            vec![
                ("accessibility".to_owned(), true, None),
                (
                    "screenRecording".to_owned(),
                    false,
                    Some(reason::SCREEN_RECORDING_NOT_GRANTED.to_owned())
                ),
            ]
        );
        assert_eq!(
            states(true, true)
                .iter()
                .map(|(_, granted, _)| *granted)
                .collect::<Vec<_>>(),
            vec![true, true]
        );
        assert_eq!(
            states(false, false)
                .iter()
                .map(|(_, granted, _)| *granted)
                .collect::<Vec<_>>(),
            vec![false, false]
        );
    }
    #[test]
    fn endpoint_defaults_to_canonical_installed_socket() {
        unsafe {
            std::env::remove_var(PRIVATE_SOCKET_ENV);
            std::env::remove_var(SOCKET_ENV);
        }
        assert_eq!(path().unwrap(), PathBuf::from(DEFAULT_SOCKET_PATH));
    }
    #[test]
    fn health_bypasses_an_unavailable_backend_worker() {
        let (router, receiver) = mpsc::channel();
        drop(receiver);
        let request = serde_json::to_string(&JsonRpcRequest::new(
            Some(JsonRpcId::Integer(1)),
            "health",
            Some(json!({})),
        ))
        .unwrap();

        let (response, stop) = dispatch(
            &request,
            &router,
            &no_browsers(),
            std::path::Path::new("/tmp/test.sock"),
        );

        assert!(!stop);
        assert_eq!(
            response.pointer("/result/provenance/backend"),
            Some(&json!("rust-axon-mac"))
        );
        assert_eq!(
            response.pointer("/result/shellContract"),
            Some(&json!(SHELL_CONTRACT_VERSION))
        );
        assert!(response.pointer("/result/provenance/processId").is_some());
        assert!(
            response
                .pointer("/result/provenance/executablePath")
                .is_some()
        );
    }
    /// A consent service whose host reports no browser running, so nothing reaches TCC.
    fn no_browsers() -> ConsentService {
        struct NoBrowsers;
        impl crate::automation::AutomationHost for NoBrowsers {
            fn determine(&self, _: &str, _: bool) -> i32 {
                panic!("no browser is running, so nothing may be determined")
            }
            fn is_running(&self, _: &str) -> bool {
                false
            }
        }
        ConsentService::new(Box::new(NoBrowsers))
    }

    fn call(method: &str, params: Value, router: &mpsc::Sender<RouterRequest>) -> Value {
        let request = serde_json::to_string(&JsonRpcRequest::new(
            Some(JsonRpcId::Integer(1)),
            method,
            Some(params),
        ))
        .unwrap();
        dispatch(
            &request,
            router,
            &no_browsers(),
            std::path::Path::new("/tmp/test.sock"),
        )
        .0
    }

    /// The consent methods never reach the serialized backend worker, so a worker that is busy
    /// for minutes (or gone) cannot stall the menu.
    #[test]
    fn consent_methods_bypass_an_unavailable_backend_worker() {
        let (router, receiver) = mpsc::channel();
        drop(receiver);

        let status = call("automation.status", json!({}), &router);
        assert_eq!(status.pointer("/result/need"), Some(&json!("none")));
        assert_eq!(
            status.pointer("/result/browsers/0/bundleIdentifier"),
            Some(&json!("com.apple.Safari"))
        );
        let request = call("automation.request", json!({}), &router);
        assert_eq!(request.pointer("/result/outcomes"), Some(&json!([])));
    }

    #[test]
    fn shell_methods_refuse_parameters() {
        let (router, _receiver) = mpsc::channel();
        for method in ["permit", "automation.status", "automation.request"] {
            let response = call(method, json!({"extra": true}), &router);
            assert_eq!(
                response.pointer("/error/code"),
                Some(&json!(-32602)),
                "{method}"
            );
        }
    }

    #[test]
    fn ownership_lock_refuses_a_second_server() {
        let path = std::env::temp_dir().join(format!("axon-mac-lock-{}", std::process::id()));
        let first = acquire_lock(&path).unwrap();
        assert_eq!(
            acquire_lock(&path).unwrap_err().kind(),
            io::ErrorKind::AddrInUse
        );
        drop(first);
        let _ = fs::remove_file(format!("{}.lock", path.display()));
    }
    #[test]
    fn non_socket_endpoints_are_identifiable_before_reclaim() {
        let path = std::env::temp_dir().join(format!("axon-mac-file-{}", std::process::id()));
        fs::write(&path, b"keep").unwrap();
        assert!(!fs::symlink_metadata(&path).unwrap().file_type().is_socket());
        fs::remove_file(path).unwrap();
    }
    #[test]
    fn large_response_waits_for_a_delayed_reader_instead_of_failing_with_would_block() {
        use std::io::Read;

        let (mut server, mut client) = UnixStream::pair().unwrap();
        server.set_nonblocking(true).unwrap();
        prepare_client_stream(&server, Duration::from_secs(2)).unwrap();
        let response = json!({"result": {"screenText": "x".repeat(1_000_000)}});
        let expected = format!("{}\n", serde_json::to_string(&response).unwrap());

        let writer = thread::spawn(move || write_response(&mut server, &response));
        thread::sleep(Duration::from_millis(50));
        let mut received = String::new();
        client.read_to_string(&mut received).unwrap();

        writer.join().unwrap().unwrap();
        assert_eq!(received, expected);
    }

    #[test]
    fn disconnected_client_error_is_contained() {
        let (server, client) = UnixStream::pair().unwrap();
        drop(client);
        let mut server = server;
        assert!(writeln!(server, "response").is_err());
    }
    #[test]
    fn facade_lists_shared_mac_surface() {
        let response = mcp_response(
            &json!({"jsonrpc":"2.0","id":1,"method":"tools/list"}),
            |_| panic!("tools/list must not contact the daemon"),
        );
        let tools = response["result"]["tools"].as_array().unwrap();
        let names = tools
            .iter()
            .map(|v| v["name"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        assert_eq!(
            names,
            [
                "look",
                "navigate",
                "windows",
                "tabs",
                "find",
                "wait_for_value",
                "wait_for_stability",
                "permit",
                "run",
                "save",
                "click",
                "type",
                "keyboard",
                "scroll",
                "invoke"
            ]
        );
        assert_eq!(tools[0]["inputSchema"]["additionalProperties"], false);
    }
    #[test]
    fn malformed_calls_are_protocol_errors_without_daemon_forwarding() {
        for params in [
            json!({"name": 3}),
            json!({"name":"look","arguments":{"depth":"2"}}),
            json!({"name":"click","arguments":{"target":{"app":"Notes"}}}),
        ] {
            let response = mcp_response(
                &json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":params}),
                |_| panic!("invalid calls must not contact the daemon"),
            );
            assert_eq!(response["error"]["code"], -32602);
        }
    }
    #[test]
    fn nested_target_is_forwarded_unchanged() {
        let target = json!({"app":"Notes","name":"Save"});
        let response = mcp_response(
            &json!({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"click","arguments":{"target":target}}}),
            |body| {
                let forwarded: Value = serde_json::from_str(body).unwrap();
                assert_eq!(forwarded["method"], "click");
                assert_eq!(forwarded["params"]["target"], target);
                Ok(json!({"jsonrpc":"2.0","id":1,"result":{"clicked":true}}).to_string())
            },
        );
        assert_eq!(response["id"], 7);
        assert_eq!(response["result"]["structuredContent"]["clicked"], true);
    }
    #[test]
    fn facade_accepts_protocol_metadata_without_forwarding_it() {
        let response = mcp_response(
            &json!({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"look","arguments":{},"_meta":{"progressToken":"p1"}}}),
            |body| {
                let forwarded: Value = serde_json::from_str(body).unwrap();
                assert!(forwarded["params"].get("_meta").is_none());
                Ok(json!({"jsonrpc":"2.0","id":1,"result":{"ok":true}}).to_string())
            },
        );
        assert_eq!(response["result"]["isError"], false);
    }
}
