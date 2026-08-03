use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct JsonRpcVersion;
impl Serialize for JsonRpcVersion {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> { serializer.serialize_str("2.0") }
}
impl<'de> Deserialize<'de> for JsonRpcVersion {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        if value == "2.0" { Ok(Self) } else { Err(serde::de::Error::custom("jsonrpc must be 2.0")) }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum JsonRpcId { String(String), Integer(i64), Null }

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: JsonRpcVersion,
    pub id: Option<JsonRpcId>,
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}
impl JsonRpcRequest {
    pub fn new(id: Option<JsonRpcId>, method: impl Into<String>, params: Option<Value>) -> Self {
        Self { jsonrpc: JsonRpcVersion, id, method: method.into(), params }
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
#[serde(deny_unknown_fields)]
pub struct JsonRpcSuccess { pub jsonrpc: JsonRpcVersion, pub id: JsonRpcId, pub result: Value }
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JsonRpcFailure { pub jsonrpc: JsonRpcVersion, pub id: JsonRpcId, pub error: JsonRpcError }
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum JsonRpcResponse { Success(JsonRpcSuccess), Failure(JsonRpcFailure) }
impl JsonRpcResponse {
    pub fn success(id: JsonRpcId, result: Value) -> Self {
        Self::Success(JsonRpcSuccess { jsonrpc: JsonRpcVersion, id, result })
    }
    pub fn failure(id: JsonRpcId, error: JsonRpcError) -> Self {
        Self::Failure(JsonRpcFailure { jsonrpc: JsonRpcVersion, id, error })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RunEnvelope<T> { pub batch: T }
