use crate::{Application, Node, Rect, Snapshot, SnapshotHandle};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Capability {
    Enumerate,
    Capture,
    RetainedHandles,
    ObserveChanges,
    Invoke,
    ReadValue,
    SetValue,
    Focus,
    Scroll,
    PointerInput,
    KeyboardInput,
    Screenshot,
    HitTest,
    SerializeHistory,
    ObserveGlobalInput,
}

impl Capability {
    /// The complete vocabulary in canonical order, mirrored by `knownCapabilities` in
    /// `schema/health-v1.schema.json`. Health documents report one entry per capability, so this
    /// list is what makes "unusable here" distinguishable from "older than your vocabulary".
    pub const ALL: [Capability; 15] = [
        Capability::Enumerate,
        Capability::Capture,
        Capability::RetainedHandles,
        Capability::ObserveChanges,
        Capability::Invoke,
        Capability::ReadValue,
        Capability::SetValue,
        Capability::Focus,
        Capability::Scroll,
        Capability::PointerInput,
        Capability::KeyboardInput,
        Capability::Screenshot,
        Capability::HitTest,
        Capability::SerializeHistory,
        Capability::ObserveGlobalInput,
    ];

    /// The wire name used in health documents.
    pub fn key(&self) -> &'static str {
        match self {
            Capability::Enumerate => "enumerate",
            Capability::Capture => "capture",
            Capability::RetainedHandles => "retainedHandles",
            Capability::ObserveChanges => "observeChanges",
            Capability::Invoke => "invoke",
            Capability::ReadValue => "readValue",
            Capability::SetValue => "setValue",
            Capability::Focus => "focus",
            Capability::Scroll => "scroll",
            Capability::PointerInput => "pointerInput",
            Capability::KeyboardInput => "keyboardInput",
            Capability::Screenshot => "screenshot",
            Capability::HitTest => "hitTest",
            Capability::SerializeHistory => "serializeHistory",
            Capability::ObserveGlobalInput => "observeGlobalInput",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapabilityInfo {
    pub capability: Capability,
    pub usable: bool,
    pub restriction: Option<String>,
}

#[derive(Clone, Debug, PartialEq, thiserror::Error)]
pub enum BackendError {
    #[error("capability {capability:?} is unavailable: {reason}")]
    Capability {
        capability: Capability,
        reason: String,
        diagnostic: Option<String>,
    },
    #[error("operation {operation} failed: {message}")]
    Operation {
        operation: String,
        message: String,
        diagnostic: Option<String>,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AppQuery {
    pub name: Option<String>,
    pub identifier: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Observation {
    pub changed: bool,
    pub reason: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Screenshot {
    pub bytes: Vec<u8>,
    pub media_type: String,
    pub width: u32,
    pub height: u32,
    pub frame: Rect,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RecordedCall {
    pub tool: String,
    pub params: Value,
    pub result: Value,
}

/// What a keyboard action was asked to deliver.
///
/// Two intents rather than one string, because no backend can tell them apart after the fact:
/// `End` is three characters as text and one keystroke as a key, and `ctrl+c` is a chord or eight
/// literal characters depending only on which parameter the caller used. The tool surface requires
/// exactly one of `text` and `key` for this reason, and the trait carries that decision through
/// rather than re-guessing it at the point of dispatch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyboardIntent<'a> {
    /// Literal characters, entered exactly as given.
    Text(&'a str),
    /// A recognized key or chord such as `End`, `Return`, or `ctrl+shift+p`. An unrecognized name
    /// is refused rather than typed.
    Key(&'a str),
}

impl KeyboardIntent<'_> {
    pub fn as_str(&self) -> &str {
        match self {
            KeyboardIntent::Text(text) => text,
            KeyboardIntent::Key(key) => key,
        }
    }
}

/// Narrow native boundary. Native objects and status codes remain behind this trait.
pub trait PlatformBackend {
    fn capabilities(&self) -> Result<Vec<CapabilityInfo>, BackendError>;
    fn enumerate_applications(&self) -> Result<Vec<Application>, BackendError>;
    fn capture(&mut self, app: &AppQuery) -> Result<Snapshot, BackendError>;
    fn invoke(&mut self, target: &SnapshotHandle, action: &str) -> Result<(), BackendError>;
    fn read_value(&self, target: &SnapshotHandle) -> Result<Option<String>, BackendError>;
    fn set_value(&mut self, target: &SnapshotHandle, value: &str) -> Result<(), BackendError>;
    fn focus(&mut self, target: &SnapshotHandle) -> Result<(), BackendError>;
    fn scroll(&mut self, target: &SnapshotHandle, delta: (f64, f64)) -> Result<(), BackendError>;
    fn observe(&mut self, app: &AppQuery, timeout: Duration) -> Result<Observation, BackendError>;
    fn wait_for_value(
        &mut self,
        target: &SnapshotHandle,
        predicate: &Value,
        timeout: Duration,
    ) -> Result<Observation, BackendError>;
    fn pointer_click(&mut self, point: (f64, f64)) -> Result<(), BackendError>;
    fn pointer_drag(
        &mut self,
        from: (f64, f64),
        to: (f64, f64),
        duration: Duration,
    ) -> Result<(), BackendError>;
    fn keyboard(&mut self, app: &AppQuery, intent: KeyboardIntent<'_>) -> Result<(), BackendError>;
    fn screenshot(&mut self, app: &AppQuery) -> Result<Screenshot, BackendError>;
    fn hit_test(&mut self, point: (f64, f64)) -> Result<Option<Node>, BackendError>;
    fn recorded_calls(&self) -> Result<Vec<RecordedCall>, BackendError>;
    fn set_recording(&mut self, enabled: bool) -> Result<(), BackendError>;
    fn observe_global_input(
        &mut self,
        timeout: Duration,
    ) -> Result<Vec<RecordedCall>, BackendError>;

    /// Whether this backend can run a transactional foreground escalation: capture the prior
    /// foreground, activate the target, prove it came forward, and hand the session back.
    ///
    /// False by default, and that default is load-bearing. The foreground rung is not merely
    /// "global input" — it is global input that restores what it borrowed. A backend that cannot
    /// do all of that must not offer the rung at all, because unrestored global input is exactly
    /// what the delivery contract exists to prevent. Reporting `delivery: "foreground"` for a bare
    /// `SendInput` or `XTest` call would claim a guarantee the backend does not keep.
    fn supports_foreground_transaction(&self) -> bool {
        false
    }

    /// Stable identity of whatever currently holds the foreground.
    fn frontmost_application(&mut self) -> Result<Option<String>, BackendError> {
        Err(BackendError::Capability {
            capability: Capability::Focus,
            reason: "this backend cannot read the foreground application".into(),
            diagnostic: None,
        })
    }

    /// Brings `identity` forward. Returns whether the request was accepted; the caller still has to
    /// prove the target actually came forward by reading the foreground back.
    fn activate_application(&mut self, identity: &str) -> Result<bool, BackendError> {
        let _ = identity;
        Err(BackendError::Capability {
            capability: Capability::Focus,
            reason: "this backend cannot activate an application".into(),
            diagnostic: None,
        })
    }

    /// The stable identity of the application an `AppQuery` names, spelled exactly the way
    /// `frontmost_application` and `activate_application` spell it.
    ///
    /// A foreground escalation aimed at an application compares and activates that string, and a
    /// request carries a display name or a caller-visible identifier instead. Without this
    /// translation an aimed action can never match what the backend answers with, and would refuse
    /// every time.
    ///
    /// `Ok(None)` means no application matched. A caller must not read that as "whatever is
    /// frontmost": posting global input at an application the request never named is precisely what
    /// the transaction exists to prevent.
    fn resolve_application(&mut self, app: &AppQuery) -> Result<Option<String>, BackendError> {
        let _ = app;
        Ok(None)
    }

    /// Where the real pointer is now, in the same screen coordinates a dispatch is aimed with.
    ///
    /// `Ok(None)` is the answer of a backend with no pointer to speak of: a dispatch here cannot
    /// move one, so there is nothing to put back. `Err` is a different answer — the backend has a
    /// pointer and could not read it, which means a dispatch that moves the cursor would have
    /// nowhere to return it to. The foreground transaction treats the two differently.
    fn pointer_location(&mut self) -> Result<Option<(f64, f64)>, BackendError> {
        Ok(None)
    }

    /// Puts the real pointer back at `to`. Returns whether the request was accepted; as with
    /// activation, the caller proves the outcome by reading the location back rather than trusting
    /// the acknowledgement.
    fn move_pointer(&mut self, to: (f64, f64)) -> Result<bool, BackendError> {
        let _ = to;
        Err(BackendError::Capability {
            capability: Capability::PointerInput,
            reason: "this backend cannot move the pointer".into(),
            diagnostic: None,
        })
    }
}
