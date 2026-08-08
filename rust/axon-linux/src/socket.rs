//! The daemon's local transport: the server that owns the socket, the client that speaks to it,
//! and the MCP stdio facade layered over that client.
//!
//! One connection carries exactly one line-delimited JSON-RPC request and one line-delimited
//! response. Nothing about a connection outlives it.

use axon_core::{JsonRpcId, JsonRpcRequest, health::DaemonReport};
use serde_json::{Value, json};
use std::{
    io::{self, BufRead, BufReader, Write},
    os::unix::net::{UnixListener, UnixStream},
    path::PathBuf,
    time::{Duration, Instant},
};

#[cfg(target_os = "linux")]
use crate::{
    LinuxBackend, Router,
    lifecycle::{SessionEnvironment, daemon_report},
    parse_request,
};
#[cfg(target_os = "linux")]
use axon_core::{CapabilityInfo, JsonRpcResponse, PlatformBackend};
#[cfg(target_os = "linux")]
use std::{fs, os::unix::fs::PermissionsExt};

/// How long the daemon gives a connected client to send its request.
///
/// The daemon answers one connection at a time, so a client that connects and then says nothing
/// would hold the entire session hostage. Every Axon client writes its request immediately on
/// connecting, so this bound is only ever reached by a client that has stopped participating.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// How many accept failures in a row mean the listener is broken rather than unlucky.
const ACCEPT_FAILURE_LIMIT: usize = 16;

pub fn path() -> io::Result<PathBuf> {
    let dir = std::env::var_os("XDG_RUNTIME_DIR")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is not set"))?;
    Ok(PathBuf::from(dir).join("axon-v1.sock"))
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
    serde_json::from_value(result).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
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
    mut handle: impl FnMut(&str) -> (Value, bool),
) -> io::Result<()> {
    let mut failures = 0usize;
    for incoming in listener.incoming() {
        let stream = match incoming {
            Ok(stream) => {
                failures = 0;
                stream
            }
            // An accept can fail for reasons that belong to the connection being accepted: a
            // client that gave up while queued, an interrupted syscall, a momentarily exhausted
            // descriptor table. Retrying is right. An unbroken run of failures is a different
            // claim -- the listener can no longer produce connections at all -- and spinning on
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
        match answer(stream, request_timeout, &mut handle) {
            Ok(true) => return Ok(()),
            Ok(false) => {}
            Err(error) => eprintln!("axon-linux: dropped a client connection: {error}"),
        }
    }
    Ok(())
}

/// Reads one request, answers it, and reports whether that request asked the daemon to stop.
fn answer(
    mut stream: UnixStream,
    request_timeout: Duration,
    handle: &mut impl FnMut(&str) -> (Value, bool),
) -> io::Result<bool> {
    // The deadline is a guard, not a precondition. A client that closed before the daemon reached
    // this line can leave the socket in a state that refuses the option (macOS answers EINVAL)
    // while its request sits in the receive buffer, already arrived and still owed an attempt.
    // Failing the connection over an unset option would discard a request the daemon has in hand.
    let _ = stream.set_read_timeout(Some(request_timeout));
    let mut line = String::new();
    // A connection that closes without sending anything asked nothing, so there is nothing to
    // answer and nothing to report: this is what a liveness probe looks like from in here.
    if BufReader::new(stream.try_clone()?).read_line(&mut line)? == 0 {
        return Ok(false);
    }
    let (response, stop) = handle(line.trim());
    // The request was received and carried out. A client that is no longer there to read the
    // answer changes nothing about that, so the answer's fate is reported rather than propagated,
    // and a `shutdown` whose caller walked away still shuts the daemon down.
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
    // Captured once: the backend's capability list describes the build, not the moment, and
    // rebuilding it per request would add an AT-SPI round trip to every health check.
    let reported: Vec<CapabilityInfo> = backend.capabilities().unwrap_or_default();
    let mut router = Router::new(backend);

    let listener = UnixListener::bind(&path)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    let endpoint = path.display().to_string();
    let result = serve_connections(&listener, REQUEST_TIMEOUT, |line| {
        dispatch(line, &mut router, &reported, &endpoint)
    });
    let _ = fs::remove_file(path);
    result
}

/// Routes one request, answering `health` and `shutdown` here and everything else through the
/// backend router.
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
    match request.method.as_str() {
        "health" => {
            let report = daemon_report(
                endpoint.to_owned(),
                std::process::id(),
                reported,
                &SessionEnvironment::from_env(),
                true,
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
    let Some(id) = value.get("id").cloned() else {
        return Ok(None);
    };
    let response = match value.get("method").and_then(Value::as_str) {
        Some("initialize") => {
            json!({"jsonrpc":"2.0","id":id,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"axon-linux","version":env!("CARGO_PKG_VERSION")}}})
        }
        Some("tools/list") => json!({"jsonrpc":"2.0","id":id,"result":{"tools": tools()}}),
        Some("tools/call") => {
            let p = &value["params"];
            let name = p["name"].as_str().unwrap_or("");
            let args = p.get("arguments").cloned().unwrap_or(json!({}));
            let rpc = serde_json::to_string(&JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                name,
                Some(args),
            ))
            .unwrap();
            match request(&rpc) {
                Ok(body) => {
                    let response: Value = serde_json::from_str(&body).map_err(io::Error::other)?;
                    if let Some(error) = response.get("error") {
                        json!({"jsonrpc":"2.0","id":id,"result":{"content":[{"type":"text","text":error.get("message").and_then(Value::as_str).unwrap_or("Axon error")}],"structuredContent":error,"isError":true}})
                    } else {
                        let result = response.get("result").cloned().unwrap_or(Value::Null);
                        json!({"jsonrpc":"2.0","id":id,"result":{"content":[{"type":"text","text":serde_json::to_string(&result).unwrap()}],"structuredContent":result,"isError":false}})
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

fn tools() -> Vec<Value> {
    ["look", "find", "invoke", "type", "scroll", "run"]
        .into_iter()
        .map(|name| {
            json!({"name":name,"description":format!("Axon Linux {name}"),"inputSchema":{"type":"object","additionalProperties":true}})
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn socket_lives_in_private_runtime_directory() {
        unsafe {
            std::env::set_var("XDG_RUNTIME_DIR", "/run/user/123");
        }
        assert_eq!(path().unwrap(), PathBuf::from("/run/user/123/axon-v1.sock"));
    }
    #[test]
    fn facade_exposes_supported_surface() {
        let names = tools()
            .into_iter()
            .map(|v| v["name"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        assert!(names.contains(&"invoke".into()));
        assert!(!names.contains(&"drag".into()));
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
}
