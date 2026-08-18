//! Shared daemon ownership for recording lifecycle routes.
//!
//! Transports and platform routers are adapters. This module owns the stable recording state and
//! strict socket schemas so macOS, Windows, and Linux cannot drift into three lifecycle contracts.

use crate::{
    AxnArgument, AxnCodec, AxnDocument, JsonRpcError, RecordedUserEventGroup, RecordingScope,
    RedactionMarkerTaint, UserRecordingTranslator,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};

/// Process-local state shared by every native platform router.
#[derive(Default)]
pub struct NativeDaemonState {
    pub history: crate::ActionHistoryStore,
    pub recording: DaemonRecordingOwner,
}

impl NativeDaemonState {
    pub fn dispatch(
        &mut self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Option<Result<Value, JsonRpcError>> {
        Some(match method {
            "save" => self.history.save(params),
            "recording.start" => self.recording.start(params).and_then(value),
            "recording.status" => {
                if params.is_empty() {
                    serde_json::to_value(self.recording.status()).map_err(internal)
                } else {
                    Err(invalid("params", "recording.status accepts no fields"))
                }
            }
            "recording.stop" => self.recording.stop(params),
            "editor.recordFromHere" => self.recording.record_from_here(params).and_then(value),
            _ => return None,
        })
    }

}

fn value<T: serde::Serialize>(value: T) -> Result<Value, JsonRpcError> {
    serde_json::to_value(value).map_err(internal)
}

fn internal(error: serde_json::Error) -> JsonRpcError {
    JsonRpcError {
        code: -32603,
        message: "response serialization failed".into(),
        data: Some(json!({"reason":error.to_string()})),
    }
}

const INVALID_PARAMS: i64 = -32602;
const RECORDING_CONFLICT: i64 = -32005;

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecordingStartParams {
    pub scope: RecordingScope,
    #[serde(default)]
    pub destination: Option<RecordingDestination>,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecordFromHereParams {
    pub document_id: String,
    #[serde(default)]
    pub before_block_id: Option<String>,
    #[serde(default)]
    pub scope: Option<RecordingScope>,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecordingDestination {
    pub document_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub before_block_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingStatus {
    pub recording: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scope: Option<RecordingScope>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destination: Option<RecordingDestination>,
}

#[derive(Clone, Debug)]
struct ActiveRecording {
    session_id: String,
    scope: RecordingScope,
    destination: Option<RecordingDestination>,
    groups: Vec<RecordedUserEventGroup>,
    arguments: Vec<AxnArgument>,
}

/// The one recording session owned by a daemon process.
#[derive(Debug, Default)]
pub struct DaemonRecordingOwner {
    next_session: u64,
    active: Option<ActiveRecording>,
}

impl DaemonRecordingOwner {
    pub fn start(&mut self, params: &Map<String, Value>) -> Result<RecordingStatus, JsonRpcError> {
        let params: RecordingStartParams = strict_params(params)?;
        self.start_validated(params.scope, params.destination)
    }

    pub fn record_from_here(
        &mut self,
        params: &Map<String, Value>,
    ) -> Result<RecordingStatus, JsonRpcError> {
        let params: RecordFromHereParams = strict_params(params)?;
        if params.document_id.trim().is_empty() {
            return Err(invalid("params.documentId", "must not be empty"));
        }
        self.start_validated(
            params.scope.unwrap_or(RecordingScope::AllApplications),
            Some(RecordingDestination {
                document_id: params.document_id,
                before_block_id: params.before_block_id,
            }),
        )
    }

    fn start_validated(
        &mut self,
        scope: RecordingScope,
        destination: Option<RecordingDestination>,
    ) -> Result<RecordingStatus, JsonRpcError> {
        if self.active.is_some() {
            return Err(JsonRpcError {
                code: RECORDING_CONFLICT,
                message: "a recording session is already active".into(),
                data: Some(json!({"reason":"recording-active"})),
            });
        }
        if let RecordingScope::Application { app } = &scope
            && app.name.trim().is_empty()
            && app
                .bundle_identifier
                .as_deref()
                .is_none_or(|value| value.trim().is_empty())
        {
            return Err(invalid(
                "params.scope.app",
                "must identify an application by name or identifier",
            ));
        }
        if let Some(destination) = &destination
            && destination.document_id.trim().is_empty()
        {
            return Err(invalid("params.destination.documentId", "must not be empty"));
        }
        self.next_session += 1;
        self.active = Some(ActiveRecording {
            session_id: format!("recording-{:04}", self.next_session),
            scope,
            destination,
            groups: Vec::new(),
            arguments: Vec::new(),
        });
        Ok(self.status())
    }

    pub fn status(&self) -> RecordingStatus {
        let Some(active) = &self.active else {
            return RecordingStatus {
                recording: false,
                session_id: None,
                scope: None,
                destination: None,
            };
        };
        RecordingStatus {
            recording: true,
            session_id: Some(active.session_id.clone()),
            scope: Some(active.scope.clone()),
            destination: active.destination.clone(),
        }
    }

    pub fn push_group(&mut self, group: RecordedUserEventGroup) -> Result<(), JsonRpcError> {
        self.active
            .as_mut()
            .ok_or_else(recording_inactive)?
            .groups
            .push(group);
        Ok(())
    }

    pub fn stop(&mut self, params: &Map<String, Value>) -> Result<Value, JsonRpcError> {
        if !params.is_empty() {
            return Err(invalid("params", "recording.stop accepts no fields"));
        }
        let active = self.active.take().ok_or_else(recording_inactive)?;
        let document = UserRecordingTranslator::new()
            .axn_document(&active.groups, active.arguments, &RedactionMarkerTaint)
            .map_err(|error| JsonRpcError {
                code: -32603,
                message: "recording could not be authored".into(),
                data: Some(json!({"reason":error.to_string()})),
            })?;
        recording_result(active.session_id, active.destination, document)
    }

    /// Clears daemon-owned state after disconnect or shutdown. Native observer cleanup belongs to
    /// the caller that owns the backend hook and must happen before this method is called.
    pub fn abandon(&mut self) {
        self.active = None;
    }
}

fn strict_params<T: for<'de> Deserialize<'de>>(params: &Map<String, Value>) -> Result<T, JsonRpcError> {
    serde_json::from_value(Value::Object(params.clone()))
        .map_err(|error| invalid("params", &error.to_string()))
}

fn recording_result(
    session_id: String,
    destination: Option<RecordingDestination>,
    document: AxnDocument,
) -> Result<Value, JsonRpcError> {
    let action_count = document.actions.len();
    let script = AxnCodec::to_yaml(&document).map_err(|error| JsonRpcError {
        code: -32603,
        message: "recording could not be serialized".into(),
        data: Some(json!({"reason":error.to_string()})),
    })?;
    Ok(json!({
        "sessionId": session_id,
        "destination": destination,
        "script": script,
        "actionCount": action_count,
    }))
}

fn invalid(path: &str, reason: &str) -> JsonRpcError {
    JsonRpcError {
        code: INVALID_PARAMS,
        message: format!("Invalid params: {path} {reason}"),
        data: Some(json!({"path":path,"reason":reason})),
    }
}

fn recording_inactive() -> JsonRpcError {
    JsonRpcError {
        code: RECORDING_CONFLICT,
        message: "no recording session is active".into(),
        data: Some(json!({"reason":"recording-inactive"})),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::RecordedUserAction;

    fn object(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn lifecycle_has_strict_schemas_and_stable_state() {
        let mut owner = DaemonRecordingOwner::default();
        assert!(!owner.status().recording);
        let status = owner
            .start(&object(json!({"scope":{"scope":"allApplications"}})))
            .unwrap();
        assert_eq!(status.session_id.as_deref(), Some("recording-0001"));
        assert_eq!(owner.start(&object(json!({"scope":{"scope":"allApplications"}}))).unwrap_err().data, Some(json!({"reason":"recording-active"})));
        owner.push_group(RecordedUserEventGroup::new(RecordedUserAction::TypeText { app: "Notes".into(), text: "hello".into() })).unwrap();
        let stopped = owner.stop(&Map::new()).unwrap();
        assert_eq!(stopped["actionCount"], 1);
        assert!(stopped["script"].as_str().unwrap().contains("hello"));
        assert!(!owner.status().recording);
    }

    #[test]
    fn unknown_fields_and_nonempty_editor_identity_are_rejected() {
        let mut owner = DaemonRecordingOwner::default();
        assert_eq!(owner.start(&object(json!({"scope":{"scope":"allApplications"},"extra":true}))).unwrap_err().code, INVALID_PARAMS);
        assert_eq!(owner.record_from_here(&object(json!({"documentId":""}))).unwrap_err().code, INVALID_PARAMS);
        assert_eq!(owner.stop(&object(json!({"extra":true}))).unwrap_err().code, INVALID_PARAMS);
    }

    #[test]
    fn editor_destination_is_metadata_not_script_content() {
        let mut owner = DaemonRecordingOwner::default();
        let status = owner.record_from_here(&object(json!({"documentId":"doc-1","beforeBlockId":"block-2"}))).unwrap();
        assert_eq!(status.destination.unwrap().document_id, "doc-1");
        let result = owner.stop(&Map::new()).unwrap();
        assert_eq!(result["destination"]["beforeBlockId"], "block-2");
        assert!(!result["script"].as_str().unwrap().contains("doc-1"));
    }

    #[test]
    fn native_adapter_routes_save_and_recording_with_strict_shared_schemas() {
        let mut state = NativeDaemonState::default();
        let unknown = state.dispatch("save", &object(json!({"extra":true}))).unwrap().unwrap_err();
        assert_eq!(unknown.code, INVALID_PARAMS);

        let started = state.dispatch("recording.start", &object(json!({"scope":{"scope":"allApplications"}}))).unwrap().unwrap();
        assert_eq!(started["recording"], true);
        let status = state.dispatch("recording.status", &Map::new()).unwrap().unwrap();
        assert_eq!(status["sessionId"], "recording-0001");
        assert!(state.dispatch("recording.status", &object(json!({"extra":true}))).unwrap().is_err());
        assert_eq!(state.dispatch("recording.stop", &Map::new()).unwrap().unwrap()["actionCount"], 0);
    }
}