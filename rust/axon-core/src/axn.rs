use crate::Resolution;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AxnDocument {
    pub version: u32,
    #[serde(default, rename = "args")]
    pub arguments: Vec<AxnArgument>,
    #[serde(default)]
    pub actions: Vec<AxnAction>,
    #[serde(flatten)]
    pub flags: Map<String, Value>,
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
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ArgumentType {
    String,
    Email,
    Number,
    Path,
    Secret,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AxnAction {
    #[serde(default)]
    pub id: Option<String>,
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
        if doc.version != 1 {
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
    #[serde(default)]
    pub result: Value,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub resolution: Option<Resolution>,
}
pub trait ToolDispatcher {
    fn dispatch(&mut self, tool: &str, params: &Map<String, Value>) -> DispatchOutcome;
    fn verify(&mut self, fact: &ExpectedFact) -> Result<(), String>;
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
    pub resolution: Option<Resolution>,
}

pub struct AxnRunner<'a, D: ToolDispatcher> {
    dispatcher: &'a mut D,
    sources: HashMap<String, Box<dyn ArgumentSourceResolver + 'a>>,
}
impl<'a, D: ToolDispatcher> AxnRunner<'a, D> {
    pub fn new(dispatcher: &'a mut D) -> Self {
        Self {
            dispatcher,
            sources: HashMap::new(),
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
    pub fn run(
        &mut self,
        doc: &AxnDocument,
        arg_values: &Map<String, Value>,
        options: RunOptions,
    ) -> Result<RunResult, AxnError> {
        let bindings = self.bind(&doc.arguments, arg_values)?;
        let dry_run = options
            .dry_run
            .unwrap_or_else(|| document_flag(doc, "dryRun"));
        let continue_on_error = options
            .continue_on_error
            .unwrap_or_else(|| document_flag(doc, "continueOnError"));
        let mut trace = Vec::new();
        let mut facts = HashSet::new();
        let mut success = true;
        for (index, action) in doc.actions.iter().enumerate() {
            if let Some(missing) = action.requires.iter().find(|id| !facts.contains(*id)) {
                let e = format!("required fact is unavailable: {missing}");
                trace.push(TraceEntry {
                    index,
                    tool: action.tool.clone(),
                    success: false,
                    action_id: action.id.clone(),
                    result: None,
                    error: Some(e),
                    resolution: None,
                });
                success = false;
                if !continue_on_error {
                    break;
                } else {
                    continue;
                }
            }
            let (params, secret_fields) = substitute_map(&action.params, &bindings)?;
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
                    result: Value::Object(shown),
                    error: None,
                    resolution: None,
                }
            } else {
                self.dispatcher.dispatch(&action.tool, &params)
            };
            let redacted = if secret_fields.is_empty() {
                outcome.result
            } else {
                Value::String("<redacted: contains-secret>".into())
            };
            let verification_error = if outcome.success && !dry_run {
                action
                    .expects
                    .iter()
                    .find_map(|fact| self.dispatcher.verify(fact).err())
            } else {
                None
            };
            let action_success = outcome.success && verification_error.is_none();
            let entry = TraceEntry {
                index,
                tool: action.tool.clone(),
                success: action_success,
                action_id: action.id.clone(),
                result: (!redacted.is_null()).then_some(redacted),
                error: verification_error.or(outcome
                    .error
                    .map(|e| {
                        if secret_fields.is_empty() {
                            e
                        } else {
                            "<redacted: contains-secret>".into()
                        }
                    })
                    .or_else(|| (!outcome.success).then(|| "action failed".into()))),
                resolution: outcome.resolution,
            };
            if entry.success && !dry_run {
                facts.extend(action.expects.iter().map(|f| f.id.clone()))
            } else {
                success = false
            }
            let failed = !entry.success;
            trace.push(entry);
            if failed && !continue_on_error {
                break;
            }
        }
        Ok(RunResult {
            success,
            dry_run: dry_run,
            continue_on_error: continue_on_error,
            trace,
        })
    }
    fn bind(
        &self,
        args: &[AxnArgument],
        values: &Map<String, Value>,
    ) -> Result<HashMap<String, (String, bool)>, AxnError> {
        let mut out = HashMap::new();
        for arg in args {
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
        ArgumentType::Number => v.as_f64().map(|n| {
            if n.fract() == 0.0 {
                format!("{}", n as i64)
            } else {
                n.to_string()
            }
        }),
        ArgumentType::Email => v.as_str().filter(|s| s.contains('@')).map(str::to_owned),
        _ => v.as_str().map(str::to_owned),
    }
}
fn substitute_map(
    map: &Map<String, Value>,
    bindings: &HashMap<String, (String, bool)>,
) -> Result<(Map<String, Value>, HashSet<String>), AxnError> {
    let mut out = map.clone();
    let mut tainted = HashSet::new();
    for key in ["value", "text", "key"] {
        if let Some(Value::String(s)) = out.get(key) {
            let mut next = s.clone();
            for (name, (value, secret)) in bindings {
                let token = format!("{{{{{name}}}}}");
                if next.contains(&token) && *secret {
                    tainted.insert(key.into());
                }
                next = next.replace(&token, value)
            }
            out.insert(key.into(), Value::String(next));
        }
    }
    Ok((out, tainted))
}

fn document_flag(doc: &AxnDocument, key: &str) -> bool {
    doc.flags.get(key).and_then(Value::as_bool).unwrap_or(false)
}
