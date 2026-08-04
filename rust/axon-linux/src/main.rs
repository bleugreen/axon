#[cfg(not(target_os = "linux"))]
fn main() { eprintln!("axon-linux runs only on Linux"); std::process::exit(1); }

#[cfg(target_os = "linux")]
fn main() {
    if let Err(error) = linux_main() { eprintln!("axon-linux: {error}"); std::process::exit(1); }
}

#[cfg(target_os = "linux")]
fn linux_main() -> Result<(), Box<dyn std::error::Error>> {
    use axon_linux::{LinuxBackend, Router};
    match std::env::args().nth(1).as_deref().unwrap_or("serve") {
        "serve" => socket::serve(Router::new(LinuxBackend::start()?))?,
        "mcp" => socket::mcp()?,
        "shutdown" => { socket::shutdown()?; }
        other => return Err(format!("unknown subcommand {other:?}; expected serve, mcp, or shutdown").into()),
    }
    Ok(())
}

#[cfg(target_os = "linux")]
mod socket {
    use axon_core::{JsonRpcId, JsonRpcRequest};
    use axon_linux::{LinuxBackend, Router, parse_request};
    use serde_json::{Value, json};
    use std::{fs, io::{self, BufRead, BufReader, Write}, os::unix::{fs::PermissionsExt, net::{UnixListener, UnixStream}}, path::PathBuf};

    fn path() -> io::Result<PathBuf> {
        let dir = std::env::var_os("XDG_RUNTIME_DIR").ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is not set"))?;
        Ok(PathBuf::from(dir).join("axon-v1.sock"))
    }
    fn request(line: &str) -> io::Result<String> {
        let mut stream = UnixStream::connect(path()?)?;
        stream.write_all(line.as_bytes())?; stream.write_all(b"\n")?;
        let mut response = String::new(); BufReader::new(stream).read_line(&mut response)?;
        Ok(response)
    }
    pub fn serve(mut router: Router<LinuxBackend>) -> io::Result<()> {
        let path = path()?;
        if path.exists() { match UnixStream::connect(&path) { Ok(_) => return Err(io::Error::new(io::ErrorKind::AddrInUse, "Axon daemon is already running")), Err(_) => fs::remove_file(&path)? } }
        let listener = UnixListener::bind(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        let result = (|| {
            for incoming in listener.incoming() {
                let mut stream = incoming?;
                let mut line = String::new(); BufReader::new(stream.try_clone()?).read_line(&mut line)?;
                let response = if line.trim() == "{\"method\":\"shutdown\"}" { json!({"processId":std::process::id()}) }
                    else { match parse_request(line.trim()) { Ok(req) => router.request(req).map(|r| serde_json::to_value(r).unwrap()).unwrap_or(Value::Null), Err(r) => serde_json::to_value(r).unwrap() } };
                writeln!(stream, "{}", serde_json::to_string(&response).unwrap())?;
                if line.trim() == "{\"method\":\"shutdown\"}" { break; }
            }
            Ok(())
        })();
        let _ = fs::remove_file(path); result
    }
    pub fn shutdown() -> io::Result<()> { request("{\"method\":\"shutdown\"}").map(|_| ()) }
    pub fn mcp() -> io::Result<()> {
        let stdin = io::stdin(); let mut stdout = io::stdout();
        for line in stdin.lock().lines() {
            let line = line?; let value: Value = serde_json::from_str(&line).map_err(io::Error::other)?;
            let Some(response) = mcp_response(&value)? else { continue };
            Ok(Some(response))
    }
    fn mcp_response(value: &Value) -> io::Result<Option<Value>> {
            let Some(id) = value.get("id").cloned() else { return Ok(None) };
            let response = match value.get("method").and_then(Value::as_str) {
                Some("initialize") => json!({"jsonrpc":"2.0","id":id,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"axon-linux","version":"0.1.0"}}}),
                Some("tools/list") => json!({"jsonrpc":"2.0","id":id,"result":{"tools": tools()}}),
                Some("tools/call") => {
                    let p=&value["params"]; let name=p["name"].as_str().unwrap_or(""); let args=p.get("arguments").cloned().unwrap_or(json!({}));
                    let rpc=serde_json::to_string(&JsonRpcRequest::new(Some(JsonRpcId::Integer(1)), name, Some(args))).unwrap();
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
                        Err(e)=>json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":e.to_string()}})
                    }
                }
                _ => json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"method not found"}}),
            };
            writeln!(stdout, "{}", serde_json::to_string(&response).unwrap())?; stdout.flush()?;
        }
        Ok(())
    }
    fn tools() -> Vec<Value> {
        ["look","find","invoke","type","scroll","run"].into_iter().map(|name| json!({"name":name,"description":format!("Axon Linux {name}"),"inputSchema":{"type":"object","additionalProperties":true}})).collect()
    }
    #[cfg(test)] mod tests {
        use super::*;
        #[test] fn socket_lives_in_private_runtime_directory() { unsafe { std::env::set_var("XDG_RUNTIME_DIR", "/run/user/123"); } assert_eq!(path().unwrap(), PathBuf::from("/run/user/123/axon-v1.sock")); }
        #[test] fn facade_exposes_supported_surface() { let names=tools().into_iter().map(|v|v["name"].as_str().unwrap().to_owned()).collect::<Vec<_>>(); assert!(names.contains(&"invoke".into())); assert!(!names.contains(&"drag".into())); }
        #[test] fn mcp_notifications_have_no_response() {
            let notification = json!({"jsonrpc":"2.0","method":"notifications/initialized"});
            assert!(mcp_response(&notification).unwrap().is_none());
        }
    }
}