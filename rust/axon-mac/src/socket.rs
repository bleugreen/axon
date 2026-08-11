//! Isolated Unix-socket daemon and MCP stdio facade for the Rust macOS backend.
//! The endpoint is mandatory and has no fallback to the installed Swift daemon.
use axon_core::{
    CapabilityInfo, CapabilityState, DaemonReport, HealthPlatform, JsonRpcId, JsonRpcRequest,
    JsonRpcResponse, PermissionState, PlatformBackend, SessionHealth, health::reason,
};
use axon_core::rpc::JsonRpcError;
use crate::{MacBackend, Router, parse_request};
use serde_json::{Value, json};
use std::{
    fs,
    io::{self, BufRead, BufReader, Write},
    os::unix::{fs::PermissionsExt, net::{UnixListener, UnixStream}},
    path::PathBuf,
    time::Duration,
};

pub const SOCKET_ENV: &str = "AXON_MAC_SOCKET";
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

pub fn path() -> io::Result<PathBuf> {
    let value = std::env::var_os(SOCKET_ENV)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("{SOCKET_ENV} must name an isolated socket")))?;
    let path = PathBuf::from(value);
    if path == PathBuf::from("/tmp/axon.sock") {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "the installed daemon socket is forbidden"));
    }
    Ok(path)
}
pub fn request(line: &str) -> io::Result<String> {
    let mut stream = UnixStream::connect(path()?)?;
    stream.set_read_timeout(Some(REQUEST_TIMEOUT))?;
    stream.write_all(line.as_bytes())?;
    stream.write_all(b"\n")?;
    let mut response = String::new();
    BufReader::new(stream).read_line(&mut response)?;
    Ok(response)
}
pub fn serve() -> io::Result<()> {
    let path = path()?;
    if path.exists() {
        if UnixStream::connect(&path).is_ok() {
            return Err(io::Error::new(io::ErrorKind::AddrInUse, "socket already has a listener"));
        }
        fs::remove_file(&path)?;
    }
    let backend = MacBackend::new().map_err(|e| io::Error::other(e.to_string()))?;
    let reported = backend.capabilities().unwrap_or_default();
    let trusted = backend.accessibility_enabled();
    let mut router = Router::new(backend);
    let listener = UnixListener::bind(&path)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    for incoming in listener.incoming() {
        let mut stream = incoming?;
        stream.set_read_timeout(Some(REQUEST_TIMEOUT))?;
        stream.set_write_timeout(Some(REQUEST_TIMEOUT))?;
        let mut line = String::new();
        if BufReader::new(stream.try_clone()?).read_line(&mut line)? == 0 { continue; }
        let (response, stop) = dispatch(line.trim(), &mut router, &reported, trusted, &path);
        writeln!(stream, "{}", serde_json::to_string(&response).unwrap())?;
        if stop { break; }
    }
    let _ = fs::remove_file(path);
    Ok(())
}
fn dispatch(line: &str, router: &mut Router<MacBackend>, reported: &[CapabilityInfo], trusted: bool, endpoint: &std::path::Path) -> (Value, bool) {
    let request = match parse_request(line) {
        Ok(v) => v,
        Err(v) => return (serde_json::to_value(v).unwrap(), false),
    };
    let Some(id) = request.id.clone() else { return (Value::Null, false) };
    match request.method.as_str() {
        "health" => {
            let permission = if trusted { PermissionState::granted("accessibility") } else {
                PermissionState::ungranted("accessibility", reason::ACCESSIBILITY_NOT_GRANTED, None)
            };
            let report = DaemonReport {
                version: env!("CARGO_PKG_VERSION").into(),
                platform: HealthPlatform::Macos,
                ready: trusted,
                process_id: std::process::id(),
                endpoint: endpoint.display().to_string(),
                session: SessionHealth::usable(None),
                permissions: vec![permission],
                capabilities: CapabilityState::complete(reported),
            };
            (serde_json::to_value(JsonRpcResponse::success(id, serde_json::to_value(report).unwrap())).unwrap(), false)
        }
        "shutdown" => (serde_json::to_value(JsonRpcResponse::success(id, json!({"shutdown":true,"processId":std::process::id()}))).unwrap(), true),
        _ => (router.request(request).map(|v| serde_json::to_value(v).unwrap()).unwrap_or(Value::Null), false),
    }
}
pub fn mcp() -> io::Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    for line in stdin.lock().lines() {
        let value: Value = serde_json::from_str(&line?).map_err(io::Error::other)?;
        let Some(id) = value.get("id").cloned() else { continue };
        let response = match value.get("method").and_then(Value::as_str) {
            Some("initialize") => json!({"jsonrpc":"2.0","id":id,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"axon-mac","version":env!("CARGO_PKG_VERSION")}}}),
            Some("tools/list") => json!({"jsonrpc":"2.0","id":id,"result":{"tools":tools()}}),
            Some("tools/call") => {
                let name = value.pointer("/params/name").and_then(Value::as_str).unwrap_or("");
                let args = value.pointer("/params/arguments").cloned().unwrap_or_else(|| json!({}));
                let rpc = serde_json::to_string(&JsonRpcRequest::new(Some(JsonRpcId::Integer(1)), name, Some(args))).unwrap();
                match request(&rpc) {
                    Ok(body) => {
                        let response: Value = serde_json::from_str(&body).map_err(io::Error::other)?;
                        if let Some(error) = response.get("error") {
                            json!({"jsonrpc":"2.0","id":id,"result":{"content":[{"type":"text","text":error["message"].as_str().unwrap_or("Axon error")}],"structuredContent":error,"isError":true}})
                        } else {
                            let result = response.get("result").cloned().unwrap_or(Value::Null);
                            json!({"jsonrpc":"2.0","id":id,"result":{"content":[{"type":"text","text":serde_json::to_string(&result).unwrap()}],"structuredContent":result,"isError":false}})
                        }
                    }
                    Err(error) => json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":error.to_string()}}),
                }
            }
            _ => json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"method not found"}}),
        };
        writeln!(stdout, "{}", serde_json::to_string(&response).unwrap())?;
        stdout.flush()?;
    }
    Ok(())
}
fn tools() -> Vec<Value> {
    ["look","find","click","type","keyboard","invoke","scroll","run"].into_iter()
        .map(|name| json!({"name":name,"description":format!("Axon macOS {name}"),"inputSchema":{"type":"object","additionalProperties":true}})).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn endpoint_is_explicit_and_rejects_installed_socket() {
        unsafe { std::env::set_var(SOCKET_ENV, "/tmp/axon.sock") };
        assert_eq!(path().unwrap_err().kind(), io::ErrorKind::PermissionDenied);
    }
    #[test]
    fn facade_is_exact_v1_surface() {
        let names = tools().into_iter().map(|v| v["name"].as_str().unwrap().to_owned()).collect::<Vec<_>>();
        assert_eq!(names, ["look","find","click","type","keyboard","invoke","scroll","run"]);
    }
}
