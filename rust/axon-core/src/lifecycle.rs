//! Platform-neutral pieces of the daemon lifecycle contract.
//!
//! Everything here is pure so it compiles and is tested on any host, not only the platform it
//! describes. The Windows and Linux lifecycles otherwise hide behind `cfg` gates where nothing
//! but the target machine could ever check them.

/// The exit-code contract every Axon CLI honors.
///
/// A consumer scripting a lifecycle depends on telling "you used this wrongly" apart from "it
/// could not be done", so the meanings are stated once here rather than at each exit site.
pub mod exit_code {
    /// A lifecycle operation succeeded, or status successfully described any state — including a
    /// daemon that is not running.
    pub const SUCCESS: i32 = 0;
    /// The command was used correctly and could not be completed.
    pub const FAILURE: i32 = 1;
    /// The command was used wrongly.
    pub const USAGE: i32 = 2;
}

/// Path fragments that mark a location as temporary or build-scoped.
pub const EPHEMERAL_PATH_MARKERS: &[&str] = &[
    "/.build/",
    "/target/debug/",
    "/target/release/",
    "/DerivedData/",
    "/.cairn/build-slots/",
    "/var/folders/",
    "/tmp/",
    "\\target\\debug\\",
    "\\target\\release\\",
    "\\AppData\\Local\\Temp\\",
    "\\_work\\",
];

/// Warns when a path is somewhere a daemon registration should never point.
///
/// `daemon install` registers the invoking executable, so invoking it from a build directory
/// registers a path that disappears on the next clean and a registration that can never start
/// again. Mirrored by `DaemonRegistrationPath` in `Sources/AxonCore/LaunchAgentManager.swift`.
pub fn ephemeral_path_warning(path: &str) -> Option<String> {
    let marker = EPHEMERAL_PATH_MARKERS
        .iter()
        .find(|marker| path.contains(**marker))?;
    Some(format!(
        "{path} looks like a build or temporary location (matched {marker:?}). \
         Start-at-login will fail once it is cleaned up. Install from a permanent path instead."
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_directory_install_paths_are_flagged() {
        // The failure this guards against: installing from a build slot registers a path that
        // disappears, leaving a registration that can never start again.
        assert!(
            ephemeral_path_warning("/home/agent/axon/rust/target/debug/axon-linux")
                .is_some_and(|warning| warning.contains("permanent path"))
        );
        assert!(ephemeral_path_warning(r"D:\_work\axon\target\debug\axon-win.exe").is_some());
        assert!(ephemeral_path_warning("/tmp/axon-linux").is_some());
    }

    #[test]
    fn permanent_install_paths_are_not_flagged() {
        assert!(ephemeral_path_warning("/opt/axon/0.1.7/axon-linux").is_none());
        assert!(ephemeral_path_warning(r"C:\Program Files\Axon\axon-win.exe").is_none());
    }
}
