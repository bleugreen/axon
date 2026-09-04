#![cfg(windows)]

use crate::{Router, WindowsBackend, parse_request};
use axon_core::{
    JsonRpcId, JsonRpcRequest, PlatformBackend, ToolBackend, backend_tools, poll_wait_request,
    validate_tools_call,
};
use serde_json::{Value, json};
use std::{
    ffi::c_void,
    fs::OpenOptions,
    io::{self, BufRead, BufReader, Write},
    ptr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

#[repr(C)]
struct SecurityAttributes {
    length: u32,
    descriptor: *mut c_void,
    inherit_handle: i32,
}
#[repr(C)]
struct SidAndAttributes {
    sid: *mut c_void,
    attributes: u32,
}

const PIPE: &str = r"\\.\pipe\axon-v1";
const PIPE_WIDE: &[u16] = &[
    92, 92, 46, 92, 112, 105, 112, 101, 92, 97, 120, 111, 110, 45, 118, 49, 0,
];
const INVALID_HANDLE_VALUE: isize = -1;
const PIPE_ACCESS_DUPLEX: u32 = 3;
const PIPE_TYPE_BYTE: u32 = 0;
const PIPE_READMODE_BYTE: u32 = 0;
const PIPE_WAIT: u32 = 0;
const PIPE_REJECT_REMOTE_CLIENTS: u32 = 8;
const PIPE_UNLIMITED_INSTANCES: u32 = 255;

#[link(name = "kernel32")]
unsafe extern "system" {
    fn CreateNamedPipeW(
        name: *const u16,
        open_mode: u32,
        pipe_mode: u32,
        max_instances: u32,
        out_size: u32,
        in_size: u32,
        timeout: u32,
        security: *const c_void,
    ) -> isize;
    fn ConnectNamedPipe(pipe: isize, overlapped: *mut c_void) -> i32;
    fn DisconnectNamedPipe(pipe: isize) -> i32;
    fn CloseHandle(handle: isize) -> i32;
    fn ReadFile(
        handle: isize,
        buffer: *mut c_void,
        len: u32,
        read: *mut u32,
        overlapped: *mut c_void,
    ) -> i32;
    fn WriteFile(
        handle: isize,
        buffer: *const c_void,
        len: u32,
        written: *mut u32,
        overlapped: *mut c_void,
    ) -> i32;
    fn LocalFree(memory: *mut c_void) -> *mut c_void;
}
#[link(name = "advapi32")]
unsafe extern "system" {
    fn GetTokenInformation(
        token: isize,
        class: u32,
        info: *mut c_void,
        len: u32,
        needed: *mut u32,
    ) -> i32;
    fn ConvertSidToStringSidW(sid: *mut c_void, string_sid: *mut *mut u16) -> i32;
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        text: *const u16,
        revision: u32,
        descriptor: *mut *mut c_void,
        size: *mut u32,
    ) -> i32;
}

struct PipeSecurity {
    attributes: SecurityAttributes,
    sid_string: *mut u16,
}
impl PipeSecurity {
    fn current_user() -> io::Result<Self> {
        const TOKEN_USER: u32 = 1;
        const TOKEN: isize = -4; // GetCurrentProcessToken pseudo-handle.
        let mut needed = 0;
        unsafe { GetTokenInformation(TOKEN, TOKEN_USER, ptr::null_mut(), 0, &mut needed) };
        if needed == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut token_user = vec![0u8; needed as usize];
        if unsafe {
            GetTokenInformation(
                TOKEN,
                TOKEN_USER,
                token_user.as_mut_ptr().cast(),
                needed,
                &mut needed,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        let sid = unsafe { (*(token_user.as_ptr() as *const SidAndAttributes)).sid };
        let mut sid_string = ptr::null_mut();
        if unsafe { ConvertSidToStringSidW(sid, &mut sid_string) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let sid_len = unsafe { (0..).find(|&i| *sid_string.add(i) == 0).unwrap() };
        let sid_text =
            unsafe { String::from_utf16_lossy(std::slice::from_raw_parts(sid_string, sid_len)) };
        // Protected DACL: only the process token's user SID receives generic-all.
        let sddl: Vec<u16> = format!("D:P(A;;GA;;;{sid_text})\0")
            .encode_utf16()
            .collect();
        let mut descriptor = ptr::null_mut();
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                1,
                &mut descriptor,
                ptr::null_mut(),
            )
        } == 0
        {
            unsafe {
                LocalFree(sid_string.cast());
            }
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            attributes: SecurityAttributes {
                length: std::mem::size_of::<SecurityAttributes>() as u32,
                descriptor,
                inherit_handle: 0,
            },
            sid_string,
        })
    }
}
impl Drop for PipeSecurity {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.attributes.descriptor);
            LocalFree(self.sid_string.cast());
        };
    }
}

pub fn serve(
    start_backend: impl FnOnce() -> Result<WindowsBackend, Box<dyn std::error::Error>> + Send + 'static,
    on_bound: impl FnOnce(),
) -> Result<(), Box<dyn std::error::Error>> {
    let mut security = PipeSecurity::current_user()?;
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let started = start_backend().map_err(|error| error.to_string());
        let _ = ready_tx.send(started);
    });

    // One bind, then one answer. The pipe is created before the backend is waited on so a client
    // that connects during a slow UI Automation startup finds an endpoint rather than nothing, and
    // it is closed either way: the serving loop below creates its own instances.
    let handle = create_pipe(&mut security)?;
    on_bound();
    let ready = ready_rx.recv().map_err(io::Error::other)?;
    close_pipe(handle);
    let backend = ready.map_err(|error| io::Error::other(error))?;
    let capabilities = Arc::new(backend.capabilities().unwrap_or_default());
    let router = Arc::new(Mutex::new(Router::new(backend)));
    let stopping = Arc::new(AtomicBool::new(false));

    while !stopping.load(Ordering::Acquire) {
        let handle = create_pipe(&mut security)?;
        let connected = unsafe { ConnectNamedPipe(handle, ptr::null_mut()) } != 0
            || io::Error::last_os_error().raw_os_error() == Some(535);
        if !connected {
            close_pipe(handle);
            continue;
        }
        if stopping.load(Ordering::Acquire) {
            close_pipe(handle);
            break;
        }
        let router = Arc::clone(&router);
        let capabilities = Arc::clone(&capabilities);
        let stopping = Arc::clone(&stopping);
        thread::spawn(move || {
            if let Err(error) = connection(handle, &router, &capabilities, &stopping) {
                eprintln!("axon-win: dropped a client connection: {error}");
            }
            close_pipe(handle);
        });
    }
    Ok(())
}

fn create_pipe(security: &mut PipeSecurity) -> io::Result<isize> {
    let handle = unsafe {
        CreateNamedPipeW(
            PIPE_WIDE.as_ptr(),
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            PIPE_UNLIMITED_INSTANCES,
            1024 * 1024,
            1024 * 1024,
            0,
            (&mut security.attributes as *mut SecurityAttributes).cast(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        Err(io::Error::last_os_error())
    } else {
        Ok(handle)
    }
}

fn close_pipe(handle: isize) {
    unsafe {
        DisconnectNamedPipe(handle);
        CloseHandle(handle);
    }
}

fn wake_listener() {
    // The accept loop may be between instances when shutdown is dispatched. Retry long enough to
    // either connect to its next blocking listener or observe that it exited before creating one.
    for _ in 0..100 {
        match OpenOptions::new().read(true).write(true).open(PIPE) {
            Ok(_) => return,
            Err(error) if matches!(error.raw_os_error(), Some(2 | 231)) => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(_) => return,
        }
    }
}

fn connection(
    handle: isize,
    router: &Arc<Mutex<Router<WindowsBackend>>>,
    capabilities: &[axon_core::CapabilityInfo],
    stopping: &AtomicBool,
) -> io::Result<()> {
    let mut pending = Vec::new();
    let mut buf = [0u8; 8192];
    loop {
        let mut n = 0;
        if unsafe {
            ReadFile(
                handle,
                buf.as_mut_ptr().cast(),
                buf.len() as u32,
                &mut n,
                ptr::null_mut(),
            )
        } == 0
            || n == 0
        {
            return Ok(());
        }
        pending.extend_from_slice(&buf[..n as usize]);
        while let Some(pos) = pending.iter().position(|b| *b == b'\n') {
            let line = pending.drain(..=pos).collect::<Vec<_>>();
            let line = String::from_utf8_lossy(&line);
            let (response, shutdown) =
                dispatch_request(parse_request(line.trim()), router, capabilities)?;
            if let Some(response) = response {
                let mut out = serde_json::to_vec(&response)?;
                out.push(b'\n');
                let mut written = 0;
                if unsafe {
                    WriteFile(
                        handle,
                        out.as_ptr().cast(),
                        out.len() as u32,
                        &mut written,
                        ptr::null_mut(),
                    )
                } == 0
                {
                    return Err(io::Error::last_os_error());
                }
            }
            if shutdown {
                stopping.store(true, Ordering::Release);
                wake_listener();
                return Ok(());
            }
        }
    }
}

fn dispatch_request(
    parsed: Result<JsonRpcRequest, axon_core::JsonRpcResponse>,
    router: &Arc<Mutex<Router<WindowsBackend>>>,
    capabilities: &[axon_core::CapabilityInfo],
) -> io::Result<(Option<axon_core::JsonRpcResponse>, bool)> {
    Ok(dispatch_with(parsed, capabilities, |request| {
        if matches!(
            request.method.as_str(),
            "wait_for_value" | "wait_for_stability"
        ) {
            poll_wait_request(request, |poll| router.lock().unwrap().request(poll))
        } else {
            router.lock().unwrap().request(request)
        }
    }))
}

fn dispatch_with(
    parsed: Result<JsonRpcRequest, axon_core::JsonRpcResponse>,
    capabilities: &[axon_core::CapabilityInfo],
    request: impl FnOnce(JsonRpcRequest) -> Option<axon_core::JsonRpcResponse>,
) -> (Option<axon_core::JsonRpcResponse>, bool) {
    let shutdown = matches!(&parsed, Ok(req) if req.method == "shutdown" && req.id.is_some());
    let response = match parsed {
        // Lifecycle requests deliberately bypass the per-connection router.
        Ok(req) if req.method == "health" => req.id.map(|id| {
            axon_core::JsonRpcResponse::success(
                id,
                serde_json::to_value(crate::lifecycle::daemon_report(
                    std::process::id(),
                    capabilities,
                    crate::lifecycle::current_session(),
                ))
                .unwrap_or(Value::Null),
            )
        }),
        Ok(req) if shutdown => req.id.map(|id| {
            axon_core::JsonRpcResponse::success(
                id,
                json!({"shutdown": true, "processId": std::process::id()}),
            )
        }),
        Ok(req) => request(req),
        Err(error) => Some(error),
    };
    (response, shutdown)
}

pub fn shutdown() -> io::Result<u32> {
    let (tx, rx) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let _ = tx.send(shutdown_rpc());
    });
    rx.recv_timeout(Duration::from_secs(35)).map_err(|error| {
        io::Error::new(
            io::ErrorKind::TimedOut,
            format!("daemon shutdown RPC timed out: {error}"),
        )
    })?
}

fn shutdown_rpc() -> io::Result<u32> {
    let response = send_rpc(&JsonRpcRequest::new(
        Some(JsonRpcId::Integer(1)),
        "shutdown",
        Some(json!({})),
    ))?;
    response
        .pointer("/result/processId")
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .ok_or_else(|| io::Error::other(format!("daemon rejected shutdown: {response}")))
}

/// Waits for a successful health round trip.
///
/// A pipe that exists proves only that some process created it, which is exactly what a
/// half-started daemon leaves behind. Answering is the readiness contract.
pub fn wait_until_ready(timeout: Duration) -> io::Result<axon_core::DaemonReport> {
    wait_until_ready_with(timeout, Arc::new(daemon_health))
}

fn wait_until_ready_with<T: Send + 'static>(
    timeout: Duration,
    health: Arc<dyn Fn() -> io::Result<T> + Send + Sync>,
) -> io::Result<T> {
    let start = Instant::now();
    loop {
        let Some(remaining) = timeout.checked_sub(start.elapsed()) else {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "daemon did not become ready to serve requests",
            ));
        };
        let (tx, rx) = mpsc::sync_channel(1);
        let health = Arc::clone(&health);
        thread::spawn(move || {
            let _ = tx.send(health());
        });
        match rx.recv_timeout(remaining) {
            Ok(Ok(value)) => return Ok(value),
            Ok(Err(_)) => thread::sleep(Duration::from_millis(50).min(remaining)),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "daemon did not become ready to serve requests",
                ));
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err(io::Error::other("daemon health check worker stopped"));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn blocking_wait_does_not_starve_another_non_lifecycle_request() {
        let (entered_tx, entered_rx) = mpsc::sync_channel(0);
        let (release_tx, release_rx) = mpsc::sync_channel(0);
        let waiting = thread::spawn(move || {
            let wait = JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                "wait_for_value",
                Some(json!({})),
            );
            dispatch_with(Ok(wait), &[], |request| {
                assert_eq!(request.method, "wait_for_value");
                entered_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                request.id.map(|id| {
                    axon_core::JsonRpcResponse::success(id, json!({"outcome":"satisfied"}))
                })
            })
        });
        entered_rx.recv().unwrap();

        let (done_tx, done_rx) = mpsc::sync_channel(0);
        thread::spawn(move || {
            let look = JsonRpcRequest::new(
                Some(JsonRpcId::Integer(2)),
                "look",
                Some(json!({"app":"Editor"})),
            );
            let result = dispatch_with(Ok(look), &[], |request| {
                request
                    .id
                    .map(|id| axon_core::JsonRpcResponse::success(id, json!({"app":"Editor"})))
            });
            done_tx.send(result).unwrap();
        });

        let (response, shutdown) = done_rx
            .recv_timeout(Duration::from_millis(250))
            .expect("a second non-lifecycle connection must finish while the wait is blocked");
        assert!(response.is_some());
        assert!(!shutdown);
        release_tx.send(()).unwrap();
        assert!(waiting.join().unwrap().0.is_some());
    }

    #[test]
    fn lifecycle_requests_bypass_connection_routers() {
        let health = JsonRpcRequest::new(Some(JsonRpcId::Integer(2)), "health", Some(json!({})));
        let (response, shutdown) = dispatch_with(Ok(health), &[], |_| {
            panic!("health must not reach a connection router")
        });
        assert!(response.is_some());
        assert!(!shutdown);

        let stop = JsonRpcRequest::new(Some(JsonRpcId::Integer(3)), "shutdown", Some(json!({})));
        let (response, shutdown) = dispatch_with(Ok(stop), &[], |_| {
            panic!("shutdown must not reach a connection router")
        });
        assert!(response.is_some());
        assert!(shutdown);
    }

    #[test]
    fn readiness_requires_a_successful_health_response() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let observed = Arc::clone(&attempts);
        wait_until_ready_with(
            Duration::from_secs(1),
            Arc::new(move || {
                if observed.fetch_add(1, Ordering::SeqCst) == 0 {
                    Err(io::Error::other("not ready"))
                } else {
                    Ok(())
                }
            }),
        )
        .unwrap();
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn readiness_deadline_bounds_a_silent_health_check() {
        let started = Instant::now();
        let error = wait_until_ready_with(
            Duration::from_millis(25),
            Arc::new(|| {
                thread::sleep(Duration::from_secs(1));
                Ok(())
            }),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_millis(250));
    }

    #[test]
    fn readiness_refuses_a_daemon_that_answers_without_being_ready() {
        // The AXN-45 distinction, kept: a pipe that answers is not the same as a backend that
        // finished starting, and only the second one may satisfy a lifecycle command.
        let unready = json!({"result": {
            "version": "0.1.7", "platform": "windows", "ready": false, "processId": 1,
            "endpoint": r"\\.\pipe\axon-v1",
            "session": {"interactive": true, "graphical": true},
            "permissions": [], "capabilities": []
        }});
        let report: axon_core::DaemonReport =
            serde_json::from_value(unready["result"].clone()).unwrap();

        assert!(!report.ready);
    }
}

/// Asks the running daemon to describe itself.
pub fn daemon_health() -> io::Result<axon_core::DaemonReport> {
    let response = send_rpc(&JsonRpcRequest::new(
        Some(JsonRpcId::Integer(1)),
        "health",
        Some(json!({})),
    ))?;
    let result = response
        .get("result")
        .cloned()
        .ok_or_else(|| io::Error::other(format!("daemon rejected health check: {response}")))?;
    // InvalidData rather than a generic error: a daemon that answers unintelligibly is a
    // running daemon of another version, and the caller reports that differently from silence.
    let report: axon_core::DaemonReport = serde_json::from_value(result)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if report.ready {
        Ok(report)
    } else {
        Err(io::Error::other("daemon is not ready to serve requests"))
    }
}

pub fn is_daemon_absent(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(2 | 3))
}

pub fn is_unresponsive_daemon(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::TimedOut
            | io::ErrorKind::BrokenPipe
            | io::ErrorKind::UnexpectedEof
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::ConnectionReset
    )
}

fn send_rpc(request: &JsonRpcRequest) -> io::Result<Value> {
    let start = Instant::now();
    let mut stream = loop {
        match OpenOptions::new().read(true).write(true).open(PIPE) {
            Ok(stream) => break stream,
            Err(error)
                if error.raw_os_error() == Some(231)
                    && start.elapsed() < Duration::from_secs(10) =>
            {
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => return Err(error),
        }
    };
    writeln!(stream, "{}", serde_json::to_string(request)?)?;
    stream.flush()?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    Ok(serde_json::from_str(&line)?)
}

pub fn mcp() -> io::Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    for line in stdin.lock().lines() {
        let line = line?;
        let input: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                writeln!(
                    stdout,
                    "{}",
                    json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":e.to_string()}})
                )?;
                continue;
            }
        };
        let id = input.get("id").cloned().unwrap_or(Value::Null);
        let method = input.get("method").and_then(Value::as_str).unwrap_or("");
        let output = match method {
            "initialize" => {
                json!({"jsonrpc":"2.0","id":id,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"axon-win","version":env!("CARGO_PKG_VERSION")}}})
            }
            "tools/list" => tool_list_response(id, backend_tools(ToolBackend::Windows)),
            "tools/call" => forward(&input)?,
            _ => {
                if input.get("id").is_none() {
                    continue;
                } else {
                    json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":format!("unknown MCP method {method}")}})
                }
            }
        };
        writeln!(stdout, "{output}")?;
        stdout.flush()?;
    }
    Ok(())
}
fn forward(input: &Value) -> io::Result<Value> {
    forward_with_request(input, send_rpc)
}
fn forward_with_request(
    input: &Value,
    mut send: impl FnMut(&JsonRpcRequest) -> io::Result<Value>,
) -> io::Result<Value> {
    let id = input.get("id").cloned().unwrap_or(Value::Null);
    let call = match validate_tools_call(ToolBackend::Windows, input.get("params").cloned()) {
        Ok(call) => call,
        Err(error) => return Ok(json!({"jsonrpc":"2.0","id":id,"error":error})),
    };
    let rpc = JsonRpcRequest::new(
        Some(JsonRpcId::Integer(1)),
        call.socket_method,
        Some(call.arguments),
    );
    let response = send(&rpc)?;
    if let Some(error) = response.get("error") {
        Ok(
            json!({"jsonrpc":"2.0","id":id,"result":{"content":[{"type":"text","text":error.get("message").and_then(Value::as_str).unwrap_or("Axon error")}],"structuredContent":error,"isError":true}}),
        )
    } else {
        let result = response.get("result").cloned().unwrap_or(Value::Null);
        Ok(success_response(id, result))
    }
}
fn success_response(id: Value, result: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"result":axon_core::mcp_tool_result(result, false)})
}
fn tool_list_response(id: Value, tools: Result<Vec<Value>, axon_core::JsonRpcError>) -> Value {
    match tools {
        Ok(tools) => json!({"jsonrpc":"2.0","id":id,"result":{"tools":tools}}),
        Err(error) => json!({"jsonrpc":"2.0","id":id,"error":error}),
    }
}

#[cfg(test)]
mod facade_tests {
    use super::*;

    #[test]
    fn facade_matches_shared_observation_envelope() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../schema/fixtures/mcp-look-observation-envelope.json"
        ))
        .unwrap();
        assert_eq!(
            success_response(json!(1), fixture["structuredContent"].clone())["result"],
            fixture["result"]
        );
    }
    #[test]
    fn facade_accepts_protocol_metadata_without_forwarding_it() {
        let response = forward_with_request(
            &json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"look","arguments":{},"_meta":{"progressToken":"p1"}}}),
            |request| {
                let forwarded = serde_json::to_value(request).unwrap();
                assert!(forwarded["params"].get("_meta").is_none());
                Ok(json!({"jsonrpc":"2.0","id":1,"result":{"ok":true}}))
            },
        )
        .unwrap();
        assert_eq!(response["result"]["isError"], false);
    }
}
