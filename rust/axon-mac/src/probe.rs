//! `axon-mac probe <name>` — measurement harnesses for questions the build slot cannot answer.
//!
//! These are not part of the daemon's tool surface. They exist because some macOS behaviour is only
//! observable while a human toggles a System Settings switch on a real machine, and a measurement
//! is worth more than an inference about what HIServices caches.

use crate::accessibility;
use std::{io, thread, time::Duration};

const USAGE: &str = "usage: axon-mac probe trust [--pid N] [--interval-ms N] [--count N]";

fn usage(message: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, format!("{message}\n\n{USAGE}"))
}

pub fn run(args: &[String]) -> io::Result<()> {
    match args.first().map(String::as_str) {
        None | Some("trust") => trust(args.get(1..).unwrap_or_default()),
        Some(other) => Err(usage(format!("unknown probe {other:?}"))),
    }
}

/// Sample every Accessibility trust signal side by side, one JSON object per line.
///
/// Run this across a revoke and a re-grant of the Accessibility row while the process keeps
/// running. Four columns beside each other over that toggle separate "the trust verdict is cached"
/// from "the API is disabled for this process" without any inference: `axIsProcessTrusted` and
/// `axIsProcessTrustedWithOptions` are the cached verdicts, `systemWideStatus` is the raw `AXError`
/// from a live system-wide read, and `pidStatus` is the raw `AXError` from the `AXTitle` read that
/// application enumeration actually makes.
fn trust(args: &[String]) -> io::Result<()> {
    let mut pid: Option<i32> = None;
    let mut interval = Duration::from_millis(1000);
    let mut count: Option<usize> = None;
    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        let value = args
            .get(index + 1)
            .ok_or_else(|| usage(format!("{flag} needs a value")))?;
        let number = |kind: &str| {
            value
                .parse::<u64>()
                .map_err(|_| usage(format!("{flag} needs {kind}, got {value:?}")))
        };
        match flag {
            "--pid" => {
                pid = Some(
                    value
                        .parse()
                        .map_err(|_| usage(format!("--pid needs a process id, got {value:?}")))?,
                )
            }
            "--interval-ms" => interval = Duration::from_millis(number("milliseconds")?),
            "--count" => count = Some(number("a sample count")? as usize),
            other => return Err(usage(format!("unknown flag {other:?}"))),
        }
        index += 2;
    }

    let mut taken = 0usize;
    loop {
        let observation = accessibility::observe(pid);
        println!(
            "{}",
            serde_json::to_string(&observation).map_err(io::Error::other)?
        );
        taken += 1;
        if count.is_some_and(|limit| taken >= limit) {
            return Ok(());
        }
        thread::sleep(interval);
    }
}
