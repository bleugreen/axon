//! The macOS background delivery table: which actions can reach an application without activating
//! it and without touching the real pointer, and the measurement behind each answer.
//!
//! Both halves are properties of the delivery mechanism, `CGEventPostToPid`, rather than of any
//! application, because one observation explains every row the acceptance campaign measured
//! (`scripts/macos-toolkit-acceptance/README.md`): posting to a process bypasses the window
//! server's hit testing. A mouse or wheel event delivered that way carries window number 0 and no
//! window receives it. A key event is routed by the application itself to its own key window, so
//! it reaches the focused control as an ordinary keystroke would.
//!
//! That is why there is no per-application allowlist here. A bundle identifier is the only key a
//! backend can read at dispatch time, and keying a mechanism-level fact on it would refuse every
//! application nobody happened to measure for a reason that has nothing to do with them.
//!
//! Dispatch is not delivery. An available application rung licenses a dispatch, never goal
//! success; `success` still needs a readback or a declared postcondition.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use axon_core::KeyboardIntent;

/// The measured rows the pointer refusal rests on: every target refused a pid-targeted click.
/// Spelled out in [`PID_POINTER_REFUSED`] for the caller, and listed here so the tests can hold
/// each against the committed results.
#[cfg_attr(not(test), allow(dead_code))]
pub const POINTER_EVIDENCE: &[&str] = &[
    "safari-click-2026-08-16",
    "chrome-click-2026-08-16",
    "electron-click-2026-08-16",
    "AxonAcceptanceTarget-click-2026-08-16",
    "AxonAcceptanceWebView-click-2026-08-16",
];

/// Why no pointer action, click or wheel, has an application rung on macOS, for any application.
///
/// It names the mechanism rather than the target, because a caller told "this application
/// declined" would reasonably try another one, and every application refuses for the same reason.
pub const PID_POINTER_REFUSED: &str = "macOS delivers no window-bound mouse event to a process: \
     CGEventPostToPid bypasses window-server hit testing, so a posted click or wheel event arrives \
     with window number 0 and no window receives it (measured refused on safari-click-2026-08-16, \
     chrome-click-2026-08-16, electron-click-2026-08-16, AxonAcceptanceTarget-click-2026-08-16, \
     and AxonAcceptanceWebView-click-2026-08-16)";

/// The measured rows the keyboard availability rests on, across WebKit, Chromium, Electron,
/// AppKit, and an embedded WKWebView. Mechanism evidence, not an allowlist: an application absent
/// from this list is available all the same.
pub const KEYBOARD_EVIDENCE: &[&str] = &[
    "safari-keyboard-2026-08-16",
    "chrome-keyboard-2026-08-16",
    "electron-keyboard-2026-08-16",
    "AxonAcceptanceTarget-keyboard-2026-08-16",
    "AxonAcceptanceWebView-keyboard-2026-08-16",
];

/// The one event construction the keyboard rows measured. A denylist entry must cite a row
/// measured with exactly this variant; a report from any other construction says nothing about it.
pub const KEYBOARD_VARIANT: &str = "keyDown+keyUp/source=null";

/// Why a keystroke holding a modifier has no application rung.
pub const MODIFIED_KEYSTROKES_UNMEASURED: &str = "modified keystrokes were not measured at the \
     application rung: every measured row posted unmodified keyDown+keyUp pairs, and a chord such as \
     cmd+s is a different variant";

/// Why a keyboard request naming no application has no application rung.
pub const NO_APPLICATION_NAMED: &str = "keyboard input naming no application is addressed at \
     whatever holds the foreground, so there is no process to post it to";

/// An application measured not to act on application-rung keystrokes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DenylistEntry {
    pub bundle_id: &'static str,
    pub reason: &'static str,
    /// Row ids in `scripts/macos-toolkit-acceptance/results.json`, each measured with
    /// [`KEYBOARD_VARIANT`] and refused.
    pub evidence: &'static [&'static str],
}

/// Applications that do not act on `CGEventPostToPid` keystrokes.
///
/// Empty, because no measured row has refused. An entry enters only on a refused row measured at
/// [`KEYBOARD_VARIANT`]; a field report against another event construction (the Swift daemon's
/// layout-translated keystrokes, a different event source) does not qualify, because it measured a
/// different thing. There is no version keying: availability is a property of the mechanism, and
/// a version pin would carry no information about it.
pub const DENYLIST: &[DenylistEntry] = &[];

/// One running application a keystroke can be posted to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApplicationProcess {
    pub process_identifier: i32,
    /// The bundle identifier, or `pid:<n>` for an application with no bundle.
    pub identity: String,
}

/// Whether the application rung can carry one keyboard request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApplicationPlan {
    Bound(ApplicationProcess),
    /// The rung's specific obstacle, carried intact to the caller.
    Unavailable(String),
}

/// Decides the application rung for one keyboard request. Pure: the planner may discard the answer
/// and refuse before anything native happens.
///
/// `process` is `None` for a request that named no application. A request that named one and did
/// not resolve is refused before the ladder runs, because falling through would post into whatever
/// the user is working in.
pub fn application_keyboard_availability(
    process: Option<ApplicationProcess>,
    intent: KeyboardIntent<'_>,
    denylist: &[DenylistEntry],
) -> ApplicationPlan {
    if let KeyboardIntent::Key(spec) = intent
        && crate::input::has_modifiers(spec).unwrap_or(true)
    {
        return ApplicationPlan::Unavailable(MODIFIED_KEYSTROKES_UNMEASURED.into());
    }
    let Some(process) = process else {
        return ApplicationPlan::Unavailable(NO_APPLICATION_NAMED.into());
    };
    if let Some(entry) = denylist
        .iter()
        .find(|entry| entry.bundle_id == process.identity)
    {
        return ApplicationPlan::Unavailable(format!(
            "{} does not act on keystrokes posted to its process: {} (measured on {})",
            entry.bundle_id,
            entry.reason,
            entry.evidence.join(", ")
        ));
    }
    ApplicationPlan::Bound(process)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const RESULTS: &str = include_str!("../../../scripts/macos-toolkit-acceptance/results.json");

    fn row(id: &str) -> Value {
        let results: Value = serde_json::from_str(RESULTS).expect("the committed results parse");
        results["rows"]
            .as_array()
            .expect("results carry rows")
            .iter()
            .find(|row| row["id"] == id)
            .cloned()
            .unwrap_or_else(|| panic!("{id} is cited but is not a measured row"))
    }

    fn process(identity: &str) -> Option<ApplicationProcess> {
        Some(ApplicationProcess {
            process_identifier: 4242,
            identity: identity.into(),
        })
    }

    #[test]
    fn the_shipped_denylist_is_empty() {
        assert!(
            DENYLIST.is_empty(),
            "an entry needs a refused row at {KEYBOARD_VARIANT}"
        );
    }

    /// The table is constants and prose, and the measurement is JSON in another directory; this is
    /// the only thing that stops the two from drifting apart.
    #[test]
    fn every_cited_row_exists_and_says_what_it_is_cited_for() {
        for id in POINTER_EVIDENCE {
            let row = row(id);
            assert_eq!(row["action"], "click", "{id}");
            assert_eq!(row["mechanism"], "CGEventPostToPid", "{id}");
            assert_eq!(row["verdict"], "refused", "{id}");
            assert!(
                PID_POINTER_REFUSED.contains(id),
                "{id} is not named in the refusal"
            );
        }
        for id in KEYBOARD_EVIDENCE {
            let row = row(id);
            assert_eq!(row["action"], "keyboard", "{id}");
            assert_eq!(row["mechanism"], "CGEventPostToPid", "{id}");
            assert_eq!(row["variant"], KEYBOARD_VARIANT, "{id}");
            assert_eq!(row["verdict"], "accepted", "{id}");
        }
        for entry in DENYLIST {
            assert!(
                !entry.evidence.is_empty(),
                "{} cites nothing",
                entry.bundle_id
            );
            for id in entry.evidence {
                let row = row(id);
                assert_eq!(row["action"], "keyboard", "{id}");
                assert_eq!(row["variant"], KEYBOARD_VARIANT, "{id}");
                assert_eq!(row["verdict"], "refused", "{id}");
                assert_eq!(
                    row["target"]["identity"]["bundleId"], entry.bundle_id,
                    "{id} measured a different application"
                );
            }
        }
    }

    #[test]
    fn an_application_nobody_measured_is_available() {
        assert_eq!(
            application_keyboard_availability(
                process("com.apple.TextEdit"),
                KeyboardIntent::Text("hello"),
                DENYLIST
            ),
            ApplicationPlan::Bound(process("com.apple.TextEdit").unwrap())
        );
        assert!(matches!(
            application_keyboard_availability(
                process("pid:77"),
                KeyboardIntent::Key("Return"),
                DENYLIST
            ),
            ApplicationPlan::Bound(_)
        ));
    }

    #[test]
    fn chords_and_unaimed_requests_are_unavailable() {
        assert_eq!(
            application_keyboard_availability(
                process("com.apple.TextEdit"),
                KeyboardIntent::Key("cmd+s"),
                DENYLIST
            ),
            ApplicationPlan::Unavailable(MODIFIED_KEYSTROKES_UNMEASURED.into())
        );
        assert_eq!(
            application_keyboard_availability(None, KeyboardIntent::Text("x"), DENYLIST),
            ApplicationPlan::Unavailable(NO_APPLICATION_NAMED.into())
        );
    }

    #[test]
    fn a_denylisted_bundle_is_unavailable_with_its_evidence_named() {
        const ENTRY: DenylistEntry = DenylistEntry {
            bundle_id: "com.example.Deaf",
            reason: "its terminal view reads only window-server routed key events",
            evidence: &["deaf-keyboard-2099-01-01"],
        };
        let ApplicationPlan::Unavailable(reason) = application_keyboard_availability(
            process("com.example.Deaf"),
            KeyboardIntent::Text("x"),
            &[ENTRY],
        ) else {
            panic!("a denylisted bundle has no application rung")
        };
        assert!(reason.contains("com.example.Deaf"), "{reason}");
        assert!(reason.contains("deaf-keyboard-2099-01-01"), "{reason}");
    }
}
