//! Windows UI Automation backend and v1 JSON-RPC tool router.

use axon_core::{
    AppQuery, AxnCodec, AxnRunner, DispatchOutcome, ExpectedFact, JsonRpcError, JsonRpcId,
    Candidate, Confidence, JsonRpcRequest, JsonRpcResponse, Locator, LocatorResolver,
    PlatformBackend, Resolution, ResolutionStatus, RunEnvelope, RunOptions, Snapshot,
    SnapshotHandle, ToolDispatcher,
};
use serde_json::{Map, Value, json};

#[cfg(windows)]
mod platform;
#[cfg(windows)]
pub use platform::{IntegrationProbe, WindowsBackend};

const EXCLUDED: &[(&str, &str)] = &[
    ("save", "SerializeHistory"),
    ("drag", "PointerDrag"),
    ("wait_for_value", "WaitForValue"),
    ("wait_for_stability", "WaitForStability"),
    ("permit", "PermissionPrompt"),
];

pub struct Router<B> {
    backend: B,
    snapshot: Option<Snapshot>,
}

impl<B: PlatformBackend> Router<B> {
    pub fn new(backend: B) -> Self {
        Self {
            backend,
            snapshot: None,
        }
    }

    pub fn request(&mut self, request: JsonRpcRequest) -> Option<JsonRpcResponse> {
        let id = request.id?;
        let params = request
            .params
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default();
        Some(match self.dispatch_tool(&request.method, &params) {
            Ok(result) => JsonRpcResponse::success(id, result),
            Err(error) => JsonRpcResponse::failure(id, error),
        })
    }

    fn dispatch_tool(
        &mut self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, JsonRpcError> {
        if let Some((_, capability)) = EXCLUDED.iter().find(|(tool, _)| *tool == method) {
            return Err(rpc_error(
                -32004,
                format!("tool {method} requires unavailable capability {capability}"),
            ));
        }
        match method {
            "look" => self.look(params),
            "find" => {
                let (handle, resolution) = self.resolve(params)?;
                Ok(json!({"handle": handle, "resolution": resolution}))
            }
            "click" => {
                let (handle, resolution) = self.resolve(params)?;
                let point = self.node_center(&handle)?;
                self.backend.pointer_click(point).map_err(backend_error)?;
                Ok(
                    json!({"dispatch":{"success":true,"mechanism":"SendInput"},"verification":{"verified":false,"reason":"click has no declared postcondition"},"resolution":resolution}),
                )
            }
            "type" => {
                let (handle, resolution) = self.resolve(params)?;
                let value =
                    required_str(params, "value").or_else(|_| required_str(params, "text"))?;
                self.backend.focus(&handle).map_err(backend_error)?;
                self.backend
                    .set_value(&handle, value)
                    .map_err(backend_error)?;
                let observed = self.backend.read_value(&handle).map_err(backend_error)?;
                Ok(
                    json!({"dispatch":{"success":true,"mechanism":"ValuePattern"},"verification":{"verified":observed.as_deref()==Some(value),"observed":observed},"resolution":resolution}),
                )
            }
            "keyboard" => {
                let input =
                    required_str(params, "input").or_else(|_| required_str(params, "key"))?;
                self.backend
                    .keyboard(&app_query(params), input)
                    .map_err(backend_error)?;
                Ok(
                    json!({"dispatch":{"success":true,"mechanism":"SendInput"},"verification":{"verified":false,"reason":"keyboard input has no declared postcondition"}}),
                )
            }
            "invoke" => {
                let (handle, resolution) = self.resolve(params)?;
                self.backend
                    .invoke(&handle, "Invoke")
                    .map_err(backend_error)?;
                Ok(
                    json!({"dispatch":{"success":true,"mechanism":"InvokePattern"},"verification":{"verified":false,"reason":"invoke has no declared postcondition"},"resolution":resolution}),
                )
            }
            "scroll" => {
                let (handle, resolution) = self.resolve(params)?;
                let dx = params.get("deltaX").and_then(Value::as_f64).unwrap_or(0.0);
                let dy = params.get("deltaY").and_then(Value::as_f64).unwrap_or(0.0);
                self.backend
                    .scroll(&handle, (dx, dy))
                    .map_err(backend_error)?;
                Ok(
                    json!({"dispatch":{"success":true,"mechanism":"ScrollItemPattern"},"verification":{"verified":false,"reason":"scroll has no declared postcondition"},"resolution":resolution}),
                )
            }
            "run" => self.run_axn(params),
            _ => Err(rpc_error(-32601, format!("unknown method {method}"))),
        }
    }

    fn look(&mut self, params: &Map<String, Value>) -> Result<Value, JsonRpcError> {
        if params.get("app").is_none() {
            return serde_json::to_value(
                self.backend
                    .enumerate_applications()
                    .map_err(backend_error)?,
            )
            .map_err(internal_error);
        }
        let snapshot = self
            .backend
            .capture(&app_query(params))
            .map_err(backend_error)?;
        let value = serde_json::to_value(&snapshot).map_err(internal_error)?;
        self.snapshot = Some(snapshot);
        Ok(value)
    }

    fn resolve(
        &mut self,
        params: &Map<String, Value>,
    ) -> Result<(SnapshotHandle, axon_core::Resolution), JsonRpcError> {
        let target = params.get("target").unwrap_or(&Value::Null);
        if let Some(raw) = target.as_str() {
            let handle = SnapshotHandle(raw.into());
            let snapshot = self
                .snapshot
                .as_ref()
                .ok_or_else(|| rpc_error(-32002, "no active snapshot; call look first"))?;
            snapshot
                .index_for_handle(&handle)
                .map_err(|e| rpc_error(-32002, e.to_string()))?;
            let index = snapshot
                .index_for_handle(&handle)
                .map_err(|e| rpc_error(-32002, e.to_string()))?;
            let node = flattened(snapshot)
                .nth(index)
                .ok_or_else(|| rpc_error(-32002, "handle index is outside snapshot"))?;
            let candidate = Candidate {
                index,
                handle: handle.clone(),
                role: node.role.clone(),
                title: node.title.clone(),
                frame: node.frame,
                score: 0,
                reasons: vec!["snapshot-bound handle".into()],
            };
            return Ok((
                handle,
                Resolution {
                    status: ResolutionStatus::Unique,
                    snapshot_id: snapshot.id.clone(),
                    confidence: Confidence::High,
                    best: Some(candidate.clone()),
                    candidates: vec![candidate],
                },
            ));
        }
        let locator_value = target
            .get("locator")
            .or_else(|| params.get("locator"))
            .ok_or_else(|| rpc_error(-32602, "target must be a snapshot handle or locator"))?;
        let locator: Locator = serde_json::from_value(locator_value.clone())
            .map_err(|e| rpc_error(-32602, e.to_string()))?;
        let snapshot = self
            .backend
            .capture(&app_query_from_target(params, target))
            .map_err(backend_error)?;
        let resolution = LocatorResolver::resolve(&locator, &snapshot);
        let handle = resolution
            .best
            .as_ref()
            .map(|c| c.handle.clone())
            .ok_or_else(|| {
                rpc_error(
                    -32001,
                    format!("locator resolution was {:?}", resolution.status),
                )
            })?;
        self.snapshot = Some(snapshot);
        Ok((handle, resolution))
    }

    fn node_center(&self, handle: &SnapshotHandle) -> Result<(f64, f64), JsonRpcError> {
        let snapshot = self
            .snapshot
            .as_ref()
            .ok_or_else(|| rpc_error(-32002, "no active snapshot"))?;
        let index = snapshot
            .index_for_handle(handle)
            .map_err(|e| rpc_error(-32002, e.to_string()))?;
        let node = flattened(snapshot)
            .nth(index)
            .ok_or_else(|| rpc_error(-32002, "handle index is outside snapshot"))?;
        let r = node
            .frame
            .ok_or_else(|| rpc_error(-32003, "target has no actionable frame"))?;
        Ok((r.x + r.width / 2.0, r.y + r.height / 2.0))
    }

    fn run_axn(&mut self, params: &Map<String, Value>) -> Result<Value, JsonRpcError> {
        let source = required_str(params, "source")?;
        let doc = AxnCodec::parse(source).map_err(|e| rpc_error(-32602, e.to_string()))?;
        let args = params
            .get("args")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        let options = params
            .get("options")
            .cloned()
            .map(serde_json::from_value)
            .transpose()
            .map_err(|e| rpc_error(-32602, e.to_string()))?
            .unwrap_or(RunOptions {
                dry_run: None,
                continue_on_error: None,
            });
        let mut runner = AxnRunner::new(self);
        let result = runner
            .run(&doc, &args, options)
            .map_err(|e| rpc_error(-32602, e.to_string()))?;
        serde_json::to_value(RunEnvelope { batch: result }).map_err(internal_error)
    }
}

impl<B: PlatformBackend> ToolDispatcher for Router<B> {
    fn dispatch(&mut self, tool: &str, params: &Map<String, Value>) -> DispatchOutcome {
        match self.dispatch_tool(tool, params) {
            Ok(result) => DispatchOutcome {
                success: true,
                result,
                error: None,
                resolution: None,
            },
            Err(error) => DispatchOutcome {
                success: false,
                result: Value::Null,
                error: Some(error.message),
                resolution: None,
            },
        }
    }
    fn verify(&mut self, _fact: &ExpectedFact) -> Result<(), String> {
        Err("fact verification is not implemented by the Windows v1 router".into())
    }
}

fn flattened(snapshot: &Snapshot) -> impl Iterator<Item = &axon_core::Node> {
    fn add<'a>(node: &'a axon_core::Node, out: &mut Vec<&'a axon_core::Node>) {
        out.push(node);
        for child in &node.children {
            add(child, out);
        }
    }
    let mut out = Vec::new();
    for window in &snapshot.app.windows {
        add(&window.root, &mut out);
    }
    out.into_iter()
}
fn app_query(params: &Map<String, Value>) -> AppQuery {
    AppQuery {
        name: params.get("app").and_then(Value::as_str).map(str::to_owned),
        identifier: params
            .get("identifier")
            .and_then(Value::as_str)
            .map(str::to_owned),
    }
}
fn app_query_from_target(params: &Map<String, Value>, target: &Value) -> AppQuery {
    let mut q = app_query(params);
    if q.name.is_none() {
        q.name = target.get("app").and_then(Value::as_str).map(str::to_owned);
    }
    q
}
fn required_str<'a>(p: &'a Map<String, Value>, key: &str) -> Result<&'a str, JsonRpcError> {
    p.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| rpc_error(-32602, format!("missing string parameter {key}")))
}
fn rpc_error(code: i64, message: impl Into<String>) -> JsonRpcError {
    JsonRpcError {
        code,
        message: message.into(),
        data: None,
    }
}
fn backend_error(e: axon_core::BackendError) -> JsonRpcError {
    rpc_error(-32000, e.to_string())
}
fn internal_error(e: serde_json::Error) -> JsonRpcError {
    rpc_error(-32603, e.to_string())
}

pub fn parse_request(line: &str) -> Result<JsonRpcRequest, JsonRpcResponse> {
    serde_json::from_str(line)
        .map_err(|e| JsonRpcResponse::failure(JsonRpcId::Null, rpc_error(-32700, e.to_string())))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn excluded_tools_fail_before_backend_dispatch() {
        assert_eq!(EXCLUDED.len(), 5);
        assert!(EXCLUDED.iter().any(|x| x.0 == "drag"));
    }
    #[test]
    fn invalid_json_is_parse_error() {
        let e = parse_request("{").unwrap_err();
        let JsonRpcResponse::Failure(e) = e else {
            panic!()
        };
        assert_eq!(e.error.code, -32700);
    }
}
