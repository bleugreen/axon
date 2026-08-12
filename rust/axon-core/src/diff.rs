//! Pure semantic comparison of named accessibility snapshots.
//!
//! Ambiguous names are paired only at the same candidate ordinal and only when their identity
//! keys agree. Duplicate order is a conservative correspondence hint; it is never permission to
//! pair unrelated controls.

use crate::{Node, SemanticElementName, SemanticNameResolution, Snapshot};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashSet;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SemanticDiff {
    pub added: Vec<AddedElement>,
    pub removed: Vec<String>,
    pub changed: Vec<FieldChange>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AddedElement {
    pub name: String,
    pub role: String,
    pub label: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FieldChange {
    pub name: String,
    pub field: String,
    pub from: Value,
    pub to: Value,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DiffPolicy {
    threshold: f64,
}

impl Default for DiffPolicy {
    fn default() -> Self {
        Self { threshold: 0.5 }
    }
}

impl DiffPolicy {
    pub fn new(threshold: f64) -> Result<Self, DiffError> {
        if threshold.is_finite() && (0.0..=1.0).contains(&threshold) {
            Ok(Self { threshold })
        } else {
            Err(DiffError::InvalidThreshold)
        }
    }

    pub fn threshold(self) -> f64 {
        self.threshold
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum DiffClassification {
    Unchanged,
    Diff(SemanticDiff),
    ThresholdExceeded,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum DiffError {
    #[error("diff threshold must be a finite fraction from zero through one")]
    InvalidThreshold,
    #[error("semantic name source index {index} is outside the snapshot preorder")]
    SourceIndexOutOfBounds { index: usize },
    #[error("semantic name source index {index} occurs more than once")]
    DuplicateSourceIndex { index: usize },
    #[error("ambiguous semantic name {name:?} has a malformed candidate label")]
    MalformedCandidateLabel { name: String },
}

struct Entry<'a> {
    semantic: &'a SemanticElementName,
    node: &'a Node,
    ordinal: Option<usize>,
}

pub fn classify_semantic_diff(
    baseline: &Snapshot,
    baseline_names: &[SemanticElementName],
    fresh: &Snapshot,
    fresh_names: &[SemanticElementName],
    policy: DiffPolicy,
) -> Result<DiffClassification, DiffError> {
    let baseline = entries(baseline, baseline_names)?;
    let fresh = entries(fresh, fresh_names)?;
    let mut baseline_matched = vec![false; baseline.len()];
    let mut fresh_match = vec![None; fresh.len()];

    for (fresh_index, fresh_entry) in fresh.iter().enumerate() {
        if let Some((baseline_index, _)) = baseline.iter().enumerate().find(|(index, entry)| {
            !baseline_matched[*index] && compatible(entry, fresh_entry)
        }) {
            baseline_matched[baseline_index] = true;
            fresh_match[fresh_index] = Some(baseline_index);
        }
    }

    let removed = baseline
        .iter()
        .enumerate()
        .filter(|(index, _)| !baseline_matched[*index])
        .map(|(_, entry)| entry.semantic.name.clone())
        .collect::<Vec<_>>();
    let added = fresh
        .iter()
        .enumerate()
        .filter(|(index, _)| fresh_match[*index].is_none())
        .map(|(_, entry)| AddedElement {
            name: entry.semantic.name.clone(),
            role: entry.semantic.role.clone(),
            label: entry.semantic.label.clone(),
        })
        .collect::<Vec<_>>();
    let mut changed = Vec::new();
    let mut changed_elements = 0;
    for (fresh_index, baseline_index) in fresh_match.iter().enumerate() {
        let Some(baseline_index) = baseline_index else { continue };
        let before = changed.len();
        compare_fields(
            baseline[*baseline_index].node,
            fresh[fresh_index].node,
            &fresh[fresh_index].semantic.name,
            &mut changed,
        );
        changed_elements += usize::from(changed.len() != before);
    }

    let diff = SemanticDiff { added, removed, changed };
    if diff.added.is_empty() && diff.removed.is_empty() && diff.changed.is_empty() {
        return Ok(DiffClassification::Unchanged);
    }
    let denominator = baseline.len().max(fresh.len());
    let cost = diff.added.len() + diff.removed.len() + changed_elements;
    if denominator != 0 && cost as f64 / denominator as f64 > policy.threshold {
        Ok(DiffClassification::ThresholdExceeded)
    } else {
        Ok(DiffClassification::Diff(diff))
    }
}

fn entries<'a>(
    snapshot: &'a Snapshot,
    names: &'a [SemanticElementName],
) -> Result<Vec<Entry<'a>>, DiffError> {
    let mut nodes = Vec::new();
    fn collect<'a>(node: &'a Node, nodes: &mut Vec<&'a Node>) {
        nodes.push(node);
        for child in &node.children { collect(child, nodes); }
    }
    for window in &snapshot.app.windows { collect(&window.root, &mut nodes); }

    let mut seen = HashSet::new();
    let mut result = Vec::new();
    for semantic in names {
        if !seen.insert(semantic.source_index) {
            return Err(DiffError::DuplicateSourceIndex { index: semantic.source_index });
        }
        let node = *nodes.get(semantic.source_index).ok_or(DiffError::SourceIndexOutOfBounds {
            index: semantic.source_index,
        })?;
        if is_noise(node) { continue; }
        let ordinal = match semantic.resolution {
            SemanticNameResolution::Unique => None,
            SemanticNameResolution::Ambiguous => Some(candidate_ordinal(semantic)?),
        };
        result.push(Entry { semantic, node, ordinal });
    }
    Ok(result)
}

fn candidate_ordinal(name: &SemanticElementName) -> Result<usize, DiffError> {
    let prefix = format!("{}-", name.name);
    name.candidate_label
        .as_deref()
        .and_then(|label| label.strip_prefix(&prefix))
        .and_then(|ordinal| ordinal.parse::<usize>().ok())
        .filter(|ordinal| *ordinal > 0)
        .ok_or_else(|| DiffError::MalformedCandidateLabel { name: name.name.clone() })
}

fn compatible(left: &Entry<'_>, right: &Entry<'_>) -> bool {
    left.semantic.name == right.semantic.name
        && left.semantic.resolution == right.semantic.resolution
        && left.ordinal == right.ordinal
        && left.semantic.identity_key == right.semantic.identity_key
}

fn normalized_role(role: &str) -> String {
    role.chars().filter(|c| c.is_ascii_alphanumeric()).flat_map(char::to_lowercase).collect()
}

fn is_noise(node: &Node) -> bool {
    let role = normalized_role(&node.role);
    if matches!(role.as_str(), "scrollbar" | "axscrollbar" | "indicator" | "scrollindicator" | "axscrollindicator") {
        return true;
    }
    matches!(role.as_str(), "row" | "axrow" | "cell" | "axcell" | "group" | "axgroup" | "container" | "axcontainer")
        && [&node.title, &node.label, &node.value, &node.description, &node.identifier]
            .into_iter().all(|value| value.as_deref().is_none_or(|value| value.trim().is_empty()))
        && node.actions.is_empty()
}

fn semantic_label(node: &Node) -> Option<&str> {
    node.title.as_deref().filter(|v| !v.trim().is_empty())
        .or_else(|| node.label.as_deref().filter(|v| !v.trim().is_empty()))
}

fn compare_fields(before: &Node, after: &Node, name: &str, changes: &mut Vec<FieldChange>) {
    let fields = [
        ("role", json!(before.role), json!(after.role)),
        ("subrole", json!(before.subrole), json!(after.subrole)),
        ("label", json!(semantic_label(before)), json!(semantic_label(after))),
        ("value", json!(before.value), json!(after.value)),
        ("description", json!(before.description), json!(after.description)),
        ("identifier", json!(before.identifier), json!(after.identifier)),
        ("actions", json!(before.actions), json!(after.actions)),
        ("editable", json!(before.editable), json!(after.editable)),
        ("childCount", json!(before.child_count), json!(after.child_count)),
        ("truncationReason", json!(before.truncation_reason), json!(after.truncation_reason)),
    ];
    changes.extend(fields.into_iter().filter_map(|(field, from, to)| {
        (from != to).then(|| FieldChange { name: name.into(), field: field.into(), from, to })
    }));
}
+
+#[cfg(test)]
+mod tests {
+    use super::*;
+    use crate::{Application, Rect, SemanticNameDeriver, SnapshotId, Window};
+
+    fn node(role: &str, label: Option<&str>) -> Node {
+        Node {
+            role: role.into(), subrole: None, name: None, title: None,
+            label: label.map(Into::into), value: None, description: None,
+            identifier: None, actions: vec![], frame: None, editable: false,
+            children: vec![], child_count: None, truncation_reason: None,
+        }
+    }
+    fn snapshot(id: &str, children: Vec<Node>) -> Snapshot {
+        let mut root = node("window", Some("Main"));
+        root.children = children;
+        Snapshot { id: SnapshotId(id.into()), app: Application {
+            name: "Fixture".into(), identifier: Some("fixture.app".into()),
+            windows: vec![Window { title: Some("Main".into()), root }],
+        }}
+    }
+    fn classify(before: &Snapshot, after: &Snapshot) -> DiffClassification {
+        classify_semantic_diff(
+            before, &SemanticNameDeriver::derive(before),
+            after, &SemanticNameDeriver::derive(after),
+            DiffPolicy::default(),
+        ).unwrap()
+    }
+
+    #[test]
+    fn value_null_transitions_and_action_order_retain_wire_types() {
+        let before = snapshot("s1", vec![node("textField", Some("Search"))]);
+        let mut filled = node("textField", Some("Search"));
+        filled.value = Some("axon".into());
+        filled.actions = vec!["focus".into(), "setValue".into()];
+        let after = snapshot("s2", vec![filled]);
+        let DiffClassification::Diff(diff) = classify(&before, &after) else { panic!() };
+        assert_eq!(diff.changed[0].field, "value");
+        assert_eq!(diff.changed[0].from, Value::Null);
+        assert_eq!(diff.changed[0].to, json!("axon"));
+        assert_eq!(diff.changed[1].to, json!(["focus", "setValue"]));
+
+        let DiffClassification::Diff(reverse) = classify(&after, &before) else { panic!() };
+        assert_eq!(reverse.changed[0].from, json!("axon"));
+        assert_eq!(reverse.changed[0].to, Value::Null);
+    }
+
+    #[test]
+    fn frame_and_canonical_noise_are_unchanged() {
+        let mut moving = node("button", Some("Save"));
+        moving.frame = Some(Rect { x: 1.0, y: 2.0, width: 3.0, height: 4.0 });
+        let before = snapshot("s1", vec![moving.clone(), node("AXScrollBar", None), node("group", None)]);
+        moving.frame.as_mut().unwrap().x = 50.0;
+        let after = snapshot("s2", vec![moving, node("scroll-indicator", None)]);
+        assert_eq!(classify(&before, &after), DiffClassification::Unchanged);
+    }
+
+    #[test]
+    fn invalid_sources_and_identity_reuse_are_conservative() {
+        let before = snapshot("s1", vec![node("button", Some("Save"))]);
+        let after = before.clone();
+        let mut names = SemanticNameDeriver::derive(&before);
+        names[0].source_index = 99;
+        assert!(matches!(
+            classify_semantic_diff(&before, &names, &after, &SemanticNameDeriver::derive(&after), DiffPolicy::default()),
+            Err(DiffError::SourceIndexOutOfBounds { .. })
+        ));
+
+        let baseline_names = SemanticNameDeriver::derive(&before);
+        let mut fresh_names = baseline_names.clone();
+        fresh_names[1].identity_key.push_str("different");
+        let DiffClassification::ThresholdExceeded = classify_semantic_diff(
+            &before, &baseline_names, &after, &fresh_names, DiffPolicy::default()
+        ).unwrap() else { panic!() };
+    }
+
+    #[test]
+    fn threshold_counts_changed_elements_and_keeps_exact_boundary() {
+        let before = snapshot("s1", vec![node("button", Some("A")), node("button", Some("B"))]);
+        let mut changed = node("button", Some("A"));
+        changed.value = Some("new".into());
+        changed.editable = true;
+        let after = snapshot("s2", vec![changed, node("button", Some("B"))]);
+        assert!(matches!(classify(&before, &after), DiffClassification::Diff(_)));
+
+        let over = snapshot("s3", vec![node("button", Some("C")), node("button", Some("D"))]);
+        assert_eq!(classify(&before, &over), DiffClassification::ThresholdExceeded);
+        assert_eq!(DiffPolicy::new(0.5).unwrap().threshold(), 0.5);
+        assert!(DiffPolicy::new(f64::NAN).is_err());
+    }
+}
