//! `axon-linux`: the AT-SPI daemon, its MCP facade, and the systemd-user lifecycle around them.

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("axon-linux runs only on Linux");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
fn main() {
    match linux_main() {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("axon-linux: {error}");
            std::process::exit(axon_core::exit_code::FAILURE);
        }
    }
}

#[cfg(target_os = "linux")]
fn linux_main() -> Result<i32, Box<dyn std::error::Error>> {
    use axon_core::exit_code;
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    match args.first().map(String::as_str).unwrap_or("serve") {
        "serve" => socket::serve()?,
        "mcp" => socket::mcp()?,
        "shutdown" => lifecycle::shutdown()?,
        "daemon" => return lifecycle::daemon(args.get(1).map(String::as_str)),
        "status" => return status::run(&args[1..]),
        "version" | "--version" => println!("{}", env!("CARGO_PKG_VERSION")),
        "help" | "--help" | "-h" => print!("{USAGE}"),
        other => {
            eprintln!("axon-linux: unknown subcommand {other:?}\n\n{USAGE}");
            return Ok(exit_code::USAGE);
        }
    }
    Ok(exit_code::SUCCESS)
}

#[cfg(target_os = "linux")]
const USAGE: &str = "\
usage: axon-linux <command>

embedding lifecycle:
  daemon install    register this executable as a systemd user service, then wait for health
  daemon uninstall  stop the daemon and remove the registration
  daemon restart    restart the registered daemon and wait for health
  shutdown          stop the running daemon, leaving the registration in place
  status [--json]   describe daemon, registration, session, permissions, capabilities
  version           print the product version

`daemon install` registers the path of the executable you invoked, so run it from a permanent
location. Installing from a build directory registers a path that disappears.

other commands:
  serve             run the AT-SPI daemon on the local socket
  mcp               run an MCP stdio facade backed by the daemon socket
";

#[cfg(target_os = "linux")]
mod socket {
    use axon_core::{
        CapabilityInfo, JsonRpcId, JsonRpcRequest, JsonRpcResponse, PlatformBackend,
        health::DaemonReport,
    };
    use axon_linux::{
        LinuxBackend, Router,
        lifecycle::{SessionEnvironment, daemon_report},
        parse_request,
    };
    use serde_json::{Value, json};
    use std::{
        fs,
        io::{self, BufRead, BufReader, Write},
        os::unix::{
            fs::PermissionsExt,
            net::{UnixListener, UnixStream},
        },
        path::PathBuf,
        time::{Duration, Instant},
    };

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

    pub fn shutdown_rpc() -> io::Result<u32> {
        let response = rpc("shutdown")?;
        response
            .pointer("/result/processId")
            .and_then(Value::as_u64)
            .and_then(|value| u32::try_from(value).ok())
            .ok_or_else(|| io::Error::other(format!("daemon rejected shutdown: {response}")))
    }

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
        let result = (|| {
            for incoming in listener.incoming() {
                let mut stream = incoming?;
                let mut line = String::new();
                BufReader::new(stream.try_clone()?).read_line(&mut line)?;
                let (response, stop) = dispatch(line.trim(), &mut router, &reported, &endpoint);
                writeln!(stream, "{}", serde_json::to_string(&response).unwrap())?;
                if stop {
                    break;
                }
            }
            Ok(())
        })();
        let _ = fs::remove_file(path);
        result
    }

    /// Routes one request, answering `health` and `shutdown` here and everything else through the
    /// backend router.
    ///
    /// `shutdown` is an ordinary JSON-RPC method with an id and a reply, not a magic frame: a
    /// lifecycle command learns which process it stopped from that reply, and cannot otherwise
    /// tell a clean stop from a daemon that crashed while being asked.
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
                        let response: Value =
                            serde_json::from_str(&body).map_err(io::Error::other)?;
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
        ["look","find","invoke","type","scroll","run"].into_iter().map(|name| json!({"name":name,"description":format!("Axon Linux {name}"),"inputSchema":{"type":"object","additionalProperties":true}})).collect()
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
}

#[cfg(target_os = "linux")]
mod lifecycle {
    use super::socket;
    use axon_core::{ephemeral_path_warning, exit_code};
    use axon_linux::lifecycle::{UNIT_NAME, unit_file};
    use std::{fs, io, path::PathBuf, process::Command, time::Duration};

    /// Where systemd looks for a user unit this CLI owns.
    pub fn unit_path() -> io::Result<PathBuf> {
        let base = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
            .ok_or_else(|| io::Error::other("neither XDG_CONFIG_HOME nor HOME is set"))?;
        Ok(base.join("systemd/user").join(UNIT_NAME))
    }

    pub fn installed_unit() -> Option<String> {
        fs::read_to_string(unit_path().ok()?).ok()
    }

    pub fn daemon(subcommand: Option<&str>) -> Result<i32, Box<dyn std::error::Error>> {
        match subcommand {
            Some("install") => install()?,
            Some("uninstall") => uninstall()?,
            Some("restart") => restart()?,
            other => {
                eprintln!(
                    "axon-linux: daemon requires install, uninstall, or restart (got {other:?})"
                );
                return Ok(exit_code::USAGE);
            }
        }
        Ok(exit_code::SUCCESS)
    }

    /// Registers the invoking executable and waits for the daemon to answer.
    ///
    /// Idempotent: rewriting the unit and enabling an already-enabled service both no-op, so a
    /// consumer can run this on every deploy without checking first.
    fn install() -> Result<(), Box<dyn std::error::Error>> {
        let executable = std::env::current_exe()?.canonicalize()?;
        let executable = executable.display().to_string();
        if let Some(warning) = ephemeral_path_warning(&executable) {
            eprintln!("axon-linux: warning: {warning}");
        }

        let path = unit_path()?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&path, unit_file(&executable))?;
        systemctl(&["daemon-reload"])?;
        systemctl(&["enable", "--now", UNIT_NAME])?;

        let report = socket::wait_until_ready(Duration::from_secs(60))?;
        println!("registered {UNIT_NAME} -> {executable}");
        println!(
            "daemon ready (pid {}, version {})",
            report.process_id, report.version
        );
        Ok(())
    }

    fn uninstall() -> Result<(), Box<dyn std::error::Error>> {
        // Tolerated rather than required: disabling a service that was never enabled is the
        // requested end state already reached, not a failure.
        let _ = systemctl(&["disable", "--now", UNIT_NAME]);
        let path = unit_path()?;
        if path.exists() {
            fs::remove_file(&path)?;
        }
        let _ = systemctl(&["daemon-reload"]);
        println!("unregistered {UNIT_NAME}");
        Ok(())
    }

    fn restart() -> Result<(), Box<dyn std::error::Error>> {
        systemctl(&["restart", UNIT_NAME])?;
        let report = socket::wait_until_ready(Duration::from_secs(60))?;
        println!(
            "restarted {UNIT_NAME} (pid {}, version {})",
            report.process_id, report.version
        );
        Ok(())
    }

    /// Stops the running daemon while leaving the registration in place.
    ///
    /// The unit is stopped rather than only asked to exit, because `Restart=on-failure` plus a
    /// systemd-managed process means asking alone can be undone a second later.
    pub fn shutdown() -> Result<(), Box<dyn std::error::Error>> {
        let stopped = socket::shutdown_rpc().ok();
        if installed_unit().is_some() {
            let _ = systemctl(&["stop", UNIT_NAME]);
        }
        match stopped {
            Some(process_id) => {
                println!("stopped daemon (pid {process_id}); registration left in place")
            }
            None => println!("no daemon was running; registration left in place"),
        }
        Ok(())
    }

    fn systemctl(args: &[&str]) -> io::Result<()> {
        let mut command = Command::new("systemctl");
        command.arg("--user").args(args);
        let output = command.output()?;
        if output.status.success() {
            Ok(())
        } else {
            Err(io::Error::other(format!(
                "systemctl --user {} failed with {}: {}",
                args.join(" "),
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            )))
        }
    }
}

#[cfg(target_os = "linux")]
mod status {
    use super::{lifecycle, socket};
    use axon_core::{HealthReport, exit_code};
    use axon_linux::lifecycle::{SessionEnvironment, incompatible, not_running, registration};
    use std::io;

    pub fn run(args: &[String]) -> Result<i32, Box<dyn std::error::Error>> {
        let json = args.iter().any(|arg| arg == "--json");
        if let Some(unexpected) = args.iter().find(|arg| *arg != "--json") {
            eprintln!("axon-linux: unexpected status argument: {unexpected}");
            return Ok(exit_code::USAGE);
        }

        let report = current();
        if json {
            println!("{}", serde_json::to_string(&report)?);
        } else {
            print_human(&report);
        }
        // Describing a machine honestly is a success even when what it describes is degraded.
        Ok(exit_code::SUCCESS)
    }

    /// Builds the published document.
    ///
    /// The daemon authors what only it knows. Registration is read from the unit file here because
    /// the daemon process does not own that fact.
    fn current() -> HealthReport {
        let registration = registration(lifecycle::installed_unit().as_deref());
        let env = SessionEnvironment::from_env();
        match socket::daemon_health() {
            Ok(report) => HealthReport::running(report, registration),
            Err(error) if error.kind() == io::ErrorKind::InvalidData => incompatible(
                socket::endpoint(),
                registration,
                &env,
                Some(error.to_string()),
            ),
            Err(error) => not_running(
                socket::endpoint(),
                registration,
                &env,
                Some(error.to_string()),
            ),
        }
    }

    fn print_human(report: &HealthReport) {
        println!("Version:        {}", report.version);
        println!(
            "Daemon:         {}",
            match (report.daemon.running, report.daemon.ready) {
                (true, true) => "ready".to_owned(),
                (true, false) => "running, not ready".to_owned(),
                _ => format!(
                    "not running ({})",
                    report.daemon.reason.as_deref().unwrap_or("unknown")
                ),
            }
        );
        println!("Endpoint:       {}", report.daemon.endpoint);
        println!(
            "Registration:   {}",
            report
                .registration
                .path
                .as_deref()
                .unwrap_or("not registered")
        );
        println!(
            "Session:        {}",
            match (report.session.interactive, report.session.graphical) {
                (_, true) => "graphical".to_owned(),
                (true, false) => format!(
                    "interactive, no desktop ({})",
                    report.session.reason.as_deref().unwrap_or("unknown")
                ),
                _ => "not interactive".to_owned(),
            }
        );
        for permission in &report.permissions {
            println!(
                "{:<16}{}",
                permission.name,
                if permission.granted {
                    "granted"
                } else {
                    "not granted"
                }
            );
        }
        let unusable = report
            .capabilities
            .iter()
            .filter(|state| !state.usable)
            .map(|state| state.capability.as_str())
            .collect::<Vec<_>>();
        println!(
            "Unusable:       {}",
            if unusable.is_empty() {
                "none".to_owned()
            } else {
                unusable.join(", ")
            }
        );
    }
}
