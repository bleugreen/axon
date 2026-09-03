//! Production Unix-socket daemon and MCP stdio facade for the Rust macOS backend.
use crate::{
    MacBackend, Router, parse_request,
    platform::{MacPermissions, capability_report},
};
use axon_core::{
    CapabilityState, DaemonProvenance, DaemonReport, HealthPlatform, JsonRpcId, JsonRpcRequest,
    JsonRpcResponse, PermissionState, PlatformBackend, SessionHealth, ToolBackend, backend_tools,
    health::reason, validate_tools_call,
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
        Some("run" | "wait_for_value" | "wait_for_stability")
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
    thread::spawn(move || {
        let backend = MacBackend::new().map_err(|error| error.to_string());
        let _ = ready_tx.send(backend.as_ref().map(|_| ()).map_err(Clone::clone));
        let Ok(backend) = backend else {
            return;
        };
        let mut router = Router::new(backend);
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
                let endpoint = path.clone();
                thread::spawn(move || {
                    if let Err(error) = answer(stream, &router, &endpoint, &stopping) {
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
    endpoint: &std::path::Path,
    stopping: &AtomicBool,
) -> io::Result<()> {
    prepare_client_stream(&stream, REQUEST_TIMEOUT)?;
    let mut line = String::new();
    if BufReader::new(stream.try_clone()?).read_line(&mut line)? == 0 {
        return Ok(());
    }
    let (response, stop) = dispatch(line.trim(), router, endpoint);
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

fn dispatch(
    line: &str,
    router: &mpsc::Sender<RouterRequest>,
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
        "health" => {
            // Health deliberately does not take the mutable router lock. A replay or wait may own
            // backend state for minutes, but status must remain a truthful liveness probe.
            //
            // The permissions are read once, directly, and used for both the permission block and
            // the capability census. Reading them back out of the census is what made a
            // denied-Accessibility daemon report Screen Recording ungranted, and going through
            // `MacBackend::new()` here meant a construction failure would silently publish an
            // empty capability list.
            let permissions = MacPermissions::read();
            let reported = capability_report(permissions);
            let version = env!("CARGO_PKG_VERSION").to_owned();
            let process_id = std::process::id();
            let executable_path = std::env::current_exe()
                .map(|path| path.display().to_string())
                .unwrap_or_default();
            let session = session_health();
            let report = DaemonReport {
                version: version.clone(),
                platform: HealthPlatform::Macos,
                ready: permissions.accessibility && session.interactive && session.graphical,
                process_id,
                endpoint: endpoint.display().to_string(),
                provenance: Some(DaemonProvenance {
                    backend: "rust-axon-mac".into(),
                    process_id,
                    executable_path,
                    version,
                }),
                session,
                permissions: permission_states(permissions),
                capabilities: CapabilityState::complete(&reported),
            };
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

        let (response, stop) = dispatch(&request, &router, std::path::Path::new("/tmp/test.sock"));

        assert!(!stop);
        assert_eq!(
            response.pointer("/result/provenance/backend"),
            Some(&json!("rust-axon-mac"))
        );
        assert!(response.pointer("/result/provenance/processId").is_some());
        assert!(
            response
                .pointer("/result/provenance/executablePath")
                .is_some()
        );
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
                "find",
                "wait_for_value",
                "wait_for_stability",
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
