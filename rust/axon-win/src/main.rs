#[cfg(not(windows))]
fn main() {
    eprintln!("axon-win runs only on Windows");
    std::process::exit(1);
}

#[cfg(windows)]
mod lifecycle {
    use super::pipe;
    use std::{env, io, path::Path, process::Command, time::Duration};

    const TASK_NAME: &str = "Axon Windows Daemon";
    const SYNCHRONIZE: u32 = 0x0010_0000;
    const WAIT_OBJECT_0: u32 = 0;
    const WAIT_TIMEOUT: u32 = 258;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn OpenProcess(access: u32, inherit: i32, process_id: u32) -> isize;
        fn WaitForSingleObject(handle: isize, milliseconds: u32) -> u32;
        fn CloseHandle(handle: isize) -> i32;
    }

    pub fn run(mut args: impl Iterator<Item = String>) -> Result<(), Box<dyn std::error::Error>> {
        match args.next().as_deref() {
            Some("install" | "restart") => {
                stop_if_running()?;
                register()?;
                start()?;
            }
            Some("uninstall") => {
                stop_if_running()?;
                delete()?;
            }
            other => {
                return Err(format!(
                    "unknown daemon command {other:?}; expected install, restart, or uninstall"
                )
                .into());
            }
        }

        Ok(())
    }

    fn register() -> io::Result<()> {
        let executable = env::current_exe()?;
        let user = command_output("whoami", &[])?;
        let action = task_action(&executable);
        command(
            "schtasks",
            &[
                "/create", "/tn", TASK_NAME, "/tr", &action, "/sc", "ONLOGON", "/ru", &user, "/it",
                "/f",
            ],
        )
    }

    fn start() -> io::Result<()> {
        command("schtasks", &["/run", "/tn", TASK_NAME])?;
        pipe::wait_until_ready(Duration::from_secs(10))
    }

    fn stop_if_running() -> io::Result<()> {
        match pipe::shutdown() {
            Ok(process_id) => wait_for_process_exit(process_id, Duration::from_secs(10)),
            Err(error) if pipe::is_daemon_absent(&error) => Ok(()),
            Err(error) => Err(error),
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

    fn task_action(executable: &Path) -> String {
        format!("\"{}\" serve", executable.display())
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
        fn scheduled_task_action_quotes_executable_paths() {
            assert_eq!(
                task_action(Path::new(r"C:\Program Files\Axon\axon-win.exe")),
                r#""C:\Program Files\Axon\axon-win.exe" serve"#
            );
        }

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
    if let Err(error) = windows_main() {
        eprintln!("axon-win: {error}");
        std::process::exit(1);
    }
}

#[cfg(windows)]
fn windows_main() -> Result<(), Box<dyn std::error::Error>> {
    use axon_win::{IntegrationProbe, Router, WindowsBackend};
    let command = std::env::args().nth(1).unwrap_or_else(|| "serve".into());
    match command.as_str() {
        "serve" => pipe::serve(Router::new(WindowsBackend::start()?))?,
        "mcp" => pipe::mcp()?,
        "shutdown" => {
            pipe::shutdown()?;
        }
        "daemon" => lifecycle::run(std::env::args().skip(2))?,
        "probe" => {
            let args = std::env::args().skip(2).collect::<Vec<_>>();
            println!(
                "{}",
                serde_json::to_string_pretty(&IntegrationProbe::run(&args)?)?
            )
        }
        other => {
            return Err(format!(
                "unknown subcommand {other:?}; expected serve, mcp, shutdown, daemon, or probe"
            )
            .into());
        }
    }
    Ok(())
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
        ptr, thread,
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

    pub fn serve(mut router: Router<WindowsBackend>) -> io::Result<()> {
        let mut security = PipeSecurity::current_user()?;
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
                return Err(io::Error::last_os_error());
            }
            let connected = unsafe { ConnectNamedPipe(handle, ptr::null_mut()) } != 0
                || io::Error::last_os_error().raw_os_error() == Some(535);
            if connected {
                let shutdown = connection(handle, &mut router).unwrap_or(false);
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

    pub fn wait_until_ready(timeout: Duration) -> io::Result<()> {
        wait_for_pipe(timeout, true)
    }

    fn wait_for_pipe(timeout: Duration, ready: bool) -> io::Result<()> {
        let start = Instant::now();
        loop {
            let present = OpenOptions::new().read(true).write(true).open(PIPE).is_ok();
            if present == ready {
                return Ok(());
            }
            if start.elapsed() >= timeout {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    if ready {
                        "daemon pipe did not become ready"
                    } else {
                        "daemon pipe did not stop"
                    },
                ));
            }
            thread::sleep(Duration::from_millis(50));
        }
    }

    pub fn is_daemon_absent(error: &io::Error) -> bool {
        matches!(error.raw_os_error(), Some(2 | 3))
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
