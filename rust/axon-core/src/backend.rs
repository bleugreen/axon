use crate::{
    Application, CaptureBounds, ChildPageCapture, ChildPageRequest, Node, Rect, Snapshot,
    SnapshotHandle,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashSet, time::Duration};

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

#[cfg(test)]
mod tests {
    use super::AppQuery;

    #[test]
    fn app_query_accepts_the_legacy_serialized_shape() {
        let query: AppQuery =
            serde_json::from_str(r#"{"name":"Editor","identifier":"com.example.Editor"}"#).unwrap();
        assert_eq!(query.process_id, None);
        assert_eq!(
            serde_json::to_value(query).unwrap(),
            serde_json::json!({"name":"Editor","identifier":"com.example.Editor"})
        );
    }
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
    #[error("capability {capability:?} is unavailable: {reason}")]
    CapabilityReason {
        capability: Capability,
        code: &'static str,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub process_id: Option<crate::ProcessId>,
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
    /// Runtime process identities visible when semantic evidence is registered.
    fn live_process_ids(&self) -> Result<HashSet<crate::ProcessId>, BackendError> {
        Ok(self
            .enumerate_applications()?
            .into_iter()
            .filter_map(|application| application.process_id)
            .collect())
    }
    fn capture(&mut self, app: &AppQuery) -> Result<Snapshot, BackendError>;
    fn capture_bounded(
        &mut self,
        app: &AppQuery,
        bounds: CaptureBounds,
    ) -> Result<Snapshot, BackendError> {
        let mut snapshot = self.capture(app)?;
        if let Some(depth) = bounds.child_depth {
            fn trim(node: &mut Node, remaining: usize) {
                if remaining == 0 {
                    if !node.children.is_empty() {
                        node.child_count.get_or_insert(node.children.len());
                        node.truncation_reason
                            .get_or_insert_with(|| "depth limit reached".into());
                        node.children.clear();
                    }
                } else {
                    for child in &mut node.children {
                        trim(child, remaining - 1);
                    }
                }
            }
            for window in &mut snapshot.app.windows {
                trim(&mut window.root, depth);
            }
        }
        Ok(snapshot)
    }
    fn capture_child_page(
        &mut self,
        _target: &SnapshotHandle,
        _request: ChildPageRequest,
    ) -> Result<ChildPageCapture, BackendError> {
        Err(BackendError::Capability {
            capability: Capability::Capture,
            reason: "bounded child capture is unavailable".into(),
            diagnostic: None,
        })
    }
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

    /// The native global-input observer this backend provides.
    ///
    /// This is the whole recording seam. A platform supplies only the evidence it alone can gather
    /// — what the pointer hit, what holds focus, which application is frontmost — and shared core
    /// owns ordering, grouping, semantic target construction, history, redaction, and v2 authoring.
    /// A backend without a hook refuses here with a stable reason, which is the same state its
    /// `observeGlobalInput` capability reports, so a claim and a dispatch can never disagree.
    fn global_input_observer(
        &mut self,
    ) -> Result<&mut dyn crate::GlobalInputObserver, BackendError> {
        Err(BackendError::CapabilityReason {
            capability: Capability::ObserveGlobalInput,
            code: "observer-unavailable",
            reason: "this backend has no global input observer".into(),
            diagnostic: None,
        })
    }

    /// Whether this backend can capture the foreground, activate a target, and prove it came forward
    /// before dispatch. Cleanup still attempts and reports the hand-back on every exit path.
    ///
    /// False by default, and that default is load-bearing. A backend that cannot prove activation
    /// must not offer global input because it cannot prove where the event will land.
    fn supports_foreground_transaction(&self) -> bool {
        false
    }

    /// Why a proved, dispatched foreground action must leave its target frontmost instead of
    /// restoring the prior application. Backends return a reason only when restoring would make
    /// delivery itself unreliable; the transaction still restores on every pre-dispatch exit.
    fn post_dispatch_restoration_restriction(&self) -> Option<&'static str> {
        None
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
