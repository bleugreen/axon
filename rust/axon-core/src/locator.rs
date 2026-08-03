use crate::{Node, Rect, Snapshot, SnapshotHandle, SnapshotId};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

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
            (actual.to_lowercase(), expected.to_lowercase())
        };
        if contains {
            actual.contains(&expected)
        } else {
            actual == expected
        }
    }
    fn reason(&self) -> String {
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
    pub role: Option<String>,
    pub subrole: Option<String>,
    pub identifier: Option<TextMatcher>,
    pub title: Option<TextMatcher>,
    pub label: Option<TextMatcher>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Locator {
    pub role: Option<String>,
    pub subrole: Option<String>,
    pub title: Option<TextMatcher>,
    pub label: Option<TextMatcher>,
    pub value: Option<TextMatcher>,
    pub description: Option<TextMatcher>,
    pub identifier: Option<TextMatcher>,
    #[serde(default)]
    pub actions: Vec<String>,
    #[serde(default)]
    pub ancestors: Vec<AncestorLocator>,
    pub window: Option<AncestorLocator>,
    #[serde(default)]
    pub nearby_text: Vec<TextMatcher>,
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
        && l.label.as_ref().is_none_or(|x| x.matches(n.label.as_deref()))
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
    if let Some(window) = &locator.window {
        let window_node = std::iter::once(node)
            .chain(ancestors.iter().copied())
            .find(|n| {
                snapshot
                    .app
                    .windows
                    .iter()
                    .any(|w| std::ptr::eq(&w.root, *n))
            });
        let Some(w) = window_node else { return None };
        if !ancestor_matches(window, w) {
            return None;
        }
        reasons.push("window scope".into())
    }
    let mut start = 0;
    for expected in &locator.ancestors {
        let Some(offset) = ancestors[start..]
            .iter()
            .position(|n| ancestor_matches(expected, n))
        else {
            return None;
        };
        start += offset + 1;
        reasons.push("ordered ancestor".into())
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
