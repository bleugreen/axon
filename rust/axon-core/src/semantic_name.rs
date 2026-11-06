use crate::{
    AncestorLocator, Locator, LocatorResolver, Resolution, ResolutionStatus, Snapshot,
    SnapshotHandle, TextMatcher, WireElementTarget,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use unicode_normalization::{UnicodeNormalization, char::is_combining_mark};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SemanticNameResolution {
    Unique,
    Ambiguous,
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
/// The application facts a retained record resolves against.
///
/// Deliberately not the [`crate::Application`] itself. One record exists per named element, and an
/// application owns its whole window tree, so keeping the application in a record retained a
/// complete copy of the observation for every element in it. Only these three fields are ever
/// read; the tree was dead weight, and it was quadratic dead weight.
#[derive(Clone, Debug)]
struct RecordedApp {
    name: String,
    identifier: Option<String>,
    process_id: Option<crate::ProcessId>,
}

impl From<&crate::Application> for RecordedApp {
    fn from(app: &crate::Application) -> Self {
        Self {
            name: app.name.clone(),
            identifier: app.identifier.clone(),
            process_id: app.process_id,
        }
    }
}

#[derive(Clone)]
struct Record {
    target: WireElementTarget,
    app: RecordedApp,
    candidate_label: Option<String>,
    role: String,
    label: String,
    locator: Locator,
    handle: SnapshotHandle,
}

#[derive(Clone, Debug)]
pub struct SemanticResolutionContext {
    target: WireElementTarget,
    locator: Locator,
    process_id: Option<crate::ProcessId>,
    recorded_snapshot_id: Option<crate::SnapshotId>,
    recorded_handle: Option<SnapshotHandle>,
    captured: Option<Arc<CaptureProvenance>>,
    app: Option<RecordedApp>,
}

impl SemanticResolutionContext {
    pub fn target(&self) -> &WireElementTarget {
        &self.target
    }

    pub fn locator(&self) -> &Locator {
        &self.locator
    }

    pub fn app_name(&self) -> &str {
        self.app.as_ref().map_or(&self.target.app, |app| &app.name)
    }

    pub fn app_identifier(&self) -> Option<&str> {
        self.app.as_ref().and_then(|app| app.identifier.as_deref())
    }

    pub fn process_id(&self) -> Option<crate::ProcessId> {
        self.process_id
    }

    /// Backend-owned retained evidence for operations that can execute against the observed node
    /// without recapturing its whole application.
    pub fn recorded_handle(&self) -> Option<&SnapshotHandle> {
        self.recorded_handle.as_ref()
    }

    pub fn resolve(&self, live: &Snapshot) -> SemanticLookup {
        if self
            .process_id
            .is_some_and(|expected| live.app.process_id != Some(expected))
        {
            return SemanticLookup::Missing {
                target: self.target.clone(),
                reason: MissingReason::ProcessChanged,
            };
        }
        let resolution = LocatorResolver::resolve(&self.locator, live);
        if self.recorded_snapshot_id.as_ref() == Some(&live.id)
            && resolution.status == ResolutionStatus::Unique
            && self.recorded_handle.as_ref().is_some_and(|handle| {
                resolution
                    .best
                    .as_ref()
                    .is_some_and(|best| &best.handle == handle)
            })
        {
            return SemanticLookup::Unique {
                handle: self.recorded_handle.clone().unwrap(),
                resolution,
            };
        }
        lookup_from_resolution(&self.target, resolution, &self.locator)
    }
}

pub enum SemanticSelection {
    Selected(Box<SemanticResolutionContext>),
    Missing {
        target: WireElementTarget,
    },
    Ambiguous {
        target: WireElementTarget,
        candidates: Vec<SemanticCandidate>,
    },
}

pub(crate) enum RetainedSemanticSelection {
    NoRecord,
    Selected(SemanticSelection),
}

pub const SEMANTIC_TARGET_GUIDANCE: &str = "target semantic targets must be {app,name}; for an app observation pass the top-level app: parameter (bundle identifier, PID, or app name)";

pub enum SemanticLookup {
    Unique {
        handle: SnapshotHandle,
        resolution: Resolution,
    },
    Missing {
        target: WireElementTarget,
        reason: MissingReason,
    },
    Ambiguous {
        target: WireElementTarget,
        candidates: Vec<SemanticCandidate>,
    },
}

/// Why a semantic target found no element. The three read alike to a client — the target is
/// `missing` — but send a reader to different places: the name registry, the locator, or the
/// application's process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MissingReason {
    /// Nothing is recorded under the name.
    NoRecord,
    /// The name's locator was evaluated against a live snapshot and matched no element.
    NoCandidates { snapshot_id: crate::SnapshotId },
    /// The name was issued for an application process that is no longer the one running.
    ProcessChanged,
}

impl SemanticLookup {
    /// The JSON-RPC answer every backend gives for a lookup: the element, or a `-32002` error
    /// with `status` `missing` or `ambiguous` that names why.
    pub fn into_rpc_result(self) -> Result<(SnapshotHandle, Resolution), crate::JsonRpcError> {
        use serde_json::json;
        let (message, data) = match self {
            Self::Unique { handle, resolution } => return Ok((handle, resolution)),
            Self::Ambiguous { target, candidates } => (
                format!(
                    "semantic name is ambiguous: {} / {}",
                    target.app, target.name
                ),
                json!({"status":"ambiguous","query":target,"candidates":candidates}),
            ),
            Self::Missing {
                target,
                reason: MissingReason::NoRecord,
            } => (
                format!("semantic name not found: {} / {}", target.app, target.name),
                json!({"status":"missing","query":target}),
            ),
            Self::Missing {
                target,
                reason: MissingReason::NoCandidates { snapshot_id },
            } => (
                format!(
                    "no element matches the locator for {} / {} (0 candidates in snapshot {})",
                    target.app, target.name, snapshot_id.0
                ),
                json!({
                    "status":"missing",
                    "reason":"noCandidates",
                    "query":target,
                    "snapshotId":snapshot_id
                }),
            ),
            Self::Missing {
                target,
                reason: MissingReason::ProcessChanged,
            } => (
                format!(
                    "{} / {} was issued for an application process that is no longer the one running",
                    target.app, target.name
                ),
                json!({"status":"missing","reason":"processChanged","query":target}),
            ),
        };
        Err(crate::JsonRpcError {
            code: -32002,
            message,
            data: Some(data),
        })
    }
}

#[derive(Clone)]
struct ReplayRecord {
    locator: Locator,
    process_id: Option<crate::ProcessId>,
}

/// Whether a registration covers the process's whole observable application.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SemanticRegistrationCoverage {
    Complete,
    Partial,
}

impl SemanticRegistrationCoverage {
    /// Capture intent and native markers, before any display-only pruning is applied.
    pub fn for_capture(snapshot: &Snapshot, child_depth: Option<usize>) -> Self {
        fn truncated(node: &crate::Node) -> bool {
            node.truncation_reason.is_some() || node.children.iter().any(truncated)
        }
        if child_depth.is_some()
            || snapshot
                .app
                .windows
                .iter()
                .any(|window| truncated(&window.root))
        {
            Self::Partial
        } else {
            Self::Complete
        }
    }
}

pub const MAX_RETAINED_PARTIAL_CAPTURES_PER_PROCESS: usize = 32;
pub const DEFAULT_MAX_RETAINED_PROCESSES: usize = 8;

/// Shared by every name group emitted by one registration, never keyed by snapshot ID.
#[derive(Debug)]
struct CaptureProvenance {
    identity: Snapshot,
}

#[derive(Clone)]
struct NameGroup {
    records: Vec<Record>,
    provenance: Arc<CaptureProvenance>,
    freshness: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum ProcessKey {
    Pid(crate::ProcessId),
    App(String),
}

#[derive(Clone)]
struct ProcessEntry {
    app: RecordedApp,
    // Complete evidence survives partial pressure, including refreshes of the same name.
    baseline: HashMap<String, NameGroup>,
    partial: HashMap<String, NameGroup>,
    partial_order: VecDeque<u64>,
}

#[derive(Clone)]
pub struct SemanticNameRegistry {
    max_processes: usize,
    order: VecDeque<ProcessKey>,
    processes: HashMap<ProcessKey, ProcessEntry>,
    next_freshness: u64,
    replay_locators: HashMap<WireElementTarget, Vec<ReplayRecord>>,
}
impl Default for SemanticNameRegistry {
    fn default() -> Self {
        Self::new(DEFAULT_MAX_RETAINED_PROCESSES)
    }
}
impl SemanticNameRegistry {
    pub fn new(max_processes: usize) -> Self {
        Self {
            max_processes: max_processes.max(1),
            order: VecDeque::new(),
            processes: HashMap::new(),
            next_freshness: 0,
            replay_locators: HashMap::new(),
        }
    }

    /// Returns the durable locator behind a session-local semantic name for history export.
    ///
    /// A saved script crosses the same boundary a recording does, so it carries the persisted
    /// shape: identity, plus the least scope that still resolved uniquely in the observation the
    /// name came from. `None` where no scope disambiguates — an exported action names its element
    /// rather than pinning a locator that cannot find it again.
    pub fn durable_locator(
        &self,
        app: &str,
        name: &str,
    ) -> Option<serde_json::Map<String, serde_json::Value>> {
        let target = WireElementTarget {
            app: app.to_owned(),
            name: name.to_owned(),
        };
        let SemanticSelection::Selected(context) = self.select(&target) else {
            return None;
        };
        let locator = match context.captured.as_ref() {
            Some(captured) => crate::persisted_locator(context.locator(), &captured.identity)?,
            // A replay locator came from a document rather than from a capture this process took,
            // so there is no observation to narrow its scope against. State is dropped all the
            // same: a document authored elsewhere may carry any of the scoring fields, and saving
            // one back out is exactly how they would re-enter an artifact.
            None => crate::persisted_locator_shape(context.locator()),
        };
        serde_json::to_value(locator).ok()?.as_object().cloned()
    }

    pub fn register(
        &mut self,
        snapshot: &Snapshot,
        coverage: SemanticRegistrationCoverage,
    ) -> Vec<SemanticElementName> {
        self.register_with_liveness(snapshot, coverage, |_| true)
    }

    pub fn register_with_liveness(
        &mut self,
        snapshot: &Snapshot,
        coverage: SemanticRegistrationCoverage,
        is_process_live: impl Fn(crate::ProcessId) -> bool,
    ) -> Vec<SemanticElementName> {
        let app = RecordedApp::from(&snapshot.app);
        if let Some(replacement_pid) = app.process_id {
            let identity = app_identity(&app);
            self.processes.retain(|_, entry| {
                !entry.app.process_id.is_some_and(|pid| {
                    pid != replacement_pid
                        && app_identity(&entry.app) == identity
                        && !is_process_live(pid)
                })
            });
            self.order.retain(|key| self.processes.contains_key(key));
        }

        let names = SemanticNameDeriver::derive(snapshot);
        let mut contexts = Vec::new();
        for window in &snapshot.app.windows {
            walk_context(&window.root, &[], window.title.as_deref(), &mut contexts)
        }
        let records: Vec<Record> = names
            .iter()
            .filter_map(|name| {
                contexts
                    .get(name.source_index)
                    .map(|(node, ancestors, window)| Record {
                        // `window` is already borrowed from the observation, so nothing here
                        // copies out of the tree.
                        target: WireElementTarget {
                            app: snapshot.app.name.clone(),
                            name: name.name.clone(),
                        },
                        app: RecordedApp::from(&snapshot.app),
                        candidate_label: name.candidate_label.clone(),
                        role: name.role.clone(),
                        label: name.label.clone(),
                        locator: locator(node, ancestors, *window),
                        handle: snapshot.handle(name.source_index),
                    })
            })
            .collect();
        self.next_freshness += 1;
        let freshness = self.next_freshness;
        let provenance = Arc::new(CaptureProvenance {
            identity: crate::locator::identity_skeleton(snapshot),
        });
        let mut groups = HashMap::<String, NameGroup>::new();
        for record in records {
            groups
                .entry(record.target.name.clone())
                .or_insert_with(|| NameGroup {
                    records: Vec::new(),
                    provenance: provenance.clone(),
                    freshness,
                })
                .records
                .push(record);
        }
        let key = app
            .process_id
            .map_or_else(|| ProcessKey::App(app_identity(&app)), ProcessKey::Pid);
        let entry = self
            .processes
            .entry(key.clone())
            .or_insert_with(|| ProcessEntry {
                app: app.clone(),
                baseline: HashMap::new(),
                partial: HashMap::new(),
                partial_order: VecDeque::new(),
            });
        entry.app = app;
        match coverage {
            SemanticRegistrationCoverage::Complete => {
                entry.baseline = groups;
                entry.partial.clear();
                entry.partial_order.clear();
            }
            SemanticRegistrationCoverage::Partial => {
                if !groups.is_empty() {
                    entry.partial.extend(groups);
                    let referenced: HashSet<_> = entry
                        .partial
                        .values()
                        .map(|group| group.freshness)
                        .collect();
                    entry.partial_order.retain(|id| referenced.contains(id));
                    entry.partial_order.push_back(freshness);
                    while entry.partial_order.len() > MAX_RETAINED_PARTIAL_CAPTURES_PER_PROCESS {
                        if let Some(evicted) = entry.partial_order.pop_front() {
                            entry.partial.retain(|_, group| group.freshness != evicted);
                        }
                    }
                }
            }
        }
        // Process observation recency is independent of the freshness of each emitted name.
        self.order.retain(|old| old != &key);
        self.order.push_back(key);
        while self.order.len() > self.max_processes {
            if let Some(evicted) = self.order.pop_front() {
                self.processes.remove(&evicted);
            }
        }
        names
    }

    pub fn register_replay_locator(&mut self, target: WireElementTarget, locator: Locator) {
        self.register_replay_locator_for_process(target, locator, None);
    }

    pub fn register_replay_locator_for_process(
        &mut self,
        target: WireElementTarget,
        locator: Locator,
        process_id: Option<crate::ProcessId>,
    ) {
        let records = self.replay_locators.entry(target).or_default();
        records.retain(|record| record.process_id != process_id);
        records.push(ReplayRecord {
            locator,
            process_id,
        });
    }

    pub fn replay_locator(&self, target: &WireElementTarget) -> Option<&Locator> {
        let records = self.replay_locators.get(target)?;
        (records.len() == 1).then(|| &records[0].locator)
    }

    pub fn select(&self, target: &WireElementTarget) -> SemanticSelection {
        if let Some(selection) = self.select_replay(target) {
            return selection;
        }
        match self.select_retained(target) {
            RetainedSemanticSelection::NoRecord => SemanticSelection::Missing {
                target: target.clone(),
            },
            RetainedSemanticSelection::Selected(selection) => selection,
        }
    }

    fn select_replay(&self, target: &WireElementTarget) -> Option<SemanticSelection> {
        let records = self.replay_locators.get(target)?;
        let query_pid = parse_process_id(&target.app);
        let matches: Vec<_> = records
            .iter()
            .filter(|record| query_pid.is_none_or(|pid| record.process_id == Some(pid)))
            .collect();
        if matches.len() != 1 {
            return Some(SemanticSelection::Ambiguous {
                target: target.clone(),
                candidates: vec![],
            });
        }
        let record = matches[0];
        Some(SemanticSelection::Selected(Box::new(
            SemanticResolutionContext {
                target: target.clone(),
                locator: record.locator.clone(),
                process_id: record.process_id,
                recorded_snapshot_id: None,
                recorded_handle: None,
                captured: None,
                app: None,
            },
        )))
    }

    pub fn resolve(&self, target: &WireElementTarget, live: &Snapshot) -> SemanticLookup {
        match self.select(target) {
            SemanticSelection::Selected(context) => context.resolve(live),
            SemanticSelection::Missing { target } => SemanticLookup::Missing {
                target,
                reason: MissingReason::NoRecord,
            },
            SemanticSelection::Ambiguous { target, candidates } => {
                SemanticLookup::Ambiguous { target, candidates }
            }
        }
    }

    pub(crate) fn select_retained(&self, target: &WireElementTarget) -> RetainedSemanticSelection {
        let group = self
            .processes
            .values()
            .filter_map(|entry| {
                let group = entry
                    .partial
                    .get(&target.name)
                    .or_else(|| entry.baseline.get(&target.name))?;
                group
                    .records
                    .first()
                    .filter(|record| app_matches(&target.app, &record.app))
                    .map(|_| group)
            })
            .max_by_key(|group| group.freshness);
        let Some(group) = group else {
            return RetainedSemanticSelection::NoRecord;
        };
        let latest = &group.records;
        if latest.len() > 1 {
            return RetainedSemanticSelection::Selected(SemanticSelection::Ambiguous {
                target: target.clone(),
                candidates: latest
                    .iter()
                    .map(|record| SemanticCandidate {
                        name: record.target.name.clone(),
                        candidate_label: record.candidate_label.clone(),
                        role: record.role.clone(),
                        label: record.label.clone(),
                        locator: record.locator.clone(),
                    })
                    .collect(),
            });
        }
        let record = &latest[0];
        RetainedSemanticSelection::Selected(SemanticSelection::Selected(Box::new(
            SemanticResolutionContext {
                target: target.clone(),
                locator: record.locator.clone(),
                process_id: record.app.process_id,
                recorded_snapshot_id: Some(group.provenance.identity.id.clone()),
                recorded_handle: Some(record.handle.clone()),
                captured: Some(group.provenance.clone()),
                app: Some(record.app.clone()),
            },
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
            reason: MissingReason::NoCandidates {
                snapshot_id: result.snapshot_id,
            },
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
fn parse_process_id(query: &str) -> Option<crate::ProcessId> {
    query.strip_prefix("pid:").unwrap_or(query).parse().ok()
}

fn app_identity(app: &RecordedApp) -> String {
    app.identifier
        .as_deref()
        .unwrap_or(&app.name)
        .to_ascii_lowercase()
}

fn app_matches(query: &str, app: &RecordedApp) -> bool {
    if let Some(pid) = parse_process_id(query) {
        return app.process_id == Some(pid);
    }
    query.eq_ignore_ascii_case(&app.name)
        || app
            .identifier
            .as_deref()
            .is_some_and(|identifier| query.eq_ignore_ascii_case(identifier))
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
pub(crate) fn locator(n: &crate::Node, a: &[&crate::Node], window: Option<&str>) -> Locator {
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
        ancestors: a.iter().rev().take(2).rev().map(|n| scope(n)).collect(),
        window: window.map(|v| AncestorLocator {
            title: exact(Some(v)),
            ..Default::default()
        }),
        nearby_text: vec![],
        frame: n.frame,
    }
}
/// One node of an observation with the ancestry and window title a locator is built from.
///
/// Borrowed rather than owned, because a [`crate::Node`] owns its descendants: cloning one copies
/// its entire subtree. Collecting an owned node and an owned ancestor chain per node therefore
/// copied the root's whole subtree once for every element beneath it, which is quadratic in the
/// size of the tree. On a desktop shell with a couple of thousand elements that reached a gigabyte
/// before the observation had been rendered at all.
pub(crate) type NodeContext<'a> = (&'a crate::Node, Vec<&'a crate::Node>, Option<&'a str>);

pub(crate) fn walk_context<'a>(
    n: &'a crate::Node,
    a: &[&'a crate::Node],
    w: Option<&'a str>,
    out: &mut Vec<NodeContext<'a>>,
) {
    out.push((n, a.to_vec(), w));
    let mut next = a.to_vec();
    next.push(n);
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
                process_id: None,
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
            focused: None,
            enabled: None,
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

    fn hierarchical_capture(id: &str) -> Snapshot {
        with_pid(
            snapshot(
                id,
                vec![Node {
                    role: "group".into(),
                    title: Some("Editor".into()),
                    children: vec![button("Save", Some("save"))],
                    ..empty_node()
                }],
            ),
            41,
        )
    }

    fn assert_retained_descendant_after(mut partial: Snapshot) {
        let mut registry = SemanticNameRegistry::default();
        let original = hierarchical_capture("original");
        let name = registry
            .register(&original, SemanticRegistrationCoverage::Complete)
            .into_iter()
            .find(|name| name.label == "Save")
            .unwrap()
            .name;
        let target = target("pid:41", name);
        let SemanticSelection::Selected(before) = registry.select(&target) else {
            panic!("original evidence missing");
        };
        partial.app.process_id = Some(41);
        registry.register(&partial, SemanticRegistrationCoverage::Partial);
        let SemanticSelection::Selected(after) = registry.select(&target) else {
            panic!("partial observation revoked uncovered descendant");
        };
        assert_eq!(after.process_id(), Some(41));
        assert_eq!(after.locator(), before.locator());
        assert_eq!(after.recorded_handle(), before.recorded_handle());
        assert_eq!(after.recorded_snapshot_id, Some(original.id.clone()));
        assert!(Arc::ptr_eq(
            after.captured.as_ref().unwrap(),
            before.captured.as_ref().unwrap()
        ));
        let fresh = hierarchical_capture("fresh");
        match after.resolve(&fresh) {
            SemanticLookup::Unique { handle, .. } => assert_eq!(handle, fresh.handle(2)),
            _ => panic!("retained descendant did not resolve against fresh evidence"),
        }
    }

    #[test]
    fn partial_root_only_retains_original_descendant() {
        assert_retained_descendant_after(snapshot("root-only", vec![]));
    }

    #[test]
    fn partial_empty_leaf_page_retains_original_hierarchical_name() {
        let mut page = snapshot("leaf-page", vec![]);
        page.app.windows[0].root = button("Save", Some("save"));
        assert!(page.app.windows[0].root.children.is_empty());
        assert_retained_descendant_after(page);
    }

    #[test]
    fn registry_resolves_recorded_facts_against_a_fresh_capture() {
        let mut registry = SemanticNameRegistry::default();
        let observed = snapshot("old", vec![button("Save", Some("save"))]);
        let name = registry
            .register(&observed, SemanticRegistrationCoverage::Complete)
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
    fn saved_locators_carry_identity_without_the_captured_document() {
        let mut registry = SemanticNameRegistry::default();
        let document = "everything the user had open ".repeat(64);
        let observed = snapshot(
            "capture",
            vec![Node {
                role: "text".into(),
                identifier: Some("document".into()),
                value: Some(document.clone()),
                editable: true,
                actions: vec!["confirm".into()],
                frame: Some(crate::Rect {
                    x: 0.0,
                    y: 0.0,
                    width: 600.0,
                    height: 400.0,
                }),
                ..empty_node()
            }],
        );
        let name = registry
            .register(&observed, SemanticRegistrationCoverage::Complete)
            .into_iter()
            .find(|name| name.role == "text")
            .unwrap()
            .name;

        let locator = registry
            .durable_locator("com.example.App", &name)
            .expect("a saved action carries the durable locator behind its name");

        assert_eq!(locator.get("role"), Some(&serde_json::json!("text")));
        assert_eq!(
            locator.get("identifier"),
            Some(&serde_json::json!({"exact": "document"}))
        );
        for absent in [
            "value",
            "frame",
            "actions",
            "nearbyText",
            "ancestors",
            "window",
        ] {
            assert!(!locator.contains_key(absent), "{absent} in {locator:?}");
        }
        assert!(
            !serde_json::to_string(&locator)
                .unwrap()
                .contains("user had open")
        );
    }

    /// Replaying a document registers the locator it carries, and that document may have been
    /// authored anywhere. Saving after such a replay must not copy its state back out.
    #[test]
    fn saved_locators_drop_state_carried_in_by_a_replayed_document() {
        let mut registry = SemanticNameRegistry::default();
        let target = WireElementTarget {
            app: "com.example.App".into(),
            name: "document-area".into(),
        };
        let recorded: Locator = serde_json::from_value(serde_json::json!({
            "role": "text",
            "identifier": {"exact": "document"},
            "value": {"exact": "everything the user had open"},
            "actions": ["confirm"],
            "nearbyText": [{"contains": "Untitled"}],
            "frame": {"x": 0.0, "y": 0.0, "width": 600.0, "height": 400.0},
            "window": {"title": {"exact": "Untitled"}},
            "ancestors": [{"role": "group", "title": {"exact": "Editor"}}]
        }))
        .unwrap();
        registry.register_replay_locator(target, recorded);

        let locator = registry
            .durable_locator("com.example.App", "document-area")
            .expect("a replayed target still names a durable locator");

        for absent in ["value", "frame", "actions", "nearbyText"] {
            assert!(!locator.contains_key(absent), "{absent} in {locator:?}");
        }
        assert!(
            !serde_json::to_string(&locator)
                .unwrap()
                .contains("user had open")
        );
        // Scope the document already carried is kept: with no capture to test it against, dropping
        // it could leave a locator that no longer resolves.
        assert!(locator.contains_key("window"));
        assert_eq!(
            locator.get("ancestors"),
            Some(&serde_json::json!([{"role": "group", "title": {"exact": "Editor"}}]))
        );
    }

    #[test]
    fn ambiguous_names_return_handle_free_candidate_summaries() {
        let mut registry = SemanticNameRegistry::default();
        let observed = snapshot("old", vec![button("Share", None), button("Share", None)]);
        let name = registry
            .register(&observed, SemanticRegistrationCoverage::Complete)
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
            .register(&app_a, SemanticRegistrationCoverage::Complete)
            .into_iter()
            .find(|name| name.label == "Save")
            .unwrap()
            .name;

        let mut app_b = snapshot("b-new", vec![button("Save", Some("b-save"))]);
        app_b.app.name = "App B".into();
        app_b.app.identifier = Some("com.example.b".into());
        registry.register(&app_b, SemanticRegistrationCoverage::Complete);

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
    fn with_pid(mut snapshot: Snapshot, pid: crate::ProcessId) -> Snapshot {
        snapshot.app.process_id = Some(pid);
        snapshot
    }

    fn target(app: &str, name: String) -> WireElementTarget {
        WireElementTarget {
            app: app.into(),
            name,
        }
    }

    #[test]
    fn pid_aliases_select_the_exact_process() {
        let mut registry = SemanticNameRegistry::default();
        let one = with_pid(snapshot("one", vec![button("Save", Some("one"))]), 41);
        let name = registry
            .register(&one, SemanticRegistrationCoverage::Complete)
            .into_iter()
            .find(|n| n.label == "Save")
            .unwrap()
            .name;
        let two = with_pid(snapshot("two", vec![button("Save", Some("two"))]), 42);
        registry.register(&two, SemanticRegistrationCoverage::Complete);

        for alias in ["41", "pid:41"] {
            let SemanticSelection::Selected(context) =
                registry.select(&target(alias, name.clone()))
            else {
                panic!("PID alias did not select evidence");
            };
            assert_eq!(context.process_id(), Some(41));
        }
    }

    #[test]
    fn live_same_identity_processes_coexist_and_name_uses_newest_process() {
        let mut registry = SemanticNameRegistry::default();
        let old = with_pid(snapshot("old", vec![button("Save", Some("old"))]), 41);
        let name = registry
            .register_with_liveness(&old, SemanticRegistrationCoverage::Complete, |_| true)
            .into_iter()
            .find(|n| n.label == "Save")
            .unwrap()
            .name;
        let new = with_pid(snapshot("new", vec![button("Save", Some("new"))]), 42);
        registry.register_with_liveness(&new, SemanticRegistrationCoverage::Complete, |pid| {
            pid == 41
        });

        let SemanticSelection::Selected(by_name) = registry.select(&target("App", name.clone()))
        else {
            panic!("name did not select newest process");
        };
        assert_eq!(by_name.process_id(), Some(42));
        let SemanticSelection::Selected(by_pid) = registry.select(&target("41", name)) else {
            panic!("old live process was discarded");
        };
        assert_eq!(by_pid.process_id(), Some(41));
    }

    #[test]
    fn frequent_recaptures_do_not_evict_a_live_sibling_process() {
        let mut registry = SemanticNameRegistry::new(3);
        let sibling = with_pid(
            snapshot("sibling", vec![button("Save", Some("sibling"))]),
            41,
        );
        let name = registry
            .register_with_liveness(&sibling, SemanticRegistrationCoverage::Complete, |_| true)
            .into_iter()
            .find(|n| n.label == "Save")
            .unwrap()
            .name;

        for index in 0..10 {
            let current = with_pid(
                snapshot(
                    &format!("current-{index}"),
                    vec![button("Save", Some("current"))],
                ),
                42,
            );
            registry.register_with_liveness(
                &current,
                SemanticRegistrationCoverage::Complete,
                |_| true,
            );
        }

        let SemanticSelection::Selected(context) = registry.select(&target("41", name)) else {
            panic!("recapturing one live process evicted its live sibling");
        };
        assert_eq!(context.process_id(), Some(41));
    }

    #[test]
    fn replacement_removes_only_proven_dead_same_identity_process() {
        let mut registry = SemanticNameRegistry::default();
        let old = with_pid(snapshot("old", vec![button("Save", Some("old"))]), 41);
        let name = registry
            .register(&old, SemanticRegistrationCoverage::Complete)
            .into_iter()
            .find(|n| n.label == "Save")
            .unwrap()
            .name;
        let mut unrelated = with_pid(snapshot("other", vec![button("Save", Some("other"))]), 99);
        unrelated.app.name = "Other".into();
        unrelated.app.identifier = Some("com.example.other".into());
        let other_name = registry
            .register(&unrelated, SemanticRegistrationCoverage::Complete)
            .into_iter()
            .find(|n| n.label == "Save")
            .unwrap()
            .name;
        let replacement = with_pid(
            snapshot("replacement", vec![button("Save", Some("new"))]),
            42,
        );
        registry.register_with_liveness(
            &replacement,
            SemanticRegistrationCoverage::Complete,
            |_| false,
        );

        assert!(matches!(
            registry.select(&target("41", name)),
            SemanticSelection::Missing { .. }
        ));
        assert!(matches!(
            registry.select(&target("99", other_name)),
            SemanticSelection::Selected(_)
        ));
    }

    #[test]
    fn selected_process_refuses_a_different_live_snapshot() {
        let mut registry = SemanticNameRegistry::default();
        let observed = with_pid(snapshot("old", vec![button("Save", Some("save"))]), 41);
        let name = registry
            .register(&observed, SemanticRegistrationCoverage::Complete)
            .into_iter()
            .find(|n| n.label == "Save")
            .unwrap()
            .name;
        let SemanticSelection::Selected(context) = registry.select(&target("41", name)) else {
            panic!("record was not selected");
        };
        let wrong = with_pid(snapshot("wrong", vec![button("Save", Some("save"))]), 42);
        assert!(matches!(
            context.resolve(&wrong),
            SemanticLookup::Missing {
                reason: MissingReason::ProcessChanged,
                ..
            }
        ));
        let error = context.resolve(&wrong).into_rpc_result().unwrap_err();
        assert_eq!(error.code, -32002);
        assert!(
            error.message.ends_with(
                "was issued for an application process that is no longer the one running"
            ),
            "{}",
            error.message
        );
        assert_eq!(error.data.unwrap()["reason"], "processChanged");

        let unknown = snapshot("unknown", vec![button("Save", Some("save"))]);
        assert!(matches!(
            context.resolve(&unknown),
            SemanticLookup::Missing {
                reason: MissingReason::ProcessChanged,
                ..
            }
        ));
    }

    /// A locator that matches nothing and a name that was never issued are different failures,
    /// and the error must send the reader to the right one.
    #[test]
    fn a_missing_lookup_names_why_it_found_nothing() {
        let live = snapshot("live", vec![button("Save", Some("save"))]);
        let mut registry = SemanticNameRegistry::default();
        let query = WireElementTarget {
            app: "App".into(),
            name: "gone".into(),
        };
        registry.register_replay_locator(
            query.clone(),
            Locator {
                identifier: Some(TextMatcher::Exact {
                    value: "absent".into(),
                    case_sensitive: false,
                }),
                ..Locator::default()
            },
        );

        let error = registry
            .resolve(&query, &live)
            .into_rpc_result()
            .unwrap_err();
        assert_eq!(error.code, -32002);
        assert_eq!(
            error.message,
            "no element matches the locator for App / gone (0 candidates in snapshot live)"
        );
        assert_eq!(
            error.data,
            Some(serde_json::json!({
                "status": "missing",
                "reason": "noCandidates",
                "query": {"app": "App", "name": "gone"},
                "snapshotId": "live"
            }))
        );

        let never_issued = WireElementTarget {
            app: "App".into(),
            name: "never-issued".into(),
        };
        let error = registry
            .resolve(&never_issued, &live)
            .into_rpc_result()
            .unwrap_err();
        assert_eq!(error.message, "semantic name not found: App / never-issued");
        assert_eq!(
            error.data,
            Some(serde_json::json!({
                "status": "missing",
                "query": {"app": "App", "name": "never-issued"}
            }))
        );
    }

    fn issued(
        registry: &mut SemanticNameRegistry,
        snapshot: &Snapshot,
        coverage: SemanticRegistrationCoverage,
        label: &str,
    ) -> String {
        registry
            .register(snapshot, coverage)
            .into_iter()
            .find(|name| name.label == label)
            .unwrap()
            .name
    }

    fn selected(
        registry: &SemanticNameRegistry,
        app: &str,
        name: &str,
    ) -> Box<SemanticResolutionContext> {
        let SemanticSelection::Selected(context) = registry.select(&target(app, name.into()))
        else {
            panic!("expected unique {app}/{name}");
        };
        context
    }

    fn missing(registry: &SemanticNameRegistry, app: &str, name: &str) {
        assert!(
            matches!(
                registry.select(&target(app, name.into())),
                SemanticSelection::Missing { .. }
            ),
            "expected missing {app}/{name}"
        );
    }

    fn empty_capture(id: &str, pid: crate::ProcessId) -> Snapshot {
        let mut capture = with_pid(snapshot(id, vec![]), pid);
        capture.app.windows.clear();
        capture
    }

    #[test]
    fn coverage_uses_capture_intent_and_recursive_native_markers() {
        let mut capture = hierarchical_capture("coverage");
        assert_eq!(
            SemanticRegistrationCoverage::for_capture(&capture, None),
            SemanticRegistrationCoverage::Complete
        );
        for bound in [0, 1, 100] {
            assert_eq!(
                SemanticRegistrationCoverage::for_capture(&capture, Some(bound)),
                SemanticRegistrationCoverage::Partial
            );
        }
        capture.app.windows[0].root.children[0].children[0].truncation_reason =
            Some("native limit".into());
        assert_eq!(
            SemanticRegistrationCoverage::for_capture(&capture, None),
            SemanticRegistrationCoverage::Partial
        );
    }

    #[test]
    fn complete_value_name_churn_replaces_provenance_and_revokes_omitted_names() {
        let mut registry = SemanticNameRegistry::default();
        let mut previous: Option<(String, std::sync::Weak<CaptureProvenance>)> = None;
        for index in 0..64 {
            let value = format!("Value {index}");
            let capture = with_pid(
                snapshot(
                    &format!("complete-{index}"),
                    vec![Node {
                        role: "text".into(),
                        value: Some(value.clone()),
                        editable: true,
                        ..empty_node()
                    }],
                ),
                41,
            );
            let name = issued(
                &mut registry,
                &capture,
                SemanticRegistrationCoverage::Complete,
                &value,
            );
            if let Some((old_name, old_provenance)) = previous.take() {
                missing(&registry, "41", &old_name);
                assert!(old_provenance.upgrade().is_none());
            }
            let entry = &registry.processes[&ProcessKey::Pid(41)];
            assert!(entry.partial.is_empty());
            assert!(entry.partial_order.is_empty());
            let provenance = &entry.baseline[&name].provenance;
            assert!(
                entry
                    .baseline
                    .values()
                    .all(|group| Arc::ptr_eq(&group.provenance, provenance))
            );
            previous = Some((name, Arc::downgrade(provenance)));
        }
        let (last_name, last_provenance) = previous.unwrap();
        let partial = with_pid(snapshot("partial", vec![button("Partial only", None)]), 41);
        let partial_name = issued(
            &mut registry,
            &partial,
            SemanticRegistrationCoverage::Partial,
            "Partial only",
        );
        registry.register(
            &empty_capture("complete-empty", 41),
            SemanticRegistrationCoverage::Complete,
        );
        missing(&registry, "41", &last_name);
        missing(&registry, "41", &partial_name);
        assert!(last_provenance.upgrade().is_none());
        assert!(registry.processes[&ProcessKey::Pid(41)].baseline.is_empty());
        assert!(registry.processes[&ProcessKey::Pid(41)].partial.is_empty());
    }

    #[test]
    fn partial_provenance_exact_boundary_evicts_only_partial_evidence_and_falls_back() {
        assert_eq!(MAX_RETAINED_PARTIAL_CAPTURES_PER_PROCESS, 32);
        let mut registry = SemanticNameRegistry::default();
        let baseline = with_pid(
            snapshot("baseline", vec![button("Save", Some("baseline-save"))]),
            41,
        );
        let save = issued(
            &mut registry,
            &baseline,
            SemanticRegistrationCoverage::Complete,
            "Save",
        );
        let original = selected(&registry, "41", &save);
        let overlay = with_pid(
            snapshot(
                "overlay",
                vec![
                    button("Save", Some("overlay-save")),
                    button("Overlay only", None),
                ],
            ),
            41,
        );
        let overlay_only = issued(
            &mut registry,
            &overlay,
            SemanticRegistrationCoverage::Partial,
            "Overlay only",
        );
        assert_eq!(
            selected(&registry, "41", &save).recorded_handle(),
            Some(&overlay.handle(1))
        );
        let overlay_provenance =
            Arc::downgrade(&registry.processes[&ProcessKey::Pid(41)].partial[&save].provenance);
        let mut partial_names = Vec::new();
        for index in 1..MAX_RETAINED_PARTIAL_CAPTURES_PER_PROCESS {
            let label = format!("Partial {index}");
            let capture = with_pid(
                snapshot(&format!("partial-{index}"), vec![button(&label, None)]),
                41,
            );
            partial_names.push(issued(
                &mut registry,
                &capture,
                SemanticRegistrationCoverage::Partial,
                &label,
            ));
        }
        assert_eq!(
            registry.processes[&ProcessKey::Pid(41)].partial_order.len(),
            32
        );
        selected(&registry, "41", &overlay_only);
        assert!(overlay_provenance.upgrade().is_some());
        let newest = with_pid(snapshot("one-beyond", vec![button("Newest", None)]), 41);
        registry.register(&newest, SemanticRegistrationCoverage::Partial);
        assert_eq!(
            registry.processes[&ProcessKey::Pid(41)].partial_order.len(),
            32
        );
        missing(&registry, "41", &overlay_only);
        assert!(overlay_provenance.upgrade().is_none());
        let fallback = selected(&registry, "41", &save);
        assert!(Arc::ptr_eq(
            fallback.captured.as_ref().unwrap(),
            original.captured.as_ref().unwrap()
        ));
        assert_eq!(fallback.locator(), original.locator());
        for name in &partial_names {
            selected(&registry, "41", name);
        }
        let oldest_partial = partial_names[0].clone();
        let next = with_pid(snapshot("two-beyond", vec![button("Next", None)]), 41);
        registry.register(&next, SemanticRegistrationCoverage::Partial);
        missing(&registry, "41", &oldest_partial);
        assert_eq!(
            selected(&registry, "41", &save).recorded_handle(),
            Some(&baseline.handle(1))
        );
    }

    #[test]
    fn superseded_partial_provenance_is_reclaimed_promptly_and_empty_partial_costs_no_slot() {
        let mut registry = SemanticNameRegistry::default();
        let first = with_pid(snapshot("first", vec![button("Save", Some("old"))]), 41);
        let name = issued(
            &mut registry,
            &first,
            SemanticRegistrationCoverage::Partial,
            "Save",
        );
        let weak =
            Arc::downgrade(&registry.processes[&ProcessKey::Pid(41)].partial[&name].provenance);
        let second = with_pid(snapshot("second", vec![button("Save", Some("new"))]), 41);
        registry.register(&second, SemanticRegistrationCoverage::Partial);
        assert!(weak.upgrade().is_none());
        assert_eq!(
            registry.processes[&ProcessKey::Pid(41)].partial_order.len(),
            1
        );
        registry.register(
            &empty_capture("empty", 41),
            SemanticRegistrationCoverage::Partial,
        );
        assert_eq!(
            registry.processes[&ProcessKey::Pid(41)].partial_order.len(),
            1
        );
        assert_eq!(
            selected(&registry, "41", &name).recorded_handle(),
            Some(&second.handle(1))
        );
    }

    #[test]
    fn process_capacity_is_real_configurable_lru_with_empty_partial_observation() {
        assert_eq!(DEFAULT_MAX_RETAINED_PROCESSES, 8);
        for capacity in [1, 3, DEFAULT_MAX_RETAINED_PROCESSES] {
            let mut registry = if capacity == DEFAULT_MAX_RETAINED_PROCESSES {
                SemanticNameRegistry::default()
            } else {
                SemanticNameRegistry::new(capacity)
            };
            let mut names = Vec::new();
            for pid in 1..=capacity as u32 {
                let capture = with_pid(
                    snapshot(&format!("process-{pid}"), vec![button("Save", None)]),
                    pid,
                );
                names.push(issued(
                    &mut registry,
                    &capture,
                    SemanticRegistrationCoverage::Complete,
                    "Save",
                ));
            }
            assert_eq!(registry.processes.len(), capacity);
            for (index, name) in names.iter().enumerate() {
                selected(&registry, &(index + 1).to_string(), name);
            }
            registry.register(
                &empty_capture("refresh-oldest", 1),
                SemanticRegistrationCoverage::Partial,
            );
            let beyond = with_pid(
                snapshot("beyond", vec![button("Save", None)]),
                capacity as u32 + 1,
            );
            registry.register(&beyond, SemanticRegistrationCoverage::Complete);
            assert_eq!(registry.processes.len(), capacity);
            let evicted = if capacity == 1 { 1 } else { 2 };
            missing(&registry, &evicted.to_string(), &names[evicted - 1]);
            if capacity > 1 {
                selected(&registry, "1", &names[0]);
            }
        }
        let mut minimum = SemanticNameRegistry::new(0);
        minimum.register(
            &empty_capture("one", 1),
            SemanticRegistrationCoverage::Partial,
        );
        minimum.register(
            &empty_capture("two", 2),
            SemanticRegistrationCoverage::Partial,
        );
        assert_eq!(minimum.max_processes, 1);
        assert_eq!(minimum.processes.len(), 1);
        assert!(!minimum.processes.contains_key(&ProcessKey::Pid(1)));
    }

    #[test]
    fn partial_refresh_replaces_whole_ambiguous_groups_and_preserves_other_names() {
        let mut registry = SemanticNameRegistry::default();
        let complete = with_pid(
            snapshot(
                "complete",
                vec![button("Share", None), button("Other", None)],
            ),
            41,
        );
        let share = issued(
            &mut registry,
            &complete,
            SemanticRegistrationCoverage::Complete,
            "Share",
        );
        let other = SemanticNameDeriver::derive(&complete)
            .into_iter()
            .find(|name| name.label == "Other")
            .unwrap()
            .name;
        let other_context = selected(&registry, "41", &other);
        let duplicate = with_pid(
            snapshot(
                "duplicate",
                vec![button("Share", None), button("Share", None)],
            ),
            41,
        );
        registry.register(&duplicate, SemanticRegistrationCoverage::Partial);
        let SemanticSelection::Ambiguous { candidates, .. } =
            registry.select(&target("41", share.clone()))
        else {
            panic!("whole ambiguous group was not retained");
        };
        assert_eq!(candidates.len(), 2);
        assert_eq!(
            registry.processes[&ProcessKey::Pid(41)].partial[&share]
                .records
                .iter()
                .map(|record| record.handle.clone())
                .collect::<Vec<_>>(),
            vec![duplicate.handle(1), duplicate.handle(2)]
        );
        let unique = with_pid(snapshot("unique", vec![button("Share", None)]), 41);
        registry.register(&unique, SemanticRegistrationCoverage::Partial);
        assert_eq!(
            selected(&registry, "41", &share).recorded_handle(),
            Some(&unique.handle(1))
        );
        assert!(Arc::ptr_eq(
            selected(&registry, "41", &other).captured.as_ref().unwrap(),
            other_context.captured.as_ref().unwrap()
        ));
    }

    #[test]
    fn name_group_freshness_does_not_follow_process_observation_recency() {
        let mut registry = SemanticNameRegistry::new(3);
        let one = with_pid(snapshot("one", vec![button("Save", None)]), 41);
        let save = issued(
            &mut registry,
            &one,
            SemanticRegistrationCoverage::Complete,
            "Save",
        );
        let two = with_pid(snapshot("two", vec![button("Save", None)]), 42);
        registry.register_with_liveness(&two, SemanticRegistrationCoverage::Partial, |_| true);
        let unrelated = with_pid(snapshot("other-name", vec![button("Other", None)]), 41);
        registry.register(&unrelated, SemanticRegistrationCoverage::Partial);
        registry.register(
            &empty_capture("empty", 41),
            SemanticRegistrationCoverage::Partial,
        );
        assert_eq!(selected(&registry, "App", &save).process_id(), Some(42));
        for alias in ["41", "pid:41"] {
            assert_eq!(selected(&registry, alias, &save).process_id(), Some(41));
        }
        let refreshed = with_pid(snapshot("refreshed-save", vec![button("Save", None)]), 41);
        registry.register(&refreshed, SemanticRegistrationCoverage::Partial);
        assert_eq!(
            selected(&registry, "com.example.App", &save).process_id(),
            Some(41)
        );
    }

    #[test]
    fn pidless_evidence_is_isolated_normalized_and_uses_process_capacity() {
        let mut registry = SemanticNameRegistry::new(2);
        let anonymous = snapshot("anonymous", vec![button("Anonymous", None)]);
        let name = issued(
            &mut registry,
            &anonymous,
            SemanticRegistrationCoverage::Complete,
            "Anonymous",
        );
        let pid = with_pid(snapshot("pid", vec![button("Save", None)]), 41);
        let save = issued(
            &mut registry,
            &pid,
            SemanticRegistrationCoverage::Partial,
            "Save",
        );
        missing(&registry, "41", &name);
        assert_eq!(selected(&registry, "App", &name).process_id(), None);
        let mut normalized = snapshot("same-app", vec![button("Other", None)]);
        normalized.app.identifier = Some("COM.EXAMPLE.APP".into());
        registry.register(&normalized, SemanticRegistrationCoverage::Partial);
        assert_eq!(registry.processes.len(), 2);
        selected(&registry, "App", &name);
        let another = with_pid(snapshot("another-process", vec![button("New", None)]), 42);
        registry.register(&another, SemanticRegistrationCoverage::Partial);
        missing(&registry, "41", &save);
        selected(&registry, "App", &name);
        registry.register(
            &snapshot("anonymous-empty", vec![]),
            SemanticRegistrationCoverage::Complete,
        );
        missing(&registry, "App", &name);
        assert_eq!(registry.processes.len(), 2);
    }

    #[test]
    fn partial_replacement_removes_only_proven_dead_same_identity_process_and_checks_live_pid() {
        let mut registry = SemanticNameRegistry::default();
        let old = with_pid(snapshot("old", vec![button("Save", None)]), 41);
        let save = issued(
            &mut registry,
            &old,
            SemanticRegistrationCoverage::Complete,
            "Save",
        );
        let sibling = with_pid(snapshot("sibling", vec![button("Save", None)]), 42);
        registry.register_with_liveness(&sibling, SemanticRegistrationCoverage::Partial, |_| true);
        let mut unrelated = with_pid(snapshot("unrelated", vec![button("Save", None)]), 99);
        unrelated.app.identifier = Some("com.example.other".into());
        registry.register(&unrelated, SemanticRegistrationCoverage::Complete);
        let new = with_pid(snapshot("new", vec![button("Other", None)]), 43);
        registry.register_with_liveness(&new, SemanticRegistrationCoverage::Partial, |pid| {
            pid != 41 && pid != 99
        });
        missing(&registry, "41", &save);
        let retained = selected(&registry, "42", &save);
        selected(&registry, "99", &save);
        assert!(matches!(
            retained.resolve(&old),
            SemanticLookup::Missing { .. }
        ));
        let mut fresh = sibling.clone();
        fresh.id = crate::SnapshotId("fresh".into());
        assert!(matches!(
            retained.resolve(&fresh),
            SemanticLookup::Unique { .. }
        ));
    }

    #[test]
    fn durable_locator_uses_original_scope_after_partial_and_duplicate_snapshot_ids() {
        let mut registry = SemanticNameRegistry::default();
        let scoped = |title: &str| Node {
            role: "group".into(),
            title: Some(title.into()),
            children: vec![Node {
                value: Some("captured state".into()),
                ..button("Save", None)
            }],
            ..empty_node()
        };
        let original = with_pid(
            snapshot("reused-id", vec![scoped("Left"), scoped("Right")]),
            41,
        );
        let name = registry
            .register(&original, SemanticRegistrationCoverage::Complete)
            .into_iter()
            .find(|name| name.source_index == 2)
            .unwrap()
            .name;
        let durable = registry.durable_locator("41", &name).unwrap();
        assert!(
            durable.contains_key("ancestors"),
            "scope must disambiguate the two Save buttons: {durable:?}"
        );
        for state in ["value", "frame", "actions", "nearbyText"] {
            assert!(!durable.contains_key(state));
        }
        let other = with_pid(snapshot("reused-id", vec![button("Other", None)]), 42);
        registry.register(&other, SemanticRegistrationCoverage::Complete);
        let partial = with_pid(snapshot("reused-id", vec![button("Different", None)]), 41);
        registry.register(&partial, SemanticRegistrationCoverage::Partial);
        assert_eq!(registry.durable_locator("41", &name).unwrap(), durable);
        let context = selected(&registry, "41", &name);
        assert_eq!(context.recorded_snapshot_id, Some(original.id.clone()));
        assert_eq!(context.app_name(), "App");
        assert_eq!(context.app_identifier(), Some("com.example.App"));
        let mut fresh = original.clone();
        fresh.id = crate::SnapshotId("fresh".into());
        match context.resolve(&fresh) {
            SemanticLookup::Unique { handle, .. } => assert_eq!(handle, fresh.handle(2)),
            _ => panic!("original scoped evidence did not resolve"),
        }
    }

    #[test]
    fn process_eviction_reclaims_both_baseline_and_partial_provenance() {
        let mut registry = SemanticNameRegistry::new(1);
        let baseline = with_pid(snapshot("baseline", vec![button("Save", None)]), 41);
        let save = issued(
            &mut registry,
            &baseline,
            SemanticRegistrationCoverage::Complete,
            "Save",
        );
        let partial = with_pid(snapshot("partial", vec![button("Other", None)]), 41);
        let other = issued(
            &mut registry,
            &partial,
            SemanticRegistrationCoverage::Partial,
            "Other",
        );
        let entry = &registry.processes[&ProcessKey::Pid(41)];
        let baseline_weak = Arc::downgrade(&entry.baseline[&save].provenance);
        let partial_weak = Arc::downgrade(&entry.partial[&other].provenance);
        registry.register(
            &empty_capture("new-process", 42),
            SemanticRegistrationCoverage::Partial,
        );
        assert!(baseline_weak.upgrade().is_none());
        assert!(partial_weak.upgrade().is_none());
        missing(&registry, "41", &save);
        missing(&registry, "41", &other);
    }

    #[test]
    fn pidless_and_pid_groups_with_same_name_select_newest_without_merging_candidates() {
        let mut registry = SemanticNameRegistry::default();
        let anonymous = snapshot("anonymous", vec![button("Save", Some("anonymous"))]);
        let save = issued(
            &mut registry,
            &anonymous,
            SemanticRegistrationCoverage::Partial,
            "Save",
        );
        let pid = with_pid(snapshot("pid", vec![button("Save", Some("pid"))]), 41);
        registry.register(&pid, SemanticRegistrationCoverage::Partial);
        assert_eq!(selected(&registry, "App", &save).process_id(), Some(41));
        registry.register(&anonymous, SemanticRegistrationCoverage::Partial);
        assert_eq!(selected(&registry, "App", &save).process_id(), None);
        assert_eq!(
            selected(&registry, "pid:41", &save).recorded_handle(),
            Some(&pid.handle(1))
        );
        assert_eq!(registry.processes.len(), 2);
    }

    #[test]
    fn replay_precedence_and_persistence_are_unchanged_by_partial_observations() {
        let mut registry = SemanticNameRegistry::default();
        let capture = with_pid(
            snapshot("capture", vec![button("Save", Some("captured"))]),
            41,
        );
        let name = issued(
            &mut registry,
            &capture,
            SemanticRegistrationCoverage::Complete,
            "Save",
        );
        let replay_target = target("App", name.clone());
        let replay_locator = locator(&button("Save", Some("replay")), &[], None);
        registry.register_replay_locator_for_process(
            replay_target.clone(),
            replay_locator.clone(),
            Some(42),
        );
        registry.register(
            &empty_capture("partial", 41),
            SemanticRegistrationCoverage::Partial,
        );
        let context = selected(&registry, "App", &name);
        assert_eq!(context.locator(), &replay_locator);
        assert!(context.captured.is_none());
        assert!(context.recorded_handle().is_none());
        assert_eq!(context.process_id(), Some(42));
        let durable: Locator = serde_json::from_value(serde_json::Value::Object(
            registry.durable_locator("App", &name).unwrap(),
        ))
        .unwrap();
        assert_eq!(durable, crate::persisted_locator_shape(&replay_locator));
        registry.register_replay_locator_for_process(
            replay_target.clone(),
            replay_locator,
            Some(43),
        );
        assert!(matches!(
            registry.select(&replay_target),
            SemanticSelection::Ambiguous { .. }
        ));
        assert_eq!(selected(&registry, "41", &name).process_id(), Some(41));
    }

    #[test]
    fn replay_evidence_is_pinned_and_legacy_duplicates_are_ambiguous() {
        let mut registry = SemanticNameRegistry::default();
        let replay_target = target("App", "save".into());
        let evidence = locator(&button("Save", Some("save")), &[], None);
        registry.register_replay_locator_for_process(
            replay_target.clone(),
            evidence.clone(),
            Some(41),
        );
        let SemanticSelection::Selected(context) = registry.select(&replay_target) else {
            panic!("single replay record was not selected");
        };
        assert_eq!(context.process_id(), Some(41));

        registry.register_replay_locator_for_process(replay_target.clone(), evidence, Some(42));
        assert!(matches!(
            registry.select(&replay_target),
            SemanticSelection::Ambiguous { .. }
        ));
        let pid_target = target("pid:41", "save".into());
        registry.register_replay_locator_for_process(
            pid_target.clone(),
            locator(&button("Save", Some("save")), &[], None),
            Some(41),
        );
        let SemanticSelection::Selected(context) = registry.select(&pid_target) else {
            panic!("PID replay record was not selected");
        };
        assert_eq!(context.process_id(), Some(41));
    }
}
