#[cfg(not(windows))]
fn main() {
    eprintln!("axon-win runs only on Windows");
    std::process::exit(1);
}

#[cfg(windows)]
mod lifecycle {
    use axon_core::{RegistrationHealth, ephemeral_path_warning, exit_code};
    use axon_win::pipe;
    use axon_win::{
        lifecycle::{TASK_NAME, daemon_sibling, registration_from_task_xml, scheduler_error},
        scheduler,
    };
    use std::{env, io, process::Command, time::Duration};

    const SYNCHRONIZE: u32 = 0x0010_0000;
    const WAIT_OBJECT_0: u32 = 0;
    const WAIT_TIMEOUT: u32 = 258;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn OpenProcess(access: u32, inherit: i32, process_id: u32) -> isize;
        fn WaitForSingleObject(handle: isize, milliseconds: u32) -> u32;
        fn CloseHandle(handle: isize) -> i32;
    }

    pub fn run(mut args: impl Iterator<Item = String>) -> Result<i32, Box<dyn std::error::Error>> {
        match args.next().as_deref() {
            Some("install") => {
                let executable = register()?;
                stop_if_running()?;
                let report = start()?;
                println!("registered {TASK_NAME:?} -> {executable}");
                println!(
                    "daemon ready (pid {}, version {})",
                    report.process_id, report.version
                );
            }
            Some("restart") => {
                // Restart deliberately does not re-register. It restarts the daemon that is
                // installed, whatever binary is asking, so restarting from a build directory
                // cannot repoint a working installation at a path that is about to disappear.
                let registered = registration();
                let Some(path) = registered.path.filter(|_| registered.registered) else {
                    return Err(format!(
                        "{TASK_NAME:?} is not registered; run `daemon install` from the permanent install path first"
                    )
                    .into());
                };
                stop_if_running()?;
                let report = start()?;
                println!("restarted {TASK_NAME:?} -> {path}");
                println!(
                    "daemon ready (pid {}, version {})",
                    report.process_id, report.version
                );
            }
            Some("uninstall") => {
                delete()?;
                stop_if_running()?;
                println!("unregistered {TASK_NAME:?}");
            }
            other => {
                eprintln!(
                    "axon-win: daemon requires install, uninstall, or restart (got {other:?})"
                );
                return Ok(exit_code::USAGE);
            }
        }

        Ok(exit_code::SUCCESS)
    }

    /// Registers the permanent sibling daemon and returns the path Task Scheduler holds.
    fn register() -> io::Result<String> {
        let daemon = daemon_sibling(&env::current_exe()?)?;
        let daemon = daemon
            .canonicalize()
            .unwrap_or(daemon)
            .display()
            .to_string();
        // Extended-length paths are filesystem syntax, not valid Task Scheduler actions.
        let daemon = daemon.strip_prefix(r"\\?\").unwrap_or(&daemon).to_owned();
        if let Some(warning) = ephemeral_path_warning(&daemon) {
            eprintln!("axon-win: warning: {warning}");
        }
        let existed = registration().registered;
        scheduler::register(TASK_NAME, &daemon)
            .map_err(|error| scheduler_error("scheduled-task replacement", existed, error))?;
        Ok(daemon)
    }

    /// The registration as Task Scheduler holds it, for health documents.
    pub fn registration() -> RegistrationHealth {
        let xml =
            command_output("schtasks", &["/query", "/tn", TASK_NAME, "/xml"]).unwrap_or_default();
        registration_from_task_xml(&xml)
    }

    fn start() -> io::Result<axon_core::DaemonReport> {
        command("schtasks", &["/run", "/tn", TASK_NAME])?;
        pipe::wait_until_ready(Duration::from_secs(60))
    }

    fn stop_if_running() -> io::Result<()> {
        match pipe::shutdown() {
            Ok(process_id) => wait_for_process_exit(process_id, Duration::from_secs(10)),
            Err(error) if pipe::is_daemon_absent(&error) => Ok(()),
            Err(error) if pipe::is_unresponsive_daemon(&error) => end_task(),
            Err(error) => Err(error),
        }
    }

    fn end_task() -> io::Result<()> {
        let output = Command::new("schtasks")
            .args(["/end", "/tn", TASK_NAME])
            .output()?;
        if output.status.success()
            || String::from_utf8_lossy(&output.stderr).contains("not currently running")
        {
            Ok(())
        } else {
            Err(command_error("schtasks", &output))
        }
    }

    pub fn wait_for_process_exit(process_id: u32, timeout: Duration) -> io::Result<()> {
        let handle = unsafe { OpenProcess(SYNCHRONIZE, 0, process_id) };
        if handle == 0 {
            let error = io::Error::last_os_error();
            // ERROR_INVALID_PARAMETER means the process exited before OpenProcess.
            return if error.raw_os_error() == Some(87) {
                Ok(())
            } else {
                Err(error)
            };
        }
        let wait = unsafe { WaitForSingleObject(handle, timeout.as_millis() as u32) };
        unsafe { CloseHandle(handle) };
        match wait {
            WAIT_OBJECT_0 => Ok(()),
            WAIT_TIMEOUT => Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("daemon process {process_id} did not exit"),
            )),
            _ => Err(io::Error::last_os_error()),
        }
    }

    fn delete() -> io::Result<()> {
        let existed = registration().registered;
        if !existed {
            return Ok(());
        }
        scheduler::delete(TASK_NAME)
            .map_err(|error| scheduler_error("scheduled-task deletion", true, error))
    }

    fn command(program: &str, args: &[&str]) -> io::Result<()> {
        let output = Command::new(program).args(args).output()?;
        if output.status.success() {
            Ok(())
        } else {
            Err(command_error(program, &output))
        }
    }

    fn command_output(program: &str, args: &[&str]) -> io::Result<String> {
        let output = Command::new(program).args(args).output()?;
        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
        } else {
            Err(command_error(program, &output))
        }
    }

    fn command_error(program: &str, output: &std::process::Output) -> io::Error {
        let detail = String::from_utf8_lossy(&output.stderr);
        io::Error::other(format!(
            "{program} failed with {}: {}",
            output.status,
            detail.trim()
        ))
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn busy_pipe_is_not_absent() {
            assert!(!pipe::is_daemon_absent(&io::Error::from_raw_os_error(231)));
            assert!(pipe::is_daemon_absent(&io::Error::from_raw_os_error(2)));
            assert!(pipe::is_daemon_absent(&io::Error::from_raw_os_error(3)));
        }
    }
}

#[cfg(windows)]
fn main() {
    match windows_main() {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("axon-win: {error}");
            std::process::exit(axon_core::exit_code::FAILURE);
        }
    }
}

#[cfg(windows)]
const USAGE: &str = "\
usage: axon-win <command>

embedding lifecycle:
  daemon install    register the sibling daemon executable at logon, then wait for health
  daemon uninstall  stop the daemon and remove the registration
  daemon restart    restart the registered daemon and wait for health
  shutdown          stop the running daemon, leaving the registration in place
  status [--json]   describe daemon, registration, session, permissions, capabilities
  version           print the product version

`daemon install` registers axon-win-daemon.exe beside this executable, so both must be in a
permanent installation directory.

other commands:
  mcp               run an MCP stdio facade backed by the daemon pipe
  probe             run a session-1 integration probe

probes:
  probe value <app-query>
  probe events <app-query> [seconds]
  probe timeout [app-query] [milliseconds]
  probe pixel-click <app-query> <element-query> [--observe <query>] [--unverified-class] [--settle-ms N]
  probe foreground <app-query> [--strategy A|B|C|D|E|F|G|H]

Probes drive real windows and must run in the interactive desktop session. Over SSH they land in
session 0, where UI Automation and SetForegroundWindow cannot reach the logged-in desktop and
every answer is a false negative.
";

#[cfg(windows)]
fn windows_main() -> Result<i32, Box<dyn std::error::Error>> {
    use axon_core::exit_code;
    use axon_win::{IntegrationProbe, pipe};
    let command = std::env::args().nth(1).unwrap_or_else(|| "help".into());
    match command.as_str() {
        "mcp" => pipe::mcp()?,
        "shutdown" => status::shutdown()?,
        "daemon" => return lifecycle::run(std::env::args().skip(2)),
        "status" => return status::run(&std::env::args().skip(2).collect::<Vec<_>>()),
        "version" | "--version" => println!("{}", env!("CARGO_PKG_VERSION")),
        "help" | "--help" | "-h" => print!("{USAGE}"),
        "probe" => {
            let args = std::env::args().skip(2).collect::<Vec<_>>();
            println!(
                "{}",
                serde_json::to_string_pretty(&IntegrationProbe::run(&args)?)?
            )
        }
        other => {
            eprintln!("axon-win: unknown subcommand {other:?}\n\n{USAGE}");
            return Ok(exit_code::USAGE);
        }
    }
    Ok(exit_code::SUCCESS)
}

#[cfg(windows)]
use axon_win::lifecycle::current_session;

#[cfg(windows)]
mod status {
    use super::{current_session, lifecycle};
    use axon_core::{HealthReport, exit_code};
    use axon_win::lifecycle::{incompatible, not_running};
    use axon_win::pipe;
    use std::io;

    pub fn run(args: &[String]) -> Result<i32, Box<dyn std::error::Error>> {
        let json = args.iter().any(|arg| arg == "--json");
        if let Some(unexpected) = args.iter().find(|arg| *arg != "--json") {
            eprintln!("axon-win: unexpected status argument: {unexpected}");
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
    /// The daemon authors what only it knows. Registration is read from Task Scheduler here
    /// because the daemon process does not own that fact, and the session falls back to this
    /// process only when no daemon could report its own.
    fn current() -> HealthReport {
        let registration = lifecycle::registration();
        match pipe::daemon_health() {
            Ok(report) => HealthReport::running(report, registration),
            Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                incompatible(registration, current_session(), Some(error.to_string()))
            }
            Err(error) => not_running(registration, current_session(), Some(error.to_string())),
        }
    }

    /// Stops the running daemon while leaving the registration in place.
    ///
    /// Only an absent pipe counts as an already-reached end state. A daemon that acknowledges
    /// shutdown is then waited for, because the acknowledgement is sent before the UI Automation
    /// thread joins and the COM apartment is torn down; reporting a stop before the process is
    /// gone is how a relaunch races the next lifecycle command.
    pub fn shutdown() -> Result<(), Box<dyn std::error::Error>> {
        match pipe::shutdown() {
            Ok(process_id) => {
                lifecycle::wait_for_process_exit(process_id, std::time::Duration::from_secs(10))?;
                println!("stopped daemon (pid {process_id}); registration left in place")
            }
            Err(error) if pipe::is_daemon_absent(&error) => {
                println!("no daemon was running; registration left in place")
            }
            Err(error) => return Err(error.into()),
        }
        Ok(())
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
                (_, true) => "interactive desktop".to_owned(),
                _ => format!(
                    "degraded ({})",
                    report.session.reason.as_deref().unwrap_or("unknown")
                ),
            }
        );
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
