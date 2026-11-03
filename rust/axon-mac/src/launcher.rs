//! What the bundle's main executable does when it is opened rather than supervised.
//!
//! `Axon.app/Contents/MacOS/Axon` is this binary, so Finder, `open`, and Spotlight start it with
//! no verb. launchd starts it the same way, but with `AXON_DAEMON_MANAGED_BY_LAUNCHD=1` in its
//! environment. Only the supervised launch may serve: a person opening the app wants the installed
//! daemon and its menu running, which is `axon start`'s job, and a second hand-launched daemon
//! would only lose the socket lock to the one launchd owns. So an unsupervised, verb-less launch
//! inside Axon's own bundle runs the bundled CLI's `start` and exits with its status.
//!
//! Anything outside a bundle keeps serving, which is how `cargo run` and the benches use it. A
//! bundle with any other identifier refuses instead of launching: its CLI's `start` would act on
//! the *production* registration, and a bench or development bundle must never reach it by
//! accident.

use std::path::{Path, PathBuf};

/// The identifier of the only bundle whose open runs the launcher.
pub const AXON_BUNDLE_IDENTIFIER: &str = "com.bleugreen.axon";

/// Set by every launchd job that runs this binary as the daemon.
pub const LAUNCHD_MANAGED_KEY: &str = "AXON_DAEMON_MANAGED_BY_LAUNCHD";

/// Where the CLI lives inside the bundle.
pub const BUNDLED_CLI_RELATIVE_PATH: &str = "Contents/Resources/bin/axon";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Entry {
    Serve,
    Mcp,
    Probe(Vec<String>),
    Version,
    /// Run `<cli> start` for the bundle that was opened, then exit with its status.
    Launch { bundle: PathBuf, cli: PathBuf },
    /// Opened inside a bundle that is not Axon's: refuse rather than touch any registration.
    Refuse {
        bundle: PathBuf,
        identifier: Option<String>,
    },
    Usage,
}

/// Chooses what this process does from its arguments (without argv\[0\]), whether launchd
/// manages it, and where its executable lives.
///
/// `identifier_of` reads a bundle's `CFBundleIdentifier`; it is a parameter so the decision is
/// testable without a bundle on disk.
pub fn select(
    arguments: &[String],
    managed: bool,
    executable: &Path,
    identifier_of: impl Fn(&Path) -> Option<String>,
) -> Entry {
    // LaunchServices on older systems appends a process serial number argument; it is not a verb.
    let mut verbs = arguments.iter().filter(|argument| !argument.starts_with("-psn_"));
    match verbs.next().map(String::as_str) {
        Some("serve") => Entry::Serve,
        Some("mcp") => Entry::Mcp,
        Some("probe") => Entry::Probe(verbs.cloned().collect()),
        Some("version" | "--version") => Entry::Version,
        Some(_) => Entry::Usage,
        None if managed => Entry::Serve,
        None => match enclosing_bundle(executable) {
            None => Entry::Serve,
            Some(bundle) => match identifier_of(&bundle) {
                Some(identifier) if identifier == AXON_BUNDLE_IDENTIFIER => Entry::Launch {
                    cli: bundle.join(BUNDLED_CLI_RELATIVE_PATH),
                    bundle,
                },
                identifier => Entry::Refuse { bundle, identifier },
            },
        },
    }
}

/// `<X>.app` when `executable` is `<X>.app/Contents/MacOS/<name>`, the one place a bundle's main
/// executable can be.
pub fn enclosing_bundle(executable: &Path) -> Option<PathBuf> {
    let macos = executable.parent()?;
    let contents = macos.parent()?;
    let bundle = contents.parent()?;
    (macos.file_name()? == "MacOS"
        && contents.file_name()? == "Contents"
        && bundle.extension()? == "app")
        .then(|| bundle.to_path_buf())
}

/// `CFBundleIdentifier` from an XML `Info.plist`, the form `scripts/package-app` writes. A plist
/// this cannot read yields no identifier, which refuses: the launcher acts only on a bundle it has
/// positively identified as Axon's.
pub fn bundle_identifier(bundle: &Path) -> Option<String> {
    let plist = std::fs::read_to_string(bundle.join("Contents/Info.plist")).ok()?;
    let pattern =
        regex::Regex::new(r"<key>CFBundleIdentifier</key>\s*<string>([^<]*)</string>").ok()?;
    Some(pattern.captures(&plist)?.get(1)?.as_str().trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAIN: &str = "/Applications/Axon.app/Contents/MacOS/Axon";

    fn axon(_: &Path) -> Option<String> {
        Some(AXON_BUNDLE_IDENTIFIER.to_owned())
    }

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn opening_axon_app_runs_the_bundled_cli_start() {
        assert_eq!(
            select(&[], false, Path::new(MAIN), axon),
            Entry::Launch {
                bundle: PathBuf::from("/Applications/Axon.app"),
                cli: PathBuf::from("/Applications/Axon.app/Contents/Resources/bin/axon"),
            }
        );
    }

    #[test]
    fn a_process_serial_number_argument_is_not_a_verb() {
        assert!(matches!(
            select(&args(&["-psn_0_12345"]), false, Path::new(MAIN), axon),
            Entry::Launch { .. }
        ));
    }

    #[test]
    fn launchd_supervision_serves_without_a_verb() {
        assert_eq!(select(&[], true, Path::new(MAIN), axon), Entry::Serve);
    }

    #[test]
    fn an_explicit_serve_serves_even_when_opened_unsupervised() {
        assert_eq!(
            select(&args(&["serve"]), false, Path::new(MAIN), axon),
            Entry::Serve
        );
    }

    #[test]
    fn a_binary_outside_any_bundle_keeps_serving() {
        for executable in [
            "/Users/dev/axon/rust/target/release/axon-mac",
            "/tmp/Contents/MacOS/Axon",
            "/tmp/Axon.app/Contents/Resources/bin/axon",
        ] {
            assert_eq!(
                select(&[], false, Path::new(executable), axon),
                Entry::Serve,
                "{executable}"
            );
        }
    }

    #[test]
    fn a_bench_or_development_bundle_refuses_rather_than_touching_the_registration() {
        let bench = Path::new("/Users/dev/AxonBench/AxonMacDev.app/Contents/MacOS/AxonMacDev");
        assert_eq!(
            select(&[], false, bench, |_| Some("dev.axon.mac-bench".to_owned())),
            Entry::Refuse {
                bundle: PathBuf::from("/Users/dev/AxonBench/AxonMacDev.app"),
                identifier: Some("dev.axon.mac-bench".to_owned()),
            }
        );
        assert!(matches!(
            select(&[], false, Path::new(MAIN), |_| None),
            Entry::Refuse {
                identifier: None,
                ..
            }
        ));
    }

    #[test]
    fn verbs_keep_their_meaning() {
        assert_eq!(
            select(&args(&["mcp"]), false, Path::new(MAIN), axon),
            Entry::Mcp
        );
        assert_eq!(
            select(&args(&["--version"]), true, Path::new(MAIN), axon),
            Entry::Version
        );
        assert_eq!(
            select(&args(&["probe", "look", "x"]), false, Path::new(MAIN), axon),
            Entry::Probe(args(&["look", "x"]))
        );
        assert_eq!(
            select(&args(&["install"]), false, Path::new(MAIN), axon),
            Entry::Usage
        );
    }

    #[test]
    fn reads_the_identifier_package_app_writes() {
        let directory = std::env::temp_dir().join(format!("axon-launcher-{}", std::process::id()));
        let bundle = directory.join("Axon.app");
        std::fs::create_dir_all(bundle.join("Contents")).unwrap();
        std::fs::write(
            bundle.join("Contents/Info.plist"),
            "<plist><dict>\n  <key>CFBundleExecutable</key>\n  <string>Axon</string>\n  <key>CFBundleIdentifier</key>\n  <string>com.bleugreen.axon</string>\n</dict></plist>",
        )
        .unwrap();
        assert_eq!(
            bundle_identifier(&bundle).as_deref(),
            Some(AXON_BUNDLE_IDENTIFIER)
        );
        assert_eq!(bundle_identifier(&directory.join("Missing.app")), None);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
