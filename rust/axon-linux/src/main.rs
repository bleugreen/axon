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
    use axon_linux::socket;
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
mod lifecycle {
    use axon_core::{ephemeral_path_warning, exit_code};
    use axon_linux::lifecycle::{
        SessionEnvironment, UNIT_NAME, session_health, unit_executable, unit_file,
    };
    use axon_linux::socket;
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
    ///
    /// On a host with no desktop the registration still succeeds and the wait is skipped. The unit
    /// is bound to `graphical-session.target`, so it starts when someone logs in; blocking for a
    /// readiness that cannot arrive until then would report a timeout for work that was done.
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

        // Without a desktop the unit is enabled but deliberately not started. `--now` would start
        // it anyway, contradicting the unit's own binding to graphical-session.target and leaving
        // a daemon running where it has no desktop to automate.
        let session = session_health(&SessionEnvironment::from_env());
        if !session.graphical {
            systemctl(&["enable", UNIT_NAME])?;
            println!("registered {UNIT_NAME} -> {executable}");
            println!(
                "daemon not started: {}; it will start with the graphical session",
                session.reason.as_deref().unwrap_or("no graphical session")
            );
            return Ok(());
        }

        systemctl(&["enable", "--now", UNIT_NAME])?;
        println!("registered {UNIT_NAME} -> {executable}");
        let report = socket::wait_until_ready(Duration::from_secs(60))?;
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

    /// Restarts the registered daemon.
    ///
    /// Deliberately does not rewrite the unit. Restart restarts the daemon that is installed,
    /// whatever binary is asking, so restarting from a build directory cannot repoint a working
    /// installation at a path that is about to disappear.
    fn restart() -> Result<(), Box<dyn std::error::Error>> {
        let Some(path) = installed_unit().as_deref().and_then(unit_executable) else {
            return Err(format!(
                "{UNIT_NAME} is not registered; run `daemon install` from the permanent install path first"
            )
            .into());
        };
        systemctl(&["restart", UNIT_NAME])?;
        println!("restarted {UNIT_NAME} -> {path}");

        let session = session_health(&SessionEnvironment::from_env());
        if !session.graphical {
            println!(
                "daemon not started: {}; it will start with the graphical session",
                session.reason.as_deref().unwrap_or("no graphical session")
            );
            return Ok(());
        }

        let report = socket::wait_until_ready(Duration::from_secs(60))?;
        println!(
            "daemon ready (pid {}, version {})",
            report.process_id, report.version
        );
        Ok(())
    }

    /// Stops the running daemon while leaving the registration in place.
    ///
    /// The unit is stopped as well as asked to exit, because `Restart=on-failure` plus a
    /// systemd-managed process means asking alone can be undone a second later.
    ///
    /// Only an absent endpoint counts as an already-reached end state. A daemon that accepts a
    /// connection and then does not answer, or a `systemctl stop` that fails, must reach the
    /// caller: reporting a stop that did not happen leaves a process holding the socket while
    /// whoever asked believes the machine is clear.
    pub fn shutdown() -> Result<(), Box<dyn std::error::Error>> {
        let registered = installed_unit().is_some();
        let stopped = match socket::shutdown_rpc() {
            Ok(process_id) => Some(process_id),
            Err(error) if socket::is_daemon_absent(&error) => {
                println!("no daemon was running; registration left in place");
                return Ok(());
            }
            Err(error) if registered => {
                eprintln!(
                    "axon-linux: the daemon did not answer a shutdown request ({error}); stopping {UNIT_NAME}"
                );
                None
            }
            Err(error) => {
                return Err(format!(
                    "a daemon at {} did not answer a shutdown request and no {UNIT_NAME} \
                     registration exists to stop it: {error}",
                    socket::endpoint()
                )
                .into());
            }
        };

        if registered {
            systemctl(&["stop", UNIT_NAME])?;
        }

        if !socket::wait_until_absent(Duration::from_secs(10)) {
            return Err(format!("a daemon is still answering at {}", socket::endpoint()).into());
        }

        match stopped {
            Some(process_id) => {
                println!("stopped daemon (pid {process_id}); registration left in place")
            }
            None => println!("stopped daemon; registration left in place"),
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
    use super::lifecycle;
    use axon_core::{HealthReport, exit_code};
    use axon_linux::lifecycle::{SessionEnvironment, incompatible, not_running, registration};
    use axon_linux::socket;
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
        println!("{:<18}{}", "Version:", report.version);
        println!(
            "{:<18}{}",
            "Daemon:",
            match (report.daemon.running, report.daemon.ready) {
                (true, true) => "ready".to_owned(),
                (true, false) => "running, not ready".to_owned(),
                _ => format!(
                    "not running ({})",
                    report.daemon.reason.as_deref().unwrap_or("unknown")
                ),
            }
        );
        println!("{:<18}{}", "Endpoint:", report.daemon.endpoint);
        println!(
            "{:<18}{}",
            "Registration:",
            report
                .registration
                .path
                .as_deref()
                .unwrap_or("not registered")
        );
        println!(
            "{:<18}{}",
            "Session:",
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
                "{:<18}{}",
                format!("{}:", permission.name),
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
            "{:<18}{}",
            "Unusable:",
            if unusable.is_empty() {
                "none".to_owned()
            } else {
                unusable.join(", ")
            }
        );
    }
}
