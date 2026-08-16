//! The Linux daemon lifecycle: a systemd user unit bound to the graphical session.
//!
//! Deliberately free of `cfg(target_os = "linux")`. Unit rendering, session classification, and
//! status assembly are pure functions of their inputs, so they compile and are tested on any host
//! rather than only on the one machine that could ever exercise them. Only the calls that touch
//! systemd and the socket live behind the target gate in `main.rs`.

use axon_core::{
    CapabilityInfo, CapabilityState, DaemonReport, HealthPlatform, HealthReport, NotRunningHealth,
    PermissionState, RegistrationHealth, RegistrationMechanism, SessionHealth, reason,
};

/// The AT-SPI accessibility bus, which is the one gate Linux applies to automation.
pub const ACCESSIBILITY_BUS: &str = "accessibilityBus";

/// What a session with `org.a11y.Status.IsEnabled` false is, said once.
///
/// Chromium and its embedders read that property at process start and never join the accessibility
/// bus while it is false. On such a session those applications are not thin — they are absent,
/// which is indistinguishable from a misspelled name unless the caller is told. The same sentence
/// serves both places a caller can meet the fact: the health document's session detail, and the
/// capture refusal that names it for someone who has already asked for an application. It lives
/// here rather than in the backend because this module compiles on every host, and because one
/// sentence in two voices is how the two surfaces drift apart.
pub const ACCESSIBILITY_DISABLED: &str = "this session reports accessibility disabled \
     (org.a11y.Status.IsEnabled is false), so applications that read it at startup — Chromium, \
     Electron, and Chromium-backed webviews — are not on the bus at all";

pub const UNIT_NAME: &str = "axon.service";
const UNIT_TEMPLATE: &str = include_str!("../systemd/axon.service.in");
const EXEC_PLACEHOLDER: &str = "@EXEC@";

/// Renders the user unit for a specific executable.
pub fn unit_file(executable: &str) -> String {
    UNIT_TEMPLATE.replace(EXEC_PLACEHOLDER, &systemd_quote(executable))
}

/// Renders a path as one systemd command argument.
///
/// systemd tokenizes `ExecStart=` on whitespace and treats `%` as a specifier prefix. An
/// unquoted permanent install path such as `/opt/Axon Stable/axon-linux` would therefore register
/// a unit that tries to execute `/opt/Axon`, and a literal `%` in a path would be replaced with
/// something else. `daemon install` registers whatever path the caller invoked, so the rendering
/// has to survive any path the filesystem allows rather than only the convenient ones.
pub fn systemd_quote(path: &str) -> String {
    let mut quoted = String::with_capacity(path.len() + 2);
    quoted.push('"');
    for character in path.chars() {
        match character {
            '\\' => quoted.push_str(r"\\"),
            '"' => quoted.push_str("\\\""),
            // A specifier is introduced by one `%`; doubling it is how systemd spells a literal.
            '%' => quoted.push_str("%%"),
            _ => quoted.push(character),
        }
    }
    quoted.push('"');
    quoted
}

/// Reverses [`systemd_quote`].
pub fn systemd_unquote(value: &str) -> String {
    let inner = value
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
        .unwrap_or(value);
    let mut path = String::with_capacity(inner.len());
    let mut characters = inner.chars().peekable();
    while let Some(character) = characters.next() {
        match character {
            '\\' => {
                if let Some(escaped) = characters.next() {
                    path.push(escaped);
                }
            }
            '%' if characters.peek() == Some(&'%') => {
                characters.next();
                path.push('%');
            }
            _ => path.push(character),
        }
    }
    path
}

/// Reads back the executable a rendered unit points at.
///
/// Health reports the path systemd will actually run rather than the one this process would
/// register, so a registration left pointing at a deleted build directory is visible instead of
/// assumed correct.
pub fn unit_executable(unit: &str) -> Option<String> {
    let exec_start = unit
        .lines()
        .map(str::trim)
        .find_map(|line| line.strip_prefix("ExecStart="))?;
    let executable = exec_start.strip_suffix(" serve").unwrap_or(exec_start);
    Some(systemd_unquote(executable))
}

pub fn registration(unit: Option<&str>) -> RegistrationHealth {
    match unit.and_then(unit_executable) {
        Some(path) => RegistrationHealth::present(RegistrationMechanism::SystemdUser, path),
        None => RegistrationHealth::absent(RegistrationMechanism::SystemdUser),
    }
}

/// The desktop-session facts Axon needs, read from the environment.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionEnvironment {
    pub runtime_dir: Option<String>,
    pub session_type: Option<String>,
    pub wayland_display: Option<String>,
    pub x11_display: Option<String>,
    pub session_bus: Option<String>,
}

impl SessionEnvironment {
    pub fn from_env() -> Self {
        let read = |key: &str| std::env::var(key).ok().filter(|value| !value.is_empty());
        Self {
            runtime_dir: read("XDG_RUNTIME_DIR"),
            session_type: read("XDG_SESSION_TYPE"),
            wayland_display: read("WAYLAND_DISPLAY"),
            x11_display: read("DISPLAY"),
            session_bus: read("DBUS_SESSION_BUS_ADDRESS"),
        }
    }

    pub fn is_wayland(&self) -> bool {
        self.wayland_display.is_some() || self.session_type.as_deref() == Some("wayland")
    }

    fn has_display(&self) -> bool {
        self.wayland_display.is_some() || self.x11_display.is_some()
    }
}

/// Classifies the session independently along each axis that can fail on its own.
///
/// A host can have a user manager and a session bus and still sit at the greeter with no desktop,
/// which is the state that must report honestly rather than claim readiness. Each condition is
/// therefore checked separately instead of collapsing into one "is it working" guess.
///
/// `accessibility_enabled` is `org.a11y.Status.IsEnabled` as the daemon read it, and `None` where
/// nobody asked: the property lives on the session bus, so only a running daemon holding that
/// connection can answer it, and a CLI reporting on a daemon that never came up says nothing about
/// it rather than guessing. It is the one fact here that is not an environment variable, which is
/// why it arrives as an argument instead of being read from `env`.
pub fn session_health(
    env: &SessionEnvironment,
    accessibility_enabled: Option<bool>,
) -> SessionHealth {
    SessionHealth {
        accessibility_enabled,
        ..classify(env, accessibility_enabled)
    }
}

/// The verdict alone. Its caller stamps `accessibility_enabled` onto whichever branch answers, so
/// the fact is carried by every session this classifies and not only by the one it explains.
fn classify(env: &SessionEnvironment, accessibility_enabled: Option<bool>) -> SessionHealth {
    if env.runtime_dir.is_none() {
        return SessionHealth::degraded(
            false,
            false,
            reason::NOT_INTERACTIVE_SESSION,
            Some("XDG_RUNTIME_DIR is unset; there is no systemd user manager for this user".into()),
        );
    }
    if !env.has_display() {
        return SessionHealth::degraded(
            true,
            false,
            reason::NO_GRAPHICAL_SESSION,
            Some(
                "No WAYLAND_DISPLAY or DISPLAY is present; the host may be at the login greeter"
                    .into(),
            ),
        );
    }
    if env.session_bus.is_none() {
        return SessionHealth::degraded(
            true,
            false,
            reason::SESSION_BUS_UNAVAILABLE,
            Some("DBUS_SESSION_BUS_ADDRESS is unset, so AT-SPI cannot be reached".into()),
        );
    }
    let session_type = env.session_type.clone().unwrap_or_else(|| {
        if env.is_wayland() {
            "wayland".into()
        } else {
            "x11".into()
        }
    });
    if accessibility_enabled == Some(false) {
        // Interactive and graphical, and degraded anyway: the desktop is up and the AT-SPI bus is
        // reachable, while every Chromium-family application on it is missing from that bus. A
        // consumer that only reads the two booleans sees a healthy session, which is why this is
        // also a reason rather than only a field.
        return SessionHealth::degraded(
            true,
            true,
            reason::ACCESSIBILITY_DISABLED,
            Some(format!("{session_type}; {ACCESSIBILITY_DISABLED}")),
        );
    }
    SessionHealth::usable(Some(session_type))
}

/// Overlays the runtime restrictions the backend's static capability list cannot know about.
///
/// `LinuxBackend::capabilities()` describes what the implementation supports. Whether the running
/// desktop permits it is a separate question: the same build that can synthesize pointer input on
/// X11 cannot on Wayland. Reporting only the static list would promise things the session refuses.
pub fn capabilities(reported: &[CapabilityInfo], env: &SessionEnvironment) -> Vec<CapabilityState> {
    let mut states = CapabilityState::complete(reported);
    if !env.is_wayland() {
        return states;
    }
    for state in &mut states {
        let restricted = matches!(
            state.capability.as_str(),
            "pointerInput" | "keyboardInput" | "observeGlobalInput"
        );
        if restricted && state.usable {
            state.usable = false;
            state.reason = Some(reason::WAYLAND_RESTRICTED.into());
            state.restriction = Some(
                "Wayland does not permit unrestricted synthetic input from an ordinary client"
                    .into(),
            );
        }
    }
    states
}

/// The daemon's own answer to a `health` request.
///
/// The two accessibility facts are separate questions and neither implies the other.
/// `accessibility_bus` is whether this daemon reached the AT-SPI bus at all;
/// `accessibility_enabled` is whether the session told the applications on it to publish.
pub fn daemon_report(
    endpoint: String,
    process_id: u32,
    reported: &[CapabilityInfo],
    env: &SessionEnvironment,
    accessibility_bus: bool,
    accessibility_enabled: Option<bool>,
) -> DaemonReport {
    DaemonReport {
        version: env!("CARGO_PKG_VERSION").into(),
        platform: HealthPlatform::Linux,
        // Answering at all means the AT-SPI backend finished starting, because the socket is only
        // served after it does.
        ready: true,
        process_id,
        endpoint,
        provenance: None,
        session: session_health(env, accessibility_enabled),
        permissions: vec![if accessibility_bus {
            PermissionState::granted(ACCESSIBILITY_BUS)
        } else {
            PermissionState::ungranted(
                ACCESSIBILITY_BUS,
                reason::ATSPI_UNAVAILABLE,
                Some("The AT-SPI accessibility bus refused a connection".into()),
            )
        }],
        capabilities: capabilities(reported, env),
    }
}

/// The published document for a daemon whose health payload this build cannot read.
pub fn incompatible(
    endpoint: String,
    registration: RegistrationHealth,
    env: &SessionEnvironment,
    detail: Option<String>,
) -> HealthReport {
    HealthReport::incompatible(
        env!("CARGO_PKG_VERSION"),
        HealthPlatform::Linux,
        endpoint,
        registration,
        session_health(env, None),
        detail,
    )
}

/// The published document for a machine whose daemon did not answer.
///
/// Without a desktop the AT-SPI bus cannot be available, and saying so is more useful than
/// reporting the gate as merely undetermined. With a desktop the daemon is the only thing that
/// could have answered, so the gate is reported undetermined rather than guessed at.
pub fn not_running(
    endpoint: String,
    registration: RegistrationHealth,
    env: &SessionEnvironment,
    detail: Option<String>,
) -> HealthReport {
    // No daemon answered, so nothing held the session bus connection that could have read the
    // accessibility switch. Saying nothing about it is the honest answer, and the schema spells
    // an absent `accessibilityEnabled` as exactly that.
    let session = session_health(env, None);
    let permission = if session.graphical {
        PermissionState::ungranted(ACCESSIBILITY_BUS, reason::DAEMON_NOT_RUNNING, None)
    } else {
        PermissionState::ungranted(ACCESSIBILITY_BUS, reason::ATSPI_UNAVAILABLE, None)
    };
    HealthReport::not_running(NotRunningHealth {
        version: env!("CARGO_PKG_VERSION").into(),
        platform: HealthPlatform::Linux,
        endpoint,
        registration,
        session,
        code: reason::DAEMON_NOT_RUNNING,
        detail,
        permissions: vec![permission],
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use axon_core::Capability;

    fn graphical() -> SessionEnvironment {
        SessionEnvironment {
            runtime_dir: Some("/run/user/1000".into()),
            session_type: Some("wayland".into()),
            wayland_display: Some("wayland-0".into()),
            x11_display: None,
            session_bus: Some("unix:path=/run/user/1000/bus".into()),
        }
    }

    #[test]
    fn the_unit_runs_the_registered_executable_and_binds_to_the_desktop() {
        let unit = unit_file("/opt/axon/0.1.7/axon-linux");

        assert!(unit.contains("ExecStart=\"/opt/axon/0.1.7/axon-linux\" serve"));
        assert!(unit.contains("WantedBy=graphical-session.target"));
        assert!(unit.contains("Restart=on-failure"));
        // A system service would run outside the user's session and could never reach AT-SPI.
        assert!(!unit.contains("multi-user.target"));
        assert!(!unit.contains(EXEC_PLACEHOLDER));
    }

    #[test]
    fn the_unit_bounds_the_memory_a_misbehaving_daemon_can_take() {
        // A daemon that grows without bound must die alone. This machine class hosts CI runners
        // beside the desktop, and an unbounded Axon has taken one down twice; the bound plus the
        // restart above turns that into a blip.
        let unit = unit_file("/opt/axon/0.1.7/axon-linux");

        assert!(unit.contains("MemoryHigh=512M"));
        assert!(unit.contains("MemoryMax=1G"));
    }

    #[test]
    fn a_permanent_path_with_spaces_stays_one_argument() {
        // systemd splits ExecStart on whitespace, so an unquoted path here would register a unit
        // that executes /opt/Axon. `daemon install` registers whatever path the caller invoked,
        // and a directory with a space in it is an ordinary permanent install location.
        let unit = unit_file("/opt/Axon Stable/axon-linux");

        assert!(unit.contains(r#"ExecStart="/opt/Axon Stable/axon-linux" serve"#));
        assert_eq!(
            unit_executable(&unit).as_deref(),
            Some("/opt/Axon Stable/axon-linux")
        );
    }

    #[test]
    fn a_percent_in_a_path_is_not_a_systemd_specifier() {
        // %h would otherwise expand to the user home directory.
        let unit = unit_file("/opt/axon-100%h/axon-linux");

        assert!(unit.contains(r#"ExecStart="/opt/axon-100%%h/axon-linux" serve"#));
        assert_eq!(
            unit_executable(&unit).as_deref(),
            Some("/opt/axon-100%h/axon-linux")
        );
    }

    #[test]
    fn quotes_and_backslashes_survive_the_round_trip() {
        for path in [
            r#"/opt/axon "quoted"/axon-linux"#,
            r"/opt/axon\backslash/axon-linux",
            "/opt/axon/axon-linux",
        ] {
            assert_eq!(
                unit_executable(&unit_file(path)).as_deref(),
                Some(path),
                "{path} did not round-trip"
            );
        }
    }

    #[test]
    fn registration_reports_the_path_systemd_will_run() {
        let unit = unit_file("/opt/axon/0.1.7/axon-linux");

        let installed = registration(Some(&unit));

        assert!(installed.registered);
        assert_eq!(installed.mechanism, RegistrationMechanism::SystemdUser);
        assert_eq!(
            installed.path.as_deref(),
            Some("/opt/axon/0.1.7/axon-linux")
        );
        assert!(!registration(None).registered);
    }

    #[test]
    fn a_logged_in_desktop_is_interactive_and_graphical() {
        let session = session_health(&graphical(), Some(true));

        assert!(session.interactive);
        assert!(session.graphical);
        assert_eq!(session.reason, None);
        assert_eq!(session.accessibility_enabled, Some(true));
    }

    #[test]
    fn a_session_with_accessibility_off_is_degraded_while_still_being_a_desktop() {
        // The state AXN-84 measured: the desktop is up, the AT-SPI bus answers, and every
        // Chromium-family application is absent from it. Reporting only the two booleans would
        // publish that session as healthy, which is the hole this fact fills.
        let session = session_health(&graphical(), Some(false));

        assert!(session.interactive && session.graphical);
        assert_eq!(session.accessibility_enabled, Some(false));
        assert_eq!(
            session.reason.as_deref(),
            Some(reason::ACCESSIBILITY_DISABLED)
        );
        let detail = session.detail.expect("a disabled session explains itself");
        assert!(
            detail.starts_with("wayland; "),
            "the session type survives alongside the explanation: {detail}"
        );
        assert!(detail.contains("org.a11y.Status.IsEnabled"));
    }

    #[test]
    fn a_switch_nobody_read_is_not_reported_as_off() {
        // `None` is the CLI's answer whenever no daemon held the session bus. Absent means no
        // claim; publishing it as false would invent a broken desktop out of a missing daemon.
        let session = session_health(&graphical(), None);

        assert_eq!(session.accessibility_enabled, None);
        assert_eq!(session.reason, None);
    }

    #[test]
    fn a_greeter_outranks_the_accessibility_switch_and_still_carries_it() {
        // One reason slot, filled by the most total statement: a host with no desktop is not
        // meaningfully a host whose Chromium trees are missing. The fact itself is still data.
        let env = SessionEnvironment {
            wayland_display: None,
            x11_display: None,
            ..graphical()
        };

        let session = session_health(&env, Some(false));

        assert_eq!(
            session.reason.as_deref(),
            Some(reason::NO_GRAPHICAL_SESSION)
        );
        assert_eq!(session.accessibility_enabled, Some(false));
    }

    #[test]
    fn the_daemon_document_carries_both_accessibility_facts_separately() {
        // Reaching the bus and being told to publish are different questions: this daemon is on
        // the bus, and the session has switched the applications off.
        let report = daemon_report(
            "/run/user/1000/axon-v1.sock".into(),
            17,
            &[],
            &graphical(),
            true,
            Some(false),
        );

        assert!(report.permissions[0].granted, "the bus itself answered");
        assert_eq!(report.session.accessibility_enabled, Some(false));
        assert_eq!(
            report.session.reason.as_deref(),
            Some(reason::ACCESSIBILITY_DISABLED)
        );
    }

    #[test]
    fn the_greeter_is_interactive_without_a_desktop() {
        // The Fedora-at-greeter case: a user manager exists, no desktop does. Reporting this as a
        // transport failure would make an executor advertise automation it cannot perform.
        let env = SessionEnvironment {
            wayland_display: None,
            x11_display: None,
            ..graphical()
        };

        let session = session_health(&env, None);

        assert!(session.interactive);
        assert!(!session.graphical);
        assert_eq!(
            session.reason.as_deref(),
            Some(reason::NO_GRAPHICAL_SESSION)
        );
    }

    #[test]
    fn a_missing_user_manager_is_not_an_interactive_session() {
        let session = session_health(&SessionEnvironment::default(), None);

        assert!(!session.interactive);
        assert_eq!(
            session.reason.as_deref(),
            Some(reason::NOT_INTERACTIVE_SESSION)
        );
    }

    #[test]
    fn a_desktop_without_a_session_bus_cannot_reach_atspi() {
        let env = SessionEnvironment {
            session_bus: None,
            ..graphical()
        };

        assert_eq!(
            session_health(&env, None).reason.as_deref(),
            Some(reason::SESSION_BUS_UNAVAILABLE)
        );
    }

    #[test]
    fn wayland_withdraws_synthetic_input_the_backend_claims_to_support() {
        let reported = [
            CapabilityInfo {
                capability: Capability::PointerInput,
                usable: true,
                restriction: None,
            },
            CapabilityInfo {
                capability: Capability::Enumerate,
                usable: true,
                restriction: None,
            },
        ];

        let states = capabilities(&reported, &graphical());
        let find = |key: &str| states.iter().find(|s| s.capability == key).unwrap();

        assert!(!find("pointerInput").usable);
        assert_eq!(
            find("pointerInput").reason.as_deref(),
            Some(reason::WAYLAND_RESTRICTED)
        );
        assert!(find("enumerate").usable);
    }

    #[test]
    fn x11_leaves_synthetic_input_alone() {
        let env = SessionEnvironment {
            session_type: Some("x11".into()),
            wayland_display: None,
            x11_display: Some(":0".into()),
            ..graphical()
        };
        let reported = [CapabilityInfo {
            capability: Capability::PointerInput,
            usable: true,
            restriction: None,
        }];

        let states = capabilities(&reported, &env);

        assert!(
            states
                .iter()
                .find(|s| s.capability == "pointerInput")
                .unwrap()
                .usable
        );
    }

    #[test]
    fn an_older_daemon_is_running_rather_than_absent() {
        // Upgrading in place leaves the new binary on disk and the old daemon still serving.
        // Calling that "not running" would send an operator looking for a process that is there.
        let report = incompatible(
            "/run/user/1000/axon-v1.sock".into(),
            registration(None),
            &graphical(),
            Some("missing field `version`".into()),
        );

        assert!(report.daemon.running);
        assert!(!report.daemon.ready);
        assert_eq!(report.daemon.reason.as_deref(), Some(reason::VERSION_SKEW));
        assert_eq!(report.capabilities.len(), Capability::ALL.len());
    }

    #[test]
    fn a_greeter_without_a_daemon_names_atspi_rather_than_guessing() {
        let env = SessionEnvironment {
            wayland_display: None,
            x11_display: None,
            ..graphical()
        };

        let report = not_running(
            "/run/user/1000/axon-v1.sock".into(),
            registration(Some(&unit_file("/opt/axon/0.1.7/axon-linux"))),
            &env,
            None,
        );

        assert!(!report.daemon.running);
        assert!(report.registration.registered);
        assert_eq!(
            report.permissions[0].reason.as_deref(),
            Some(reason::ATSPI_UNAVAILABLE)
        );
        assert_eq!(report.capabilities.len(), Capability::ALL.len());
    }
}
