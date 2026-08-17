use crate::{ActionObservation, AxnAction, AxnCodec, AxnDocument, AxnError, JsonRpcRequest, JsonRpcResponse};
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub const DEFAULT_HISTORY_SESSION: &str = "default";
pub const DEFAULT_MAX_RECORDS_PER_SESSION: usize = 2_000;

#[derive(Clone, Debug, PartialEq)]
pub struct ActionHistoryRecord {
    pub id: String,
    pub parent_id: Option<String>,
    pub session_id: String,
    pub method: String,
    pub params: Map<String, Value>,
    pub success: bool,
    pub result: Option<Value>,
    pub error: Option<String>,
    pub observation: Option<ActionObservation>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ActionHistoryContext {
    pub session_id: String,
    pub request: JsonRpcRequest,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActionHistoryExport {
    pub script: String,
    pub action_count: usize,
    pub record_count: usize,
}

#[derive(Debug, thiserror::Error)]
pub enum ActionHistoryError {
    #[error("Unknown history range boundary: {label} {id}")]
    UnknownRangeBoundary { label: &'static str, id: String },
    #[error("History range starts after it ends: from {from} to {to}")]
    ReversedRange { from: String, to: String },
    #[error(transparent)]
    Codec(#[from] AxnError),
    #[error("could not write history export to {path}: {source}")]
    Write {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

#[derive(Default)]
struct StoreState {
    next_id: u64,
    records_by_session: HashMap<String, Vec<ActionHistoryRecord>>,
    last_record_id_by_session: HashMap<String, String>,
}

pub struct ActionHistoryStore {
    state: Mutex<StoreState>,
    max_records_per_session: usize,
}

impl Default for ActionHistoryStore {
    fn default() -> Self {
        Self::new(DEFAULT_MAX_RECORDS_PER_SESSION)
    }
}

impl ActionHistoryStore {
    pub fn new(max_records_per_session: usize) -> Self {
        Self {
            state: Mutex::new(StoreState {
                next_id: 1,
                ..StoreState::default()
            }),
            max_records_per_session,
        }
    }

    /// Extracts `_session` for routing and removes it from the request that may be persisted.
    pub fn context(&self, request: &JsonRpcRequest) -> ActionHistoryContext {
        let mut request = request.clone();
        let session_id = request
            .params
            .as_ref()
            .and_then(Value::as_object)
            .and_then(|params| params.get("_session"))
            .and_then(Value::as_str)
            .filter(|session| !session.is_empty())
            .unwrap_or(DEFAULT_HISTORY_SESSION)
            .to_owned();
        if let Some(params) = request.params.as_mut().and_then(Value::as_object_mut) {
            params.remove("_session");
        }
        ActionHistoryContext { session_id, request }
    }

    /// Persists a request after the caller's shared observation boundary has sanitized it.
    pub fn record(
        &self,
        request: &JsonRpcRequest,
        response: &JsonRpcResponse,
        session_id: &str,
        observation: Option<ActionObservation>,
    ) -> Option<ActionHistoryRecord> {
        if !should_record(&request.method) {
            return None;
        }
        let mut params = request
            .params
            .as_ref()
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        params.remove("_session");
        if request.method == "run" {
            params.remove("actions");
            params.remove("args");
            params.remove("argValues");
        }
        let (success, result, error) = match response {
            JsonRpcResponse::Success(response) => (true, Some(response.result.clone()), None),
            JsonRpcResponse::Failure(response) => (false, None, Some(response.error.message.clone())),
        };

        let mut state = self.state.lock().expect("action history mutex poisoned");
        let id = format!("c{}", state.next_id);
        state.next_id += 1;
        let parent_id = state.last_record_id_by_session.get(session_id).cloned();
        let record = ActionHistoryRecord {
            id: id.clone(),
            parent_id,
            session_id: session_id.to_owned(),
            method: request.method.clone(),
            params,
            success,
            result,
            error,
            observation,
        };
        let records = state.records_by_session.entry(session_id.to_owned()).or_default();
        records.push(record.clone());
        if records.len() > self.max_records_per_session {
            records.drain(..records.len() - self.max_records_per_session);
        }
        state.last_record_id_by_session.insert(session_id.to_owned(), id);
        Some(record)
    }

    pub fn records(&self, session_id: &str) -> Vec<ActionHistoryRecord> {
        self.state
            .lock()
            .expect("action history mutex poisoned")
            .records_by_session
            .get(session_id)
            .cloned()
            .unwrap_or_default()
    }

    pub fn export_script(
        &self,
        session_id: &str,
        include_reads: bool,
        from: Option<&str>,
        to: Option<&str>,
        path: Option<&Path>,
    ) -> Result<ActionHistoryExport, ActionHistoryError> {
        let records = self.sliced_records(session_id, from, to)?;
        let actions = records
            .iter()
            .filter_map(|record| history_action(record, include_reads))
            .enumerate()
            .map(|(index, mut action)| {
                action.id = Some(format!("a{:03}", index + 1));
                action
            })
            .collect::<Vec<_>>();
        let document = AxnDocument {
            version: 2,
            arguments: Vec::new(),
            actions,
            flags: Map::new(),
        };
        let script = AxnCodec::to_yaml(&document)?;
        if let Some(path) = path {
            atomic_write(path, script.as_bytes())?;
        }
        Ok(ActionHistoryExport {
            action_count: document.actions.len(),
            record_count: records.len(),
            script,
        })
    }

    fn sliced_records(
        &self,
        session_id: &str,
        from: Option<&str>,
        to: Option<&str>,
    ) -> Result<Vec<ActionHistoryRecord>, ActionHistoryError> {
        let records = self.records(session_id);
        let boundary = |label, id: &str| {
            records.iter().position(|record| record.id == id).ok_or_else(||
                ActionHistoryError::UnknownRangeBoundary {
                    label,
                    id: id.to_owned(),
                },
            )
        };
        let start = from.map(|id| boundary("from", id)).transpose()?.unwrap_or(0);
        let end = to
            .map(|id| boundary("to", id))
            .transpose()?
            .unwrap_or_else(|| records.len().saturating_sub(1));
        if records.is_empty() {
            return Ok(Vec::new());
        }
        if start > end {
            return Err(ActionHistoryError::ReversedRange {
                from: from.unwrap_or(&records[start].id).to_owned(),
                to: to.unwrap_or(&records[end].id).to_owned(),
            });
        }
        Ok(records[start..=end].to_vec())
    }
}

fn should_record(method: &str) -> bool {
    matches!(method, "look" | "find" | "click" | "scroll" | "drag" | "invoke" | "type" | "keyboard" | "run")
}

fn history_action(record: &ActionHistoryRecord, include_reads: bool) -> Option<AxnAction> {
    let tool = match record.method.as_str() {
        "look" | "find" if include_reads => record.method.clone(),
        "click" | "scroll" | "drag" | "invoke" | "type" | "keyboard" => record.method.clone(),
        _ => return None,
    };
    let mut params = record.params.clone();
    params.remove("tool");
    Some(AxnAction {
        id: None,
        tool,
        requires: Vec::new(),
        expects: Vec::new(),
        params,
    })
}

fn atomic_write(path: &Path, contents: &[u8]) -> Result<(), ActionHistoryError> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let file_name = path.file_name().and_then(|name| name.to_str()).unwrap_or("history.axn");
    let temporary = parent.join(format!(".{file_name}.{}.tmp", std::process::id()));
    let result = (|| -> std::io::Result<()> {
        let mut file = fs::File::create(&temporary)?;
        file.write_all(contents)?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map_err(|source| ActionHistoryError::Write {
        path: path.to_owned(),
        source,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{JsonRpcId, JsonRpcSuccess, JsonRpcVersion};
    use serde_json::json;

    fn request(method: &str, params: Value) -> JsonRpcRequest {
        JsonRpcRequest::new(Some(JsonRpcId::Integer(1)), method, Some(params))
    }

    fn success() -> JsonRpcResponse {
        JsonRpcResponse::Success(JsonRpcSuccess {
            jsonrpc: JsonRpcVersion,
            id: JsonRpcId::Integer(1),
            result: json!({"ok": true}),
        })
    }

    #[test]
    fn context_extracts_session_without_persisting_it() {
        let store = ActionHistoryStore::default();
        let context = store.context(&request("click", json!({"_session": "editor", "target": "button"})));
        assert_eq!(context.session_id, "editor");
        assert_eq!(context.request.params, Some(json!({"target": "button"})));

        let fallback = store.context(&request("click", json!({"_session": ""})));
        assert_eq!(fallback.session_id, DEFAULT_HISTORY_SESSION);
    }

    #[test]
    fn records_are_monotonic_parent_linked_session_scoped_and_bounded() {
        let store = ActionHistoryStore::new(2);
        let first = store.record(&request("click", json!({})), &success(), "a", None).unwrap();
        let other = store.record(&request("click", json!({})), &success(), "b", None).unwrap();
        let second = store.record(&request("type", json!({"text": "hi"})), &success(), "a", None).unwrap();
        let third = store.record(&request("keyboard", json!({"key": "enter"})), &success(), "a", None).unwrap();

        assert_eq!((first.id.as_str(), other.id.as_str(), second.id.as_str(), third.id.as_str()), ("c1", "c2", "c3", "c4"));
        assert_eq!(second.parent_id.as_deref(), Some("c1"));
        assert_eq!(third.parent_id.as_deref(), Some("c3"));
        assert_eq!(store.records("a").iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), vec!["c3", "c4"]);
        assert_eq!(store.records("b").len(), 1);
    }

    #[test]
    fn excludes_control_methods_and_strips_run_payloads() {
        let store = ActionHistoryStore::default();
        assert!(store.record(&request("health", json!({})), &success(), "s", None).is_none());
        assert!(store.record(&request("save", json!({})), &success(), "s", None).is_none());
        let record = store.record(
            &request("run", json!({"actions": [1], "args": [2], "argValues": {"x": 3}, "dryRun": true})),
            &success(),
            "s",
            None,
        ).unwrap();
        assert_eq!(record.params, json!({"dryRun": true}).as_object().unwrap().clone());
    }

    #[test]
    fn export_filters_reads_counts_the_inclusive_range_and_round_trips() {
        let store = ActionHistoryStore::default();
        let look = store.record(&request("look", json!({"app": "Notes"})), &success(), "s", None).unwrap();
        let click = store.record(&request("click", json!({"target": {"app": "Notes", "name": "New"}})), &success(), "s", None).unwrap();
        let find = store.record(&request("find", json!({"query": "Done"})), &success(), "s", None).unwrap();

        let actions_only = store.export_script("s", false, Some(&look.id), Some(&find.id), None).unwrap();
        assert_eq!((actions_only.action_count, actions_only.record_count), (1, 3));
        let document = AxnCodec::parse(&actions_only.script).unwrap();
        assert_eq!(document.actions[0].id.as_deref(), Some("a001"));
        assert_eq!(document.actions[0].tool, "click");

        let including_reads = store.export_script("s", true, Some(&look.id), Some(&click.id), None).unwrap();
        assert_eq!((including_reads.action_count, including_reads.record_count), (2, 2));
        assert_eq!(AxnCodec::parse(&including_reads.script).unwrap().version, 2);
    }

    #[test]
    fn range_errors_are_typed() {
        let store = ActionHistoryStore::default();
        let first = store.record(&request("click", json!({})), &success(), "s", None).unwrap();
        let second = store.record(&request("type", json!({})), &success(), "s", None).unwrap();
        assert!(matches!(
            store.export_script("s", false, Some("missing"), None, None),
            Err(ActionHistoryError::UnknownRangeBoundary { label: "from", .. })
        ));
        assert!(matches!(
            store.export_script("s", false, Some(&second.id), Some(&first.id), None),
            Err(ActionHistoryError::ReversedRange { .. })
        ));
    }

    #[test]
    fn optional_path_receives_the_same_valid_script() {
        let store = ActionHistoryStore::default();
        store.record(&request("click", json!({})), &success(), "s", None);
        let path = std::env::temp_dir().join(format!("axon-history-{}-{}.axn", std::process::id(), std::thread::current().name().unwrap_or("test")));
        let export = store.export_script("s", false, None, None, Some(&path)).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), export.script);
        assert_eq!(AxnCodec::parse(&export.script).unwrap().actions.len(), 1);
        fs::remove_file(path).unwrap();
    }
}
