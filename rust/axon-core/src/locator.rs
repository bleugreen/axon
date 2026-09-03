use crate::{Node, Rect, Snapshot, SnapshotHandle, SnapshotId};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Debug, PartialEq)]
pub enum TextMatcher {
    Exact { value: String, case_sensitive: bool },
    Contains { value: String, case_sensitive: bool },
}

impl TextMatcher {
    pub fn matches(&self, actual: Option<&str>) -> bool {
        let Some(actual) = actual else { return false };
        let (expected, sensitive, contains) = match self {
            Self::Exact {
                value,
                case_sensitive,
            } => (value, *case_sensitive, false),
            Self::Contains {
                value,
                case_sensitive,
            } => (value, *case_sensitive, true),
        };
        let (actual, expected) = if sensitive {
            (actual.to_owned(), expected.to_owned())
        } else {
            (
                actual.to_lowercase().nfc().collect(),
                expected.to_lowercase().nfc().collect(),
            )
        };
        if contains {
            actual.contains(&expected)
        } else {
            actual == expected
        }
    }
    pub fn reason(&self) -> String {
        match self {
            Self::Exact { value, .. } => format!("exact {value}"),
            Self::Contains { value, .. } => format!("contains {value}"),
        }
    }
}

impl<'de> Deserialize<'de> for TextMatcher {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Wire {
            Bare(String),
            Object {
                exact: Option<String>,
                contains: Option<String>,
                #[serde(default, rename = "caseSensitive")]
                case_sensitive: bool,
            },
        }
        match Wire::deserialize(d)? {
            Wire::Bare(value) => Ok(Self::Exact {
                value,
                case_sensitive: false,
            }),
            Wire::Object {
                exact: Some(value),
                contains: None,
                case_sensitive,
            } => Ok(Self::Exact {
                value,
                case_sensitive,
            }),
            Wire::Object {
                exact: None,
                contains: Some(value),
                case_sensitive,
            } => Ok(Self::Contains {
                value,
                case_sensitive,
            }),
            _ => Err(serde::de::Error::custom(
                "text matcher must contain exactly one of exact or contains",
            )),
        }
    }
}
impl Serialize for TextMatcher {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut m = s.serialize_map(None)?;
        match self {
            Self::Exact {
                value,
                case_sensitive,
            } => {
                m.serialize_entry("exact", value)?;
                if *case_sensitive {
                    m.serialize_entry("caseSensitive", case_sensitive)?
                }
            }
            Self::Contains {
                value,
                case_sensitive,
            } => {
                m.serialize_entry("contains", value)?;
                if *case_sensitive {
                    m.serialize_entry("caseSensitive", case_sensitive)?
                }
            }
        };
        m.end()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AncestorLocator {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subrole: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identifier: Option<TextMatcher>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<TextMatcher>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<TextMatcher>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Locator {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subrole: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<TextMatcher>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<TextMatcher>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<TextMatcher>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<TextMatcher>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identifier: Option<TextMatcher>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ancestors: Vec<AncestorLocator>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<AncestorLocator>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub nearby_text: Vec<TextMatcher>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame: Option<Rect>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ResolutionStatus {
    Unique,
    Ambiguous,
    Missing,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Confidence {
    None,
    Low,
    Medium,
    High,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub index: usize,
    pub handle: SnapshotHandle,
    pub role: String,
    pub title: Option<String>,
    pub frame: Option<Rect>,
    pub score: i64,
    pub reasons: Vec<String>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Resolution {
    pub status: ResolutionStatus,
    pub snapshot_id: SnapshotId,
    pub confidence: Confidence,
    pub best: Option<Candidate>,
    pub candidates: Vec<Candidate>,
}

/// The locator a durable artifact keeps: identity, plus the least scope that still finds one
/// element in the observation it was captured from.
///
/// A recording or a saved script outlives the interface state it was written from, so it may only
/// claim what stays true about an element. `value` is state rather than identity — for an editable
/// element the very action being recorded changes it, so pinning it guarantees the locator drifts
/// on its own first replay, and it copies whatever the user had on screen into the artifact.
/// `frame`, `actions`, and `nearbyText` describe a moment rather than an element, and score only as
/// tie-breakers. What remains is the durable half: role, subrole, and the names an interface gives
/// a control.
///
/// Scope comes back only when identity alone is not enough — the window first, then ancestors from
/// the nearest outward — and each rung is judged by the resolver itself against `captured`, so this
/// never invents a second definition of what a locator matches. `None` means no rung resolves
/// uniquely: the caller records a point fallback rather than persisting a half-pinned locator that
/// cannot find its element again.
pub fn persisted_locator(recorded: &Locator, captured: &Snapshot) -> Option<Locator> {
    let mut minimal = Locator {
        role: recorded.role.clone(),
        subrole: recorded.subrole.clone(),
        title: recorded.title.clone(),
        label: recorded.label.clone(),
        description: recorded.description.clone(),
        identifier: recorded.identifier.clone(),
        ..Locator::default()
    };
    if resolves_uniquely(&minimal, captured) {
        return Some(minimal);
    }
    if recorded.window.is_some() {
        minimal.window = recorded.window.clone();
        if resolves_uniquely(&minimal, captured) {
            return Some(minimal);
        }
    }
    for depth in 1..=recorded.ancestors.len() {
        minimal.ancestors = recorded.ancestors[recorded.ancestors.len() - depth..].to_vec();
        if resolves_uniquely(&minimal, captured) {
            return Some(minimal);
        }
    }
    None
}

fn resolves_uniquely(locator: &Locator, snapshot: &Snapshot) -> bool {
    LocatorResolver::resolve(locator, snapshot).status == ResolutionStatus::Unique
}

/// An observation reduced to what a [`persisted_locator`] can match on.
///
/// Minimizing a locator is a question about the capture it came from, and the semantic-name
/// registry answers that question long after the capture is gone. Retaining the observation itself
/// would retain every element value — the document the user was editing — for as long as the name
/// lives, which is the state a persisted locator exists to leave behind. The skeleton keeps
/// identity, window titles, and tree shape, so the resolver returns the same candidates it would
/// have found in the full tree for any locator restricted to those fields, and nothing more.
pub(crate) fn identity_skeleton(snapshot: &Snapshot) -> Snapshot {
    fn skeleton(node: &Node) -> Node {
        Node {
            role: node.role.clone(),
            subrole: node.subrole.clone(),
            title: node.title.clone(),
            label: node.label.clone(),
            description: node.description.clone(),
            identifier: node.identifier.clone(),
            children: node.children.iter().map(skeleton).collect(),
            name: None,
            value: None,
            actions: Vec::new(),
            frame: None,
            editable: false,
            focused: None,
            enabled: None,
            child_count: None,
            truncation_reason: None,
        }
    }
    Snapshot {
        id: snapshot.id.clone(),
        app: crate::Application {
            name: snapshot.app.name.clone(),
            process_id: snapshot.app.process_id,
            identifier: snapshot.app.identifier.clone(),
            windows: snapshot
                .app
                .windows
                .iter()
                .map(|window| crate::Window {
                    title: window.title.clone(),
                    root: skeleton(&window.root),
                })
                .collect(),
        },
    }
}

pub struct LocatorResolver;
impl LocatorResolver {
    pub fn resolve(locator: &Locator, snapshot: &Snapshot) -> Resolution {
        let mut indexed = Vec::new();
        let mut index = 0;
        for window in &snapshot.app.windows {
            walk(&window.root, &[], &[], &mut index, &mut indexed);
        }
        let mut candidates: Vec<_> = indexed
            .into_iter()
            .filter_map(|(i, n, a, s)| candidate(locator, snapshot, i, n, &a, &s))
            .collect();
        candidates.sort_by(|a, b| b.score.cmp(&a.score).then(a.index.cmp(&b.index)));
        let status = if candidates.is_empty() {
            ResolutionStatus::Missing
        } else if candidates.len() == 1 || candidates[0].score > candidates[1].score {
            ResolutionStatus::Unique
        } else {
            ResolutionStatus::Ambiguous
        };
        let best = if status == ResolutionStatus::Unique {
            candidates.first().cloned()
        } else {
            None
        };
        let semantic = best.as_ref().map_or(0, |b| b.score / 1000);
        let confidence = if status != ResolutionStatus::Unique {
            Confidence::None
        } else if semantic >= 4 {
            Confidence::High
        } else if semantic >= 2 {
            Confidence::Medium
        } else if semantic >= 1 {
            Confidence::Low
        } else {
            Confidence::None
        };
        Resolution {
            status,
            snapshot_id: snapshot.id.clone(),
            confidence,
            best,
            candidates,
        }
    }
}

fn walk<'a>(
    node: &'a Node,
    ancestors: &[&'a Node],
    siblings: &[&'a Node],
    index: &mut usize,
    out: &mut Vec<(usize, &'a Node, Vec<&'a Node>, Vec<&'a Node>)>,
) {
    let current = *index;
    *index += 1;
    out.push((current, node, ancestors.to_vec(), siblings.to_vec()));
    let mut next = ancestors.to_vec();
    next.push(node);
    for (i, child) in node.children.iter().enumerate() {
        let peers = node
            .children
            .iter()
            .enumerate()
            .filter_map(|(j, n)| (i != j).then_some(n))
            .collect::<Vec<_>>();
        walk(child, &next, &peers, index, out)
    }
}
fn node_label(n: &Node) -> Option<&str> {
    n.label
        .as_deref()
        .or(n.title.as_deref())
        .or(n.name.as_deref())
        .or(n.value.as_deref())
        .or(n.description.as_deref())
        .or(n.identifier.as_deref())
}
fn ancestor_matches(l: &AncestorLocator, n: &Node) -> bool {
    l.role.as_ref().is_none_or(|x| x == &n.role)
        && l.subrole
            .as_ref()
            .is_none_or(|x| n.subrole.as_ref() == Some(x))
        && l.identifier
            .as_ref()
            .is_none_or(|x| x.matches(n.identifier.as_deref()))
        && l.title
            .as_ref()
            .is_none_or(|x| x.matches(n.title.as_deref()))
        && l.label
            .as_ref()
            .is_none_or(|x| x.matches(n.label.as_deref()))
}
fn add_match(
    m: &Option<TextMatcher>,
    actual: Option<&str>,
    label: &str,
    reasons: &mut Vec<String>,
) -> bool {
    match m {
        None => true,
        Some(m) if m.matches(actual) => {
            reasons.push(format!("{label} {}", m.reason()));
            true
        }
        Some(_) => false,
    }
}
fn candidate(
    locator: &Locator,
    snapshot: &Snapshot,
    index: usize,
    node: &Node,
    ancestors: &[&Node],
    siblings: &[&Node],
) -> Option<Candidate> {
    let mut reasons = Vec::new();
    if let Some(role) = &locator.role {
        if role != &node.role {
            return None;
        }
        reasons.push(format!("role {role}"));
    }
    if let Some(subrole) = &locator.subrole {
        if node.subrole.as_ref() != Some(subrole) {
            return None;
        }
        reasons.push(format!("subrole {subrole}"));
    }
    if !add_match(&locator.title, node.title.as_deref(), "title", &mut reasons)
        || !add_match(&locator.label, node.label.as_deref(), "label", &mut reasons)
        || !add_match(
            &locator.description,
            node.description.as_deref(),
            "description",
            &mut reasons,
        )
        || !add_match(
            &locator.identifier,
            node.identifier.as_deref(),
            "identifier",
            &mut reasons,
        )
    {
        return None;
    }
    if let Some(value) = &locator.value {
        if value.matches(node.value.as_deref()) {
            reasons.push(format!("value {}", value.reason()))
        } else if !node.editable {
            return None;
        }
    }
    if let Some(expected) = &locator.window {
        let actual = snapshot.app.windows.iter().find(|window| {
            std::iter::once(node)
                .chain(ancestors.iter().copied())
                .any(|candidate| std::ptr::eq(&window.root, candidate))
        })?;
        if !window_matches(expected, actual) {
            return None;
        }
        reasons.push("window scope".into());
        add_scoped_match_reasons("window", expected, &mut reasons);
    }
    let mut start = 0;
    for expected in &locator.ancestors {
        let offset = ancestors[start..]
            .iter()
            .position(|n| ancestor_matches(expected, n))?;
        start += offset + 1;
        add_scoped_match_reasons("ancestor", expected, &mut reasons);
    }
    for action in &locator.actions {
        if node.actions.contains(action) {
            reasons.push(format!("action {action}"))
        }
    }
    for matcher in &locator.nearby_text {
        if siblings
            .iter()
            .chain(ancestors.iter())
            .any(|n| matcher.matches(node_label(n)))
        {
            reasons.push(format!("nearby text {}", matcher.reason()))
        }
    }
    let mut base = reasons.len() as i64;
    if locator
        .value
        .as_ref()
        .is_some_and(|m| m.matches(node.value.as_deref()))
    {
        base += 2
    }
    let geometry = match (locator.frame, node.frame) {
        (Some(e), Some(a)) if base > 0 => {
            let dx = (e.x + e.width / 2.0) - (a.x + a.width / 2.0);
            let dy = (e.y + e.height / 2.0) - (a.y + a.height / 2.0);
            let d = dx.hypot(dy) / e.width.hypot(e.height).max(1.0);
            (100 - (d * 100.0).round() as i64).max(0)
        }
        _ => 0,
    };
    if geometry > 0 {
        reasons.push(format!("frame proximity {geometry}"))
    }
    Some(Candidate {
        index,
        handle: snapshot.handle(index),
        role: node.role.clone(),
        title: node.title.clone(),
        frame: node.frame,
        score: base * 1000 + geometry,
        reasons,
    })
}

fn add_scoped_match_reasons(prefix: &str, locator: &AncestorLocator, reasons: &mut Vec<String>) {
    if let Some(subrole) = &locator.subrole {
        reasons.push(format!("{prefix} subrole {subrole}"));
    }
    if let Some(identifier) = &locator.identifier {
        reasons.push(format!("{prefix} identifier {}", identifier.reason()));
    }
    if let Some(title) = &locator.title {
        reasons.push(format!("{prefix} title {}", title.reason()));
    }
    if let Some(label) = &locator.label {
        reasons.push(format!("{prefix} label {}", label.reason()));
    }
    if prefix == "ancestor"
        && let Some(role) = &locator.role
    {
        reasons.push(format!("ancestor role {role}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Application, SnapshotId, Window};
    use serde_json::json;

    fn tree(value: serde_json::Value) -> Node {
        serde_json::from_value(value).expect("test node")
    }

    fn snapshot(windows: Vec<(&str, serde_json::Value)>) -> Snapshot {
        Snapshot {
            id: SnapshotId("capture".into()),
            app: Application {
                name: "App".into(),
                process_id: None,
                identifier: Some("com.example.App".into()),
                windows: windows
                    .into_iter()
                    .map(|(title, root)| Window {
                        title: Some(title.into()),
                        root: tree(root),
                    })
                    .collect(),
            },
        }
    }

    /// The locator the shared pipeline derives for one node of an observation — the input
    /// `persisted_locator` is handed in production, ancestry and all.
    fn recorded(snapshot: &Snapshot, index: usize) -> Locator {
        let mut contexts = Vec::new();
        for window in &snapshot.app.windows {
            crate::semantic_name::walk_context(
                &window.root,
                &[],
                window.title.as_deref(),
                &mut contexts,
            );
        }
        let (node, ancestors, window) = &contexts[index];
        crate::semantic_name::locator(node, ancestors, *window)
    }

    fn document_window(text: &str) -> serde_json::Value {
        json!({
            "role": "AXWindow",
            "title": "Untitled",
            "children": [{
                "role": "AXTextArea",
                "identifier": "document",
                "value": text,
                "editable": true,
                "actions": ["AXConfirm"],
                "frame": {"x": 0.0, "y": 0.0, "width": 600.0, "height": 400.0}
            }]
        })
    }

    #[test]
    fn persisted_locator_keeps_identity_and_drops_captured_state() {
        let text = "the whole document the user was editing".repeat(64);
        let capture = snapshot(vec![("Untitled", document_window(&text))]);
        let recorded = recorded(&capture, 1);
        assert!(
            recorded.value.is_some() && recorded.frame.is_some(),
            "the pipeline locator is the one carrying capture state"
        );

        let persisted = persisted_locator(&recorded, &capture).expect("identity alone is unique");

        assert_eq!(persisted.role.as_deref(), Some("AXTextArea"));
        assert_eq!(
            persisted.identifier,
            Some(TextMatcher::Exact {
                value: "document".into(),
                case_sensitive: false
            })
        );
        assert_eq!(persisted.value, None);
        assert_eq!(persisted.frame, None);
        assert!(persisted.actions.is_empty());
        assert!(persisted.nearby_text.is_empty());
        assert!(persisted.ancestors.is_empty());
        assert_eq!(persisted.window, None);

        let serialized = serde_json::to_string(&persisted).unwrap();
        assert!(!serialized.contains(&text[..32]), "{serialized}");
        for absent in ["value", "frame", "actions", "nearbyText", "ancestors", "window"] {
            assert!(!serialized.contains(absent), "{absent} in {serialized}");
        }
    }

    #[test]
    fn persisted_locator_adds_the_window_when_identity_repeats_across_windows() {
        let submit = json!({
            "role": "AXWindow",
            "children": [{"role": "AXButton", "title": "Submit"}]
        });
        let capture = snapshot(vec![("Order", submit.clone()), ("Invoice", submit)]);

        let persisted = persisted_locator(&recorded(&capture, 1), &capture)
            .expect("the window disambiguates the pair");

        assert_eq!(
            persisted.window.and_then(|window| window.title),
            Some(TextMatcher::Exact {
                value: "Order".into(),
                case_sensitive: false
            })
        );
        assert!(
            persisted.ancestors.is_empty(),
            "ancestors are not reached while the window is enough"
        );
    }

    #[test]
    fn persisted_locator_adds_ancestors_only_when_the_window_is_not_enough() {
        let capture = snapshot(vec![(
            "Settings",
            json!({
                "role": "AXWindow",
                "children": [
                    {"role": "AXGroup", "title": "Billing",
                     "children": [{"role": "AXButton", "title": "Edit"}]},
                    {"role": "AXGroup", "title": "Shipping",
                     "children": [{"role": "AXButton", "title": "Edit"}]}
                ]
            }),
        )]);

        let persisted =
            persisted_locator(&recorded(&capture, 2), &capture).expect("the group disambiguates");

        assert_eq!(persisted.ancestors.len(), 1, "{persisted:?}");
        assert_eq!(persisted.ancestors[0].role.as_deref(), Some("AXGroup"));
        assert_eq!(
            persisted.ancestors[0].title,
            Some(TextMatcher::Exact {
                value: "Billing".into(),
                case_sensitive: false
            })
        );
        assert_eq!(
            LocatorResolver::resolve(&persisted, &capture).status,
            ResolutionStatus::Unique
        );
    }

    #[test]
    fn persisted_locator_declines_when_no_recorded_scope_disambiguates() {
        let capture = snapshot(vec![(
            "Settings",
            json!({
                "role": "AXWindow",
                "children": [{"role": "AXGroup", "children": [
                    {"role": "AXButton", "title": "Edit", "frame": {"x": 0.0, "y": 0.0, "width": 10.0, "height": 10.0}},
                    {"role": "AXButton", "title": "Edit", "frame": {"x": 40.0, "y": 0.0, "width": 10.0, "height": 10.0}}
                ]}]
            }),
        )]);

        assert_eq!(
            persisted_locator(&recorded(&capture, 2), &capture),
            None,
            "two identical siblings are separated only by geometry, which is not durable"
        );
    }

    #[test]
    fn identity_skeleton_answers_uniqueness_like_the_observation_it_came_from() {
        let text = "private notes".repeat(32);
        let capture = snapshot(vec![
            ("Untitled", document_window(&text)),
            (
                "Untitled",
                json!({"role": "AXWindow", "children": [{"role": "AXTextArea", "identifier": "document", "value": "other"}]}),
            ),
        ]);
        let recorded = recorded(&capture, 1);
        let skeleton = identity_skeleton(&capture);

        assert!(!serde_json::to_string(&skeleton).unwrap().contains("private notes"));
        assert_eq!(
            persisted_locator(&recorded, &skeleton),
            persisted_locator(&recorded, &capture),
            "the skeleton must decide scope exactly as the full observation does"
        );
        assert_eq!(
            persisted_locator(&recorded, &skeleton),
            None,
            "two windows sharing a title leave nothing durable to pin"
        );
    }
}

fn window_matches(locator: &AncestorLocator, window: &crate::Window) -> bool {
    locator
        .role
        .as_ref()
        .is_none_or(|role| role == &window.root.role)
        && locator
            .subrole
            .as_ref()
            .is_none_or(|subrole| window.root.subrole.as_ref() == Some(subrole))
        && locator
            .identifier
            .as_ref()
            .is_none_or(|matcher| matcher.matches(window.root.identifier.as_deref()))
        && locator.title.as_ref().is_none_or(|matcher| {
            matcher.matches(window.title.as_deref().or(window.root.title.as_deref()))
        })
        && locator
            .label
            .as_ref()
            .is_none_or(|matcher| matcher.matches(window.root.label.as_deref()))
}
