use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_SNAPSHOT: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SnapshotId(pub String);

impl SnapshotId {
    pub fn fresh() -> Self {
        Self(format!(
            "s{}",
            NEXT_SNAPSHOT.fetch_add(1, Ordering::Relaxed)
        ))
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CaptureBounds {
    /// Maximum descendant depth below each top-level window. `None` uses the backend ceiling.
    pub child_depth: Option<usize>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ChildPageRequest {
    pub offset: usize,
    pub limit: Option<usize>,
    pub include_descendants: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChildPageCapture {
    pub snapshot: SnapshotId,
    pub parent: Node,
    pub offset: usize,
    pub limit: usize,
    /// `None` means the provider could not authoritatively enumerate the direct-child range.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total: Option<usize>,
    pub children: Vec<Node>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SnapshotHandle(pub String);

/// The only public element identity accepted by the cross-platform wire contract.
///
/// Snapshot handles remain an internal backend cache key. Locator evidence may be retained beside
/// a semantic name by a recorder or resolver, but neither handles nor standalone locators decode as
/// an interactive element target.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WireElementTarget {
    pub app: String,
    pub name: String,
}

impl WireElementTarget {
    pub fn validate(self) -> Result<Self, WireElementTargetError> {
        if self.app.trim().is_empty() {
            return Err(WireElementTargetError::EmptyApp);
        }
        if self.name.trim().is_empty() {
            return Err(WireElementTargetError::EmptyName);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum WireElementTargetError {
    #[error("element target app must not be empty")]
    EmptyApp,
    #[error("element target name must not be empty")]
    EmptyName,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    /// Whether this rectangle covers a point, on the half-open convention a window's own edge
    /// follows: the leading edge belongs to the window, the trailing edge to whatever is beyond it.
    ///
    /// One definition, because every backend asks this question of a screen point and two answers
    /// that disagree on an edge disagree about which window a click belongs to.
    pub fn contains(&self, (x, y): (f64, f64)) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.width && y < self.y + self.height
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Node {
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subrole: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identifier: Option<String>,
    #[serde(default)]
    pub actions: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame: Option<Rect>,
    #[serde(default)]
    pub editable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focused: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default)]
    pub children: Vec<Node>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub child_count: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub truncation_reason: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub title: Option<String>,
    pub root: Node,
}

pub type ProcessId = u32;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Application {
    pub name: String,
    #[serde(skip)]
    pub process_id: Option<ProcessId>,
    #[serde(default)]
    pub identifier: Option<String>,
    #[serde(default)]
    pub windows: Vec<Window>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub id: SnapshotId,
    pub app: Application,
}

/// Stable observable state used to decide whether an action changed an application.
///
/// A snapshot ID identifies a capture, not application state, so it is deliberately absent. The
/// summary otherwise preserves application identity, window metadata, and every observed node.
/// This is the Rust counterpart to Swift's `SnapshotSummary`, extended to the node tree because
/// the cross-platform observation model can expose ordinary control changes directly.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotSummary {
    pub app: SnapshotAppIdentity,
    pub windows: Vec<SnapshotWindowSummary>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotAppIdentity {
    pub name: String,
    pub identifier: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotWindowSummary {
    pub title: Option<String>,
    pub root: Node,
}

impl From<&Snapshot> for SnapshotSummary {
    fn from(snapshot: &Snapshot) -> Self {
        Self {
            app: SnapshotAppIdentity {
                name: snapshot.app.name.clone(),
                identifier: snapshot.app.identifier.clone(),
            },
            windows: snapshot
                .app
                .windows
                .iter()
                .map(|window| SnapshotWindowSummary {
                    title: window.title.clone(),
                    root: window.root.clone(),
                })
                .collect(),
        }
    }
}

impl Snapshot {
    pub fn new(app: Application) -> Self {
        Self {
            id: SnapshotId::fresh(),
            app,
        }
    }
    pub fn handle(&self, index: usize) -> SnapshotHandle {
        SnapshotHandle(format!("{}:{index}", self.id.0))
    }
    pub fn node(&self, index: usize) -> Option<&Node> {
        fn add<'a>(node: &'a Node, nodes: &mut Vec<&'a Node>) {
            nodes.push(node);
            for child in &node.children {
                add(child, nodes);
            }
        }
        let mut nodes = Vec::new();
        for window in &self.app.windows {
            add(&window.root, &mut nodes);
        }
        nodes.get(index).copied()
    }
    pub fn index_for_handle(&self, handle: &SnapshotHandle) -> Result<usize, HandleError> {
        let (snapshot, index) = handle.0.split_once(':').ok_or(HandleError::Malformed)?;
        if snapshot != self.id.0 {
            return Err(HandleError::Stale {
                expected: self.id.clone(),
                actual: snapshot.into(),
            });
        }
        index.parse().map_err(|_| HandleError::Malformed)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum HandleError {
    #[error("malformed snapshot handle")]
    Malformed,
    #[error("stale snapshot handle from {actual}; current snapshot is {expected:?}")]
    Stale {
        expected: SnapshotId,
        actual: String,
    },
}

#[cfg(test)]
mod summary_tests {
    use super::*;
    use serde_json::json;

    fn snapshot(value: &str) -> Snapshot {
        serde_json::from_value(json!({
            "id": "capture-id",
            "app": {
                "name": "Editor",
                "identifier": "com.example.Editor",
                "windows": [{
                    "title": "Document",
                    "root": {
                        "role": "window",
                        "children": [{"role": "textField", "value": value}]
                    }
                }]
            }
        }))
        .unwrap()
    }

    #[test]
    fn snapshot_summary_ignores_capture_identity_for_identical_observations() {
        let first = snapshot("draft");
        let mut second = first.clone();
        second.id = SnapshotId("another-capture-id".into());

        assert_eq!(
            SnapshotSummary::from(&first),
            SnapshotSummary::from(&second)
        );
    }

    #[test]
    fn snapshot_summary_detects_ordinary_control_changes() {
        let before = snapshot("draft");
        let after = snapshot("saved");

        assert_ne!(
            SnapshotSummary::from(&before),
            SnapshotSummary::from(&after)
        );
    }

    #[test]
    fn process_identity_is_runtime_only() {
        let mut snapshot = snapshot("draft");
        snapshot.app.process_id = Some(42);

        let encoded = serde_json::to_value(&snapshot).unwrap();
        assert_eq!(encoded["app"].get("process_id"), None);
        assert_eq!(encoded["app"].get("processId"), None);

        let decoded: Snapshot = serde_json::from_value(encoded).unwrap();
        assert_eq!(decoded.app.process_id, None);
    }
}
