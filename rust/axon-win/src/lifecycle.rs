//! The Windows daemon lifecycle: an interactive `ONLOGON` scheduled task for the current user.
//!
//! Deliberately free of `cfg(windows)`. Task-action rendering, registration parsing, session
//! classification, and status assembly are pure functions of their inputs, so they compile and are
//! tested on any host rather than only on the one machine that could ever exercise them. Only the
//! calls that touch Task Scheduler and the named pipe live behind the target gate in `main.rs`.

use axon_core::{
    CapabilityInfo, CapabilityState, DaemonReport, HealthPlatform, HealthReport, NotRunningHealth,
    RegistrationHealth, RegistrationMechanism, SessionHealth, reason,
};

pub const TASK_NAME: &str = "Axon Windows Daemon";
pub const PIPE: &str = r"\\.\pipe\axon-v1";

/// The interactive window station. A process outside it cannot see the desktop, whatever else is
/// true of its session.
const INTERACTIVE_WINDOW_STATION: &str = "WinSta0";

/// The command Task Scheduler runs.
///
/// Quoted because `Program Files` is the expected install location and an unquoted path with a
/// space registers a task that tries to run `C:\Program`.
pub fn task_action(executable: &str) -> String {
    format!("\"{executable}\" serve")
}

/// Reads back the executable a registered task points at.
///
/// Health reports the path Task Scheduler will actually run rather than the one this process would
/// register, so a registration left pointing at a deleted build directory is visible instead of
/// assumed correct.
pub fn registration_from_task_xml(xml: &str) -> RegistrationHealth {
    match element_text(xml, "Command") {
        Some(command) => RegistrationHealth::present(
            RegistrationMechanism::ScheduledTask,
            command.trim().trim_matches('"'),
        ),
        None => RegistrationHealth::absent(RegistrationMechanism::ScheduledTask),
    }
}

fn element_text<'a>(xml: &'a str, name: &str) -> Option<&'a str> {
    let open = format!("<{name}>");
    let close = format!("</{name}>");
    let start = xml.find(&open)? + open.len();
    let end = xml[start..].find(&close)? + start;
    Some(&xml[start..end])
}

/// Classifies the Windows session a process occupies.
///
/// Session 0 is the service session: a daemon there can bind the pipe and answer requests while
/// being structurally unable to see a single window, which is the failure mode that makes a
/// remote-shell install look like it worked. Window-station membership is checked separately
/// because a session-1 process can still be started outside the interactive desktop.
pub fn session_health(session_id: u32, window_station: Option<&str>) -> SessionHealth {
    if session_id == 0 {
        return SessionHealth::degraded(
            false,
            false,
            reason::NOT_INTERACTIVE_SESSION,
            Some(
                "Running in session 0; UI Automation requires the logged-in desktop session".into(),
            ),
        );
    }
    match window_station {
        Some(station) if station.eq_ignore_ascii_case(INTERACTIVE_WINDOW_STATION) => {
            SessionHealth::usable(Some(format!("session {session_id}")))
        }
        Some(station) => SessionHealth::degraded(
            true,
            false,
            reason::NO_GRAPHICAL_SESSION,
            Some(format!(
                "Attached to window station {station} rather than {INTERACTIVE_WINDOW_STATION}"
            )),
        ),
        None => SessionHealth::degraded(
            true,
            false,
            reason::NO_GRAPHICAL_SESSION,
            Some("No window station is attached to this process".into()),
        ),
    }
}

/// The session this process actually occupies, as Windows reports it.
///
/// This is load-bearing well beyond the health document. `WindowsBackend::capabilities` consults
/// it, and the delivery ladder consults that, so a daemon in session 0 or off the interactive
/// window station refuses pointer and keyboard actions instead of posting `SendInput` into a
/// desktop nobody is looking at. UI Automation keeps answering in those sessions, which is exactly
/// what makes the failure quiet enough to need this.
#[cfg(windows)]
pub fn current_session() -> SessionHealth {
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

/// The daemon's own answer to a `health` request.
pub fn daemon_report(
    process_id: u32,
    reported: &[CapabilityInfo],
    session: SessionHealth,
) -> DaemonReport {
    DaemonReport {
        version: env!("CARGO_PKG_VERSION").into(),
        platform: HealthPlatform::Windows,
        // Answering at all means UI Automation finished initializing, because the router only
        // exists after it does. The pipe binds earlier so a stalled startup stays observable, and
        // a request arriving in that window is never answered as ready.
        ready: true,
        process_id,
        endpoint: PIPE.into(),
        provenance: None,
        session,
        // Windows applies no per-application permission gate to UI Automation.
        permissions: vec![],
        capabilities: CapabilityState::complete(reported),
    }
}

/// The published document for a daemon whose health payload this build cannot read.
pub fn incompatible(
    registration: RegistrationHealth,
    session: SessionHealth,
    detail: Option<String>,
) -> HealthReport {
    HealthReport::incompatible(
        env!("CARGO_PKG_VERSION"),
        HealthPlatform::Windows,
        PIPE,
        registration,
        session,
        detail,
    )
}

/// The published document for a machine whose daemon did not answer.
pub fn not_running(
    registration: RegistrationHealth,
    session: SessionHealth,
    detail: Option<String>,
) -> HealthReport {
    HealthReport::not_running(NotRunningHealth {
        version: env!("CARGO_PKG_VERSION").into(),
        platform: HealthPlatform::Windows,
        endpoint: PIPE.into(),
        registration,
        session,
        code: reason::DAEMON_NOT_RUNNING,
        detail,
        permissions: vec![],
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use axon_core::Capability;

    const TASK_XML: &str = r#"<?xml version="1.0" encoding="UTF-16"?>
<Task><Actions Context="Author"><Exec>
<Command>"C:\Program Files\Axon\axon-win.exe"</Command>
<Arguments>serve</Arguments>
</Exec></Actions></Task>"#;

    #[test]
    fn scheduled_task_action_quotes_executable_paths() {
        assert_eq!(
            task_action(r"C:\Program Files\Axon\axon-win.exe"),
            r#""C:\Program Files\Axon\axon-win.exe" serve"#
        );
    }

    #[test]
    fn registration_reports_the_path_task_scheduler_will_run() {
        let registration = registration_from_task_xml(TASK_XML);

        assert!(registration.registered);
        assert_eq!(registration.mechanism, RegistrationMechanism::ScheduledTask);
        assert_eq!(
            registration.path.as_deref(),
            Some(r"C:\Program Files\Axon\axon-win.exe")
        );
    }

    #[test]
    fn an_unregistered_machine_reports_no_task() {
        let registration = registration_from_task_xml("");

        assert!(!registration.registered);
        assert_eq!(registration.reason.as_deref(), Some(reason::NOT_REGISTERED));
    }

    #[test]
    fn the_logged_in_desktop_is_interactive_and_graphical() {
        let session = session_health(1, Some("WinSta0"));

        assert!(session.interactive);
        assert!(session.graphical);
        assert_eq!(session.reason, None);
    }

    #[test]
    fn session_zero_is_not_an_interactive_session() {
        // The remote-shell case: a daemon here binds the pipe and answers, yet can never see a
        // window. Saying so is what stops an executor advertising automation it cannot perform.
        let session = session_health(0, Some("Service-0x0-3e7$"));

        assert!(!session.interactive);
        assert!(!session.graphical);
        assert_eq!(
            session.reason.as_deref(),
            Some(reason::NOT_INTERACTIVE_SESSION)
        );
    }

    #[test]
    fn a_non_interactive_window_station_has_no_desktop() {
        let session = session_health(1, Some("Service-0x0-3e7$"));

        assert!(session.interactive);
        assert!(!session.graphical);
        assert_eq!(
            session.reason.as_deref(),
            Some(reason::NO_GRAPHICAL_SESSION)
        );
    }

    #[test]
    fn health_reports_the_complete_vocabulary_including_what_windows_omits() {
        // WindowsBackend reports only what it implements. A consumer must still be able to tell
        // "this platform cannot do that" from "this Axon is older than my vocabulary".
        let reported = [CapabilityInfo {
            capability: Capability::Enumerate,
            usable: true,
            restriction: None,
        }];

        let report = daemon_report(8124, &reported, session_health(1, Some("WinSta0")));

        assert_eq!(report.capabilities.len(), Capability::ALL.len());
        assert!(report.ready);
        assert_eq!(report.endpoint, PIPE);
        let observe = report
            .capabilities
            .iter()
            .find(|state| state.capability == "observeChanges")
            .unwrap();
        assert!(!observe.usable);
        assert_eq!(observe.reason.as_deref(), Some(reason::NOT_IMPLEMENTED));
    }

    #[test]
    fn a_registered_machine_without_a_daemon_still_describes_itself() {
        let report = not_running(
            registration_from_task_xml(TASK_XML),
            session_health(0, None),
            Some("The named pipe has no listening daemon".into()),
        );

        assert!(!report.daemon.running);
        assert!(report.registration.registered);
        assert_eq!(
            report.daemon.reason.as_deref(),
            Some(reason::DAEMON_NOT_RUNNING)
        );
        assert_eq!(report.capabilities.len(), Capability::ALL.len());
    }
}
