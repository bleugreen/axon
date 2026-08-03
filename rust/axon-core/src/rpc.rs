use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum JsonRpcId { String(String), Integer(i64), Null }

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub id: Option<JsonRpcId>,
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}
impl JsonRpcRequest {
    pub fn new(id: Option<JsonRpcId>, method: impl Into<String>, params: Option<Value>) -> Self {
        Self { jsonrpc: "2.0".into(), id, method: method.into(), params }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum JsonRpcResponse {
    Success { jsonrpc: String, id: JsonRpcId, result: Value },
    Failure { jsonrpc: String, id: JsonRpcId, error: JsonRpcError },
}
impl JsonRpcResponse {
    pub fn success(id: JsonRpcId, result: Value) -> Self {
        Self::Success { jsonrpc: "2.0".into(), id, result }
    }
    pub fn failure(id: JsonRpcId, error: JsonRpcError) -> Self {
        Self::Failure { jsonrpc: "2.0".into(), id, error }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RunEnvelope<T> { pub batch: T }
