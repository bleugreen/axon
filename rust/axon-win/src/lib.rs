//! Windows UI Automation backend and v1 JSON-RPC tool router.

use axon_core::{
    AppQuery, AxnCodec, AxnRunner, Candidate, Confidence, DispatchOutcome, ExpectedFact,
    JsonRpcError, JsonRpcId, JsonRpcRequest, JsonRpcResponse, Locator, LocatorResolver,
    PlatformBackend, Resolution, ResolutionStatus, RunEnvelope, RunOptions, Snapshot,
    SnapshotHandle, TextLocationResolution, TextLocationResolver, TextLocationSource,
    TextLocationTarget, TextRecognitionProvider, ToolDispatcher,
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

#[derive(Clone, Debug)]
pub struct VisualObservation {
    pub screenshot: Option<axon_core::Screenshot>,
    pub recognized_text: Option<Vec<axon_core::RecognizedText>>,
}

pub trait VisualObservationProvider {
    fn observe_visuals(
        &mut self,
        app: &AppQuery,
        screenshot: bool,
        screen_text: bool,
    ) -> Result<VisualObservation, axon_core::BackendError>;
}

fn text_click_result(resolution: TextLocationResolution) -> Result<Value, JsonRpcError> {
    Ok(json!({
        "dispatch":{"success":true,"mechanism":"SendInput"},
        "verification":{"verified":false,"reason":"click has no declared postcondition"},
        "resolution": resolution
    }))
}

pub trait PointerTargetVerifier: PlatformBackend {
    fn verify_pointer_target(
        &mut self,
        handle: &SnapshotHandle,
        point: (f64, f64),
    ) -> Result<bool, axon_core::BackendError>;

    fn verify_ocr_target(
        &mut self,
        app: &AppQuery,
        point: (f64, f64),
        _frame: axon_core::Rect,
    ) -> Result<bool, axon_core::BackendError> {
        let _ = app;
        Ok(self.hit_test(point)?.is_some())
    }
}

impl<B: PointerTargetVerifier + TextRecognitionProvider + VisualObservationProvider> Router<B> {
    pub fn new(backend: B) -> Self {
        Self {
            backend,
            snapshot: None,
        }
    }
    fn click_text_location(&mut self, value: &Value) -> Result<Value, JsonRpcError> {
        let target: TextLocationTarget = serde_json::from_value(value.clone())
            .map_err(|error| rpc_error(-32602, error.to_string()))?;
        if target.app.is_empty() {
            return Err(rpc_error(-32602, "location app must not be empty"));
        }
        let app = AppQuery {
            name: Some(target.app.clone()),
            identifier: None,
        };
        let snapshot = self.backend.capture(&app).map_err(backend_error)?;
        let initial = TextLocationResolver::resolve(&target, &snapshot, &[]);
        let resolution = if target.source == TextLocationSource::Screenshot
            || (target.source == TextLocationSource::Auto
                && initial.status == ResolutionStatus::Missing)
        {
            let recognized = self.backend.recognize_text(&app).map_err(backend_error)?;
            TextLocationResolver::resolve(&target, &snapshot, &recognized)
        } else {
            initial
        };
        let candidate = resolution.best.as_ref().ok_or_else(|| {
            rpc_error(
                -32001,
                format!("text location resolution was {:?}", resolution.status),
            )
        })?;
        let point = (candidate.point.x, candidate.point.y);
        let safe = match &candidate.handle {
            Some(handle) => self
                .backend
                .verify_pointer_target(handle, point)
                .map_err(backend_error)?,
            None => self
                .backend
                .verify_ocr_target(&app, point, candidate.frame)
                .map_err(backend_error)?,
        };
        if !safe {
            return Err(rpc_error(
                -32003,
                "click target moved, is covered, or no longer matches the resolved text",
            ));
        }
        self.backend.pointer_click(point).map_err(backend_error)?;
        self.snapshot = Some(snapshot);
        text_click_result(resolution)
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
                if let Some(location) = params
                    .get("target")
                    .and_then(|target| target.get("location"))
                    .or_else(|| params.get("location"))
                {
                    return self.click_text_location(location);
                }
                let (handle, resolution) = self.resolve(params)?;
                let point = self.node_center(&handle)?;
                if !self
                    .backend
                    .verify_pointer_target(&handle, point)
                    .map_err(backend_error)?
                {
                    return Err(rpc_error(
                        -32003,
                        "click target moved, is covered, or no longer matches the resolved element",
                    ));
                }
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
        let app = app_query(params);
        let snapshot = self
            .backend
            .capture(&app)
            .map_err(backend_error)?;
        let mut value = serde_json::to_value(&snapshot).map_err(internal_error)?;
        let wants_screenshot = params.get("screenshot").and_then(Value::as_bool) == Some(true);
        let wants_screen_text = params.get("screenText").and_then(Value::as_bool) == Some(true);
        let visuals = (wants_screenshot || wants_screen_text)
            .then(|| self.backend.observe_visuals(&app, wants_screenshot, wants_screen_text))
            .transpose()
            .map_err(backend_error)?;
        if let Some(screenshot) = visuals.as_ref().and_then(|result| result.screenshot.as_ref()) {
            value.as_object_mut().expect("snapshots serialize as objects").insert(
                "screenshot".into(),
                json!({
                    "mediaType": screenshot.media_type,
                    "base64Data": base64::Engine::encode(
                        &base64::engine::general_purpose::STANDARD,
                        &screenshot.bytes
                    ),
                    "width": screenshot.frame.width as u32,
                    "height": screenshot.frame.height as u32
                }),
            );
        }
        if let Some(screen_text) = visuals.and_then(|result| result.recognized_text) {
            value.as_object_mut().expect("snapshots serialize as objects")
                .insert("screenText".into(), json!(screen_text));
        }
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
        let node = self.node(handle)?;
        let r = node
            .frame
            .ok_or_else(|| rpc_error(-32003, "target has no actionable frame"))?;
        Ok((r.x + r.width / 2.0, r.y + r.height / 2.0))
    }

    fn node(&self, handle: &SnapshotHandle) -> Result<&axon_core::Node, JsonRpcError> {
        let snapshot = self
            .snapshot
            .as_ref()
            .ok_or_else(|| rpc_error(-32002, "no active snapshot"))?;
        let index = snapshot
            .index_for_handle(handle)
            .map_err(|e| rpc_error(-32002, e.to_string()))?;
        flattened(snapshot)
            .nth(index)
            .ok_or_else(|| rpc_error(-32002, "handle index is outside snapshot"))
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

impl<B: PointerTargetVerifier + TextRecognitionProvider + VisualObservationProvider> ToolDispatcher
    for Router<B>
{
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
    fn verify(&mut self, fact: &ExpectedFact) -> Result<(), String> {
        if fact.fields.get("kind").and_then(Value::as_str) != Some("value") {
            return Err(format!("unsupported expected fact kind for {}", fact.id));
        }
        let target = fact
            .fields
            .get("target")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("expected fact {} requires a target handle", fact.id))?;
        let observed = self
            .backend
            .read_value(&SnapshotHandle(target.into()))
            .map_err(|e| e.to_string())?
            .ok_or_else(|| format!("expected fact {} observed no value", fact.id))?;
        if let Some(expected) = fact.fields.get("equals").and_then(Value::as_str) {
            if observed != expected {
                return Err(format!(
                    "expected fact {} failed: expected {expected:?}, observed {observed:?}",
                    fact.id
                ));
            }
            return Ok(());
        }
        if let Some(expected) = fact.fields.get("contains").and_then(Value::as_str) {
            if !observed.contains(expected) {
                return Err(format!(
                    "expected fact {} failed: {observed:?} does not contain {expected:?}",
                    fact.id
                ));
            }
            return Ok(());
        }
        Err(format!(
            "expected value fact {} requires equals or contains",
            fact.id
        ))
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
    use axon_core::{
        Application, BackendError, CapabilityInfo, Node, Observation, RecordedCall, Rect,
        Screenshot, Window,
    };
    use std::{cell::RefCell, rc::Rc, time::Duration};

    #[derive(Clone)]
    struct FakeBackend {
        snapshot: Snapshot,
        pointer_target_matches: bool,
        verified_handles: Rc<RefCell<Vec<SnapshotHandle>>>,
        value: Rc<RefCell<Option<String>>>,
        clicks: Rc<RefCell<usize>>,
        recognized: Vec<axon_core::RecognizedText>,
        ocr_calls: Rc<RefCell<usize>>,
        visual_captures: Rc<RefCell<usize>>,
        ocr_hit_target: Option<Node>,
    }
    impl PointerTargetVerifier for FakeBackend {
        fn verify_pointer_target(
            &mut self,
            handle: &SnapshotHandle,
            _: (f64, f64),
        ) -> Result<bool, BackendError> {
            self.verified_handles.borrow_mut().push(handle.clone());
            Ok(self.pointer_target_matches)
        }
    }
    impl TextRecognitionProvider for FakeBackend {
        fn recognize_text(
            &mut self,
            _: &AppQuery,
        ) -> Result<Vec<axon_core::RecognizedText>, BackendError> {
            *self.ocr_calls.borrow_mut() += 1;
            Ok(self.recognized.clone())
        }
    }
    impl VisualObservationProvider for FakeBackend {
        fn observe_visuals(
            &mut self,
            _: &AppQuery,
            screenshot: bool,
            screen_text: bool,
        ) -> Result<VisualObservation, BackendError> {
            *self.visual_captures.borrow_mut() += 1;
            Ok(VisualObservation {
                screenshot: screenshot.then(|| Screenshot {
                    bytes: vec![1, 2, 3],
                    media_type: "image/png".into(),
                    frame: Rect { x: 4.0, y: 5.0, width: 640.0, height: 480.0 },
                }),
                recognized_text: screen_text.then(|| self.recognized.clone()),
            })
        }
    }
    impl PlatformBackend for FakeBackend {
        fn capabilities(&self) -> Result<Vec<CapabilityInfo>, BackendError> {
            Ok(vec![])
        }
        fn enumerate_applications(&self) -> Result<Vec<Application>, BackendError> {
            Ok(vec![])
        }
        fn capture(&mut self, _: &AppQuery) -> Result<Snapshot, BackendError> {
            Ok(self.snapshot.clone())
        }
        fn invoke(&mut self, _: &SnapshotHandle, _: &str) -> Result<(), BackendError> {
            Ok(())
        }
        fn read_value(&self, _: &SnapshotHandle) -> Result<Option<String>, BackendError> {
            Ok(self.value.borrow().clone())
        }
        fn set_value(&mut self, _: &SnapshotHandle, value: &str) -> Result<(), BackendError> {
            *self.value.borrow_mut() = Some(value.into());
            Ok(())
        }
        fn focus(&mut self, _: &SnapshotHandle) -> Result<(), BackendError> {
            Ok(())
        }
        fn scroll(&mut self, _: &SnapshotHandle, _: (f64, f64)) -> Result<(), BackendError> {
            Ok(())
        }
        fn observe(&mut self, _: &AppQuery, _: Duration) -> Result<Observation, BackendError> {
            unreachable!()
        }
        fn wait_for_value(
            &mut self,
            _: &SnapshotHandle,
            _: &Value,
            _: Duration,
        ) -> Result<Observation, BackendError> {
            unreachable!()
        }
        fn pointer_click(&mut self, _: (f64, f64)) -> Result<(), BackendError> {
            *self.clicks.borrow_mut() += 1;
            Ok(())
        }
        fn pointer_drag(
            &mut self,
            _: (f64, f64),
            _: (f64, f64),
            _: Duration,
        ) -> Result<(), BackendError> {
            unreachable!()
        }
        fn keyboard(&mut self, _: &AppQuery, _: &str) -> Result<(), BackendError> {
            Ok(())
        }
        fn screenshot(&mut self, _: &AppQuery) -> Result<Screenshot, BackendError> {
            unreachable!()
        }
        fn hit_test(&mut self, _: (f64, f64)) -> Result<Option<Node>, BackendError> {
            Ok(self.ocr_hit_target.clone())
        }
        fn recorded_calls(&self) -> Result<Vec<RecordedCall>, BackendError> {
            unreachable!()
        }
        fn set_recording(&mut self, _: bool) -> Result<(), BackendError> {
            unreachable!()
        }
        fn observe_global_input(&mut self, _: Duration) -> Result<Vec<RecordedCall>, BackendError> {
            unreachable!()
        }
    }
    fn node(name: &str) -> Node {
        Node {
            role: "Button".into(),
            subrole: None,
            name: Some(name.into()),
            title: Some(name.into()),
            label: Some(name.into()),
            value: None,
            description: None,
            identifier: Some(name.into()),
            actions: vec!["Invoke".into()],
            frame: Some(Rect {
                x: 0.0,
                y: 0.0,
                width: 20.0,
                height: 20.0,
            }),
            editable: false,
            children: vec![],
            child_count: Some(0),
            truncation_reason: None,
        }
    }
    fn backend(nodes: Vec<Node>, value: Option<&str>) -> FakeBackend {
        let root = Node {
            children: nodes,
            ..node("root")
        };
        FakeBackend {
            snapshot: Snapshot::new(Application {
                name: "App".into(),
                identifier: None,
                windows: vec![Window { title: None, root }],
            }),
            pointer_target_matches: true,
            verified_handles: Rc::new(RefCell::new(vec![])),
            value: Rc::new(RefCell::new(value.map(str::to_owned))),
            clicks: Rc::new(RefCell::new(0)),
            recognized: vec![],
            ocr_calls: Rc::new(RefCell::new(0)),
            visual_captures: Rc::new(RefCell::new(0)),
            ocr_hit_target: Some(node("hit")),
        }
    }
    fn request(method: &str, params: Value) -> JsonRpcRequest {
        JsonRpcRequest::new(Some(JsonRpcId::Integer(1)), method, Some(params))
    }
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
    #[test]
    fn ambiguous_locator_cannot_dispatch() {
        let mut router = Router::new(backend(vec![node("same"), node("same")], None));
        let response = router
            .request(request(
                "click",
                json!({"target":{"app":"App","locator":{"role":"Button"}}}),
            ))
            .unwrap();
        let JsonRpcResponse::Failure(error) = response else {
            panic!()
        };
        assert!(error.error.message.contains("Ambiguous"));
        assert_eq!(*router.backend.clicks.borrow(), 0);
    }
    #[test]
    fn click_rejects_mismatched_immediate_hit_before_send_input() {
        let mut backend = backend(vec![], None);
        let handle = backend.snapshot.handle(0);
        backend.pointer_target_matches = false;
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());
        let response = router
            .request(request("click", json!({"target":handle.0})))
            .unwrap();
        assert!(matches!(response, JsonRpcResponse::Failure(_)));
        assert_eq!(*clicks.borrow(), 0);
    }
    #[test]
    fn click_rejects_duplicate_name_sibling_when_native_identity_differs() {
        let mut backend = backend(vec![node("duplicate"), node("duplicate")], None);
        let target = backend.snapshot.handle(1);
        backend.pointer_target_matches = false;
        let verified_handles = backend.verified_handles.clone();
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request("click", json!({"target":target.0})))
            .unwrap();

        assert!(matches!(response, JsonRpcResponse::Failure(_)));
        assert_eq!(&*verified_handles.borrow(), &[target]);
        assert_eq!(*clicks.borrow(), 0);
    }
    fn recognized(text: &str, x: f64) -> axon_core::RecognizedText {
        axon_core::RecognizedText {
            text: text.into(),
            frame: Rect { x, y: 10.0, width: 40.0, height: 20.0 },
            confidence: Some(0.9),
        }
    }
    #[test]
    fn unique_text_location_click_returns_macos_shaped_resolution() {
        let mut router = Router::new(backend(vec![node("Save")], None));
        let response = router.request(request("click", json!({"target":{"location":{"app":"App","text":"save"}}}))).unwrap();
        let JsonRpcResponse::Success(success) = response else { panic!() };
        assert_eq!(success.result["resolution"]["status"], "unique");
        assert_eq!(success.result["resolution"]["best"]["source"], "ax");
        assert_eq!(success.result["resolution"]["point"]["x"], 10.0);
        let keys = success.result["resolution"].as_object().unwrap();
        assert!(keys.contains_key("snapshotID"));
        assert!(!keys.contains_key("snapshotId"));
        assert_eq!(*router.backend.clicks.borrow(), 1);
    }
    #[test]
    fn look_screenshot_and_text_share_one_capture_and_use_canonical_keys() {
        let mut backend = backend(vec![], None);
        backend.recognized = vec![recognized("Save", 100.0)];
        let captures = backend.visual_captures.clone();
        let mut router = Router::new(backend);
        let response = router.request(request(
            "look",
            json!({"app":"App","screenshot":true,"screenText":true}),
        )).unwrap();
        let JsonRpcResponse::Success(success) = response else { panic!() };
        let screenshot = success.result["screenshot"].as_object().unwrap();
        let keys = screenshot.keys().map(String::as_str).collect::<std::collections::BTreeSet<_>>();
        assert_eq!(keys, ["base64Data", "height", "mediaType", "width"].into_iter().collect());
        assert_eq!(screenshot["mediaType"], "image/png");
        assert_eq!(screenshot["base64Data"], "AQID");
        assert_eq!(screenshot["width"], 640);
        assert_eq!(screenshot["height"], 480);
        assert_eq!(success.result["screenText"][0]["text"], "Save");
        assert_eq!(*captures.borrow(), 1);
    }
    #[test]
    fn ambiguous_text_location_fails_closed() {
        let mut router = Router::new(backend(vec![node("Save"), node("Save")], None));
        let response = router.request(request("click", json!({"target":{"location":{"app":"App","text":"save"}}}))).unwrap();
        assert!(matches!(response, JsonRpcResponse::Failure(_)));
        assert_eq!(*router.backend.clicks.borrow(), 0);
    }
    #[test]
    fn auto_prefers_uia_without_running_ocr() {
        let mut backend = backend(vec![node("Save")], None);
        backend.recognized = vec![recognized("Save", 100.0)];
        let calls = backend.ocr_calls.clone();
        let mut router = Router::new(backend);
        let response = router.request(request("click", json!({"target":{"location":{"app":"App","text":"save","source":"auto"}}}))).unwrap();
        assert!(matches!(response, JsonRpcResponse::Success(_)));
        assert_eq!(*calls.borrow(), 0);
    }
    #[test]
    fn forced_screenshot_uses_ocr_even_when_uia_matches() {
        let mut backend = backend(vec![node("Save")], None);
        backend.recognized = vec![recognized("Save", 100.0)];
        let calls = backend.ocr_calls.clone();
        let mut router = Router::new(backend);
        let response = router.request(request("click", json!({"target":{"location":{"app":"App","text":"save","source":"screenshot"}}}))).unwrap();
        let JsonRpcResponse::Success(success) = response else { panic!() };
        assert_eq!(success.result["resolution"]["best"]["source"], "screenshot");
        assert_eq!(*calls.borrow(), 1);
    }
    #[test]
    fn ocr_click_refuses_dispatch_when_fresh_hit_test_fails() {
        let mut backend = backend(vec![], None);
        backend.recognized = vec![recognized("Save", 100.0)];
        backend.ocr_hit_target = None;
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        let response = router.request(request("click", json!({"target":{"location":{"app":"App","text":"save","source":"screenshot"}}}))).unwrap();
        assert!(matches!(response, JsonRpcResponse::Failure(_)));
        assert_eq!(*clicks.borrow(), 0);
    }
    #[test]
    fn axn_value_facts_drive_expects_requires_dry_run_and_continue_on_error() {
        let backend = backend(vec![], Some("ready now"));
        let handle = backend.snapshot.handle(0).0;
        let mut router = Router::new(backend.clone());
        router.snapshot = Some(backend.snapshot.clone());
        let source = format!(
            r#"version: 1
actions:
  - id: pass
    tool: invoke
    target: {handle}
    expects:
      - id: ready
        kind: value
        target: {handle}
        contains: ready
  - tool: invoke
    target: {handle}
    requires: [ready]
    expects:
      - id: exact
        kind: value
        target: {handle}
        equals: wrong
  - tool: invoke
    target: {handle}
"#
        );
        let response = router
            .request(request(
                "run",
                json!({"source":source,"options":{"continueOnError":true}}),
            ))
            .unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!()
        };
        let batch = &success.result["batch"];
        assert!(!batch["success"].as_bool().unwrap());
        assert_eq!(batch["trace"].as_array().unwrap().len(), 3);
        assert!(
            batch["trace"][1]["error"]
                .as_str()
                .unwrap()
                .contains("expected")
        );

        let dry = router
            .request(request(
                "run",
                json!({"source":source,"options":{"dryRun":true}}),
            ))
            .unwrap();
        let JsonRpcResponse::Success(dry) = dry else {
            panic!()
        };
        assert!(dry.result["batch"]["dryRun"].as_bool().unwrap());
        assert!(!dry.result["batch"]["success"].as_bool().unwrap());
        assert!(
            dry.result["batch"]["trace"][1]["error"]
                .as_str()
                .unwrap()
                .contains("required fact")
        );
    }
}
