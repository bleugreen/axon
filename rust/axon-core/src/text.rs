use crate::{
    AppQuery, BackendError, Node, Rect, Snapshot, SnapshotHandle, SnapshotId, TextMatcher,
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TextLocationSource {
    #[default]
    Auto,
    Ax,
    Screenshot,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextLocationTarget {
    pub app: String,
    pub text: TextMatcher,
    #[serde(default)]
    pub source: TextLocationSource,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecognizedText {
    pub text: String,
    pub frame: Rect,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f64>,
}

/// Platform OCR boundary. Implementations own capture and coordinate conversion;
/// returned frames must use the same screen coordinate space as accessibility nodes.
pub trait TextRecognitionProvider {
    fn recognize_text(&mut self, app: &AppQuery) -> Result<Vec<RecognizedText>, BackendError>;
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionPoint {
    pub x: f64,
    pub y: f64,
}

impl Rect {
    pub fn center(self) -> ActionPoint {
        ActionPoint {
            x: self.x + self.width / 2.0,
            y: self.y + self.height / 2.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextLocationCandidate {
    pub index: usize,
    pub handle: Option<SnapshotHandle>,
    pub role: String,
    pub matched_text: String,
    pub source: TextLocationSource,
    pub frame: Rect,
    pub point: ActionPoint,
    pub reasons: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextLocationResolution {
    pub status: crate::ResolutionStatus,
    #[serde(rename = "snapshotID")]
    pub snapshot_id: SnapshotId,
    pub best: Option<TextLocationCandidate>,
    pub point: Option<ActionPoint>,
    pub candidates: Vec<TextLocationCandidate>,
    /// Nodes carrying a usable frame that expose no readable text in any matched
    /// attribute. Mirrors the Swift resolution field of the same name: a non-zero
    /// count on a missing AX result means the text may be rendered inside nodes
    /// accessibility cannot describe, and only screenshot OCR can reach it.
    #[serde(default)]
    pub opaque_node_count: usize,
}

pub struct TextLocationResolver;

impl TextLocationResolver {
    pub fn resolve(
        target: &TextLocationTarget,
        snapshot: &Snapshot,
        recognized: &[RecognizedText],
    ) -> TextLocationResolution {
        let ax = ax_candidates(&target.text, snapshot);
        // An empty AX result is the only case worth explaining, so the opaque-node walk
        // is confined to it and the common path pays nothing for the diagnostic.
        let opaque_node_count = match target.source {
            TextLocationSource::Screenshot => 0,
            TextLocationSource::Ax | TextLocationSource::Auto if ax.is_empty() => {
                opaque_node_count(snapshot)
            }
            _ => 0,
        };
        let candidates = match target.source {
            TextLocationSource::Ax => ax,
            TextLocationSource::Auto if !ax.is_empty() => ax,
            TextLocationSource::Auto | TextLocationSource::Screenshot => {
                ocr_candidates(&target.text, recognized)
            }
        };
        let status = match candidates.len() {
            0 => crate::ResolutionStatus::Missing,
            1 => crate::ResolutionStatus::Unique,
            _ => crate::ResolutionStatus::Ambiguous,
        };
        let best = (status == crate::ResolutionStatus::Unique).then(|| candidates[0].clone());
        let point = best.as_ref().map(|candidate| candidate.point);
        TextLocationResolution {
            status,
            snapshot_id: snapshot.id.clone(),
            best,
            point,
            candidates,
            opaque_node_count,
        }
    }
}

/// The accessibility attributes treated as a node's readable text, in the order they
/// are consulted. The Swift port carries the same ordered list as
/// `ReadableTextAttribute`, plus `help`, which this `Node` does not model. A node with
/// none of them populated is one `source: "ax"` can never match, however the text
/// renders to a human.
fn readable_attributes(node: &Node) -> [(&'static str, Option<&str>); 4] {
    [
        ("title", node.title.as_deref()),
        ("value", node.value.as_deref()),
        ("description", node.description.as_deref()),
        ("identifier", node.identifier.as_deref()),
    ]
}

/// Counts nodes that occupy space on screen yet expose no readable text at all.
fn opaque_node_count(snapshot: &Snapshot) -> usize {
    let mut nodes = Vec::new();
    for window in &snapshot.app.windows {
        flatten(&window.root, &mut nodes);
    }
    nodes
        .into_iter()
        .filter(|node| {
            node.frame
                .is_some_and(|frame| frame.width > 0.0 && frame.height > 0.0)
                && readable_attributes(node)
                    .iter()
                    .all(|(_, value)| value.is_none_or(str::is_empty))
        })
        .count()
}

fn ax_candidates(text: &TextMatcher, snapshot: &Snapshot) -> Vec<TextLocationCandidate> {
    let mut nodes = Vec::new();
    for window in &snapshot.app.windows {
        flatten(&window.root, &mut nodes);
    }
    nodes
        .into_iter()
        .enumerate()
        .filter_map(|(index, node)| {
            let frame = node
                .frame
                .filter(|frame| frame.width > 0.0 && frame.height > 0.0)?;
            let (field, matched_text) =
                readable_attributes(node)
                    .into_iter()
                    .find_map(|(field, value)| {
                        value
                            .filter(|value| text.matches(Some(value)))
                            .map(|value| (field, value))
                    })?;
            Some(TextLocationCandidate {
                index,
                handle: Some(snapshot.handle(index)),
                role: node.role.clone(),
                matched_text: matched_text.to_owned(),
                source: TextLocationSource::Ax,
                frame,
                point: frame.center(),
                reasons: vec![format!("{field} {}", text.reason())],
            })
        })
        .collect()
}

fn ocr_candidates(text: &TextMatcher, recognized: &[RecognizedText]) -> Vec<TextLocationCandidate> {
    recognized
        .iter()
        .enumerate()
        .filter(|(_, item)| text.matches(Some(&item.text)))
        .map(|(index, item)| {
            let mut reasons = vec![format!("ocr {}", text.reason())];
            if let Some(confidence) = item.confidence {
                reasons.push(format!("confidence {confidence}"));
            }
            TextLocationCandidate {
                index,
                handle: None,
                role: "OCRText".into(),
                matched_text: item.text.clone(),
                source: TextLocationSource::Screenshot,
                frame: item.frame,
                point: item.frame.center(),
                reasons,
            }
        })
        .collect()
}

fn flatten<'a>(node: &'a Node, out: &mut Vec<&'a Node>) {
    out.push(node);
    for child in &node.children {
        flatten(child, out);
    }
}
