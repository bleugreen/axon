use crate::{
    Confidence, LocatorHealEvent, LocatorHealStatus, TargetResolution, healing_event,
    redact_target_resolution, reviewed_yaml,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::thread;
use std::time::{Duration, Instant};

pub const CHANGE_POLL_INTERVAL: Duration = Duration::from_millis(100);
pub const CHANGE_TIMEOUT: Duration = Duration::from_millis(5_000);

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AxnDocument {
    #[serde(default = "default_version", deserialize_with = "deserialize_version")]
    pub version: u32,
    #[serde(default, rename = "args")]
    pub arguments: Vec<AxnArgument>,
    #[serde(default)]
    pub actions: Vec<AxnAction>,
    #[serde(flatten)]
    pub flags: Map<String, Value>,
}

pub struct PreparedRun {
    pub document: AxnDocument,
    pub arg_values: Map<String, Value>,
    pub options: RunOptions,
    pub source_path: Option<String>,
    pub healed_path: Option<String>,
}

pub fn prepare_run(params: &Map<String, Value>) -> Result<PreparedRun, AxnError> {
    let source_path = params
        .get("path")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let inline_actions = params.get("actions").and_then(Value::as_array);
    if params.contains_key("actions") && inline_actions.is_none() {
        return Err(AxnError::Invalid("actions must be an array".into()));
    }

    let mut document = if let Some(path) = source_path.as_deref() {
        let source = fs::read_to_string(path)
            .map_err(|error| AxnError::Invalid(format!("could not read {path}: {error}")))?;
        AxnCodec::parse(&source)?
    } else if inline_actions.is_some() {
        AxnDocument {
            version: 2,
            arguments: Vec::new(),
            actions: Vec::new(),
            flags: Map::new(),
        }
    } else {
        return Err(AxnError::Invalid("run requires actions or path".into()));
    };

    if let Some(actions) = inline_actions {
        for (index, action) in actions.iter().enumerate() {
            let action = serde_json::from_value(action.clone()).map_err(|error| {
                AxnError::Invalid(format!("actions[{index}] is invalid: {error}"))
            })?;
            document.actions.push(action);
        }
    }

    Ok(PreparedRun {
        document,
        arg_values: params
            .get("argValues")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default(),
        options: RunOptions {
            dry_run: params.get("dryRun").and_then(Value::as_bool),
            continue_on_error: params.get("continueOnError").and_then(Value::as_bool),
        },
        source_path,
        healed_path: params
            .get("healedPath")
            .and_then(Value::as_str)
            .map(str::to_owned),
    })
}

pub fn unique_expected_fact_candidate<'a>(
    fact: &ExpectedFact,
    resolution: &'a crate::Resolution,
) -> Result<&'a crate::Candidate, String> {
    if resolution.status != crate::ResolutionStatus::Unique {
        return Err(format!(
            "fact {} locator did not resolve uniquely: {:?}",
            fact.id, resolution.status
        ));
    }
    resolution.best.as_ref().ok_or_else(|| {
        format!(
            "fact {} locator reported unique without a best candidate",
            fact.id
        )
    })
}

pub fn changed_snapshot_baseline(snapshot: &crate::Snapshot) -> Result<Value, String> {
    serde_json::to_value(crate::SnapshotSummary::from(snapshot)).map_err(|error| error.to_string())
}

pub fn expected_fact_target(fact: &ExpectedFact) -> Result<(String, crate::Locator), String> {
    let target = fact
        .fields
        .get("target")
        .and_then(Value::as_object)
        .ok_or_else(|| format!("fact {} target must be an object", fact.id))?;
    let app = target
        .get("app")
        .and_then(Value::as_str)
        .filter(|app| !app.is_empty())
        .ok_or_else(|| format!("fact {} target requires app", fact.id))?;
    let locator = target
        .get("locator")
        .ok_or_else(|| format!("fact {} target requires locator", fact.id))?;
    let locator = serde_json::from_value(locator.clone())
        .map_err(|error| format!("fact {} has invalid locator: {error}", fact.id))?;
    Ok((app.to_owned(), locator))
}

pub fn expected_fact_app(fact: &ExpectedFact) -> Result<String, String> {
    fact.fields
        .get("target")
        .and_then(Value::as_object)
        .and_then(|target| target.get("app"))
        .and_then(Value::as_str)
        .filter(|app| !app.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| format!("fact {} target requires app", fact.id))
}

fn same_path(left: &str, right: &str) -> bool {
    let absolute = |path: &str| {
        let path = std::path::PathBuf::from(path);
        if path.is_absolute() {
            path
        } else {
            std::env::current_dir().unwrap_or_default().join(path)
        }
    };
    std::fs::canonicalize(left).unwrap_or_else(|_| absolute(left))
        == std::fs::canonicalize(right).unwrap_or_else(|_| absolute(right))
}

fn default_version() -> u32 {
    1
}
fn deserialize_version<'de, D: serde::Deserializer<'de>>(d: D) -> Result<u32, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum V {
        N(u32),
        S(String),
    }
    match V::deserialize(d)? {
        V::N(v) => Ok(v),
        V::S(v) => v.parse().map_err(serde::de::Error::custom),
    }
}

fn validate_replay_contract(doc: &AxnDocument) -> Result<(), AxnError> {
    if doc.version != 2 {
        let obsolete = doc.actions.iter().enumerate().find_map(|(i, a)| {
            ["target", "from", "to"]
                .iter()
                .find_map(|k| a.params.get(*k).map(|v| (i, v)))
        });
        let suffix = obsolete
            .map(|(i, v)| format!("; actions[{i}] obsolete target {v}"))
            .unwrap_or_default();
        return Err(AxnError::Invalid(format!(
            ".axn version {} is not replayable; version 1 targets are obsolete and must be re-recorded or edited as version 2{suffix}",
            doc.version
        )));
    }
    for (index, action) in doc.actions.iter().enumerate() {
        if action.tool.trim().is_empty() {
            if action.params.contains_key("note") {
                continue;
            }
            return Err(AxnError::Invalid(format!("actions[{index}] requires tool")));
        }
        for key in ["target", "from", "to"] {
            if let Some(v) = action.params.get(key) {
                validate_target(v, &format!("actions[{index}].{key}"))?;
            }
        }
    }
    Ok(())
}

fn validate_target(value: &Value, path: &str) -> Result<(), AxnError> {
    let object = value.as_object().ok_or_else(|| {
        AxnError::Invalid(format!(
            "{path} must be a version 2 target object; obsolete target {value}"
        ))
    })?;
    let point = object
        .get("point")
        .and_then(Value::as_object)
        .unwrap_or(object);
    if object.contains_key("point") || point.contains_key("x") || point.contains_key("y") {
        if point.contains_key("x") && point.contains_key("y") {
            return Ok(());
        }
        return Err(AxnError::Invalid(format!(
            "{path} point target requires x and y"
        )));
    }
    let valid = object
        .get("app")
        .and_then(Value::as_str)
        .is_some_and(|v| !v.is_empty())
        && object
            .get("name")
            .and_then(Value::as_str)
            .is_some_and(|v| !v.is_empty())
        && object.get("locator").is_some_and(Value::is_object);
    if valid {
        Ok(())
    } else {
        Err(AxnError::Invalid(format!(
            "{path} requires non-empty app and name with an attached locator"
        )))
    }
}

fn prepare_dispatch_params<D: ToolDispatcher>(
    dispatcher: &mut D,
    params: &Map<String, Value>,
) -> Result<Map<String, Value>, AxnError> {
    let mut primitive = params.clone();
    for key in ["target", "from", "to"] {
        let Some(Value::Object(target)) = primitive.get_mut(key) else {
            continue;
        };
        let (Some(app), Some(name), Some(locator_value)) = (
            target.get("app").and_then(Value::as_str),
            target.get("name").and_then(Value::as_str),
            target.get("locator"),
        ) else {
            continue;
        };
        let locator: crate::Locator = serde_json::from_value(locator_value.clone())
            .map_err(|e| AxnError::Invalid(format!("invalid attached locator: {e}")))?;
        dispatcher
            .register_replay_target(app, name, &locator)
            .map_err(AxnError::Invalid)?;
        let app = app.to_owned();
        let name = name.to_owned();
        *target = Map::from_iter([
            ("app".into(), Value::String(app)),
            ("name".into(), Value::String(name)),
        ]);
    }
    Ok(primitive)
}

fn valid_argument_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}
fn valid_email(value: &str) -> bool {
    let mut p = value.split('@');
    p.next().is_some_and(|v| !v.is_empty())
        && p.next()
            .is_some_and(|v| v.contains('.') && !v.starts_with('.'))
        && p.next().is_none()
}
fn valid_date(value: &str) -> bool {
    let b = value.as_bytes();
    if !(b.len() == 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b[..4]
            .iter()
            .chain(&b[5..7])
            .chain(&b[8..10])
            .all(u8::is_ascii_digit))
    {
        return false;
    }
    let year = value[..4].parse::<u32>().unwrap();
    let month = value[5..7].parse::<usize>().unwrap();
    let day = value[8..10].parse::<u32>().unwrap();
    let leap = year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400));
    let days = [
        31,
        28 + u32::from(leap),
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    year != 0 && month != 0 && month <= 12 && day != 0 && day <= days[month - 1]
}
fn contains_reference(value: &Value) -> bool {
    match value {
        Value::String(s) => s.contains("{{") || s.contains("}}"),
        Value::Array(a) => a.iter().any(contains_reference),
        Value::Object(o) => o.values().any(contains_reference),
        _ => false,
    }
}
fn substitute_string(
    template: &str,
    bindings: &HashMap<String, (String, bool)>,
) -> Result<(String, bool), AxnError> {
    let mut output = String::new();
    let mut rest = template;
    let mut secret = false;
    while let Some(start) = rest.find("{{") {
        output.push_str(&rest[..start]);
        let tail = &rest[start + 2..];
        let end = tail.find("}}").ok_or_else(|| {
            AxnError::Invalid(format!("invalid arg reference syntax: {template}"))
        })?;
        let token = &tail[..end];
        if token.contains('{') || token.contains('}') {
            return Err(AxnError::Invalid(format!(
                "invalid arg reference syntax: {template}"
            )));
        }
        let name = token.trim();
        if !valid_reference_name(name) {
            return Err(AxnError::Invalid(format!(
                "invalid arg reference syntax: {template}"
            )));
        }
        let (value, tainted) = bindings
            .get(name)
            .ok_or_else(|| AxnError::Invalid(format!("undeclared arg reference: {name}")))?;
        output.push_str(value);
        secret |= *tainted;
        rest = &tail[end + 2..];
    }
    if rest.contains("}}") {
        return Err(AxnError::Invalid(format!(
            "invalid arg reference syntax: {template}"
        )));
    }
    output.push_str(rest);
    Ok((output, secret))
}
fn valid_reference_name(name: &str) -> bool {
    let mut c = name.chars();
    c.next().is_some_and(|x| x.is_ascii_alphabetic())
        && c.all(|x| x.is_ascii_alphanumeric() || x == '_')
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AxnArgument {
    pub name: String,
    #[serde(rename = "type")]
    pub kind: ArgumentType,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub default: Option<Value>,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(flatten)]
    pub unknown_fields: Map<String, Value>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ArgumentType {
    String,
    Email,
    Number,
    Path,
    Secret,
    Date,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AxnAction {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub tool: String,
    #[serde(default)]
    pub requires: Vec<String>,
    #[serde(default)]
    pub expects: Vec<ExpectedFact>,
    #[serde(flatten)]
    pub params: Map<String, Value>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ExpectedFact {
    pub id: String,
    #[serde(flatten)]
    pub fields: Map<String, Value>,
}

#[derive(Debug, thiserror::Error)]
pub enum AxnError {
    #[error("invalid .axn document: {0}")]
    Invalid(String),
    #[error("missing argument: {0}")]
    MissingArgument(String),
    #[error("argument {0} is invalid for its declared type")]
    InvalidArgument(String),
    #[error("no resolver is registered for source scheme: {0}")]
    MissingResolver(String),
    #[error("source resolver failed: {0}")]
    Source(String),
}

pub struct AxnCodec;
impl AxnCodec {
    pub fn parse(source: &str) -> Result<AxnDocument, AxnError> {
        let doc: AxnDocument = serde_json::from_str(source)
            .or_else(|_| serde_yaml::from_str(source))
            .map_err(|e| AxnError::Invalid(e.to_string()))?;
        if !matches!(doc.version, 1 | 2) {
            return Err(AxnError::Invalid(format!(
                "unsupported version {}",
                doc.version
            )));
        }
        Ok(doc)
    }
    pub fn to_yaml(doc: &AxnDocument) -> Result<String, AxnError> {
        serde_yaml::to_string(doc).map_err(|e| AxnError::Invalid(e.to_string()))
    }
    pub fn to_json(doc: &AxnDocument) -> Result<String, AxnError> {
        serde_json::to_string_pretty(doc).map_err(|e| AxnError::Invalid(e.to_string()))
    }
}

pub trait ArgumentSourceResolver {
    fn resolve(&self, source: &str) -> Result<Option<String>, String>;
}
impl<F> ArgumentSourceResolver for F
where
    F: Fn(&str) -> Result<Option<String>, String>,
{
    fn resolve(&self, source: &str) -> Result<Option<String>, String> {
        self(source)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DispatchOutcome {
    pub success: bool,
    /// The native action was delivered, but its semantic effect was not verified.
    ///
    /// This is the only unsuccessful outcome that replay may promote using declared
    /// postconditions. Transport, capability, target-resolution, and refusal failures
    /// must leave it false.
    #[serde(default)]
    pub dispatched_without_semantic_verification: bool,
    #[serde(default)]
    pub result: Value,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub resolution: Option<TargetResolution>,
}
pub trait ToolDispatcher {
    /// Seed platform semantic resolution with locator evidence attached by the recorder.
    /// Implementations must resolve this locator through their normal live backend.
    fn register_replay_target(
        &mut self,
        _app: &str,
        _name: &str,
        _locator: &crate::Locator,
    ) -> Result<(), String> {
        Ok(())
    }
    fn dispatch(&mut self, tool: &str, params: &Map<String, Value>) -> DispatchOutcome;
    fn verify(&mut self, fact: &ExpectedFact) -> Result<(), String>;
    fn capture_changed_baseline(&mut self, fact: &ExpectedFact) -> Result<Value, String> {
        Err(format!("changed fact {} is unsupported", fact.id))
    }
    fn change_poll_interval(&self) -> Duration {
        CHANGE_POLL_INTERVAL
    }
    fn change_timeout(&self) -> Duration {
        CHANGE_TIMEOUT
    }
    fn verify_changed(&mut self, fact: &ExpectedFact, baseline: &Value) -> Result<(), String> {
        let deadline = Instant::now() + self.change_timeout();
        loop {
            let current = self.capture_changed_baseline(fact)?;
            if current != *baseline {
                return Ok(());
            }
            if Instant::now() > deadline {
                return Err(format!(
                    "fact {} did not verify: app did not change",
                    fact.id
                ));
            }
            let interval = self.change_poll_interval();
            if !interval.is_zero() {
                thread::sleep(interval);
            }
        }
    }
    fn verify_replay_locator(
        &mut self,
        _app: &str,
        _locator: &Value,
        _minimum: Confidence,
    ) -> bool {
        false
    }
}

pub fn expected_fact_kind(fact: &ExpectedFact) -> Result<&str, String> {
    fact.fields
        .get("kind")
        .and_then(Value::as_str)
        .filter(|kind| !kind.is_empty())
        .ok_or_else(|| format!("fact {} requires kind", fact.id))
}

pub fn verify_expected_fact_state(
    fact: &ExpectedFact,
    observed: &Map<String, Value>,
) -> Result<(), String> {
    let kind = expected_fact_kind(fact)?;
    if matches!(
        kind,
        "exists" | "window" | "window-exists" | "menu-selection"
    ) {
        return observed
            .get("exists")
            .and_then(Value::as_bool)
            .unwrap_or(true)
            .then_some(())
            .ok_or_else(|| format!("fact {} did not verify: target does not exist", fact.id));
    }
    if kind == "changed" {
        return Err(format!(
            "changed fact {} requires a pre-dispatch baseline",
            fact.id
        ));
    }
    let key = match kind {
        "focused" => "focused",
        "enabled" => "enabled",
        "value" => "value",
        "selected" => "selected",
        other => {
            return Err(format!(
                "fact {} is unsupported: unknown kind {other}",
                fact.id
            ));
        }
    };
    let expected = fact
        .fields
        .get("state")
        .and_then(Value::as_object)
        .and_then(|state| state.get(key));
    let actual = observed.get(key);
    if matches!(key, "focused" | "enabled") {
        let expected = expected
            .and_then(|value| value.as_bool().or_else(|| value.get("equals")?.as_bool()))
            .unwrap_or(true);
        return (actual.and_then(Value::as_bool) == Some(expected))
            .then_some(())
            .ok_or_else(|| {
                format!(
                    "fact {} did not verify: {key} expected {expected}, got {actual:?}",
                    fact.id
                )
            });
    }
    let actual = actual.and_then(Value::as_str);
    let Some(expected) = expected else {
        return actual
            .is_some()
            .then_some(())
            .ok_or_else(|| format!("fact {} did not verify: {key} was nil", fact.id));
    };
    let (needle, contains, case_sensitive) = if let Some(value) = expected.as_str() {
        (value, false, false)
    } else if let Some(object) = expected.as_object() {
        let case_sensitive = object
            .get("caseSensitive")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if let Some(value) = object.get("contains").and_then(Value::as_str) {
            (value, true, case_sensitive)
        } else if let Some(value) = object
            .get("equals")
            .or_else(|| object.get("exact"))
            .and_then(Value::as_str)
        {
            (value, false, case_sensitive)
        } else {
            return Err(format!(
                "fact {} {key} expectation must include equals, exact, or contains",
                fact.id
            ));
        }
    } else {
        return Err(format!(
            "fact {} {key} expectation must be a string or object",
            fact.id
        ));
    };
    let matched = actual.is_some_and(|actual| {
        let (actual, needle) = if case_sensitive {
            (actual.to_owned(), needle.to_owned())
        } else {
            (actual.to_lowercase(), needle.to_lowercase())
        };
        if contains {
            actual.contains(&needle)
        } else {
            actual == needle
        }
    });
    matched.then_some(()).ok_or_else(|| {
        format!(
            "fact {} did not verify: {key} expectation failed, got {actual:?}",
            fact.id
        )
    })
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunOptions {
    #[serde(default)]
    pub dry_run: Option<bool>,
    #[serde(default)]
    pub continue_on_error: Option<bool>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunResult {
    pub success: bool,
    pub dry_run: bool,
    pub continue_on_error: bool,
    pub trace: Vec<TraceEntry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub heal: Option<HealingSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub healed_path: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HealingSummary {
    pub count: usize,
    pub events: Vec<LocatorHealEvent>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceEntry {
    pub index: usize,
    pub tool: String,
    pub success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "targetResolution")]
    pub resolution: Option<TargetResolution>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub heal: Option<LocatorHealEvent>,
}

pub struct AxnRunner<'a, D: ToolDispatcher> {
    dispatcher: &'a mut D,
    sources: HashMap<String, Box<dyn ArgumentSourceResolver + 'a>>,
    healed_output: Option<(Option<String>, String)>,
}
impl<'a, D: ToolDispatcher> AxnRunner<'a, D> {
    pub fn new(dispatcher: &'a mut D) -> Self {
        let mut sources: HashMap<String, Box<dyn ArgumentSourceResolver + 'a>> = HashMap::new();
        sources.insert("env".into(), Box::new(resolve_environment_source));
        sources.insert("op".into(), Box::new(resolve_one_password_source));
        Self {
            dispatcher,
            sources,
            healed_output: None,
        }
    }
    pub fn with_source(
        mut self,
        scheme: impl Into<String>,
        resolver: impl ArgumentSourceResolver + 'a,
    ) -> Self {
        self.sources.insert(scheme.into(), Box::new(resolver));
        self
    }
    pub fn with_healed_output(mut self, source_path: Option<String>, healed_path: String) -> Self {
        self.healed_output = Some((source_path, healed_path));
        self
    }
    pub fn run(
        &mut self,
        doc: &AxnDocument,
        arg_values: &Map<String, Value>,
        options: RunOptions,
    ) -> Result<RunResult, AxnError> {
        validate_replay_contract(doc)?;
        let bindings = self.bind(&doc.arguments, arg_values)?;
        let active_secrets: Vec<String> = bindings
            .values()
            .filter(|(_, secret)| *secret)
            .map(|(value, _)| value.clone())
            .collect();
        let dry_run = options
            .dry_run
            .unwrap_or_else(|| document_flag(doc, "dryRun"));
        let continue_on_error = options
            .continue_on_error
            .unwrap_or_else(|| document_flag(doc, "continueOnError"));
        let healed_output = self.healed_output.clone();
        let mut trace = Vec::new();
        let mut heal_events = Vec::new();
        let mut facts: HashMap<String, ExpectedFact> = HashMap::new();
        let mut success = true;
        for (index, recorded_action) in doc.actions.iter().enumerate() {
            let mut action = recorded_action.clone();
            action.expects = substitute_expected_facts(&action.expects, &bindings, index)?;
            let action = &action;
            if action.tool.is_empty() && action.params.contains_key("note") {
                continue;
            }
            if let Some(missing) = action.requires.iter().find(|id| !facts.contains_key(*id)) {
                let e = format!("required fact is unavailable: {missing}");
                trace.push(TraceEntry {
                    index,
                    tool: action.tool.clone(),
                    success: false,
                    action_id: action.id.clone(),
                    result: None,
                    error: Some(e),
                    resolution: None,
                    heal: None,
                });
                success = false;
                if !continue_on_error {
                    break;
                } else {
                    continue;
                }
            }
            if let Some(error) = action.requires.iter().find_map(|id| {
                facts.get(id).and_then(|fact| {
                    // `changed` records a transition already observed after its action. Unlike
                    // state facts, it is durable causal evidence and has no valid fresh baseline.
                    (expected_fact_kind(fact).ok() != Some("changed"))
                        .then(|| self.dispatcher.verify(fact).err())
                        .flatten()
                })
            }) {
                trace.push(TraceEntry {
                    index,
                    tool: action.tool.clone(),
                    success: false,
                    action_id: action.id.clone(),
                    result: None,
                    error: Some(redact_error(error, &active_secrets)),
                    resolution: None,
                    heal: None,
                });
                success = false;
                if !continue_on_error { break } else { continue }
            }
            let changed_baselines = if dry_run {
                HashMap::new()
            } else {
                action
                    .expects
                    .iter()
                    .filter(|fact| expected_fact_kind(fact).ok() == Some("changed"))
                    .map(|fact| {
                        self.dispatcher
                            .capture_changed_baseline(fact)
                            .map(|baseline| (fact.id.clone(), baseline))
                    })
                    .collect::<Result<HashMap<_, _>, _>>()
                    .map_err(AxnError::Invalid)?
            };
            let causal_transition = if dry_run || action.expects.is_empty() {
                false
            } else if action
                .expects
                .iter()
                .any(|fact| expected_fact_kind(fact).ok() == Some("changed"))
            {
                true
            } else if matches!(
                action.tool.as_str(),
                "click" | "keyboard" | "drag" | "scroll"
            ) {
                action
                    .expects
                    .iter()
                    .any(|fact| self.dispatcher.verify(fact).is_err())
            } else {
                false
            };
            let (params, secret_fields) = substitute_map(&action.params, &bindings, index)?;
            let params = prepare_dispatch_params(self.dispatcher, &params)?;
            let outcome = if dry_run {
                let mut shown = params.clone();
                for key in &secret_fields {
                    shown.insert(
                        key.clone(),
                        Value::String("<redacted: contains-secret>".into()),
                    );
                }
                DispatchOutcome {
                    success: true,
                    dispatched_without_semantic_verification: false,
                    result: Value::Object(shown),
                    error: None,
                    resolution: None,
                }
            } else {
                self.dispatcher.dispatch(&action.tool, &params)
            };
            let can_verify_dispatch_only =
                outcome.dispatched_without_semantic_verification && causal_transition;
            let verification_error = if (outcome.success || can_verify_dispatch_only) && !dry_run {
                action
                    .expects
                    .iter()
                    .find_map(|fact| match changed_baselines.get(&fact.id) {
                        Some(baseline) => self.dispatcher.verify_changed(fact, baseline).err(),
                        None => self.dispatcher.verify(fact).err(),
                    })
            } else {
                None
            };
            let redacted = if secret_fields.is_empty() {
                if can_verify_dispatch_only && verification_error.is_none() {
                    semantically_verified_result(&action.tool, outcome.result)
                } else {
                    outcome.result
                }
            } else {
                Value::String("<redacted: contains-secret>".into())
            };
            let heal = if dry_run {
                None
            } else {
                outcome.resolution.as_ref().and_then(|resolution| {
                    healing_event(
                        action,
                        index,
                        resolution,
                        &active_secrets,
                        |proposal, minimum| {
                            action
                                .params
                                .get("target")
                                .and_then(Value::as_object)
                                .and_then(|t| t.get("app"))
                                .and_then(Value::as_str)
                                .is_some_and(|app| {
                                    self.dispatcher
                                        .verify_replay_locator(app, proposal, minimum)
                                })
                        },
                    )
                })
            };
            if let Some(event) = &heal {
                heal_events.push(event.clone());
            }
            let action_success =
                (outcome.success || can_verify_dispatch_only) && verification_error.is_none();
            let entry = TraceEntry {
                index,
                tool: action.tool.clone(),
                success: action_success,
                action_id: action.id.clone(),
                result: (!redacted.is_null()).then_some(redacted),
                error: verification_error
                    .map(|error| redact_error(error, &active_secrets))
                    .or((!can_verify_dispatch_only)
                        .then_some(outcome.error)
                        .flatten()
                        .map(|e| {
                            if secret_fields.is_empty() {
                                e
                            } else {
                                "<redacted: contains-secret>".into()
                            }
                        })
                        .or_else(|| (!outcome.success).then(|| "action failed".into()))),
                resolution: outcome
                    .resolution
                    .map(|resolution| redact_target_resolution(&resolution, &active_secrets)),
                heal,
            };
            if entry.success {
                if !dry_run {
                    facts.extend(action.expects.iter().map(|f| (f.id.clone(), f.clone())));
                }
            } else {
                success = false;
            }
            let failed = !entry.success;
            trace.push(entry);
            if failed && !continue_on_error {
                break;
            }
        }
        let written_healed_path = if !dry_run
            && heal_events
                .iter()
                .any(|e| e.status == LocatorHealStatus::Proposed)
        {
            if let Some((source_path, path)) = healed_output {
                if source_path
                    .as_ref()
                    .is_some_and(|source| same_path(source, &path))
                {
                    return Err(AxnError::Invalid(
                        "healedPath must differ from the source path".into(),
                    ));
                }
                std::fs::write(&path, reviewed_yaml(doc, &heal_events)?)
                    .map_err(|e| AxnError::Invalid(format!("could not write healed file: {e}")))?;
                Some(path)
            } else {
                None
            }
        } else {
            None
        };
        let heal = (!heal_events.is_empty()).then_some(HealingSummary {
            count: heal_events.len(),
            events: heal_events,
        });
        Ok(RunResult {
            success,
            dry_run,
            continue_on_error,
            trace,
            heal,
            healed_path: written_healed_path,
        })
    }
    fn bind(
        &self,
        args: &[AxnArgument],
        values: &Map<String, Value>,
    ) -> Result<HashMap<String, (String, bool)>, AxnError> {
        let mut out = HashMap::new();
        let mut names = HashSet::new();
        for (index, arg) in args.iter().enumerate() {
            if !valid_argument_name(&arg.name) {
                return Err(AxnError::Invalid(format!(
                    "args[{index}] requires snake_case name"
                )));
            }
            if !names.insert(arg.name.clone()) {
                return Err(AxnError::Invalid(format!("duplicate arg: {}", arg.name)));
            }
        }
        if let Some(unknown) = values.keys().filter(|name| !names.contains(*name)).min() {
            return Err(AxnError::Invalid(format!("unknown arg: {unknown}")));
        }
        for arg in args {
            if arg.source.is_some() && values.contains_key(&arg.name) {
                return Err(AxnError::Invalid(format!(
                    "arg {} is sourced and cannot be overridden",
                    arg.name
                )));
            }
            let value = if let Some(source) = &arg.source {
                let scheme = source
                    .split_once("://")
                    .map(|x| x.0)
                    .ok_or_else(|| AxnError::Invalid(format!("invalid source: {source}")))?;
                let resolver = self
                    .sources
                    .get(scheme)
                    .ok_or_else(|| AxnError::MissingResolver(scheme.into()))?;
                resolver
                    .resolve(source)
                    .map_err(AxnError::Source)?
                    .map(Value::String)
                    .or_else(|| arg.default.clone())
            } else {
                values
                    .get(&arg.name)
                    .cloned()
                    .or_else(|| arg.default.clone())
            };
            let value = value.ok_or_else(|| AxnError::MissingArgument(arg.name.clone()))?;
            if arg.kind == ArgumentType::Secret && arg.default.is_some() {
                return Err(AxnError::Invalid(format!(
                    "secret arg cannot have default: {}",
                    arg.name
                )));
            }
            let rendered = render_arg(&arg.kind, &value)
                .ok_or_else(|| AxnError::InvalidArgument(arg.name.clone()))?;
            out.insert(
                arg.name.clone(),
                (rendered, arg.kind == ArgumentType::Secret),
            );
        }
        Ok(out)
    }
}
fn render_arg(kind: &ArgumentType, v: &Value) -> Option<String> {
    match kind {
        ArgumentType::Number => match v {
            Value::Number(n) => Some(n.to_string()),
            Value::String(s) if s.parse::<f64>().is_ok() => Some(s.clone()),
            _ => None,
        },
        ArgumentType::Email => v.as_str().filter(|s| valid_email(s)).map(str::to_owned),
        ArgumentType::Date => v.as_str().and_then(|date| match date {
            "today" => Some(chrono::Local::now().format("%Y-%m-%d").to_string()),
            "yesterday" => Some(
                (chrono::Local::now() - chrono::Duration::days(1))
                    .format("%Y-%m-%d")
                    .to_string(),
            ),
            value if valid_date(value) => Some(value.to_owned()),
            _ => None,
        }),
        _ => scalar_string(v),
    }
}
fn scalar_string(value: &Value) -> Option<String> {
    match value {
        Value::String(value) => Some(value.clone()),
        Value::Number(value) => Some(value.to_string()),
        Value::Bool(value) => Some(value.to_string()),
        _ => None,
    }
}
fn resolve_environment_source(source: &str) -> Result<Option<String>, String> {
    let name = source
        .strip_prefix("env://")
        .unwrap_or_default()
        .trim_matches('/');
    if name.is_empty() {
        return Err("env source requires a variable name".into());
    }
    Ok(std::env::var(name).ok())
}
fn resolve_one_password_source(source: &str) -> Result<Option<String>, String> {
    let output = std::process::Command::new("op")
        .args(["read", source])
        .output()
        .map_err(|error| format!("could not run op read: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
    }
    Ok(Some(
        String::from_utf8_lossy(&output.stdout)
            .trim_end()
            .to_owned(),
    ))
}
fn substitute_map(
    map: &Map<String, Value>,
    bindings: &HashMap<String, (String, bool)>,
    action_index: usize,
) -> Result<(Map<String, Value>, HashSet<String>), AxnError> {
    let mut out = map.clone();
    let mut tainted = HashSet::new();
    for (key, value) in map {
        if !matches!(key.as_str(), "value" | "text" | "key") && contains_reference(value) {
            return Err(AxnError::Invalid(format!(
                "parameter references are only supported in string value fields: actions[{action_index}].{key}"
            )));
        }
    }
    for key in ["value", "text", "key"] {
        if let Some(value) = out.get(key)
            && !value.is_string()
            && contains_reference(value)
        {
            return Err(AxnError::Invalid(format!(
                "parameter references are only supported in string value fields: actions[{action_index}].{key}"
            )));
        }
        if let Some(Value::String(s)) = out.get(key) {
            let (next, secret) = substitute_string(s, bindings)?;
            if secret {
                tainted.insert(key.into());
            }
            out.insert(key.into(), Value::String(next));
        }
    }
    Ok((out, tainted))
}

fn substitute_expected_facts(
    facts: &[ExpectedFact],
    bindings: &HashMap<String, (String, bool)>,
    action_index: usize,
) -> Result<Vec<ExpectedFact>, AxnError> {
    facts
        .iter()
        .map(|fact| {
            let mut value = Value::Object(fact.fields.clone());
            substitute_fact_value(&mut value, bindings, action_index, "expects", false)?;
            Ok(ExpectedFact {
                id: fact.id.clone(),
                fields: value.as_object().cloned().unwrap_or_default(),
            })
        })
        .collect()
}

fn substitute_fact_value(
    value: &mut Value,
    bindings: &HashMap<String, (String, bool)>,
    action_index: usize,
    path: &str,
    reference_field: bool,
) -> Result<(), AxnError> {
    match value {
        Value::Object(fields) => {
            for (key, child) in fields {
                substitute_fact_value(
                    child,
                    bindings,
                    action_index,
                    &format!("{path}.{key}"),
                    reference_field || matches!(key.as_str(), "value" | "text" | "key"),
                )?;
            }
        }
        Value::Array(values) => {
            for (offset, child) in values.iter_mut().enumerate() {
                substitute_fact_value(
                    child,
                    bindings,
                    action_index,
                    &format!("{path}[{offset}]"),
                    reference_field,
                )?;
            }
        }
        Value::String(template) if contains_reference(&Value::String(template.clone())) => {
            if !reference_field {
                return Err(AxnError::Invalid(format!(
                    "parameter references are only supported in string value fields: actions[{action_index}].{path}"
                )));
            }
            let (resolved, _) = substitute_string(template, bindings)?;
            *value = Value::String(resolved);
        }
        _ => {}
    }
    Ok(())
}

fn redact_error(error: String, secrets: &[String]) -> String {
    if secrets
        .iter()
        .any(|secret| !secret.is_empty() && error.contains(secret))
    {
        "<redacted: contains-secret>".into()
    } else {
        error
    }
}

fn semantically_verified_result(tool: &str, mut result: Value) -> Value {
    let Some(action) = result.get_mut("action").and_then(Value::as_object_mut) else {
        return result;
    };
    action.insert("success".into(), Value::Bool(true));
    action.insert("semanticSuccess".into(), Value::Bool(true));
    action.insert("semanticStatus".into(), Value::String("verified".into()));
    let mut chars = tool.chars();
    let method = chars
        .next()
        .map(|first| first.to_uppercase().collect::<String>() + chars.as_str())
        .unwrap_or_default();
    action.insert(
        "message".into(),
        Value::String(format!(
            "{method} semantic outcome verified by postcondition"
        )),
    );
    action.insert("refusal".into(), Value::Null);
    result
}

fn document_flag(doc: &AxnDocument, key: &str) -> bool {
    doc.flags.get(key).and_then(Value::as_bool).unwrap_or(false)
}
