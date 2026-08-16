//! The daemon's local transport: the server that owns the socket, the client that speaks to it,
//! and the MCP stdio facade layered over that client.
//!
//! One connection carries exactly one line-delimited JSON-RPC request and one line-delimited
//! response. Nothing about a connection outlives it.

use axon_core::{
    JsonRpcId, JsonRpcRequest, ToolBackend, backend_tools, health::DaemonReport,
    validate_tools_call,
};
use serde_json::{Value, json};
use std::{
    io::{self, BufRead, BufReader, Write},
    os::unix::net::{UnixListener, UnixStream},
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

#[cfg(target_os = "linux")]
use crate::{
    LinuxBackend, Router,
    lifecycle::{SessionEnvironment, daemon_report},
    parse_request,
};
#[cfg(target_os = "linux")]
use axon_core::{CapabilityInfo, JsonRpcResponse, PlatformBackend, poll_wait_request};
#[cfg(target_os = "linux")]
use std::{fs, os::unix::fs::PermissionsExt, sync::Mutex};

/// How long the daemon waits on a client that has stopped participating, in either direction.
///
/// Client connections are independent, so this bound contains a client that stops participating
/// without delaying unrelated requests.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// How many accept failures in a row mean the listener is broken rather than unlucky.
const ACCEPT_FAILURE_LIMIT: usize = 16;

pub fn path() -> io::Result<PathBuf> {
    let dir = std::env::var_os("XDG_RUNTIME_DIR")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is not set"))?;
    Ok(PathBuf::from(dir).join("axon-v1.sock"))
}

#[cfg(target_os = "linux")]
fn dispatch_shared(
    line: &str,
    router: &Arc<Mutex<Router<LinuxBackend>>>,
    reported: &[CapabilityInfo],
    endpoint: &str,
) -> (Value, bool) {
    let Ok(request) = parse_request(line) else {
        return dispatch(line, &mut router.lock().unwrap(), reported, endpoint);
    };
    if request.method == "capture_screen" {
        let capture = router.lock().unwrap().backend().screen_capture_handle();
        return dispatch_capture(request, capture);
    }
    if matches!(
        request.method.as_str(),
        "wait_for_value" | "wait_for_stability"
    ) {
        let response = poll_wait_request(request, |poll| router.lock().unwrap().request(poll));
        (
            response
                .map(|r| serde_json::to_value(r).unwrap())
                .unwrap_or(Value::Null),
            false,
        )
    } else {
        dispatch(line, &mut router.lock().unwrap(), reported, endpoint)
    }
}

#[cfg(target_os = "linux")]
fn dispatch_capture(
    request: JsonRpcRequest,
    capture: Option<crate::platform::ScreenCaptureProvider>,
) -> (Value, bool) {
    dispatch_capture_with(request, move |reauthorize| {
        capture
            .ok_or_else(|| crate::screencast::CaptureError::Unavailable(
                "capture_screen is available only in a Wayland session; use look screenshot for application-targeted X11 capture".into(),
            ))
            .and_then(|provider| provider.capture(reauthorize))
    })
}

#[cfg(target_os = "linux")]
fn dispatch_capture_with(
    request: JsonRpcRequest,
    capture: impl FnOnce(
        bool,
    )
        -> Result<crate::screencast::ScreenCapture, crate::screencast::CaptureError>,
) -> (Value, bool) {
    let Some(id) = request.id else {
        return (Value::Null, false);
    };
    let params = request.params.as_ref().and_then(Value::as_object);
    let invalid = request
        .params
        .as_ref()
        .is_some_and(|value| !value.is_object())
        || params.is_some_and(|values| values.keys().any(|key| key != "reauthorize"))
        || params
            .and_then(|values| values.get("reauthorize"))
            .is_some_and(|value| !value.is_boolean());
    if invalid {
        return (
            serde_json::to_value(JsonRpcResponse::failure(
                id,
                axon_core::JsonRpcError {
                    code: -32602,
                    message: "capture_screen accepts only optional boolean reauthorize".into(),
                    data: Some(json!({"path":"params"})),
                },
            ))
            .unwrap(),
            false,
        );
    }
    let reauthorize = params
        .and_then(|values| values.get("reauthorize"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let response = match capture(reauthorize) {
        Ok(capture) => JsonRpcResponse::success(id, json!({"capture": capture})),
        Err(crate::screencast::CaptureError::AuthorizationRequired | crate::screencast::CaptureError::TimedOut) =>
            JsonRpcResponse::failure(id, axon_core::JsonRpcError { code: -32004, message: "desktop portal authorization is required; retry capture_screen and approve the desktop chooser".into(), data: Some(json!({"reason":"portal-authorization-required","capability":"screenCapture"})) }),
        Err(crate::screencast::CaptureError::Unavailable(reason)) =>
            JsonRpcResponse::failure(id, axon_core::JsonRpcError { code: -32004, message: reason, data: Some(json!({"reason":"capability-unavailable","capability":"screenCapture"})) }),
        Err(crate::screencast::CaptureError::Failed(reason)) =>
            JsonRpcResponse::failure(id, axon_core::JsonRpcError { code: -32003, message: reason, data: Some(json!({"reason":"capture-failed","capability":"screenCapture"})) }),
        Err(crate::screencast::CaptureError::NoFrame) =>
            JsonRpcResponse::failure(id, axon_core::JsonRpcError { code: -32003, message: "the ScreenCast session did not produce a frame".into(), data: Some(json!({"reason":"capture-failed","capability":"screenCapture"})) }),
    };
    (serde_json::to_value(response).unwrap(), false)
}

fn mcp_success_response(id: Value, result: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"result":axon_core::mcp_tool_result(result, false)})
}

pub fn endpoint() -> String {
    path()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|_| "$XDG_RUNTIME_DIR/axon-v1.sock".into())
}

pub fn request(line: &str) -> io::Result<String> {
    let mut stream = UnixStream::connect(path()?)?;
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    stream.write_all(line.as_bytes())?;
    stream.write_all(b"\n")?;
    let mut response = String::new();
    BufReader::new(stream).read_line(&mut response)?;
    Ok(response)
}

fn rpc(method: &str) -> io::Result<Value> {
    let body = request(&serde_json::to_string(&JsonRpcRequest::new(
        Some(JsonRpcId::Integer(1)),
        method,
        Some(json!({})),
    ))?)?;
    serde_json::from_str(&body).map_err(io::Error::other)
}

/// Asks the running daemon to describe itself.
pub fn daemon_health() -> io::Result<DaemonReport> {
    let response = rpc("health")?;
    let result = response
        .get("result")
        .cloned()
        .ok_or_else(|| io::Error::other(format!("daemon rejected health: {response}")))?;
    // InvalidData rather than a generic error: a daemon that answers unintelligibly is a
    // running daemon of another version, and the caller reports that differently from silence.
    serde_json::from_value(result)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

/// Waits for a successful health round trip.
///
/// A socket that exists proves only that some process bound it, which is exactly what a
/// half-started daemon leaves behind. Answering is the readiness contract.
pub fn wait_until_ready(timeout: Duration) -> io::Result<DaemonReport> {
    let start = Instant::now();
    let mut last = io::Error::other("daemon never answered");
    while start.elapsed() < timeout {
        match daemon_health() {
            Ok(report) => return Ok(report),
            Err(error) => {
                last = error;
                std::thread::sleep(Duration::from_millis(50));
            }
        }
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!("daemon did not become ready: {last}"),
    ))
}

/// Whether an error means nothing is listening, as opposed to something listening badly.
///
/// Only the first is an already-reached end state; the second is a daemon that must be dealt
/// with rather than reported as absent.
pub fn is_daemon_absent(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
    )
}

fn is_absent() -> bool {
    match path() {
        Ok(path) => UnixStream::connect(path).is_err(),
        Err(_) => true,
    }
}

pub fn wait_until_absent(timeout: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if is_absent() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    is_absent()
}

pub fn shutdown_rpc() -> io::Result<u32> {
    let response = rpc("shutdown")?;
    response
        .pointer("/result/processId")
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .ok_or_else(|| io::Error::other(format!("daemon rejected shutdown: {response}")))
}

/// Serves one request per connection until a request asks the daemon to stop.
///
/// Every failure that belongs to a single client is contained here. A client may hang up at any
/// moment, including between sending its request and reading the answer, and none of that is the
/// daemon's to die of: that connection ends and the loop goes on. The daemon leaves this loop
/// only when a request asks it to, or when the listener itself stops producing connections.
///
/// `request_timeout` bounds the wait for a connected client's request; the daemon passes
/// [`REQUEST_TIMEOUT`], and a test passes something it is willing to wait for.
pub fn serve_connections(
    listener: &UnixListener,
    request_timeout: Duration,
    make_handle: impl Fn() -> Box<dyn FnMut(&str) -> (Value, bool) + Send> + Send + Sync,
) -> io::Result<()> {
    listener.set_nonblocking(true)?;
    let stopping = Arc::new(AtomicBool::new(false));
    let mut failures = 0usize;
    while !stopping.load(Ordering::Acquire) {
        let stream = match listener.accept() {
            Ok((stream, _)) => {
                failures = 0;
                stream
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10));
                continue;
            }
            // An accept can fail for reasons that belong to the connection being accepted: a
            // client that gave up while queued, an interrupted syscall, a momentarily exhausted
            // descriptor table. Retrying is right. An unbroken run of failures is a different
            // claim — the listener can no longer produce connections at all — and spinning on
            // that would burn a core while serving nobody, so it is reported to the supervisor.
            Err(error) => {
                failures += 1;
                eprintln!("axon-linux: accept failed: {error}");
                if failures >= ACCEPT_FAILURE_LIMIT {
                    return Err(error);
                }
                continue;
            }
        };
        let mut handle = make_handle();
        let stopping = Arc::clone(&stopping);
        thread::spawn(move || match answer(stream, request_timeout, &mut handle) {
            Ok(true) => stopping.store(true, Ordering::Release),
            Ok(false) => {}
            Err(error) => eprintln!("axon-linux: dropped a client connection: {error}"),
        });
    }
    Ok(())
}

/// Reads one request, answers it, and reports whether that request asked the daemon to stop.
fn answer(
    mut stream: UnixStream,
    request_timeout: Duration,
    handle: &mut impl FnMut(&str) -> (Value, bool),
) -> io::Result<bool> {
    // Both directions are bounded, because a client stops participating in two ways: it can go
    // quiet before asking, and it can stop draining the answer it asked for. The second is the
    // less obvious and the more expensive — a socket buffer holds a couple of hundred kilobytes
    // and a `look` at a real application exceeds that, so an undrained answer parks the daemon
    // inside one write while the whole session waits behind it.
    //
    // These are per-syscall bounds, not a deadline on the exchange: a client dribbling a byte at
    // a time stays under them indefinitely. That is a far stranger client than a stalled one, and
    // bounding it would mean a total-deadline machine this transport does not otherwise need.
    //
    // Each is a guard rather than a precondition. A client that closed before the daemon reached
    // this line can leave the socket in a state that refuses the option (macOS answers EINVAL)
    // while its request sits in the receive buffer, already arrived and still owed an attempt.
    // Failing the connection over an unset option would discard a request the daemon has in hand.
    let _ = stream.set_read_timeout(Some(request_timeout));
    let _ = stream.set_write_timeout(Some(request_timeout));
    let mut line = String::new();
    // A connection that closes without sending anything asked nothing, so there is nothing to
    // answer and nothing to report: this is what a liveness probe looks like from in here.
    if BufReader::new(stream.try_clone()?).read_line(&mut line)? == 0 {
        return Ok(false);
    }
    let (response, stop) = handle(line.trim());
    // The request was received and carried out. A client that is no longer there to read the
    // answer, or no longer willing to, changes nothing about that, so the answer's fate is
    // reported rather than propagated, and a `shutdown` whose caller walked away still shuts the
    // daemon down.
    if let Err(error) = writeln!(stream, "{}", serde_json::to_string(&response).unwrap()) {
        eprintln!("axon-linux: client hung up before its answer was written: {error}");
    }
    Ok(stop)
}

#[cfg(target_os = "linux")]
pub fn serve() -> io::Result<()> {
    let path = path()?;
    if path.exists() {
        match UnixStream::connect(&path) {
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    "Axon daemon is already running",
                ));
            }
            Err(_) => fs::remove_file(&path)?,
        }
    }
    let backend = LinuxBackend::start().map_err(|error| io::Error::other(error.to_string()))?;
    // Cache build/static capabilities. Health replaces screenshot from the session-specific X11
    // provider; the separate ScreenCast operation never makes app-scoped screenshot health green.
    let reported: Vec<CapabilityInfo> = backend.capabilities().unwrap_or_default();
    let listener = UnixListener::bind(&path)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    let endpoint = path.display().to_string();
    let router = Arc::new(Mutex::new(Router::new(backend)));
    let result = serve_connections(&listener, REQUEST_TIMEOUT, move || {
        let router = Arc::clone(&router);
        let reported = reported.clone();
        let endpoint = endpoint.clone();
        Box::new(move |line| dispatch_shared(line, &router, &reported, &endpoint))
    });
    let _ = fs::remove_file(path);
    result
}

#[cfg(target_os = "linux")]
fn merge_screenshot_capability(
    reported: &[CapabilityInfo],
    current: CapabilityInfo,
) -> Vec<CapabilityInfo> {
    reported
        .iter()
        .filter(|info| info.capability != axon_core::Capability::Screenshot)
        .cloned()
        .chain([current])
        .collect()
}

/// Routes one request, answering `health` and `shutdown` here and everything else through the
/// backend router.
///
/// Deliberately does not know how to serve `capture_screen`. This runs with `&mut Router` in
/// hand, so serving an interactive capture here would hold the router lock for the whole of it
/// and starve every other tool call behind a request that waits on a person. `dispatch_shared`
/// clones the capture provider out and releases the lock before capturing, which is the contract;
/// a second implementation that quietly broke it, reachable the moment routing changed, is worse
/// than no second implementation at all.
///
/// `shutdown` is an ordinary JSON-RPC method with an id and a reply, not a magic frame: a
/// lifecycle command learns which process it stopped from that reply, and cannot otherwise
/// tell a clean stop from a daemon that crashed while being asked.
#[cfg(target_os = "linux")]
fn dispatch(
    line: &str,
    router: &mut Router<LinuxBackend>,
    reported: &[CapabilityInfo],
    endpoint: &str,
) -> (Value, bool) {
    let request = match parse_request(line) {
        Ok(request) => request,
        Err(failure) => return (serde_json::to_value(failure).unwrap(), false),
    };
    let Some(id) = request.id.clone() else {
        return (Value::Null, false);
    };
    let method = request.method.clone();
    match method.as_str() {
        "health" => {
            let capabilities =
                merge_screenshot_capability(reported, router.backend().screenshot_capability());
            let report = daemon_report(
                endpoint.to_owned(),
                std::process::id(),
                &capabilities,
                &SessionEnvironment::from_env(),
                true,
                // Asked per request rather than captured with the capability list beside it: the
                // capability list describes this build, and this describes the session right now.
                router.backend().accessibility_enabled(),
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
                json!({"shutdown": true, "processId": std::process::id()}),
            ))
            .unwrap(),
            true,
        ),
        _ => (
            router
                .request(request)
                .map(|response| serde_json::to_value(response).unwrap())
                .unwrap_or(Value::Null),
            false,
        ),
    }
}

pub fn mcp() -> io::Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    for line in stdin.lock().lines() {
        let line = line?;
        let value: Value = serde_json::from_str(&line).map_err(io::Error::other)?;
        let Some(response) = mcp_response(&value)? else {
            continue;
        };
        writeln!(stdout, "{}", serde_json::to_string(&response).unwrap())?;
        stdout.flush()?;
    }
    Ok(())
}

fn mcp_response(value: &Value) -> io::Result<Option<Value>> {
    mcp_response_with_request(value, request)
}

pub(crate) fn mcp_response_with_request(
    value: &Value,
    mut send: impl FnMut(&str) -> io::Result<String>,
) -> io::Result<Option<Value>> {
    let Some(id) = value.get("id").cloned() else {
        return Ok(None);
    };
    let response = match value.get("method").and_then(Value::as_str) {
        Some("initialize") => {
            json!({"jsonrpc":"2.0","id":id,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"axon-linux","version":env!("CARGO_PKG_VERSION")}}})
        }
        Some("tools/list") => tools_response(id, backend_tools(ToolBackend::Linux)),
        Some("tools/call") => {
            let call = match validate_tools_call(ToolBackend::Linux, value.get("params").cloned()) {
                Ok(call) => call,
                Err(error) => {
                    return Ok(Some(json!({"jsonrpc":"2.0","id":id,"error":error})));
                }
            };
            let rpc = serde_json::to_string(&JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                call.socket_method,
                Some(call.arguments),
            ))
            .unwrap();
            match send(&rpc) {
                Ok(body) => {
                    let response: Value = serde_json::from_str(&body).map_err(io::Error::other)?;
                    if let Some(error) = response.get("error") {
                        json!({"jsonrpc":"2.0","id":id,"result":{"content":[{"type":"text","text":error.get("message").and_then(Value::as_str).unwrap_or("Axon error")}],"structuredContent":error,"isError":true}})
                    } else {
                        let result = response.get("result").cloned().unwrap_or(Value::Null);
                        mcp_success_response(id, result)
                    }
                }
                Err(e) => {
                    json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":e.to_string()}})
                }
            }
        }
        _ => {
            json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"method not found"}})
        }
    };
    Ok(Some(response))
}

fn tools_response(id: Value, tools: Result<Vec<Value>, axon_core::JsonRpcError>) -> Value {
    match tools {
        Ok(tools) => json!({"jsonrpc":"2.0","id":id,"result":{"tools":tools}}),
        Err(error) => json!({"jsonrpc":"2.0","id":id,"error":error}),
    }
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
    #[cfg(target_os = "linux")]
    #[test]
    fn health_merges_mutable_screenshot_state_false_true_false() {
        use axon_core::Capability;
        let cached = vec![CapabilityInfo {
            capability: Capability::Enumerate,
            usable: true,
            restriction: None,
        }];
        for usable in [false, true, false] {
            let merged = merge_screenshot_capability(
                &cached,
                CapabilityInfo {
                    capability: Capability::Screenshot,
                    usable,
                    restriction: (!usable).then(|| "authorization required".into()),
                },
            );
            let screenshot = merged
                .iter()
                .find(|info| info.capability == Capability::Screenshot)
                .unwrap();
            assert_eq!(screenshot.usable, usable);
            assert_eq!(
                merged
                    .iter()
                    .filter(|info| info.capability == Capability::Screenshot)
                    .count(),
                1
            );
        }
    }

    #[test]
    fn socket_lives_in_private_runtime_directory() {
        unsafe {
            std::env::set_var("XDG_RUNTIME_DIR", "/run/user/123");
        }
        assert_eq!(path().unwrap(), PathBuf::from("/run/user/123/axon-v1.sock"));
    }
    #[test]
    fn facade_exposes_supported_surface() {
        let tools = backend_tools(ToolBackend::Linux).unwrap();
        let names = tools
            .iter()
            .map(|v| v["name"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        assert!(names.contains(&"invoke".into()));
        let capture = tools
            .iter()
            .find(|tool| tool["name"] == "capture_screen")
            .unwrap();
        assert_eq!(
            capture["inputSchema"]["properties"]["reauthorize"]["default"],
            false
        );
        assert!(!names.contains(&"drag".into()));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn capture_validation_precedes_backend_and_defaults_reauthorize_false() {
        let invalid = JsonRpcRequest::new(
            Some(JsonRpcId::Integer(1)),
            "capture_screen",
            Some(json!({"reauthorize":"yes"})),
        );
        let response = dispatch_capture_with(invalid, |_| {
            panic!("invalid capture request reached backend")
        })
        .0;
        assert_eq!(response["error"]["code"], -32602);

        let valid = JsonRpcRequest::new(
            Some(JsonRpcId::Integer(2)),
            "capture_screen",
            Some(json!({})),
        );
        let response = dispatch_capture_with(valid, |reauthorize| {
            assert!(!reauthorize);
            Err(crate::screencast::CaptureError::AuthorizationRequired)
        })
        .0;
        assert_eq!(
            response["error"]["data"]["reason"],
            "portal-authorization-required"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn capture_errors_have_stable_reason_codes_and_x11_remediation() {
        for (error, reason) in [
            (
                crate::screencast::CaptureError::Unavailable(
                    "use look screenshot for application-targeted X11 capture".into(),
                ),
                "capability-unavailable",
            ),
            (
                crate::screencast::CaptureError::Failed("portal failed".into()),
                "capture-failed",
            ),
            (crate::screencast::CaptureError::NoFrame, "capture-failed"),
        ] {
            let request = JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                "capture_screen",
                Some(json!({})),
            );
            let response = dispatch_capture_with(request, |_| Err(error)).0;
            assert_eq!(response["error"]["data"]["reason"], reason);
            if reason == "capability-unavailable" {
                assert!(
                    response["error"]["message"]
                        .as_str()
                        .unwrap()
                        .contains("look")
                );
            }
        }
    }

    #[test]
    fn facade_forwards_capture_default_and_preserves_image_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../schema/fixtures/capture-screen-envelope.json"
        ))
        .unwrap();
        let response = mcp_response_with_request(
            &json!({"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"capture_screen","arguments":{}}}),
            |rpc| {
                let forwarded: Value = serde_json::from_str(rpc).unwrap();
                assert_eq!(forwarded["method"], "capture_screen");
                assert_eq!(forwarded["params"]["reauthorize"], false);
                Ok(json!({"jsonrpc":"2.0","id":1,"result":fixture["socketResult"]}).to_string())
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(response["result"], fixture["mcpResult"]);
    }
    #[test]
    fn tools_list_serializes_artifact_failures_as_internal_errors() {
        let response = tools_response(
            json!(4),
            Err(axon_core::JsonRpcError {
                code: -32603,
                message: "invalid embedded artifact".into(),
                data: None,
            }),
        );
        assert_eq!(response["id"], 4);
        assert_eq!(response["error"]["code"], -32603);
    }
    #[test]
    fn facade_rejects_invalid_calls_before_contacting_daemon() {
        let mut contacted = false;
        let response = mcp_response_with_request(
            &json!({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"look","arguments":{"bogus":true}}}),
            |_| {
                contacted = true;
                unreachable!("invalid calls must not reach the daemon")
            },
        )
        .unwrap()
        .unwrap();
        assert!(!contacted);
        assert_eq!(response["error"]["code"], -32602);
        assert_eq!(response["error"]["data"]["path"], "params.arguments.bogus");
    }
    #[test]
    fn facade_rejects_unadvertised_scroll_without_contacting_daemon() {
        let mut contacted = false;
        let response = mcp_response_with_request(
            &json!({"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"scroll","arguments":{"target":{"app":"App","name":"List"},"deltaY":-120}}}),
            |_| {
                contacted = true;
                unreachable!("unadvertised tools must not reach the daemon")
            },
        )
        .unwrap()
        .unwrap();

        assert!(!contacted);
        assert_eq!(response["error"]["code"], -32602);
        assert_eq!(response["error"]["data"]["path"], "params.name");
        assert_eq!(
            response["error"]["message"],
            "Invalid params at params.name: unknown or unavailable tool \"scroll\""
        );
    }
    #[test]
    fn facade_rejects_malformed_call_params_with_the_offending_key() {
        let response = mcp_response_with_request(
            &json!({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":3}}),
            |_| unreachable!("invalid calls must not reach the daemon"),
        )
        .unwrap()
        .unwrap();
        assert_eq!(response["error"]["code"], -32602);
        assert_eq!(response["error"]["data"]["path"], "params.name");
    }
    #[test]
    fn facade_forwards_normalized_arguments_without_flattening_target() {
        let target = json!({"app":"Notes","name":"Body"});
        let response = mcp_response_with_request(
            &json!({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"type","arguments":{"target":target,"value":"hello"}}}),
            |rpc| {
                let forwarded: Value = serde_json::from_str(rpc).unwrap();
                assert_eq!(forwarded["method"], "type");
                assert_eq!(forwarded["params"]["target"], target);
                assert_eq!(forwarded["params"]["deliveryPolicy"], "backgroundOnly");
                Ok(json!({"jsonrpc":"2.0","id":1,"result":{"ok":true}}).to_string())
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(response["result"]["structuredContent"], json!({"ok":true}));
        assert_eq!(response["result"]["isError"], false);
    }
    #[test]
    fn mcp_notifications_have_no_response() {
        let notification = json!({"jsonrpc":"2.0","method":"notifications/initialized"});
        assert!(mcp_response(&notification).unwrap().is_none());
    }
    #[test]
    fn the_facade_reports_the_product_version() {
        let response = mcp_response(&json!({"jsonrpc":"2.0","id":1,"method":"initialize"}))
            .unwrap()
            .unwrap();
        assert_eq!(
            response.pointer("/result/serverInfo/version").unwrap(),
            env!("CARGO_PKG_VERSION")
        );
    }
    #[test]
    fn facade_accepts_protocol_metadata_without_forwarding_it() {
        let response = mcp_response_with_request(
            &json!({"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"look","arguments":{},"_meta":{"progressToken":"p1"}}}),
            |rpc| {
                let forwarded: Value = serde_json::from_str(rpc).unwrap();
                assert!(forwarded["params"].get("_meta").is_none());
                Ok(json!({"jsonrpc":"2.0","id":1,"result":{"ok":true}}).to_string())
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(response["result"]["isError"], false);
    }
}
