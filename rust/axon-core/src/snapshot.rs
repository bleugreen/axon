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

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SnapshotHandle(pub String);

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Application {
    pub name: String,
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
