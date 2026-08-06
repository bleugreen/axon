#[cfg(not(windows))]
fn main() {
    eprintln!("axon-win runs only on Windows");
    std::process::exit(1);
}

#[cfg(windows)]
#[derive(Clone)]
struct StartupLog {
    started: std::time::Instant,
    path: std::path::PathBuf,
}

#[cfg(windows)]
impl StartupLog {
    fn new() -> Self {
        let root = std::env::var_os("ProgramData")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::path::PathBuf::from(r"C:\ProgramData"));
        Self {
            started: std::time::Instant::now(),
            path: root.join("Axon").join("axon-win-startup.log"),
        }
    }

    fn stage(&self, stage: &str) {
        use std::io::Write;
        let unix_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let line = format!(
            "timestamp_unix_ms={unix_ms} elapsed_ms={} pid={} {stage}\n",
            self.started.elapsed().as_millis(),
            std::process::id()
        );
        eprint!("{line}");
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
        {
            let _ = file.write_all(line.as_bytes());
        }
    }
}

#[cfg(windows)]
mod lifecycle {
    use super::pipe;
    use axon_core::{RegistrationHealth, ephemeral_path_warning, exit_code};
    use axon_win::lifecycle::{TASK_NAME, registration_from_task_xml, task_action};
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

    pub fn run(
        mut args: impl Iterator<Item = String>,
    ) -> Result<i32, Box<dyn std::error::Error>> {
        match args.next().as_deref() {
            Some("install") => {
                stop_if_running()?;
                let executable = register()?;
                let report = start()?;
                println!("registered {TASK_NAME:?} -> {executable}");
                println!(
                    "daemon ready (pid {}, version {})",
                    report.process_id, report.version
                );
            }
            Some("restart") => {
                stop_if_running()?;
                register()?;
                let report = start()?;
                println!(
                    "restarted {TASK_NAME:?} (pid {}, version {})",
                    report.process_id, report.version
                );
            }
            Some("uninstall") => {
                stop_if_running()?;
                delete()?;
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

    /// Registers the invoking executable and returns the path that was registered.
    ///
    /// Idempotent through `/f`, which replaces an existing task rather than failing, so a consumer
    /// can run install on every deploy without checking first.
    fn register() -> io::Result<String> {
        let executable = env::current_exe()?
            .canonicalize()
            .unwrap_or(env::current_exe()?)
            .display()
            .to_string();
        // `\\?\` is what canonicalize returns on Windows and Task Scheduler will not run it.
        let executable = executable
            .strip_prefix(r"\\?\")
            .unwrap_or(&executable)
            .to_owned();
        if let Some(warning) = ephemeral_path_warning(&executable) {
            eprintln!("axon-win: warning: {warning}");
        }
        let user = command_output("whoami", &[])?;
        let action = task_action(&executable);
        command(
            "schtasks",
            &[
                "/create", "/tn", TASK_NAME, "/tr", &action, "/sc", "ONLOGON", "/ru", &user, "/it",
                "/f",
            ],
        )?;
        Ok(executable)
    }

    /// The registration as Task Scheduler holds it, for health documents.
    pub fn registration() -> RegistrationHealth {
        let xml = command_output("schtasks", &["/query", "/tn", TASK_NAME, "/xml"]).unwrap_or_default();
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

    fn wait_for_process_exit(process_id: u32, timeout: Duration) -> io::Result<()> {
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
        let output = Command::new("schtasks")
            .args(["/delete", "/tn", TASK_NAME, "/f"])
            .output()?;
        if output.status.success()
            || String::from_utf8_lossy(&output.stderr).contains("cannot find")
        {
            Ok(())
        } else {
            Err(command_error("schtasks", &output))
        }
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
  daemon install    register this executable to start at logon, then wait for health
  daemon uninstall  stop the daemon and remove the registration
  daemon restart    restart the registered daemon and wait for health
  shutdown          stop the running daemon, leaving the registration in place
  status [--json]   describe daemon, registration, session, permissions, capabilities
  version           print the product version

`daemon install` registers the path of the executable you invoked, so run it from a permanent
location. Installing from a build directory registers a path that disappears.

other commands:
  serve             run the UI Automation daemon on the local named pipe
  mcp               run an MCP stdio facade backed by the daemon pipe
  probe             run a session-1 integration probe
";

#[cfg(windows)]
fn windows_main() -> Result<i32, Box<dyn std::error::Error>> {
    use axon_core::exit_code;
    use axon_win::{IntegrationProbe, Router, WindowsBackend};
    let command = std::env::args().nth(1).unwrap_or_else(|| "serve".into());
    match command.as_str() {
        "serve" => {
            let startup = StartupLog::new();
            startup.stage("process startup");
            let backend_log = startup.clone();
            startup.stage("pipe bind: begin");
            pipe::serve(
                move || {
                    WindowsBackend::start_with_logger(move |stage| backend_log.stage(stage))
                        .map(Router::new)
                        .map_err(Into::into)
                },
                || startup.stage("pipe bind: complete"),
            )?;
        }
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

/// The session this process occupies, as Windows reports it.
#[cfg(windows)]
fn current_session() -> axon_core::SessionHealth {
    use axon_win::lifecycle::session_health;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn ProcessIdToSessionId(process_id: u32, session_id: *mut u32) -> i32;
    }
    #[link(name = "user32")]
    unsafe extern "system" {
        fn GetProcessWindowStation() -> isize;
        fn GetUserObjectInformationW(
            object: isize,
            index: i32,
            info: *mut std::ffi::c_void,
            length: u32,
            needed: *mut u32,
        ) -> i32;
    }
    const UOI_NAME: i32 = 2;

    let mut session_id = 0u32;
    if unsafe { ProcessIdToSessionId(std::process::id(), &mut session_id) } == 0 {
        session_id = 0;
    }

    let station = (|| {
        let handle = unsafe { GetProcessWindowStation() };
        if handle == 0 {
            return None;
        }
        let mut buffer = [0u16; 256];
        let mut needed = 0u32;
        let ok = unsafe {
            GetUserObjectInformationW(
                handle,
                UOI_NAME,
                buffer.as_mut_ptr().cast(),
                (buffer.len() * 2) as u32,
                &mut needed,
            )
        };
        if ok == 0 {
            return None;
        }
        let length = buffer.iter().position(|unit| *unit == 0).unwrap_or(0);
        Some(String::from_utf16_lossy(&buffer[..length]))
    })();

    session_health(session_id, station.as_deref())
}

#[cfg(windows)]
mod status {
    use super::{current_session, lifecycle, pipe};
    use axon_core::{HealthReport, exit_code};
    use axon_win::lifecycle::not_running;

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
            Err(error) => not_running(registration, current_session(), Some(error.to_string())),
        }
    }

    /// Stops the running daemon while leaving the registration in place.
    pub fn shutdown() -> Result<(), Box<dyn std::error::Error>> {
        match pipe::shutdown() {
            Ok(process_id) => {
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

#[cfg(windows)]
mod pipe {
    use axon_core::{JsonRpcId, JsonRpcRequest};
    use axon_win::{Router, WindowsBackend, parse_request};
    use serde_json::{Value, json};
    use std::{
        ffi::c_void,
        fs::OpenOptions,
        io::{self, BufRead, BufReader, Write},
        ptr,
        sync::{Arc, mpsc},
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
            let sid_text = unsafe {
                String::from_utf16_lossy(std::slice::from_raw_parts(sid_string, sid_len))
            };
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
        start_backend: impl FnOnce() -> Result<Router<WindowsBackend>, Box<dyn std::error::Error>>,
        on_bound: impl FnOnce(),
    ) -> Result<(), Box<dyn std::error::Error>> {
        let mut security = PipeSecurity::current_user()?;
        let mut on_bound = Some(on_bound);
        let mut start_backend = Some(start_backend);
        let mut router = None;
        loop {
            let handle = unsafe {
                CreateNamedPipeW(
                    PIPE_WIDE.as_ptr(),
                    PIPE_ACCESS_DUPLEX,
                    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                    1,
                    1024 * 1024,
                    1024 * 1024,
                    0,
                    (&mut security.attributes as *mut SecurityAttributes).cast(),
                )
            };
            if handle == INVALID_HANDLE_VALUE {
                return Err(io::Error::last_os_error().into());
            }
            if let Some(on_bound) = on_bound.take() {
                on_bound();
            }
            if let Some(start_backend) = start_backend.take() {
                router = Some(start_backend()?);
            }
            let connected = unsafe { ConnectNamedPipe(handle, ptr::null_mut()) } != 0
                || io::Error::last_os_error().raw_os_error() == Some(535);
            if connected {
                let shutdown = connection(
                    handle,
                    router
                        .as_mut()
                        .expect("backend initializes after the first pipe bind"),
                )
                .unwrap_or(false);
                unsafe {
                    DisconnectNamedPipe(handle);
                    CloseHandle(handle);
                }
                if shutdown {
                    return Ok(());
                }
                continue;
            }
            unsafe {
                DisconnectNamedPipe(handle);
                CloseHandle(handle);
            }
        }
    }

    fn connection(handle: isize, router: &mut Router<WindowsBackend>) -> io::Result<bool> {
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
                return Ok(false);
            }
            pending.extend_from_slice(&buf[..n as usize]);
            while let Some(pos) = pending.iter().position(|b| *b == b'\n') {
                let line = pending.drain(..=pos).collect::<Vec<_>>();
                let line = String::from_utf8_lossy(&line);
                let parsed = parse_request(line.trim());
                let shutdown =
                    matches!(&parsed, Ok(req) if req.method == "shutdown" && req.id.is_some());
                let response = match parsed {
                    // Answering health at all means UI Automation finished initializing, because
                    // the router only exists after it does; the pipe binds earlier so a stalled
                    // startup stays observable, and a request arriving in that window is refused
                    // rather than answered as ready.
                    Ok(req) if req.method == "health" => req.id.map(|id| {
                        let capabilities = router.capabilities().unwrap_or_default();
                        axon_core::JsonRpcResponse::success(
                            id,
                            serde_json::to_value(axon_win::lifecycle::daemon_report(
                                std::process::id(),
                                &capabilities,
                                super::current_session(),
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
                    Ok(req) => router.request(req),
                    Err(e) => Some(e),
                };
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
                    return Ok(true);
                }
            }
        }
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
        let report: axon_core::DaemonReport = response
            .get("result")
            .cloned()
            .map(serde_json::from_value)
            .transpose()
            .map_err(io::Error::other)?
            .ok_or_else(|| io::Error::other(format!("daemon rejected health check: {response}")))?;
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
                "tools/list" => json!({"jsonrpc":"2.0","id":id,"result":{"tools":tool_list()}}),
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
        let params = input
            .get("params")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "tools/call requires params")
            })?;
        let name = params.get("name").and_then(Value::as_str).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "tools/call requires name")
        })?;
        let arguments = params
            .get("arguments")
            .cloned()
            .unwrap_or_else(|| json!({}));
        let rpc = JsonRpcRequest::new(Some(JsonRpcId::Integer(1)), name, Some(arguments));
        let response = send_rpc(&rpc)?;
        let id = input.get("id").cloned().unwrap_or(Value::Null);
        if let Some(error) = response.get("error") {
            Ok(
                json!({"jsonrpc":"2.0","id":id,"result":{"content":[{"type":"text","text":error.get("message").and_then(Value::as_str).unwrap_or("Axon error")}],"structuredContent":error,"isError":true}}),
            )
        } else {
            let result = response.get("result").cloned().unwrap_or(Value::Null);
            Ok(
                json!({"jsonrpc":"2.0","id":id,"result":{"content":[{"type":"text","text":serde_json::to_string(&result).unwrap()}],"structuredContent":result,"isError":false}}),
            )
        }
    }
    fn tool_list() -> Value {
        Value::Array(["look","find","click","type","keyboard","invoke","scroll","run"].into_iter().map(|name|json!({"name":name,"description":format!("Axon Windows {name} tool"),"inputSchema":{"type":"object","additionalProperties":true}})).collect())
    }
}
