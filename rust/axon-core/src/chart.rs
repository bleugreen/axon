use crate::{
    AncestorLocator, Locator, LocatorResolver, ResolutionStatus, RetainedSemanticLookup,
    SemanticCandidate, SemanticElementName, SemanticLookup, SemanticNameDeriver,
    SemanticNameRegistry, Snapshot, TextMatcher, WireElementTarget, locator as runtime_locator,
    lookup_from_resolution, walk_context,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
};

pub const CHART_SCHEMA_VERSION: u32 = 1;
pub const SEED_CONFIDENCE_FLOOR: f64 = 0.15;
pub const EVICTION_CONFIDENCE_FLOOR: f64 = 0.05;
const SECONDS_PER_DAY: f64 = 86_400.0;

#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChartKey {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub candidate_ordinal: Option<usize>,
    pub identity_key: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChartLocator {
    pub role: Option<String>,
    pub subrole: Option<String>,
    pub title: Option<TextMatcher>,
    pub label: Option<TextMatcher>,
    pub description: Option<TextMatcher>,
    pub identifier: Option<TextMatcher>,
    #[serde(default)]
    pub actions: Vec<String>,
    #[serde(default)]
    pub ancestors: Vec<AncestorLocator>,
    pub window: Option<AncestorLocator>,
    #[serde(default)]
    pub nearby_text: Vec<TextMatcher>,
}

impl From<&Locator> for ChartLocator {
    fn from(locator: &Locator) -> Self {
        Self {
            role: locator.role.clone(),
            subrole: locator.subrole.clone(),
            title: locator.title.clone(),
            label: locator.label.clone(),
            description: locator.description.clone(),
            identifier: locator.identifier.clone(),
            actions: locator.actions.clone(),
            ancestors: locator.ancestors.clone(),
            window: locator.window.clone(),
            nearby_text: locator.nearby_text.clone(),
        }
    }
}

impl ChartLocator {
    pub fn to_locator(&self) -> Locator {
        Locator {
            role: self.role.clone(),
            subrole: self.subrole.clone(),
            title: self.title.clone(),
            label: self.label.clone(),
            value: None,
            description: self.description.clone(),
            identifier: self.identifier.clone(),
            actions: self.actions.clone(),
            ancestors: self.ancestors.clone(),
            window: self.window.clone(),
            nearby_text: self.nearby_text.clone(),
            frame: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChartElement {
    #[serde(flatten)]
    pub key: ChartKey,
    pub role: String,
    pub label: String,
    pub locator: ChartLocator,
    pub first_seen: u64,
    pub last_seen: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_confirmed_app_version: Option<String>,
    pub observations: u64,
    pub resolution_successes: u64,
    pub resolution_failures: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppChart {
    pub schema_version: u32,
    pub app_identity: String,
    pub entries: Vec<ChartElement>,
}

impl AppChart {
    pub fn empty(app_identity: impl Into<String>) -> Self {
        Self {
            schema_version: CHART_SCHEMA_VERSION,
            app_identity: app_identity.into(),
            entries: Vec::new(),
        }
    }
}

/// Computes confidence without consulting wall-clock time.
///
/// Observation strength is `1 - exp(-observations / 3)`; recency has a 90-day
/// half-life; reliability is add-one smoothed; and a known app-version mismatch
/// applies a multiplicative 0.5 haircut. A clock before `last_seen` has zero age.
pub fn confidence(element: &ChartElement, now: u64, observed_app_version: Option<&str>) -> f64 {
    let observation_strength = 1.0 - (-(element.observations as f64) / 3.0).exp();
    let age_days = now.saturating_sub(element.last_seen) as f64 / SECONDS_PER_DAY;
    let recency = 2_f64.powf(-age_days / 90.0);
    let reliability = (element.resolution_successes + 1) as f64
        / (element.resolution_successes + element.resolution_failures + 1) as f64;
    let version_factor = match (
        element.last_confirmed_app_version.as_deref(),
        observed_app_version,
    ) {
        (Some(previous), Some(current)) if previous != current => 0.5,
        _ => 1.0,
    };
    (observation_strength * recency * reliability * version_factor).clamp(0.0, 1.0)
}

pub struct ChartStore {
    root: PathBuf,
    charts: HashMap<String, AppChart>,
}

impl ChartStore {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            charts: HashMap::new(),
        }
    }

    pub fn chart_path(&self, app_identity: &str) -> PathBuf {
        self.root
            .join(format!("{}.json", hex(app_identity.as_bytes())))
    }

    pub fn load(&mut self, app_identity: &str) -> AppChart {
        let chart = load_chart(&self.chart_path(app_identity), app_identity);
        self.charts.insert(app_identity.to_owned(), chart.clone());
        chart
    }

    pub fn chart(&mut self, app_identity: &str) -> &AppChart {
        self.ensure_loaded(app_identity);
        self.charts
            .get(app_identity)
            .expect("chart is loaded before access")
    }

    pub fn confirm_capture(
        &mut self,
        app_identity: &str,
        snapshot: &Snapshot,
        app_version: Option<&str>,
        now: u64,
    ) {
        self.ensure_loaded(app_identity);
        let names = SemanticNameDeriver::derive(snapshot);
        let mut contexts = Vec::new();
        for window in &snapshot.app.windows {
            walk_context(&window.root, &[], window.title.as_deref(), &mut contexts);
        }

        let observed: Vec<_> = names
            .iter()
            .filter_map(|name| {
                contexts
                    .get(name.source_index)
                    .map(|(node, ancestors, window)| {
                        new_element(
                            name,
                            ChartLocator::from(&runtime_locator(
                                node,
                                ancestors,
                                window.as_deref(),
                            )),
                            app_version,
                            now,
                        )
                    })
            })
            .collect();

        let chart = self
            .charts
            .get_mut(app_identity)
            .expect("chart is loaded before capture");
        reconcile(&mut chart.entries, observed, app_version, now);
        chart
            .entries
            .sort_by(|left, right| left.key.cmp(&right.key));
    }

    pub fn record_success(&mut self, app_identity: &str, key: &ChartKey, _now: u64) {
        self.record_outcome(app_identity, key, true);
    }

    pub fn record_failure(&mut self, app_identity: &str, key: &ChartKey, _now: u64) {
        self.record_outcome(app_identity, key, false);
    }

    pub fn seeds(
        &mut self,
        app_identity: &str,
        name: &str,
        now: u64,
        observed_app_version: Option<&str>,
    ) -> Vec<ChartElement> {
        self.ensure_loaded(app_identity);
        self.charts[app_identity]
            .entries
            .iter()
            .filter(|entry| {
                entry.key.name == name
                    && confidence(entry, now, observed_app_version) >= SEED_CONFIDENCE_FLOOR
            })
            .cloned()
            .collect()
    }

    pub fn prune(&mut self, app_identity: &str, now: u64, observed_app_version: Option<&str>) {
        self.ensure_loaded(app_identity);
        self.charts
            .get_mut(app_identity)
            .expect("chart is loaded before prune")
            .entries
            .retain(|entry| {
                confidence(entry, now, observed_app_version) >= EVICTION_CONFIDENCE_FLOOR
            });
    }

    pub fn save(&mut self, app_identity: &str, now: u64, observed_app_version: Option<&str>) {
        self.prune(app_identity, now, observed_app_version);
        let path = self.chart_path(app_identity);
        let chart = self.charts[app_identity].clone();
        if chart.entries.is_empty() {
            let _ = fs::remove_file(path);
            return;
        }
        let Ok(json) = serde_json::to_vec_pretty(&chart) else {
            return;
        };
        let Some(parent) = path.parent() else {
            return;
        };
        if fs::create_dir_all(parent).is_err() {
            return;
        }
        let temporary = temporary_path(&path);
        if fs::write(&temporary, json).is_err() {
            return;
        }
        if fs::rename(&temporary, &path).is_err() {
            let _ = fs::remove_file(&temporary);
        }
    }

    fn ensure_loaded(&mut self, app_identity: &str) {
        if !self.charts.contains_key(app_identity) {
            self.load(app_identity);
        }
    }

    fn record_outcome(&mut self, app_identity: &str, key: &ChartKey, success: bool) {
        self.ensure_loaded(app_identity);
        let Some(entry) = self
            .charts
            .get_mut(app_identity)
            .and_then(|chart| chart.entries.iter_mut().find(|entry| entry.key == *key))
        else {
            return;
        };
        if success {
            entry.resolution_successes = entry.resolution_successes.saturating_add(1);
        } else {
            entry.resolution_failures = entry.resolution_failures.saturating_add(1);
        }
    }
}

pub struct ChartSeededResolver<'a> {
    registry: &'a SemanticNameRegistry,
    charts: &'a mut ChartStore,
}

impl<'a> ChartSeededResolver<'a> {
    pub fn new(registry: &'a SemanticNameRegistry, charts: &'a mut ChartStore) -> Self {
        Self { registry, charts }
    }

    pub fn resolve(
        &mut self,
        target: &WireElementTarget,
        live: &Snapshot,
        app_identity: &str,
        current_app_version: Option<&str>,
        now: u64,
    ) -> SemanticLookup {
        match self.registry.resolve_retained(target, live) {
            RetainedSemanticLookup::Resolved(lookup) => return *lookup,
            RetainedSemanticLookup::NoRecord => {}
        }

        if !app_matches_identity(&target.app, live, app_identity) {
            return SemanticLookup::Missing {
                target: target.clone(),
            };
        }
        let seeds = self
            .charts
            .seeds(app_identity, &target.name, now, current_app_version);
        if seeds.is_empty() {
            return SemanticLookup::Missing {
                target: target.clone(),
            };
        }
        if seeds.len() == 1 {
            let seed = &seeds[0];
            let locator = seed.locator.to_locator();
            let resolution = LocatorResolver::resolve(&locator, live);
            if resolution.status == ResolutionStatus::Unique {
                self.charts.record_success(app_identity, &seed.key, now);
            } else {
                self.charts.record_failure(app_identity, &seed.key, now);
            }
            return lookup_from_resolution(target, resolution, &locator);
        }

        let mut candidates = Vec::new();
        for seed in &seeds {
            let locator = seed.locator.to_locator();
            let resolution = LocatorResolver::resolve(&locator, live);
            self.charts.record_failure(app_identity, &seed.key, now);
            candidates.extend(
                resolution
                    .candidates
                    .iter()
                    .map(|candidate| SemanticCandidate {
                        name: target.name.clone(),
                        candidate_label: None,
                        role: candidate.role.clone(),
                        label: candidate.title.clone().unwrap_or_default(),
                        locator: locator.clone(),
                    }),
            );
        }
        SemanticLookup::Ambiguous {
            target: target.clone(),
            candidates,
        }
    }
}

fn new_element(
    name: &SemanticElementName,
    locator: ChartLocator,
    app_version: Option<&str>,
    now: u64,
) -> ChartElement {
    ChartElement {
        key: ChartKey {
            name: name.name.clone(),
            candidate_ordinal: candidate_ordinal(name),
            identity_key: name.identity_key.clone(),
        },
        role: name.role.clone(),
        label: name.label.clone(),
        locator,
        first_seen: now,
        last_seen: now,
        last_confirmed_app_version: app_version.map(str::to_owned),
        observations: 1,
        resolution_successes: 0,
        resolution_failures: 0,
    }
}

fn candidate_ordinal(name: &SemanticElementName) -> Option<usize> {
    name.candidate_label
        .as_deref()
        .and_then(|label| label.strip_prefix(&format!("{}-", name.name)))
        .and_then(|ordinal| ordinal.parse().ok())
}

fn reconcile(
    current: &mut Vec<ChartElement>,
    observed: Vec<ChartElement>,
    app_version: Option<&str>,
    now: u64,
) {
    let old = std::mem::take(current);
    let observed_names = observed
        .iter()
        .map(|entry| entry.key.name.as_str())
        .collect::<std::collections::HashSet<_>>();
    let mut next: Vec<_> = old
        .iter()
        .filter(|entry| !observed_names.contains(entry.key.name.as_str()))
        .cloned()
        .collect();
    next.reserve(observed.len());
    for mut fresh in observed {
        let previous = old.iter().find(|entry| {
            entry.key.name == fresh.key.name
                && match fresh.key.candidate_ordinal {
                    Some(_) => {
                        entry.key.candidate_ordinal.is_some()
                            && entry.key.identity_key == fresh.key.identity_key
                    }
                    None => entry.key.candidate_ordinal.is_none(),
                }
        });
        if let Some(previous) = previous {
            fresh.first_seen = previous.first_seen;
            fresh.observations = previous.observations.saturating_add(1);
            fresh.resolution_successes = previous.resolution_successes;
            fresh.resolution_failures = previous.resolution_failures;
        }
        fresh.last_seen = now;
        fresh.last_confirmed_app_version = app_version.map(str::to_owned);
        next.push(fresh);
    }
    *current = next;
}

fn load_chart(path: &Path, app_identity: &str) -> AppChart {
    let loaded = fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<AppChart>(&bytes).ok());
    match loaded {
        Some(mut chart)
            if chart.schema_version == CHART_SCHEMA_VERSION
                && chart.app_identity == app_identity =>
        {
            chart
                .entries
                .sort_by(|left, right| left.key.cmp(&right.key));
            chart
        }
        _ => AppChart::empty(app_identity),
    }
}

fn temporary_path(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map_or_else(|| "chart".into(), |name| name.to_os_string());
    name.push(".tmp");
    path.with_file_name(name)
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(DIGITS[(byte >> 4) as usize] as char);
        encoded.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    encoded
}

fn app_matches_identity(query: &str, live: &Snapshot, app_identity: &str) -> bool {
    query.eq_ignore_ascii_case(&live.app.name)
        || query.eq_ignore_ascii_case(app_identity)
        || live
            .app
            .identifier
            .as_deref()
            .is_some_and(|identifier| query.eq_ignore_ascii_case(identifier))
}
