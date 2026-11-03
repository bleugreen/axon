#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("axon-mac runs only on macOS");
    std::process::exit(1);
}

#[cfg(target_os = "macos")]
fn main() {
    use axon_mac::launcher::{self, Entry};

    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let managed = std::env::var(launcher::LAUNCHD_MANAGED_KEY).as_deref() == Ok("1");
    let executable = std::env::current_exe()
        .and_then(std::fs::canonicalize)
        .unwrap_or_default();
    let result = match launcher::select(
        &arguments,
        managed,
        &executable,
        launcher::bundle_identifier,
    ) {
        Entry::Serve => axon_mac::socket::serve(),
        Entry::Mcp => axon_mac::socket::mcp(),
        Entry::Probe(arguments) => axon_mac::probe::run(&arguments),
        Entry::Version => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Entry::Launch { bundle, cli } => launch(&bundle, &cli),
        Entry::Refuse { bundle, identifier } => {
            let message = format!(
                "refusing to open {}: its identifier is {}, not {}; run it with `serve` instead",
                bundle.display(),
                identifier.as_deref().unwrap_or("unreadable"),
                launcher::AXON_BUNDLE_IDENTIFIER
            );
            log_open(&message);
            Err(std::io::Error::new(std::io::ErrorKind::PermissionDenied, message))
        }
        Entry::Usage => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "usage: axon-mac [serve|mcp|probe|version]",
        )),
    };
    if let Err(error) = result {
        eprintln!("axon-mac: {error}");
        std::process::exit(1);
    }
}

/// Runs the bundled CLI's `start` and exits with its status; never returns.
#[cfg(target_os = "macos")]
fn launch(bundle: &std::path::Path, cli: &std::path::Path) -> std::io::Result<()> {
    match std::process::Command::new(cli).arg("start").status() {
        Ok(status) if status.success() => std::process::exit(0),
        Ok(status) => {
            log_open(&format!(
                "{} start for {} exited with {status}",
                cli.display(),
                bundle.display()
            ));
            std::process::exit(status.code().unwrap_or(1));
        }
        Err(error) => {
            let message = format!("could not run {} start: {error}", cli.display());
            log_open(&message);
            Err(std::io::Error::new(error.kind(), message))
        }
    }
}

/// Appends to `~/Library/Logs/Axon/open.log`: an opened app has no terminal, so this is the one
/// place a failed open can be read afterwards.
#[cfg(target_os = "macos")]
fn log_open(message: &str) {
    use std::io::Write;
    let Some(home) = std::env::var_os("HOME") else {
        return;
    };
    let directory = std::path::Path::new(&home).join("Library/Logs/Axon");
    let _ = std::fs::create_dir_all(&directory);
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or_default();
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(directory.join("open.log"))
    {
        let _ = writeln!(file, "{seconds} pid {} {message}", std::process::id());
    }
}
