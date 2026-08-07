//! Linux AT-SPI backend and v1 JSON-RPC tool router.

use axon_core::{
    AppQuery, AxnCodec, AxnRunner, Candidate, Capability, Confidence, DeliveryCandidate,
    DeliveryCapability, DeliveryOutcome, DeliveryPolicy, DeliveryRefusal, DeliveryRefusalReason,
    DeliveryRung, DeliverySelection, DispatchOutcome, ExpectedFact, ForegroundTarget, JsonRpcError,
    JsonRpcId, JsonRpcRequest, JsonRpcResponse, KeyboardIntent, Locator, LocatorResolver,
    PlatformBackend, Resolution, ResolutionStatus, RunEnvelope, RunOptions, Snapshot,
    SnapshotHandle, ToolDispatcher, dispatch_in_foreground, select_delivery,
};
use serde_json::{Map, Value, json};

pub mod keys;
pub mod lifecycle;

#[cfg(target_os = "linux")]
mod platform;
#[cfg(target_os = "linux")]
pub use platform::LinuxBackend;
/// The X11 half of the Linux backend, public so the hermetic foreground test can drive it against
/// a real X server without a desktop session.
#[cfg(target_os = "linux")]
pub mod x11;

/// Tools this backend does not implement at all. These are not delivery decisions: the request
/// names something the Linux daemon has no code path for, which stays a JSON-RPC error.
const EXCLUDED: &[(&str, &str)] = &[
    ("save", "SerializeHistory"),
    ("wait_for_value", "WaitForValue"),
    ("wait_for_stability", "WaitForStability"),
    ("permit", "PermissionPrompt"),
];

/// X11 target-window input and the Wayland portals are not wired into this backend yet, so there
/// is no mechanism here that can be honestly classified as the pixel rung. Relabelling XTest or a
/// virtual global device as `pixel` would make the contract's central promise false, so the rung
/// is reported as unsupported until a verified target-bound path exists.
const NO_BACKGROUND_PIXEL: &str = "this Linux backend has no verified target-window input path; \
     X11 window-targeted delivery and Wayland portal delivery are not implemented";

/// Why the foreground rung is withheld rather than merely gated behind the opt-in.
///
/// On this backend that means one of three sessions: no X display to connect to, a Wayland session
/// whose compositor neither permits synthetic input nor exposes its foreground to X11, or an X11
/// session with no EWMH-capable window manager to read and set the active window through. The
/// backend's capability report names which one, and that reason reaches the caller ahead of this
/// message.
const NO_FOREGROUND_TRANSACTION: &str = "this Linux session cannot capture, prove, and restore the \
     foreground application, so it cannot deliver global input transactionally";

pub struct Router<B> {
    backend: B,
    snapshot: Option<Snapshot>,
}

pub trait PointerTargetVerifier: PlatformBackend {
    fn verify_pointer_target(
        &mut self,
        handle: &SnapshotHandle,
        point: (f64, f64),
    ) -> Result<bool, axon_core::BackendError>;
}

impl<B: PointerTargetVerifier> Router<B> {
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
        // The policy is decoded before the target is resolved and before any backend call, so an
        // unknown value can never reach a native API.
        let policy =
            DeliveryPolicy::from_params(params).map_err(|error| rpc_error(-32602, error))?;
        match method {
            "look" => self.look(params),
            "find" => {
                let (handle, resolution) = self.resolve(params)?;
                Ok(json!({"handle": handle, "resolution": resolution}))
            }
            "click" => {
                // The target is resolved first, so an absent, malformed, or stale target is a
                // JSON-RPC error. A refusal means the request was well formed and the target
                // resolved, and the daemon declined to act; the two must not be confused.
                let (handle, resolution) = self.resolve(params)?;
                let point = self.node_center(&handle)?;
                let ladder = self.global_input_ladder(Capability::PointerInput, "XTest pointer");
                let Some(candidate) = self.selected(&ladder, policy) else {
                    return Ok(self.refusal(&ladder, policy));
                };
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
                let Some(application) = self.resolved_application() else {
                    return Ok(DeliveryOutcome::refusal_result(
                        policy,
                        DeliveryRefusal::new(
                            DeliveryRefusalReason::TargetIdentityUnavailable,
                            DeliveryRung::Foreground,
                            Some(DeliveryCapability::GlobalInput),
                            "the resolved target's owning application could not be identified, so \
                             foreground delivery cannot activate and prove it",
                        ),
                    ));
                };
                self.foreground_dispatch(
                    policy,
                    &candidate,
                    ForegroundTarget::Application(&application),
                    // A pointer click moves the real cursor, so the transaction puts it back.
                    true,
                    json!({"verified":false,"reason":"click has no declared postcondition"}),
                    Some(resolution),
                    |backend| backend.pointer_click(point),
                )
            }
            "type" => {
                let (handle, resolution) = self.resolve(params)?;
                let value =
                    required_str(params, "value").or_else(|_| required_str(params, "text"))?;
                // Setting an editable value through AT-SPI needs no focus, and taking focus would
                // make this a foreground action wearing a semantic name.
                self.backend
                    .set_value(&handle, value)
                    .map_err(backend_error)?;
                let observed = self.backend.read_value(&handle).map_err(backend_error)?;
                Ok(delivered(
                    json!({"dispatch":{"success":true,"mechanism":"AT-SPI EditableText.SetTextContents"},"verification":{"verified":observed.as_deref()==Some(value),"observed":observed},"resolution":resolution}),
                    policy,
                    DeliveryRung::Semantic,
                ))
            }
            "keyboard" => {
                // The intent is validated before the ladder, so a malformed request is an error
                // rather than a refusal.
                let intent = keyboard_intent(params)?;
                let ladder = self.global_input_ladder(Capability::KeyboardInput, "XTest keyboard");
                let Some(candidate) = self.selected(&ladder, policy) else {
                    return Ok(self.refusal(&ladder, policy));
                };
                let app = app_query(params);
                // `keyboard` without an app is explicitly addressed at whatever holds the
                // foreground, so there is nothing to activate and nothing to restore. With an app
                // it is aimed, and the transaction proves that app came forward first.
                let named = app.name.clone();
                self.foreground_dispatch(
                    policy,
                    &candidate,
                    named
                        .as_deref()
                        .map_or(ForegroundTarget::Frontmost, ForegroundTarget::Application),
                    // Keyboard input never touches the cursor, and capturing a pointer it does not
                    // move would report a restoration that never happened.
                    false,
                    json!({"verified":false,"reason":"keyboard input has no declared postcondition"}),
                    None,
                    move |backend| backend.keyboard(&app, intent),
                )
            }
            "drag" => {
                let ladder = self.global_input_ladder(Capability::PointerInput, "XTest pointer");
                // Drag has no semantic rung at all, so a refusal here is the whole answer.
                if self.selected(&ladder, policy).is_none() {
                    return Ok(self.refusal(&ladder, policy));
                }
                Err(rpc_error(
                    -32004,
                    "tool drag requires unavailable capability PointerDrag",
                ))
            }
            "invoke" => {
                let (handle, resolution) = self.resolve(params)?;
                let action = required_str(params, "name")?;
                self.backend
                    .invoke(&handle, action)
                    .map_err(backend_error)?;
                Ok(delivered(
                    json!({"dispatch":{"success":true,"mechanism":"AT-SPI Action.DoAction","action":action},"verification":{"verified":false,"reason":"invoke has no declared postcondition"},"resolution":resolution}),
                    policy,
                    DeliveryRung::Semantic,
                ))
            }
            "scroll" => {
                let (handle, resolution) = self.resolve(params)?;
                let dx = params.get("deltaX").and_then(Value::as_f64).unwrap_or(0.0);
                let dy = params.get("deltaY").and_then(Value::as_f64).unwrap_or(0.0);
                self.backend
                    .scroll(&handle, (dx, dy))
                    .map_err(backend_error)?;
                Ok(delivered(
                    json!({"dispatch":{"success":true,"mechanism":"AT-SPI Component.ScrollTo"},"verification":{"verified":false,"reason":"scroll has no declared postcondition"},"resolution":resolution}),
                    policy,
                    DeliveryRung::Semantic,
                ))
            }
            "run" => self.run_axn(params),
            _ => Err(rpc_error(-32601, format!("unknown method {method}"))),
        }
    }

    /// The ladder for an action that can only travel as input: no semantic rung, no verified
    /// background path on this backend, and a foreground rung only where the runtime has one.
    fn global_input_ladder(
        &self,
        capability: Capability,
        mechanism: &str,
    ) -> Vec<DeliveryCandidate> {
        let restriction = self
            .capability_restriction(capability)
            .or_else(|| self.foreground_transaction_restriction());
        vec![
            DeliveryCandidate::unavailable(
                DeliveryRung::Pixel,
                DeliveryCapability::BackgroundPixelInput,
                "X11 window-targeted input",
                DeliveryRefusalReason::BackgroundPixelUnsupported,
                NO_BACKGROUND_PIXEL,
            ),
            match restriction {
                None => DeliveryCandidate::available(
                    DeliveryRung::Foreground,
                    DeliveryCapability::GlobalInput,
                    mechanism,
                ),
                Some(reason) => DeliveryCandidate::unavailable(
                    DeliveryRung::Foreground,
                    DeliveryCapability::GlobalInput,
                    mechanism,
                    DeliveryRefusalReason::NoDeliveryCandidate,
                    reason,
                ),
            },
        ]
    }

    /// The foreground rung is global input that restores what it borrowed. A backend that cannot
    /// capture, prove, and hand back the foreground does not get to offer it: dispatching
    /// unrestored global input while reporting `delivery: "foreground"` would claim a guarantee it
    /// does not keep, which is precisely what this contract exists to prevent.
    fn foreground_transaction_restriction(&self) -> Option<String> {
        if self.backend.supports_foreground_transaction() {
            return None;
        }
        Some(NO_FOREGROUND_TRANSACTION.to_string())
    }

    /// The health-v1 runtime overlay, consulted by the same decision that dispatches. `None` means
    /// the capability is usable; `Some` carries the reason it is not.
    fn capability_restriction(&self, capability: Capability) -> Option<String> {
        let Ok(capabilities) = self.backend.capabilities() else {
            return Some(format!(
                "{} is unavailable: backend capabilities could not be read",
                capability.key()
            ));
        };
        match capabilities
            .iter()
            .find(|info| info.capability == capability)
        {
            Some(info) if info.usable => None,
            Some(info) => {
                Some(info.restriction.clone().unwrap_or_else(|| {
                    format!("{} is not usable in this session", capability.key())
                }))
            }
            None => Some(format!(
                "{} is not available on this backend",
                capability.key()
            )),
        }
    }

    /// Dispatches one action at the selected rung, inside a foreground transaction when the rung is
    /// the foreground one.
    fn foreground_dispatch(
        &mut self,
        policy: DeliveryPolicy,
        candidate: &DeliveryCandidate,
        target: ForegroundTarget<'_>,
        restores_pointer: bool,
        verification: Value,
        resolution: Option<axon_core::Resolution>,
        body: impl FnOnce(&mut B) -> Result<(), axon_core::BackendError>,
    ) -> Result<Value, JsonRpcError> {
        let dispatch = dispatch_in_foreground(&mut self.backend, target, restores_pointer, body);
        if let Some(refusal) = dispatch.refusal {
            let mut result = DeliveryOutcome::refusal_result(policy, refusal);
            if let Some(object) = result.as_object_mut() {
                object.insert("foreground".into(), json!(dispatch.cleanup));
            }
            return Ok(result);
        }
        dispatch
            .value
            .expect("a proved activation dispatches")
            .map_err(backend_error)?;

        let mut result = json!({
            // Dispatch evidence survives a failed restoration, but the action as a whole did not
            // succeed: the user's session was not put back where they left it. A cursor left where
            // the click dropped it counts as much as a window that never came forward again.
            "success": dispatch.cleanup.session_restored(),
            "dispatch": {"success": true, "mechanism": candidate.mechanism},
            "verification": verification,
            "foreground": dispatch.cleanup,
        });
        if let (Some(object), Some(resolution)) = (result.as_object_mut(), resolution) {
            object.insert("resolution".into(), json!(resolution));
        }
        Ok(delivered(result, policy, candidate.rung))
    }

    /// The stable identity of the application that owns the currently resolved target.
    ///
    /// Foreground delivery has to activate the application the *target* belongs to, not whichever
    /// app string the request happened to carry. A handle-only request carries no app string at
    /// all, and treating that as "already frontmost" would dispatch global input with no
    /// activation and no proof — the exact bug this contract exists to close.
    fn resolved_application(&self) -> Option<String> {
        let app = &self.snapshot.as_ref()?.app;
        app.identifier
            .as_deref()
            .or(Some(app.name.as_str()))
            .filter(|identity| !identity.is_empty())
            .map(str::to_owned)
    }

    fn selected(
        &self,
        ladder: &[DeliveryCandidate],
        policy: DeliveryPolicy,
    ) -> Option<DeliveryCandidate> {
        match select_delivery(ladder, policy, None) {
            DeliverySelection::Candidate(candidate) => Some(candidate),
            DeliverySelection::Refusal(_) => None,
        }
    }

    fn refusal(&self, ladder: &[DeliveryCandidate], policy: DeliveryPolicy) -> Value {
        match select_delivery(ladder, policy, None) {
            DeliverySelection::Refusal(refusal) => DeliveryOutcome::refusal_result(policy, refusal),
            DeliverySelection::Candidate(_) => Value::Null,
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

impl<B: PointerTargetVerifier> ToolDispatcher for Router<B> {
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
/// `keyboard` carries exactly one intent. Neither is an empty request and both at once is an
/// ambiguous one; each is malformed rather than a delivery decision, so each is a transport error.
fn keyboard_intent(params: &Map<String, Value>) -> Result<KeyboardIntent<'_>, JsonRpcError> {
    let text = params.get("text").and_then(Value::as_str);
    let key = params.get("key").and_then(Value::as_str);
    match (text, key) {
        (Some(text), None) => Ok(KeyboardIntent::Text(text)),
        (None, Some(key)) => Ok(KeyboardIntent::Key(key)),
        (Some(_), Some(_)) => Err(rpc_error(
            -32602,
            "keyboard takes exactly one of text and key; text is entered literally and key names a \
             keystroke, and a request carrying both does not say which it meant",
        )),
        (None, None) => Err(rpc_error(
            -32602,
            "keyboard requires exactly one of the string parameters text and key",
        )),
    }
}
fn required_str<'a>(p: &'a Map<String, Value>, key: &str) -> Result<&'a str, JsonRpcError> {
    p.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| rpc_error(-32602, format!("missing string parameter {key}")))
}
/// Stamps the four stable delivery fields onto an action result.
fn delivered(mut result: Value, policy: DeliveryPolicy, rung: DeliveryRung) -> Value {
    if let Some(object) = result.as_object_mut() {
        DeliveryOutcome::dispatched(policy, rung).merge_into(object);
    }
    result
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
        focuses: Rc<RefCell<usize>>,
        /// Where the real pointer sits. A click moves it, which is why the transaction restores it.
        pointer: Rc<RefCell<(f64, f64)>>,
        /// Whether the foreground can be read at all, which is not the same as nothing holding it.
        foreground_readable: bool,
        /// A pointer that will not go back where it started.
        refuses_pointer_move: bool,
        /// Whether this session advertises a usable global input device, which is what decides
        /// between "opt in and it works" and "this cannot happen here".
        pointer_capability_usable: bool,
        /// Whether this backend can capture, prove, and restore the foreground. Without it the
        /// foreground rung is withheld rather than dispatched unrestored.
        foreground_transaction: bool,
        frontmost: Rc<RefCell<Option<String>>>,
        /// Applications that refuse to come forward, so activation cannot be proved.
        refuses_activation: Rc<RefCell<Vec<String>>>,
        activations: Rc<RefCell<Vec<String>>>,
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
    impl PlatformBackend for FakeBackend {
        fn capabilities(&self) -> Result<Vec<CapabilityInfo>, BackendError> {
            Ok(vec![
                CapabilityInfo {
                    capability: Capability::PointerInput,
                    usable: self.pointer_capability_usable,
                    restriction: (!self.pointer_capability_usable)
                        .then(|| "no global pointer device in this session".to_string()),
                },
                CapabilityInfo {
                    capability: Capability::KeyboardInput,
                    usable: self.pointer_capability_usable,
                    restriction: (!self.pointer_capability_usable)
                        .then(|| "no global keyboard device in this session".to_string()),
                },
            ])
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
            *self.focuses.borrow_mut() += 1;
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
        fn pointer_click(&mut self, point: (f64, f64)) -> Result<(), BackendError> {
            *self.clicks.borrow_mut() += 1;
            *self.pointer.borrow_mut() = point;
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
        fn keyboard(&mut self, _: &AppQuery, _: KeyboardIntent<'_>) -> Result<(), BackendError> {
            Ok(())
        }
        fn screenshot(&mut self, _: &AppQuery) -> Result<Screenshot, BackendError> {
            unreachable!()
        }
        fn hit_test(&mut self, _: (f64, f64)) -> Result<Option<Node>, BackendError> {
            Ok(None)
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
        fn supports_foreground_transaction(&self) -> bool {
            self.foreground_transaction
        }
        fn frontmost_application(&mut self) -> Result<Option<String>, BackendError> {
            if !self.foreground_readable {
                return Err(BackendError::Operation {
                    operation: "read the foreground".into(),
                    message: "the session refused".into(),
                    diagnostic: None,
                });
            }
            Ok(self.frontmost.borrow().clone())
        }
        fn pointer_location(&mut self) -> Result<Option<(f64, f64)>, BackendError> {
            Ok(Some(*self.pointer.borrow()))
        }
        fn move_pointer(&mut self, to: (f64, f64)) -> Result<bool, BackendError> {
            if self.refuses_pointer_move {
                return Ok(false);
            }
            *self.pointer.borrow_mut() = to;
            Ok(true)
        }
        fn activate_application(&mut self, identity: &str) -> Result<bool, BackendError> {
            self.activations.borrow_mut().push(identity.into());
            if self
                .refuses_activation
                .borrow()
                .iter()
                .any(|app| app == identity)
            {
                return Ok(false);
            }
            *self.frontmost.borrow_mut() = Some(identity.into());
            Ok(true)
        }
    }
    /// Where the fake pointer starts, deliberately away from any node's centre so a click has to
    /// move it and the transaction has something real to put back.
    const POINTER_ORIGIN: (f64, f64) = (500.0, 400.0);

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
            focuses: Rc::new(RefCell::new(0)),
            pointer: Rc::new(RefCell::new(POINTER_ORIGIN)),
            foreground_readable: true,
            refuses_pointer_move: false,
            pointer_capability_usable: false,
            foreground_transaction: false,
            frontmost: Rc::new(RefCell::new(Some("Prior".into()))),
            refuses_activation: Rc::new(RefCell::new(vec![])),
            activations: Rc::new(RefCell::new(vec![])),
        }
    }
    fn request(method: &str, params: Value) -> JsonRpcRequest {
        JsonRpcRequest::new(Some(JsonRpcId::Integer(1)), method, Some(params))
    }
    #[test]
    fn unimplemented_tools_stay_json_rpc_errors_rather_than_refusals() {
        // These are not delivery decisions: the Linux daemon has no code path for them at all, so
        // they remain transport errors instead of well-formed actions the daemon declined.
        assert_eq!(EXCLUDED.len(), 4);
        for tool in ["save", "wait_for_value", "wait_for_stability", "permit"] {
            assert!(EXCLUDED.iter().any(|entry| entry.0 == tool), "{tool}");
        }
        for tool in ["click", "keyboard", "drag", "type", "scroll", "invoke"] {
            assert!(!EXCLUDED.iter().any(|entry| entry.0 == tool), "{tool}");
        }
    }

    fn refusal(response: &JsonRpcResponse) -> &Value {
        let JsonRpcResponse::Success(success) = response else {
            panic!("a policy or capability denial is an action result, not a transport error")
        };
        &success.result
    }

    #[test]
    fn click_refuses_without_a_backend_call_and_names_the_missing_mechanism() {
        let backend = backend(vec![], None);
        let handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request("click", json!({"target": handle.0})))
            .unwrap();

        let result = refusal(&response);
        assert_eq!(result["success"], json!(false));
        assert_eq!(result["strategy"], json!("refused"));
        assert_eq!(result["deliveryPolicy"], json!("backgroundOnly"));
        assert_eq!(result["delivery"], Value::Null);
        assert_eq!(result["dispatchSuccess"], json!(false));
        // The fake backend advertises no capabilities, so global input is absent rather than
        // merely withheld: the caller must not be told to opt in to something that cannot happen.
        assert_eq!(result["refusal"]["reason"], json!("noDeliveryCandidate"));
        assert_eq!(result["refusal"]["requiredRung"], json!("foreground"));
        assert_eq!(result["refusal"]["capability"], json!("globalInput"));
        assert_eq!(*clicks.borrow(), 0);
    }

    #[test]
    fn keyboard_refuses_without_a_backend_call() {
        let mut router = Router::new(backend(vec![], None));

        let response = router
            .request(request("keyboard", json!({"text": "x"})))
            .unwrap();

        let result = refusal(&response);
        assert_eq!(result["dispatchSuccess"], json!(false));
        assert_eq!(result["refusal"]["capability"], json!("globalInput"));
    }

    /// A backend that advertises global input and can hand the foreground back.
    fn transactional_backend() -> FakeBackend {
        let mut backend = backend(vec![], None);
        backend.pointer_capability_usable = true;
        backend.foreground_transaction = true;
        backend
    }

    #[test]
    fn a_backend_that_cannot_restore_the_foreground_never_offers_the_rung() {
        // Global input that does not hand the session back is not the foreground rung, it is the
        // behaviour this contract exists to prevent. Offering it and reporting
        // `delivery: "foreground"` would claim a guarantee the backend does not keep.
        let mut backend = backend(vec![], None);
        backend.pointer_capability_usable = true;
        let handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        for policy in ["backgroundOnly", "foregroundPermitted"] {
            let response = router
                .request(request(
                    "click",
                    json!({"target": handle.0, "deliveryPolicy": policy}),
                ))
                .unwrap();
            let result = refusal(&response);
            assert_eq!(
                result["refusal"]["reason"],
                json!("noDeliveryCandidate"),
                "{policy}"
            );
            assert!(
                result["refusal"]["message"]
                    .as_str()
                    .unwrap()
                    .contains("restore"),
                "{policy}: {}",
                result["refusal"]["message"]
            );
            assert_eq!(result["dispatchSuccess"], json!(false), "{policy}");
        }
        assert_eq!(*clicks.borrow(), 0);
    }

    #[test]
    fn a_transactional_backend_makes_the_foreground_rung_an_opt_in() {
        let backend = transactional_backend();
        let handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let activations = backend.activations.clone();
        let frontmost = backend.frontmost.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let refused = router
            .request(request("click", json!({"target": handle.0})))
            .unwrap();
        let result = refusal(&refused);
        assert_eq!(result["refusal"]["reason"], json!("foregroundNotPermitted"));
        assert_eq!(*clicks.borrow(), 0);
        assert!(activations.borrow().is_empty());

        let permitted = router
            .request(request(
                "click",
                json!({
                    "target": handle.0,
                    "app": "App",
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();
        let JsonRpcResponse::Success(success) = permitted else {
            panic!("an opted-in click dispatches")
        };
        assert_eq!(success.result["delivery"], json!("foreground"));
        assert_eq!(success.result["dispatchSuccess"], json!(true));
        assert_eq!(success.result["refusal"], Value::Null);
        assert_eq!(*clicks.borrow(), 1);
        // Captured, activated, proved, dispatched once, and handed back.
        assert_eq!(success.result["foreground"]["priorApp"], json!("Prior"));
        assert_eq!(
            success.result["foreground"]["alreadyFrontmost"],
            json!(false)
        );
        assert_eq!(
            success.result["foreground"]["activationProved"],
            json!(true)
        );
        assert_eq!(success.result["foreground"]["restored"], json!(true));
        assert_eq!(
            *activations.borrow(),
            vec!["App".to_string(), "Prior".to_string()]
        );
        assert_eq!(frontmost.borrow().as_deref(), Some("Prior"));
    }

    #[test]
    fn foreground_escalation_refuses_without_dispatching_when_activation_is_not_proved() {
        let backend = transactional_backend();
        backend.refuses_activation.borrow_mut().push("App".into());
        let handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let frontmost = backend.frontmost.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({
                    "target": handle.0,
                    "app": "App",
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

        let result = refusal(&response);
        assert_eq!(result["refusal"]["reason"], json!("activationNotProved"));
        assert_eq!(result["dispatchSuccess"], json!(false));
        assert_eq!(result["delivery"], Value::Null);
        // Posting global input at this moment would send it wherever the user is working.
        assert_eq!(*clicks.borrow(), 0);
        assert_eq!(frontmost.borrow().as_deref(), Some("Prior"));
    }

    #[test]
    fn a_failed_restoration_keeps_dispatch_evidence_and_fails_overall() {
        let backend = transactional_backend();
        backend.refuses_activation.borrow_mut().push("Prior".into());
        let handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({
                    "target": handle.0,
                    "app": "App",
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

        let JsonRpcResponse::Success(success) = response else {
            panic!("the dispatch happened, so this is an action result")
        };
        assert_eq!(success.result["dispatchSuccess"], json!(true));
        assert_eq!(success.result["delivery"], json!("foreground"));
        assert_eq!(success.result["foreground"]["restored"], json!(false));
        // The events went out, but the user's session was not put back.
        assert_eq!(success.result["success"], json!(false));
        assert_eq!(*clicks.borrow(), 1);
    }

    #[test]
    fn an_unresolvable_target_is_a_transport_error_not_a_delivery_refusal() {
        // A refusal means the request was well formed and the target resolved. A target that is
        // absent, malformed, or stale never gets that far, so it stays a JSON-RPC error even under
        // the default policy where the rung would have been refused anyway.
        let backend = backend(vec![], None);
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        for target in [json!("s999:42"), json!("not-a-handle"), Value::Null] {
            let response = router
                .request(request("click", json!({"target": target})))
                .unwrap();
            let JsonRpcResponse::Failure(failure) = response else {
                panic!("an unresolvable target is a transport error, not a refusal: {target}")
            };
            assert!(failure.error.code < 0, "{target}");
        }
        assert_eq!(*clicks.borrow(), 0);
    }

    #[test]
    fn a_malformed_keyboard_request_is_a_transport_error_not_a_delivery_refusal() {
        let mut router = Router::new(backend(vec![], None));

        let response = router.request(request("keyboard", json!({}))).unwrap();

        let JsonRpcResponse::Failure(failure) = response else {
            panic!("a keyboard request with no intent is malformed, not refused")
        };
        assert_eq!(failure.error.code, -32602);
    }

    #[test]
    fn semantic_actions_report_the_semantic_rung_and_never_take_focus() {
        let backend = backend(vec![], Some("before"));
        let handle = backend.snapshot.handle(0);
        let focuses = backend.focuses.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        for (method, params) in [
            ("invoke", json!({"target": handle.0, "name": "Invoke"})),
            ("type", json!({"target": handle.0, "value": "after"})),
            ("scroll", json!({"target": handle.0, "deltaY": -120.0})),
        ] {
            let response = router.request(request(method, params)).unwrap();
            let JsonRpcResponse::Success(success) = response else {
                panic!("{method} is semantic and always allowed")
            };
            assert_eq!(success.result["delivery"], json!("semantic"), "{method}");
            assert_eq!(success.result["dispatchSuccess"], json!(true), "{method}");
            assert_eq!(success.result["refusal"], Value::Null, "{method}");
            assert_eq!(
                success.result["deliveryPolicy"],
                json!("backgroundOnly"),
                "{method}"
            );
        }
        // Focus is a system-wide side effect, so a semantic path must never take it.
        assert_eq!(*focuses.borrow(), 0);
    }

    #[test]
    fn an_unknown_policy_fails_before_resolution_or_dispatch() {
        let backend = backend(vec![], None);
        let handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let focuses = backend.focuses.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        for method in ["click", "type", "keyboard", "scroll", "invoke", "drag"] {
            let response = router
                .request(request(
                    method,
                    json!({
                        "target": handle.0,
                        "name": "Invoke",
                        "value": "x",
                        "text": "x",
                        "deliveryPolicy": "whateverItTakes"
                    }),
                ))
                .unwrap();
            let JsonRpcResponse::Failure(failure) = response else {
                panic!("{method} must reject an unknown policy")
            };
            assert_eq!(failure.error.code, -32602, "{method}");
            assert!(
                failure.error.message.contains("deliveryPolicy"),
                "{method}: {}",
                failure.error.message
            );
        }
        assert_eq!(*clicks.borrow(), 0);
        assert_eq!(*focuses.borrow(), 0);
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
                "invoke",
                json!({"target":{"app":"App","locator":{"role":"Button"}},"name":"Invoke"}),
            ))
            .unwrap();
        let JsonRpcResponse::Failure(error) = response else {
            panic!()
        };
        assert!(error.error.message.contains("Ambiguous"));
        assert_eq!(*router.backend.clicks.borrow(), 0);
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
    name: Invoke
    expects:
      - id: ready
        kind: value
        target: {handle}
        contains: ready
  - tool: invoke
    target: {handle}
    name: Invoke
    name: Invoke
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
