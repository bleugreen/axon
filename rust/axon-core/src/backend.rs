use crate::{Application, Node, Rect, Snapshot, SnapshotHandle};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
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

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
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
    pub frame: Rect,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RecordedCall {
    pub tool: String,
    pub params: Value,
    pub result: Value,
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
    fn keyboard(&mut self, app: &AppQuery, input: &str) -> Result<(), BackendError>;
    fn screenshot(&mut self, app: &AppQuery) -> Result<Screenshot, BackendError>;
    fn hit_test(&mut self, point: (f64, f64)) -> Result<Option<Node>, BackendError>;
    fn recorded_calls(&self) -> Result<Vec<RecordedCall>, BackendError>;
    fn set_recording(&mut self, enabled: bool) -> Result<(), BackendError>;
    fn observe_global_input(
        &mut self,
        timeout: Duration,
    ) -> Result<Vec<RecordedCall>, BackendError>;
}
