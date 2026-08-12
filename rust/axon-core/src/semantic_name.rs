use crate::{
    AncestorLocator, Locator, LocatorResolver, Resolution, ResolutionStatus, Snapshot,
    SnapshotHandle, TextMatcher, WireElementTarget,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet, VecDeque};
use unicode_normalization::{UnicodeNormalization, char::is_combining_mark};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SemanticNameResolution {
    Unique,
    Ambiguous,
}
pub(crate) enum RetainedSemanticLookup {
    NoRecord,
    Resolved(Box<SemanticLookup>),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SemanticElementName {
    pub name: String,
    pub role: String,
    pub label: String,
    pub source_index: usize,
    pub segment_count: usize,
    pub character_count: usize,
    pub collision_free: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disambiguation: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub candidate_label: Option<String>,
    pub resolution: SemanticNameResolution,
    pub identity_key: String,
}

pub fn render_semantic_names(snapshot: &Snapshot, names: &[SemanticElementName]) -> Snapshot {
    let by_index: HashMap<_, _> = names
        .iter()
        .map(|name| (name.source_index, name.name.clone()))
        .collect();
    let mut rendered = snapshot.clone();
    let mut index = 0;
    fn render(node: &mut crate::Node, index: &mut usize, names: &HashMap<usize, String>) {
        if let Some(name) = names.get(index) {
            node.name = Some(name.clone());
        }
        *index += 1;
        for child in &mut node.children {
            render(child, index, names);
        }
    }
    for window in &mut rendered.app.windows {
        render(&mut window.root, &mut index, &by_index);
    }
    rendered
}

#[derive(Clone)]
struct Draft {
    index: usize,
    role: String,
    label: String,
    identifier: Option<String>,
    lineage: Vec<String>,
    human: Vec<bool>,
    segments: Vec<String>,
    collision_free: bool,
    disambiguation: Option<String>,
    candidate_label: Option<String>,
}

pub struct SemanticNameDeriver;
impl SemanticNameDeriver {
    pub fn derive(snapshot: &Snapshot) -> Vec<SemanticElementName> {
        let mut drafts = Vec::new();
        let mut index = 0;
        for window in &snapshot.app.windows {
            collect(&window.root, &[], &[], &mut index, &mut drafts);
        }
        disambiguate(&mut drafts);
        drafts
            .into_iter()
            .map(|d| {
                let name = d.segments.join("/");
                SemanticElementName {
                    segment_count: d.segments.len(),
                    character_count: name.chars().count(),
                    name,
                    role: d.role.clone(),
                    label: d.label.clone(),
                    source_index: d.index,
                    collision_free: d.collision_free,
                    disambiguation: d.disambiguation,
                    candidate_label: d.candidate_label,
                    resolution: if d.collision_free {
                        SemanticNameResolution::Unique
                    } else {
                        SemanticNameResolution::Ambiguous
                    },
                    identity_key: [
                        d.role,
                        d.label,
                        d.lineage.join("\u{1f}"),
                        d.identifier.unwrap_or_default(),
                    ]
                    .join("\u{1f}"),
                }
            })
            .collect()
    }
}

fn meaningful(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|v| !v.is_empty() && !v.starts_with("<redacted:"))
        .map(str::to_owned)
}
fn generated(v: &str) -> bool {
    let b = v.as_bytes();
    (v.starts_with("_NS:") && v[4..].chars().all(|c| c.is_ascii_digit()))
        || (v.starts_with("<AXUIElement 0x") && v.ends_with('>') && b.len() > 15)
}
pub fn semantic_slug(value: &str, max: usize) -> Option<String> {
    let mut raw = String::new();
    let mut dash = false;
    for c in value
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
    {
        if c.is_alphanumeric() {
            raw.push(c);
            dash = false;
        } else if !raw.is_empty() && !dash {
            raw.push('-');
            dash = true;
        }
    }
    while raw.ends_with('-') {
        raw.pop();
    }
    if raw.is_empty() {
        return None;
    }
    if raw.chars().count() <= max {
        return Some(raw);
    }
    let prefix: String = raw.chars().take(max).collect();
    let cut = prefix
        .rfind('-')
        .map(|i| &prefix[..i])
        .filter(|s| !s.is_empty())
        .unwrap_or(&prefix);
    Some(cut.to_owned())
}
fn append_distinct(mut v: Vec<String>, s: String) -> Vec<String> {
    if v.last() != Some(&s) {
        v.push(s)
    }
    v
}
fn collect(
    node: &crate::Node,
    lineage: &[String],
    human: &[bool],
    index: &mut usize,
    out: &mut Vec<Draft>,
) {
    let own = *index;
    *index += 1;
    let role = node.role.clone();
    let identifier = meaningful(node.identifier.as_deref()).filter(|v| !generated(v));
    let human_label = meaningful(node.title.as_deref())
        .or_else(|| meaningful(node.label.as_deref()))
        .or_else(|| meaningful(node.value.as_deref()))
        .or_else(|| meaningful(node.description.as_deref()));
    let raw = human_label.clone().or_else(|| identifier.clone());
    let leaf = raw.as_deref().and_then(|v| semantic_slug(v, 32));
    let landmark = matches!(
        role.as_str(),
        "menu" | "window" | "toolbar" | "list" | "web"
    )
    .then(|| role.clone());
    let segment = leaf.clone().or(landmark.clone());
    let next = segment
        .clone()
        .map(|s| append_distinct(lineage.to_vec(), s))
        .unwrap_or_else(|| lineage.to_vec());
    let next_human = segment
        .map(|s| {
            if lineage.last() == Some(&s) {
                human.to_vec()
            } else {
                let mut h = human.to_vec();
                h.push(human_label.is_some() || landmark.is_some());
                h
            }
        })
        .unwrap_or_else(|| human.to_vec());
    if let (Some(label), Some(leaf)) = (raw, leaf)
        && !matches!(
            role.as_str(),
            "item" | "cell" | "row" | "group" | "scroll" | "splitter"
        )
    {
        let mut l = lineage.to_vec();
        l.push(leaf);
        let segments = l
            .iter()
            .rev()
            .take(3)
            .cloned()
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        out.push(Draft {
            index: own,
            role,
            label,
            identifier,
            lineage: l,
            human: {
                let mut h = human.to_vec();
                h.push(human_label.is_some());
                h
            },
            segments,
            collision_free: true,
            disambiguation: None,
            candidate_label: None,
        });
    }
    for child in &node.children {
        collect(child, &next, &next_human, index, out);
    }
}
fn groups(d: &[Draft]) -> HashMap<String, Vec<usize>> {
    let mut g = HashMap::new();
    for (i, x) in d.iter().enumerate() {
        g.entry(x.segments.join("/"))
            .or_insert_with(Vec::new)
            .push(i)
    }
    g
}
fn disambiguate(d: &mut [Draft]) {
    let mut occupied: HashSet<String> = groups(d).into_keys().collect();
    for ids in groups(d).into_values().filter(|v| v.len() > 1) {
        let proposals: Vec<_> =
            ids.iter()
                .map(|&i| {
                    let x = &d[i];
                    (x.segments.len() == 3 && x.lineage.len() > 3 && x.human[x.lineage.len() - 4])
                        .then(|| {
                            let mut p = vec![x.lineage[x.lineage.len() - 4].clone()];
                            p.extend(x.segments.clone());
                            p
                        })
                })
                .collect();
        let names: Vec<_> = proposals
            .iter()
            .filter_map(|p| p.as_ref().map(|p| p.join("/")))
            .collect();
        if names.len() == ids.len()
            && names.iter().collect::<HashSet<_>>().len() == ids.len()
            && names.iter().all(|n| !occupied.contains(n))
        {
            for ((&i, p), n) in ids.iter().zip(proposals).zip(names) {
                d[i].segments = p.unwrap();
                d[i].disambiguation = Some("ancestor".into());
                occupied.insert(n);
            }
        }
    }
    qualify(d, &mut occupied, "identifier", |x| {
        x.identifier.as_deref().and_then(|v| semantic_slug(v, 24))
    });
    let gs = groups(d);
    for ids in gs.into_values().filter(|v| v.len() > 1) {
        let counts = ids.iter().fold(HashMap::new(), |mut m, &i| {
            *m.entry(d[i].role.clone()).or_insert(0) += 1;
            m
        });
        if counts.len() > 1 {
            for i in ids {
                if counts[&d[i].role] == 1 {
                    reserve(d, i, d[i].role.clone(), "role", &mut occupied)
                }
            }
        }
    }
    for ids in groups(d).into_values().filter(|v| v.len() > 1) {
        let mut ids = ids;
        ids.sort_by_key(|&i| d[i].index);
        for (ord, i) in ids.into_iter().enumerate() {
            d[i].collision_free = false;
            d[i].disambiguation = Some("ambiguous".into());
            d[i].candidate_label = Some(format!("{}-{}", d[i].segments.join("/"), ord + 1));
        }
    }
}
fn qualify<F: Fn(&Draft) -> Option<String>>(
    d: &mut [Draft],
    occupied: &mut HashSet<String>,
    kind: &str,
    f: F,
) {
    for ids in groups(d).into_values().filter(|v| v.len() > 1) {
        let vals: Vec<_> = ids.iter().map(|&i| f(&d[i])).collect();
        let mut counts = HashMap::new();
        for v in vals.iter().flatten() {
            *counts.entry(v.clone()).or_insert(0) += 1
        }
        for (&i, v) in ids.iter().zip(vals.iter()) {
            if let Some(v) = v
                && counts[v] == 1
            {
                reserve(d, i, v.clone(), kind, occupied)
            }
        }
    }
}
fn reserve(d: &mut [Draft], i: usize, base: String, kind: &str, occupied: &mut HashSet<String>) {
    let leaf = d[i].segments.last().cloned().unwrap();
    let mut suffix = base.clone();
    let mut n = 0;
    loop {
        let mut p = d[i].segments.clone();
        *p.last_mut().unwrap() = format!("{leaf}-{suffix}");
        let name = p.join("/");
        if !occupied.contains(&name) {
            d[i].segments = p;
            d[i].disambiguation = Some(kind.into());
            occupied.insert(name);
            break;
        }
        n += 1;
        suffix = if n == 1 {
            format!("{}-{kind}", suffix)
        } else {
            format!("{}-{kind}-{n}", base)
        };
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SemanticCandidate {
    pub name: String,
    pub candidate_label: Option<String>,
    pub role: String,
    pub label: String,
    pub locator: Locator,
}
#[derive(Clone)]
struct Record {
    target: WireElementTarget,
    app: crate::Application,
    snapshot_id: crate::SnapshotId,
    candidate_label: Option<String>,
    role: String,
    label: String,
    locator: Locator,
    handle: SnapshotHandle,
}
pub enum SemanticLookup {
    Unique {
        handle: SnapshotHandle,
        resolution: Resolution,
    },
    Missing {
        target: WireElementTarget,
    },
    Ambiguous {
        target: WireElementTarget,
        candidates: Vec<SemanticCandidate>,
    },
}
pub struct SemanticNameRegistry {
    max_snapshots: usize,
    order: VecDeque<crate::SnapshotId>,
    records: HashMap<crate::SnapshotId, Vec<Record>>,
}
impl Default for SemanticNameRegistry {
    fn default() -> Self {
        Self::new(8)
    }
}
impl SemanticNameRegistry {
    pub fn new(max: usize) -> Self {
        Self {
            max_snapshots: max.max(1),
            order: VecDeque::new(),
            records: HashMap::new(),
        }
    }
    pub fn register(&mut self, s: &Snapshot) -> Vec<SemanticElementName> {
        let names = SemanticNameDeriver::derive(s);
        let mut contexts = Vec::new();
        for w in &s.app.windows {
            walk_context(&w.root, &[], w.title.as_deref(), &mut contexts)
        }
        let records = names
            .iter()
            .filter_map(|n| {
                contexts.get(n.source_index).map(|(node, a, w)| Record {
                    target: WireElementTarget {
                        app: s.app.name.clone(),
                        name: n.name.clone(),
                    },
                    app: s.app.clone(),
                    snapshot_id: s.id.clone(),
                    candidate_label: n.candidate_label.clone(),
                    role: n.role.clone(),
                    label: n.label.clone(),
                    locator: locator(node, a, w.as_deref()),
                    handle: s.handle(n.source_index),
                })
            })
            .collect();
        self.order.retain(|id| id != &s.id);
        self.order.push_back(s.id.clone());
        self.records.insert(s.id.clone(), records);
        while self.order.len() > self.max_snapshots {
            if let Some(id) = self.order.pop_front() {
                self.records.remove(&id);
            }
        }
        names
    }
    pub fn resolve(&self, target: &WireElementTarget, live: &Snapshot) -> SemanticLookup {
        match self.resolve_retained(target, live) {
            RetainedSemanticLookup::NoRecord => SemanticLookup::Missing {
                target: target.clone(),
            },
            RetainedSemanticLookup::Resolved(lookup) => *lookup,
        }
    }
    pub(crate) fn resolve_retained(
        &self,
        target: &WireElementTarget,
        live: &Snapshot,
    ) -> RetainedSemanticLookup {
        if !app_matches(&target.app, &live.app) {
            return RetainedSemanticLookup::Resolved(Box::new(SemanticLookup::Missing {
                target: target.clone(),
            }));
        }
        let matches: Vec<_> = self
            .order
            .iter()
            .rev()
            .filter_map(|id| self.records.get(id))
            .flatten()
            .filter(|r| app_matches(&target.app, &r.app) && r.target.name == target.name)
            .collect();
        if matches.is_empty() {
            return RetainedSemanticLookup::NoRecord;
        }
        let newest = matches[0].snapshot_id.clone();
        let latest: Vec<_> = matches
            .into_iter()
            .filter(|r| r.snapshot_id == newest)
            .collect();
        if latest.len() > 1 {
            return RetainedSemanticLookup::Resolved(Box::new(SemanticLookup::Ambiguous {
                target: target.clone(),
                candidates: latest
                    .into_iter()
                    .map(|r| SemanticCandidate {
                        name: r.target.name.clone(),
                        candidate_label: r.candidate_label.clone(),
                        role: r.role.clone(),
                        label: r.label.clone(),
                        locator: r.locator.clone(),
                    })
                    .collect(),
            }));
        }
        if latest[0].snapshot_id == live.id {
            let validation = LocatorResolver::resolve(&latest[0].locator, live);
            if validation.status == ResolutionStatus::Unique
                && validation
                    .best
                    .as_ref()
                    .is_some_and(|best| best.handle == latest[0].handle)
            {
                return RetainedSemanticLookup::Resolved(Box::new(SemanticLookup::Unique {
                    handle: latest[0].handle.clone(),
                    resolution: validation,
                }));
            }
        }
        let result = LocatorResolver::resolve(&latest[0].locator, live);
        RetainedSemanticLookup::Resolved(Box::new(lookup_from_resolution(
            target,
            result,
            &latest[0].locator,
        )))
    }
}
pub(crate) fn lookup_from_resolution(
    target: &WireElementTarget,
    result: Resolution,
    locator: &Locator,
) -> SemanticLookup {
    match result.status {
        ResolutionStatus::Unique => SemanticLookup::Unique {
            handle: result
                .best
                .as_ref()
                .expect("unique resolution has a best candidate")
                .handle
                .clone(),
            resolution: result,
        },
        ResolutionStatus::Missing => SemanticLookup::Missing {
            target: target.clone(),
        },
        ResolutionStatus::Ambiguous => SemanticLookup::Ambiguous {
            target: target.clone(),
            candidates: result
                .candidates
                .iter()
                .map(|candidate| SemanticCandidate {
                    name: target.name.clone(),
                    candidate_label: None,
                    role: candidate.role.clone(),
                    label: candidate.title.clone().unwrap_or_default(),
                    locator: locator.clone(),
                })
                .collect(),
        },
    }
}
fn app_matches(q: &str, a: &crate::Application) -> bool {
    q.eq_ignore_ascii_case(&a.name)
        || a.identifier
            .as_deref()
            .is_some_and(|v| q.eq_ignore_ascii_case(v))
}
fn exact(v: Option<&str>) -> Option<TextMatcher> {
    meaningful(v).map(|value| TextMatcher::Exact {
        value,
        case_sensitive: false,
    })
}
fn scope(n: &crate::Node) -> AncestorLocator {
    AncestorLocator {
        role: Some(n.role.clone()),
        subrole: n.subrole.clone(),
        identifier: exact(n.identifier.as_deref()),
        title: exact(n.title.as_deref()),
        label: exact(n.label.as_deref()),
    }
}
pub(crate) fn locator(n: &crate::Node, a: &[crate::Node], window: Option<&str>) -> Locator {
    Locator {
        role: Some(n.role.clone()),
        subrole: n.subrole.clone(),
        title: exact(n.title.as_deref()),
        label: exact(n.label.as_deref()),
        value: exact(n.value.as_deref()),
        description: exact(n.description.as_deref()),
        identifier: exact(n.identifier.as_deref())
            .filter(|_| n.identifier.as_deref().is_some_and(|v| !generated(v))),
        actions: n.actions.clone(),
        ancestors: a.iter().rev().take(2).rev().map(scope).collect(),
        window: window.map(|v| AncestorLocator {
            title: exact(Some(v)),
            ..Default::default()
        }),
        nearby_text: vec![],
        frame: n.frame,
    }
}
pub(crate) fn walk_context(
    n: &crate::Node,
    a: &[crate::Node],
    w: Option<&str>,
    out: &mut Vec<(crate::Node, Vec<crate::Node>, Option<String>)>,
) {
    out.push((n.clone(), a.to_vec(), w.map(str::to_owned)));
    let mut next = a.to_vec();
    next.push(n.clone());
    for c in &n.children {
        walk_context(c, &next, w, out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Application, Node, SnapshotId, Window};

    fn snapshot(id: &str, children: Vec<Node>) -> Snapshot {
        Snapshot {
            id: SnapshotId(id.into()),
            app: Application {
                name: "App".into(),
                identifier: Some("com.example.App".into()),
                windows: vec![Window {
                    title: Some("Main".into()),
                    root: Node {
                        role: "window".into(),
                        title: Some("Main".into()),
                        children,
                        ..empty_node()
                    },
                }],
            },
        }
    }
    fn empty_node() -> Node {
        Node {
            role: String::new(),
            subrole: None,
            name: None,
            title: None,
            label: None,
            value: None,
            description: None,
            identifier: None,
            actions: vec![],
            frame: None,
            editable: false,
            children: vec![],
            child_count: None,
            truncation_reason: None,
        }
    }
    fn button(title: &str, id: Option<&str>) -> Node {
        Node {
            role: "button".into(),
            title: Some(title.into()),
            identifier: id.map(str::to_owned),
            actions: vec!["invoke".into()],
            ..empty_node()
        }
    }

    #[test]
    fn registry_resolves_recorded_facts_against_a_fresh_capture() {
        let mut registry = SemanticNameRegistry::default();
        let observed = snapshot("old", vec![button("Save", Some("save"))]);
        let name = registry
            .register(&observed)
            .into_iter()
            .find(|n| n.label == "Save")
            .unwrap()
            .name;
        let live = snapshot(
            "new",
            vec![button("Other", None), button("Save", Some("save"))],
        );
        match registry.resolve(
            &WireElementTarget {
                app: "com.example.App".into(),
                name,
            },
            &live,
        ) {
            SemanticLookup::Unique { handle, .. } => assert_eq!(handle, live.handle(2)),
            _ => panic!("recorded name did not resolve live"),
        }
    }

    #[test]
    fn ambiguous_names_return_handle_free_candidate_summaries() {
        let mut registry = SemanticNameRegistry::default();
        let observed = snapshot("old", vec![button("Share", None), button("Share", None)]);
        let name = registry
            .register(&observed)
            .into_iter()
            .find(|n| n.label == "Share")
            .unwrap()
            .name;
        match registry.resolve(
            &WireElementTarget {
                app: "App".into(),
                name,
            },
            &observed,
        ) {
            SemanticLookup::Ambiguous { candidates, .. } => {
                assert_eq!(candidates.len(), 2);
                let json = serde_json::to_string(&candidates).unwrap();
                assert!(!json.contains("handle"));
            }
            _ => panic!("duplicate name was not ambiguous"),
        }
    }

    #[test]
    fn registry_never_uses_a_newer_record_from_another_application() {
        let mut registry = SemanticNameRegistry::default();
        let mut app_a = snapshot("a-old", vec![button("Save", Some("a-save"))]);
        app_a.app.name = "App A".into();
        app_a.app.identifier = Some("com.example.a".into());
        let name = registry
            .register(&app_a)
            .into_iter()
            .find(|name| name.label == "Save")
            .unwrap()
            .name;

        let mut app_b = snapshot("b-new", vec![button("Save", Some("b-save"))]);
        app_b.app.name = "App B".into();
        app_b.app.identifier = Some("com.example.b".into());
        registry.register(&app_b);

        let mut live_a = snapshot("a-live", vec![button("Save", Some("a-save"))]);
        live_a.app = app_a.app.clone();
        match registry.resolve(
            &WireElementTarget {
                app: "com.example.a".into(),
                name,
            },
            &live_a,
        ) {
            SemanticLookup::Unique { handle, .. } => assert_eq!(handle, live_a.handle(1)),
            _ => panic!("App B's newer record shadowed App A's semantic name"),
        }
    }
}
