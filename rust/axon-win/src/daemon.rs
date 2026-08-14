//! Windowless Windows daemon process entry point.

#![cfg(windows)]

use crate::{WindowsBackend, pipe};
use std::{
    io::Write,
    path::PathBuf,
    time::{Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Clone)]
struct StartupLog {
    started: Instant,
    path: PathBuf,
}

impl StartupLog {
    fn new() -> Self {
        let root = std::env::var_os("ProgramData")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"));
        Self {
            started: Instant::now(),
            path: root.join("Axon").join("axon-win-startup.log"),
        }
    }

    fn stage(&self, stage: &str) {
        let unix_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let line = format!(
            "timestamp_unix_ms={unix_ms} elapsed_ms={} pid={} {stage}\n",
            self.started.elapsed().as_millis(),
            std::process::id()
        );
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

/// Runs the named-pipe/UI Automation daemon until a shutdown request is received.
pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    let startup = StartupLog::new();
    startup.stage("process startup");
    let backend_log = startup.clone();
    startup.stage("pipe bind: begin");
    pipe::serve(
        move || {
            WindowsBackend::start_with_logger(move |stage| backend_log.stage(stage))
                .map_err(Into::into)
        },
        || startup.stage("pipe bind: complete"),
    )
}
