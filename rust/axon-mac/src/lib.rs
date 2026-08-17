//! macOS Accessibility backend and v1 JSON-RPC tool router.

use axon_core::{
    AppQuery, AxnRunner, Capability, DeliveryCandidate, DeliveryCapability, DeliveryOutcome,
    DeliveryPolicy, DeliveryRefusal, DeliveryRefusalReason, DeliveryRung, DeliverySelection,
    DiffPolicy, DispatchOutcome, ExpectedFact, ForegroundTarget, JsonRpcError, JsonRpcId,
    JsonRpcRequest, JsonRpcResponse, KeyboardIntent, PlatformBackend, PointerContract,
    ResolutionStatus, RunEnvelope, SemanticElementName, SemanticLookup, SemanticNameRegistry,
    SemanticSelection, SinceToken, Snapshot, SnapshotHandle, TextLocationResolver,
    TextLocationSource, TextLocationTarget, TextRecognitionProvider, ToolDispatcher,
    classify_semantic_diff, dispatch_in_foreground, goal_success, look_since_response, prepare_run,
    select_delivery,
};
use serde_json::{Map, Value, json};
use std::{
    collections::HashMap,
    thread,
    time::{Duration, Instant},
};

#[cfg(target_os = "macos")]
pub mod socket;

#[cfg(target_os = "macos")]
mod platform;
#[cfg(target_os = "macos")]
mod global_input;
#[cfg(target_os = "macos")]
pub use platform::MacBackend;

/// Tools this backend does not implement at all. These are not delivery decisions: the request
/// names something the macOS daemon has no code path for, which stays a JSON-RPC error.
const EXCLUDED: &[(&str, &str)] = &[
    ("save", "SerializeHistory"),
    ("drag", "PointerDrag"),
    ("permit", "PermissionPrompt"),
    ("navigate", "BrowserScripting"),
    ("windows", "BrowserScripting"),
    ("tabs", "BrowserScripting"),
    ("debug.create", "DebugSession"),
    ("debug.start", "DebugSession"),
    ("debug.step", "DebugSession"),
    ("debug.retry", "DebugSession"),
    ("debug.continue", "DebugSession"),
    ("debug.resume", "DebugSession"),
    ("debug.runTo", "DebugSession"),
    ("debug.setBreakpoints", "DebugSession"),
    ("debug.stop", "DebugSession"),
];

/// Pixel delivery is withheld in v1; this mechanism label makes that absence explicit.
const PIXEL_MECHANISM: &str = "unimplemented macOS target-bound input";

/// Why `keyboard` has no pixel rung, and never will in this shape.
///
/// The pixel rung is target-bound input derived from verified window geometry. `keyboard` names an
/// application and an input string; there is no element, so there is no window to bind to and no
/// transform to report. Key delivery gets an honest home as a `type` fallback, below ValuePattern,
/// once the pointer path is proven on real targets.
const NO_KEYBOARD_GEOMETRY: &str = "keyboard input names an application rather than an element, so \
     there is no verified window geometry to bind it to";

/// Why a text location that resolved from screen text alone cannot travel the pixel rung.
const NO_RECOGNIZED_TEXT_GEOMETRY: &str = "this text location resolved from recognized screen text \
     rather than an accessibility element, so there is no ancestry to bind a window to";

/// Why the foreground rung is withheld rather than merely gated behind the opt-in.
///
/// Specific because the specifics are what a caller can act on, and what tells the next person
/// which part of the transaction still needs work.
const NO_FOREGROUND_TRANSACTION: &str = "this backend cannot capture the foreground, activate the \
     requested target, and prove that activation before dispatch";

pub struct Router<B> {
    backend: B,
    snapshot: Option<Snapshot>,
    semantic_names: SemanticNameRegistry,
    observations: HashMap<String, (Snapshot, Vec<SemanticElementName>)>,
    observation_sequence: u64,
    observation_redaction: axon_core::ObservationRedactionContext,
}

fn visual_observation_result(
    result: Result<VisualObservation, axon_core::BackendError>,
    wants_screenshot: bool,
    wants_screen_text: bool,
) -> (
    Option<VisualObservation>,
    Option<axon_core::ScreenshotUnavailable>,
    Option<Value>,
) {
    match result {
        Ok(visuals) => (Some(visuals), None, None),
        Err(error) if wants_screen_text => {
            let reason = error.to_string();
            (
                None,
                wants_screenshot
                    .then(|| axon_core::ScreenshotUnavailable::from_backend_error(error)),
                Some(json!({"code":"ocr-failed","reason":reason})),
            )
        }
        Err(error) if wants_screenshot => (
            None,
            Some(axon_core::ScreenshotUnavailable::from_backend_error(error)),
            None,
        ),
        Err(_) => (None, None, None),
    }
}

fn observation_object(
    value: &mut Value,
    format: axon_core::LookFormat,
) -> Option<&mut Map<String, Value>> {
    if format == axon_core::LookFormat::Debug {
        value.get_mut("observation").and_then(Value::as_object_mut)
    } else {
        value.as_object_mut()
    }
}

fn application_enumeration<T: serde::Serialize>(apps: Vec<T>) -> Value {
    json!({"apps": apps})
}

/// Replay targets may carry recording-only locator evidence. Native tool decoding receives only
/// the primitive semantic target; the shared runner remains responsible for registering the
/// attached locator before crossing this boundary.
fn attach_target_resolution(result: &mut Value, resolution: &axon_core::TargetResolution) {
    let Some(object) = result.as_object_mut() else {
        return;
    };
    object.remove("resolution");
    object.insert(
        "targetResolution".into(),
        serde_json::to_value(resolution).expect("target resolution serializes"),
    );
}

fn primitive_dispatch_params(params: &Map<String, Value>) -> Map<String, Value> {
    let mut params = params.clone();
    for key in ["target", "from", "to"] {
        let Some(Value::Object(target)) = params.get_mut(key) else {
            continue;
        };
        if target.get("app").and_then(Value::as_str).is_some()
            && target.get("name").and_then(Value::as_str).is_some()
        {
            target.retain(|field, _| field == "app" || field == "name");
        }
    }

    params
}
pub trait ReadableStateProvider {
    fn readable_state(
        &self,
        target: &SnapshotHandle,
    ) -> Result<Map<String, Value>, axon_core::BackendError>;
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

/// A target-bound pointer mechanism: input delivered to one verified window, without activating
/// the application and without moving the real pointer.
///
/// This is the pixel rung's whole contract expressed as a seam. The router that decides *when* to
/// use it is platform-neutral and testable anywhere; the mechanism behind it is Win32 and is not.
pub trait BackgroundPixelPointer: PlatformBackend {
    /// Resolves a delivery plan for one click. Pure inspection with no native side effect, because
    /// the planner may discard the result and refuse before anything is allowed to happen.
    fn plan_pixel_click(
        &mut self,
        handle: &SnapshotHandle,
        point: (f64, f64),
    ) -> Result<PixelPlan, axon_core::BackendError>;

    /// Revalidates the plan and dispatches it. A revalidation failure returns `Stale` and must
    /// post nothing: a window that moved or an ancestry that broke between planning and dispatch
    /// means the recorded coordinates now name somewhere else.
    fn dispatch_pixel_click(
        &mut self,
        target: &PixelTarget,
    ) -> Result<PixelDispatch, PixelDispatchError>;
}

/// Whether a target-bound mechanism exists for one specific click.
#[derive(Clone, Debug, PartialEq)]
pub enum PixelPlan {
    Bound(PixelTarget),
    /// No target-bound mechanism here. `reason` names the specific obstacle, because a caller who
    /// is told only "unsupported" cannot tell an elevated window from an unknown control class.
    Unavailable {
        reason: String,
        /// Whether the obstacle stops *any* synthetic input at this target rather than only the
        /// target-bound rung.
        ///
        /// An integrity boundary is the case that matters: UIPI discards posted messages and
        /// `SendInput` alike from a lower-integrity process, and `SetForegroundWindow` fails the
        /// same way. Leaving the foreground candidate available there would answer an elevated
        /// target with "opt in to foreground delivery", and the opt-in would buy a dispatch
        /// macOS silently drops — dressed up as a successful one. The obstacle has to be named
        /// at both rungs or it is not really being refused.
        blocks_global_input: bool,
    },
}

impl PixelPlan {
    /// No target-bound mechanism, but the obstacle is specific to this rung: a louder one may
    /// still carry the action.
    pub fn unavailable(reason: impl Into<String>) -> Self {
        PixelPlan::Unavailable {
            reason: reason.into(),
            blocks_global_input: false,
        }
    }

    /// No mechanism at all, at any rung, for the reason given.
    pub fn blocked(reason: impl Into<String>) -> Self {
        PixelPlan::Unavailable {
            reason: reason.into(),
            blocks_global_input: true,
        }
    }
}

/// One window, bound to one element, with the coordinate transform that reaches it.
#[derive(Clone, Debug, PartialEq)]
pub struct PixelTarget {
    /// The element this plan is bound to. Dispatch re-checks it, because a window that is still
    /// exactly where it was can still be showing something else by then.
    pub handle: SnapshotHandle,
    /// The leaf window that receives the messages.
    pub window: u64,
    pub window_class: String,
    /// How the target declares its DPI awareness. Reported so a probe run can distinguish a
    /// reconciliation that ran from one that was a no-op, which is what tells an allowlist entry
    /// earned at 100% scaling from one earned where the transform actually had work to do.
    pub dpi_awareness: &'static str,
    /// The top-level window the UIA ancestry bound this to. Revalidated before dispatch, so a leaf
    /// that has been reparented out of the captured window cannot be clicked.
    pub root_window: u64,
    pub process_identifier: i64,
    pub screen_point: (f64, f64),
    /// The window's client origin in screen coordinates: the transform itself, kept so it can be
    /// both revalidated and reported.
    pub client_origin: (f64, f64),
    pub client_point: (f64, f64),
}

impl PixelTarget {
    /// The transform reported as evidence rather than implied.
    ///
    /// A dispatch that landed in the wrong window is only diagnosable after the fact if the window
    /// it went to and the arithmetic that chose the point are both on the wire.
    pub fn evidence(&self) -> Value {
        json!({
            "nativeWindowHandle": format!("0x{:08X}", self.window),
            "windowClass": self.window_class,
            "rootNativeWindowHandle": format!("0x{:08X}", self.root_window),
            "dpiAwareness": self.dpi_awareness,
            "clientOrigin": {"x": self.client_origin.0, "y": self.client_origin.1},
            "windowPoint": {"x": self.client_point.0, "y": self.client_point.1},
            "sourceCoordinateSpace": "screen",
        })
    }
}

/// What a delivered sequence did, and the evidence that it stayed in the background.
#[derive(Clone, Debug, PartialEq)]
pub struct PixelDispatch {
    /// Whether the target processed the whole sequence.
    ///
    /// Processed, not effective. A window procedure that examines a click and does nothing returns
    /// from it exactly like one that acts on it, so this is dispatch evidence and goal success
    /// still needs a readback or a declared postcondition.
    pub complete: bool,
    /// Set when part of the sequence landed and the rest did not, naming the state the target was
    /// left in. A partial dispatch never escalates: the target may already consider the button
    /// held, and a second attempt at another rung would compound it.
    pub partial: Option<String>,
    /// Observed across the delivery, which is only meaningful because the delivery has an explicit
    /// end: the backend does not report these until the target's window procedure has processed
    /// every message. A handler that activates its application or moves the cursor is inside the
    /// window these two comparisons straddle.
    pub frontmost_unchanged: bool,
    pub pointer_unchanged: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PixelDispatchError {
    /// Revalidation failed between planning and dispatch. Nothing was posted.
    Stale(String),
    Backend(axon_core::BackendError),
}

/// What a click resolved to, and therefore what can be bound and verified before it is delivered.
///
/// The distinction is load-bearing rather than cosmetic: only an element carries the accessibility
/// ancestry a pixel plan is built from, so a point recovered from screen text has no window to
/// bind to however precise the point itself is.
enum ClickTarget {
    Element(SnapshotHandle),
    /// A point inside a frame of recognized screen text, with no element behind it.
    Recognized(AppQuery, axon_core::Rect),
}

impl<
    B: PointerTargetVerifier
        + TextRecognitionProvider
        + VisualObservationProvider
        + ReadableStateProvider
        + BackgroundPixelPointer,
> Router<B>
{
    /// What the backend can do, for health documents.
    ///
    /// The backend is otherwise private to the router; health is the one caller that needs to ask
    /// it a question rather than dispatch a tool through it.
    pub fn capabilities(&self) -> Result<Vec<axon_core::CapabilityInfo>, axon_core::BackendError> {
        self.backend.capabilities()
    }

    pub fn new(backend: B) -> Self {
        Self {
            backend,
            snapshot: None,
            semantic_names: SemanticNameRegistry::default(),
            observations: HashMap::new(),
            observation_sequence: 0,
            observation_redaction: Default::default(),
        }
    }
    fn register_snapshot(&mut self, snapshot: &Snapshot) -> Vec<axon_core::SemanticElementName> {
        let live_processes = self.backend.live_process_ids().ok();
        self.semantic_names.register_with_liveness(snapshot, |pid| {
            live_processes
                .as_ref()
                .is_none_or(|processes| processes.contains(&pid))
        })
    }

    fn click_text_location(
        &mut self,
        value: &Value,
        policy: DeliveryPolicy,
    ) -> Result<Value, JsonRpcError> {
        let target: TextLocationTarget = serde_json::from_value(value.clone())
            .map_err(|error| rpc_error(-32602, error.to_string()))?;
        if target.app.is_empty() {
            return Err(rpc_error(-32602, "location app must not be empty"));
        }
        let app = AppQuery {
            process_id: None,
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
        let click_target = match &candidate.handle {
            Some(handle) => ClickTarget::Element(handle.clone()),
            None => ClickTarget::Recognized(app.clone(), candidate.frame),
        };
        // The snapshot becomes the router's before the ladder runs, so foreground delivery recovers
        // the same canonical identity a handle click does. Handing the caller's raw app string to
        // the transaction instead would compare a display name against whatever identity the
        // backend reports for the foreground window, and the two can never match.
        self.snapshot = Some(snapshot);
        // A resolved text location is a click like any other. It travels the same ladder and the
        // same transaction; a separate path here is how a caller ends up with global pointer input
        // under a policy that forbids it.
        self.deliver_click(policy, click_target, point, json!(resolution))
    }

    /// One click, whatever resolved it, travelling the whole ladder exactly once.
    fn deliver_click(
        &mut self,
        policy: DeliveryPolicy,
        target: ClickTarget,
        point: (f64, f64),
        resolution: Value,
    ) -> Result<Value, JsonRpcError> {
        let mut result = self.select_and_deliver_click(policy, target, point)?;
        if let (Some(object), false) = (result.as_object_mut(), resolution.is_null()) {
            object.insert("resolution".into(), resolution);
        }
        Ok(result)
    }

    fn select_and_deliver_click(
        &mut self,
        policy: DeliveryPolicy,
        target: ClickTarget,
        point: (f64, f64),
    ) -> Result<Value, JsonRpcError> {
        // Planning is pure inspection, so it is safe before the ladder decides. The planner may
        // discard this plan and refuse, and by then nothing native may have happened.
        let plan = match &target {
            ClickTarget::Element(handle) => self
                .backend
                .plan_pixel_click(handle, point)
                .map_err(backend_error)?,
            ClickTarget::Recognized(..) => PixelPlan::unavailable(NO_RECOGNIZED_TEXT_GEOMETRY),
        };
        let ladder = self.pointer_ladder(&plan);
        let Some(candidate) = self.selected(&ladder, policy) else {
            return Ok(self.refusal(&ladder, policy));
        };
        // Freshness is checked after selection, so the planner still decides before anything
        // happens, and a target that moved under the request stays a stale-target error rather
        // than becoming a delivery refusal.
        let (fresh, stale) = match &target {
            ClickTarget::Element(handle) => (
                self.backend.verify_pointer_target(handle, point),
                "click target moved, is covered, or no longer matches the resolved element",
            ),
            ClickTarget::Recognized(app, frame) => (
                self.backend.verify_ocr_target(app, point, *frame),
                "click target moved, is covered, or no longer matches the resolved text",
            ),
        };
        if !fresh.map_err(backend_error)? {
            return Err(rpc_error(-32003, stale));
        }
        let verification =
            json!({"verified": false, "reason": "click has no declared postcondition"});
        if candidate.rung == DeliveryRung::Pixel {
            let PixelPlan::Bound(bound) = plan else {
                unreachable!("the pixel rung is only offered for a bound plan")
            };
            return self.dispatch_pixel(
                policy,
                &candidate,
                &bound,
                PointerContract::Asserted,
                verification,
            );
        }
        // Owning-application identity is a foreground concern. Refusing on it while a bound pixel
        // plan was available would decline an action that had a perfectly good target-bound path.
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
            // `SendInput` drives the real cursor, so the transaction puts it back.
            true,
            verification,
            |backend| backend.pointer_click(point),
        )
    }

    /// Posts one bound sequence to one verified window, and reports what that proved.
    /// `pointer` is `Asserted` for every caller here because `click` is the only action with a
    /// pixel rung in this router: `keyboard` binds to an application rather than a window, so it
    /// takes the semantic or foreground path and never reaches this one.
    fn dispatch_pixel(
        &mut self,
        policy: DeliveryPolicy,
        candidate: &DeliveryCandidate,
        target: &PixelTarget,
        pointer: PointerContract,
        verification: Value,
    ) -> Result<Value, JsonRpcError> {
        let dispatch = match self.backend.dispatch_pixel_click(target) {
            Ok(dispatch) => dispatch,
            // Revalidation failed, so nothing was posted and the plan now names somewhere else.
            // That is the same stale target a moved element produces, and it reads the same way.
            Err(PixelDispatchError::Stale(reason)) => return Err(rpc_error(-32003, reason)),
            Err(PixelDispatchError::Backend(error)) => return Err(backend_error(error)),
        };
        // This rung is defined by what it does not do. A dispatch that changed the foreground or
        // moved the real pointer was not background delivery, whatever it managed to deliver.
        let mut problems = Vec::new();
        if let Some(partial) = &dispatch.partial {
            problems.push(partial.clone());
        }
        if !dispatch.frontmost_unchanged {
            problems.push("the foreground window changed across the dispatch".to_string());
        }
        if pointer.is_asserted() && !dispatch.pointer_unchanged {
            problems.push("the real pointer moved across the dispatch".to_string());
        }
        // Mechanism acceptance and goal success are kept apart because at this rung the gap between
        // them is the whole problem. A completed post proves each message was accepted and returned
        // from; a window procedure that examined one and did nothing returns exactly like one that
        // acted on it, which is the stated reason `PIXEL_MESSAGE_CLASSES` exists at all. Collapsing
        // the two would hollow out that table's own defence: a class that regressed, or one that
        // behaved differently in a context nobody probed, would produce an accepted post, intact
        // invariants, and a report that the caller's click had worked.
        let mut result = json!({
            "success": goal_success(&verification, dispatch.complete && problems.is_empty()),
            "dispatch": {"success": dispatch.complete, "mechanism": candidate.mechanism},
            "verification": verification,
            "backgroundDelivery": {
                "targetProcessIdentifier": target.process_identifier,
                "frontmostAppUnchanged": dispatch.frontmost_unchanged,
                "pointerUnchanged": dispatch.pointer_unchanged,
                // Whether that reading is a promise this dispatch made or an observation of the
                // desktop it ran on.
                "pointerAsserted": pointer.is_asserted(),
            },
            "targetWindow": target.evidence(),
        });
        let object = result
            .as_object_mut()
            .expect("a JSON object literal is an object");
        if !problems.is_empty() {
            object.insert("message".into(), json!(problems.join("; ")));
        }
        DeliveryOutcome {
            policy,
            delivery: Some(DeliveryRung::Pixel),
            dispatch_success: dispatch.complete,
            refusal: None,
        }
        .merge_into(object);
        Ok(result)
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
            return Err(capability_unavailable(
                method,
                capability,
                "not-implemented",
            ));
        }
        // The policy is decoded before the target is resolved and before any backend call, so an
        // unknown value can never reach a native API.
        let policy =
            DeliveryPolicy::from_params(params).map_err(|error| rpc_error(-32602, error))?;
        match method {
            "look" => self.look(params),
            "wait_for_value" => self.wait_for_value(params),
            "wait_for_stability" => self.wait_for_stability(params),
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
                    return self.click_text_location(&location.clone(), policy);
                }
                if params.get("target").is_some_and(pointer_target_is_point) {
                    return Err(capability_unavailable(
                        "click",
                        "point-target",
                        "not-implemented",
                    ));
                }
                let (handle, resolution) = self.resolve(params)?;
                self.backend
                    .invoke(&handle, "AXPress")
                    .map_err(backend_error)?;
                Ok(delivered(
                    json!({"dispatch":{"success":true,"mechanism":"AXPress"},"verification":{"verified":false,"reason":"click has no declared postcondition"},"resolution":resolution}),
                    policy,
                    DeliveryRung::Semantic,
                ))
            }
            "type" => {
                let value = required_str(params, "value")?;
                let (handle, resolution) = self.resolve(params)?;
                // AXValue is target-bound and does not require global keyboard input.
                self.backend
                    .set_value(&handle, value)
                    .map_err(backend_error)?;
                let observed = self.backend.read_value(&handle).map_err(backend_error)?;
                Ok(delivered(
                    json!({"dispatch":{"success":true,"mechanism":"AXValue"},"verification":{"verified":observed.as_deref()==Some(value),"observed":observed},"resolution":resolution}),
                    policy,
                    DeliveryRung::Semantic,
                ))
            }
            "keyboard" => {
                // The intent is validated before the ladder, so a malformed request is an error
                // rather than a refusal.
                let intent = keyboard_intent(params)?;
                let ladder = self.keyboard_ladder();
                let Some(candidate) = self.selected(&ladder, policy) else {
                    return Ok(self.refusal(&ladder, policy));
                };
                let app = app_query(params);
                // `keyboard` naming no application is explicitly addressed at whatever holds the
                // foreground: nothing to activate, nothing to restore. Naming one makes it aimed,
                // and the transaction compares and activates the backend's own identity for that
                // application rather than the display name the request carried.
                let aimed = app.name.is_some() || app.identifier.is_some();
                let target = if aimed {
                    match self
                        .backend
                        .resolve_application(&app)
                        .map_err(backend_error)?
                    {
                        Some(identity) => Some(identity),
                        // Falling through to the frontmost here would post keystrokes into whatever
                        // the user happens to be working in, having been asked for something else.
                        None => {
                            return Ok(DeliveryOutcome::refusal_result(
                                policy,
                                DeliveryRefusal::new(
                                    DeliveryRefusalReason::TargetIdentityUnavailable,
                                    DeliveryRung::Foreground,
                                    Some(DeliveryCapability::GlobalInput),
                                    "the requested application could not be identified, so \
                                     foreground delivery cannot activate and prove it",
                                ),
                            ));
                        }
                    }
                } else {
                    None
                };
                self.foreground_dispatch(
                    policy,
                    &candidate,
                    target
                        .as_deref()
                        .map_or(ForegroundTarget::Frontmost, ForegroundTarget::Application),
                    // Keyboard input never touches the cursor, and capturing a pointer it does not
                    // move would report a restoration that never happened.
                    false,
                    json!({"verified":false,"reason":"keyboard input has no declared postcondition"}),
                    move |backend| backend.keyboard(&app, intent),
                )
            }
            "invoke" => {
                let action = required_str(params, "name")?;
                let (handle, resolution) = self.resolve(params)?;
                self.backend
                    .invoke(&handle, action)
                    .map_err(backend_error)?;
                Ok(delivered(
                    json!({"dispatch":{"success":true,"mechanism":"AX action"},"verification":{"verified":false,"reason":"invoke has no declared postcondition"},"resolution":resolution}),
                    policy,
                    DeliveryRung::Semantic,
                ))
            }
            "scroll" => {
                // These defaults mirror the generated public schema. Any amount or directional
                // request is unsupported by AXScrollToVisible and must be refused before target
                // resolution can capture an application or call another native API.
                let dx = number_param(params, "deltaX", 0.0)?;
                let dy = number_param(params, "deltaY", -120.0)?;
                if dx != 0.0 || dy != 0.0 {
                    return Err(capability_unavailable(
                        "scroll",
                        "directional-scroll",
                        "not-implemented",
                    ));
                }
                let Some(target) = params.get("target") else {
                    return Err(capability_unavailable(
                        "scroll",
                        "semantic-target",
                        "not-implemented",
                    ));
                };
                if pointer_target_is_point(target) || target.get("location").is_some() {
                    return Err(capability_unavailable(
                        "scroll",
                        "non-semantic-target",
                        "not-implemented",
                    ));
                }
                let (handle, resolution) = self.resolve(params)?;
                self.backend
                    .scroll(&handle, (dx, dy))
                    .map_err(backend_error)?;
                Ok(delivered(
                    json!({"dispatch":{"success":true,"mechanism":"AXScrollToVisible"},"verification":{"verified":false,"reason":"scroll has no declared postcondition"},"resolution":resolution}),
                    policy,
                    DeliveryRung::Semantic,
                ))
            }
            "run" => self.run_axn(params),
            _ => Err(rpc_error(-32601, format!("unknown method {method}"))),
        }
    }

    /// The ladder for a pointer action: no semantic rung, a pixel rung the backend answers for per
    /// target, and `SendInput` behind the explicit opt-in.
    fn pointer_ladder(&self, plan: &PixelPlan) -> Vec<DeliveryCandidate> {
        vec![
            match plan {
                PixelPlan::Bound(_) => DeliveryCandidate::available(
                    DeliveryRung::Pixel,
                    DeliveryCapability::BackgroundPixelInput,
                    PIXEL_MECHANISM,
                ),
                // The plan's own reason travels intact. A generic "unsupported" here would leave a
                // caller unable to tell an elevated window from an unrecognized control class.
                PixelPlan::Unavailable { reason, .. } => DeliveryCandidate::unavailable(
                    DeliveryRung::Pixel,
                    DeliveryCapability::BackgroundPixelInput,
                    PIXEL_MECHANISM,
                    DeliveryRefusalReason::BackgroundPixelUnsupported,
                    reason.clone(),
                ),
            },
            match plan {
                // An obstacle that blocks every synthetic input at this target blocks the loud
                // rung too, and saying so is what stops the refusal from recommending an opt-in
                // that would buy a dispatch macOS discards.
                PixelPlan::Unavailable {
                    reason,
                    blocks_global_input: true,
                } => DeliveryCandidate::unavailable(
                    DeliveryRung::Foreground,
                    DeliveryCapability::GlobalInput,
                    "SendInput",
                    DeliveryRefusalReason::NoDeliveryCandidate,
                    reason.clone(),
                ),
                _ => self.foreground_candidate(Capability::PointerInput, "SendInput"),
            },
        ]
    }

    /// The ladder for keyboard input, whose pixel rung is permanently absent by construction.
    fn keyboard_ladder(&self) -> Vec<DeliveryCandidate> {
        vec![
            DeliveryCandidate::unavailable(
                DeliveryRung::Pixel,
                DeliveryCapability::BackgroundPixelInput,
                PIXEL_MECHANISM,
                DeliveryRefusalReason::BackgroundPixelUnsupported,
                NO_KEYBOARD_GEOMETRY,
            ),
            self.foreground_candidate(Capability::KeyboardInput, "SendInput"),
        ]
    }

    fn foreground_candidate(&self, capability: Capability, mechanism: &str) -> DeliveryCandidate {
        match self
            .capability_restriction(capability)
            .or_else(|| self.foreground_transaction_restriction())
        {
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
        }
    }

    /// The health-v1 runtime overlay, consulted by the same decision that dispatches. Session 0, a
    /// noninteractive window station, and an integrity boundary all arrive here as a restriction.
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

    /// The foreground rung requires a backend to capture the foreground, activate the target, and
    /// prove that activation before dispatch. The hand-back is always attempted and reported, but
    /// a backend that cannot provide the activation proof does not get to offer this rung.
    fn foreground_transaction_restriction(&self) -> Option<String> {
        if self.backend.supports_foreground_transaction() {
            return None;
        }
        Some(NO_FOREGROUND_TRANSACTION.to_string())
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
        if let Err(error) = dispatch.value.expect("a proved activation dispatches") {
            // The transaction activated and then handed the session back around this failure, so
            // its cleanup evidence is the only record of what happened to the user's foreground.
            // It rides on the error rather than being dropped.
            let mut failure = backend_error(error);
            failure.data = Some(json!({ "foreground": dispatch.cleanup }));
            return Err(failure);
        }

        let result = json!({
            // This rung promises proved activation and exactly one dispatch. The hand-back remains
            // reported cleanup evidence, while verification proves whether the target acted.
            "success": goal_success(&verification, dispatch.cleanup.activation_proved),
            "dispatch": {"success": true, "mechanism": candidate.mechanism},
            "verification": verification,
            "foreground": dispatch.cleanup,
        });
        Ok(delivered(result, policy, candidate.rung))
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
        let request = axon_core::LookRequest::decode(params)
            .map_err(|error| rpc_error(-32602, error.to_string()))?;
        if let axon_core::LookMode::ChildPage {
            target,
            offset,
            limit,
            direct,
        } = &request.mode
        {
            let context = match self.semantic_names.select(target) {
                SemanticSelection::Selected(context) => context,
                SemanticSelection::Missing { target } => {
                    return Err(JsonRpcError {
                        code: -32002,
                        message: format!(
                            "semantic name not found: {} / {}",
                            target.app, target.name
                        ),
                        data: Some(json!({"status":"missing","query":target})),
                    });
                }
                SemanticSelection::Ambiguous { target, candidates } => {
                    return Err(JsonRpcError {
                        code: -32002,
                        message: format!(
                            "semantic name is ambiguous: {} / {}",
                            target.app, target.name
                        ),
                        data: Some(
                            json!({"status":"ambiguous","query":target,"candidates":candidates}),
                        ),
                    });
                }
            };
            let handle = context
                .recorded_handle()
                .ok_or_else(|| {
                    rpc_error(
                        -32002,
                        "semantic target has no live retained capture; call look for its app first",
                    )
                })?
                .clone();
            let page = self
                .backend
                .capture_child_page(
                    &handle,
                    axon_core::ChildPageRequest {
                        offset: *offset,
                        limit: *limit,
                        include_descendants: !*direct,
                    },
                )
                .map_err(backend_error)?;
            let mut parent = page.parent.clone();
            parent.children = page.children.clone();
            let snapshot = Snapshot {
                id: page.snapshot.clone(),
                app: axon_core::Application {
                    name: target.app.clone(),
                    process_id: context.process_id(),
                    identifier: None,
                    windows: vec![axon_core::Window {
                        title: None,
                        root: parent,
                    }],
                },
            };
            let names = self.register_snapshot(&snapshot);
            let rendered = axon_core::render_semantic_names(&snapshot, &names);
            self.snapshot = Some(snapshot);
            return Ok(json!({
                "children": axon_core::format_child_page(
                    &page,
                    target,
                    &rendered,
                    &request.display,
                )
            }));
        }
        if let axon_core::LookMode::AppList { all } = &request.mode {
            if *all {
                return Err(rpc_error(
                    -32602,
                    "all-process application listing is unavailable on this backend",
                ));
            }
            return Ok(application_enumeration(
                self.backend
                    .enumerate_applications()
                    .map_err(backend_error)?,
            ));
        }
        let (app, child_depth) = match &request.mode {
            axon_core::LookMode::FullApp { app, child_depth }
            | axon_core::LookMode::ChangeCheck {
                app, child_depth, ..
            } => (app.clone(), *child_depth),
            _ => unreachable!(),
        };
        let snapshot = self
            .backend
            .capture_bounded(&app, axon_core::CaptureBounds { child_depth })
            .map_err(backend_error)?;
        let names = self.register_snapshot(&snapshot);
        self.observation_sequence += 1;
        let app_identity = snapshot
            .app
            .identifier
            .as_deref()
            .unwrap_or(&snapshot.app.name);
        let next_since = SinceToken::new(app_identity, &snapshot.id, self.observation_sequence);
        if let Some(raw_since) = params.get("since").and_then(Value::as_str) {
            let requested = SinceToken::parse(raw_since)
                .map_err(|error| rpc_error(-32602, error.to_string()))?;
            let comparison = self
                .observations
                .get(requested.as_str())
                .map(|(baseline, baseline_names)| {
                    classify_semantic_diff(
                        baseline,
                        baseline_names,
                        &snapshot,
                        &names,
                        DiffPolicy::default(),
                    )
                })
                .transpose()
                .map_err(|error| rpc_error(-32603, error.to_string()))?;
            let result = look_since_response(
                snapshot.app.name.clone(),
                snapshot.clone(),
                next_since.clone(),
                comparison,
            );
            self.observations
                .insert(next_since.as_str().into(), (snapshot.clone(), names));
            self.snapshot = Some(snapshot);
            return serde_json::to_value(result).map_err(internal_error);
        }
        let rendered = axon_core::render_semantic_names(&snapshot, &names);
        let mut value = axon_core::format_snapshot(&rendered, &request.display);
        let wants_screenshot = axon_core::screenshot_requested(
            request.screenshot,
            axon_core::LookObservationKind::FullApp,
        );
        let wants_screen_text = request.screen_text;
        let (visuals, screenshot_unavailable, screen_text_unavailable) =
            if wants_screenshot || wants_screen_text {
                visual_observation_result(
                    self.backend
                        .observe_visuals(&app, wants_screenshot, wants_screen_text),
                    wants_screenshot,
                    wants_screen_text,
                )
            } else {
                (None, None, None)
            };
        if let Some(screenshot) = visuals
            .as_ref()
            .and_then(|result| result.screenshot.as_ref())
        {
            observation_object(&mut value, request.display.format)
                .expect("snapshots serialize as objects")
                .insert(
                    "screenshot".into(),
                    json!({
                        "mediaType": screenshot.media_type,
                        "base64Data": base64::Engine::encode(
                            &base64::engine::general_purpose::STANDARD,
                            &screenshot.bytes
                        ),
                        "width": screenshot.width,
                        "height": screenshot.height
                    }),
                );
        }
        if let Some(screen_text) = visuals.and_then(|result| result.recognized_text) {
            observation_object(&mut value, request.display.format)
                .expect("snapshots serialize as objects")
                .insert(
                    "screenText".into(),
                    axon_core::format_screen_text(
                        &screen_text,
                        request.display.frames,
                        &self.observation_redaction,
                    ),
                );
        }
        if let Some(unavailable) = screenshot_unavailable {
            observation_object(&mut value, request.display.format)
                .expect("snapshots serialize as objects")
                .insert(
                    "screenshotUnavailable".into(),
                    serde_json::to_value(unavailable).map_err(internal_error)?,
                );
        }
        if let Some(unavailable) = screen_text_unavailable {
            observation_object(&mut value, request.display.format)
                .expect("snapshots serialize as objects")
                .insert("screenTextUnavailable".into(), unavailable);
        }
        observation_object(&mut value, request.display.format)
            .expect("snapshots serialize as objects")
            .insert("since".into(), json!(next_since));
        self.observations
            .insert(next_since.as_str().into(), (snapshot.clone(), names));
        self.snapshot = Some(snapshot);
        Ok(value)
    }

    fn wait_for_value(&mut self, params: &Map<String, Value>) -> Result<Value, JsonRpcError> {
        let predicates = ["contains", "equals", "matches"]
            .into_iter()
            .filter_map(|key| {
                params
                    .get(key)
                    .and_then(Value::as_str)
                    .map(|value| (key, value))
            })
            .collect::<Vec<_>>();
        if predicates.len() != 1 || predicates[0].1.is_empty() {
            return Err(rpc_error(
                -32602,
                "wait_for_value requires exactly one non-empty contains, equals, or matches predicate",
            ));
        }
        let (predicate_kind, predicate_value) = predicates[0];
        let regex = (predicate_kind == "matches")
            .then(|| {
                regex::Regex::new(predicate_value)
                    .map_err(|error| rpc_error(-32602, error.to_string()))
            })
            .transpose()?;
        let predicate = json!({predicate_kind: predicate_value});
        let timeout = bounded_ms(params, "timeoutMs", 5_000, 0, 60_000)?;
        let interval = bounded_ms(
            params,
            "intervalMs",
            100,
            10,
            timeout.as_millis().max(100) as u64,
        )?;
        let started = Instant::now();
        let mut last_observed = None;
        let mut last_resolution = None;
        loop {
            match self.resolve(params) {
                Ok((handle, resolution)) => {
                    last_resolution = Some(resolution.clone());
                    let observed = self
                        .backend
                        .readable_state(&handle)
                        .map_err(backend_error)?;
                    last_observed = Some(observed.clone());
                    let matched = ["value", "title", "description", "identifier", "help"]
                        .into_iter()
                        .find_map(|field| {
                            observed
                                .get(field)
                                .and_then(Value::as_str)
                                .filter(|value| match predicate_kind {
                                    "equals" => *value == predicate_value,
                                    "contains" => value
                                        .to_lowercase()
                                        .contains(&predicate_value.to_lowercase()),
                                    "matches" => {
                                        regex.as_ref().is_some_and(|regex| regex.is_match(value))
                                    }
                                    _ => false,
                                })
                                .map(|value| json!({"field":field,"value":value}))
                        });
                    if let Some(matched) = matched {
                        return Ok(
                            json!({"wait":{"success":true,"status":"satisfied","predicate":predicate,"elapsedMs":started.elapsed().as_millis(),"matched":matched,"lastObserved":observed,"resolution":resolution,"message":"wait_for_value predicate satisfied"}}),
                        );
                    }
                }
                Err(error) if error.code == -32002 => {}
                Err(error) => return Err(error),
            }
            if started.elapsed() >= timeout {
                let status = if last_observed
                    .as_ref()
                    .is_some_and(|state| !state.is_empty())
                {
                    "predicate_timeout"
                } else {
                    "target_unresolved_timeout"
                };
                return Ok(
                    json!({"wait":{"success":false,"status":status,"predicate":predicate,"elapsedMs":started.elapsed().as_millis(),"matched":null,"lastObserved":last_observed,"resolution":last_resolution,"message":if status == "predicate_timeout" {"wait_for_value timed out before the predicate matched"} else {"wait_for_value timed out before the target resolved uniquely"}}}),
                );
            }
            thread::sleep(interval.min(timeout.saturating_sub(started.elapsed())));
        }
    }

    fn wait_for_stability(&mut self, params: &Map<String, Value>) -> Result<Value, JsonRpcError> {
        let app = app_query(params);
        if app.name.is_none() && app.identifier.is_none() {
            return Err(rpc_error(-32602, "wait_for_stability requires app"));
        }
        let timeout = bounded_ms(params, "timeoutMs", 5_000, 0, 60_000)?;
        let interval = bounded_ms(
            params,
            "intervalMs",
            100,
            10,
            timeout.as_millis().max(100) as u64,
        )?;
        let stable_for = bounded_ms(params, "stableMs", 300, 0, 10_000)?;
        let condition = params
            .get("condition")
            .and_then(Value::as_str)
            .unwrap_or("stable");
        if !matches!(condition, "stable" | "changed") {
            return Err(rpc_error(-32602, "condition must be stable or changed"));
        }
        let started = Instant::now();
        let first = self.backend.capture(&app).map_err(backend_error)?;
        let first_names = self.register_snapshot(&first);
        if params
            .get(axon_core::SINGLE_STABILITY_CAPTURE)
            .and_then(Value::as_bool)
            == Some(true)
        {
            return Ok(
                json!({"wait":{"success":false,"status":"polling","condition":condition,"elapsedMs":started.elapsed().as_millis(),"stableMs":0,"snapshot":first}}),
            );
        }
        let mut last = first.clone();
        let mut last_names = first_names.clone();
        let mut stable_since = Instant::now();
        loop {
            let snapshot = self.backend.capture(&app).map_err(backend_error)?;
            let names = self.register_snapshot(&snapshot);
            let changed_from_last = !matches!(
                classify_semantic_diff(
                    &last,
                    &last_names,
                    &snapshot,
                    &names,
                    DiffPolicy::default()
                )
                .map_err(|error| rpc_error(-32603, error.to_string()))?,
                axon_core::DiffClassification::Unchanged
            );
            if changed_from_last {
                last = snapshot.clone();
                last_names = names.clone();
                stable_since = Instant::now();
            }
            let satisfied = if condition == "changed" {
                !matches!(
                    classify_semantic_diff(
                        &first,
                        &first_names,
                        &snapshot,
                        &names,
                        DiffPolicy::default()
                    )
                    .map_err(|error| rpc_error(-32603, error.to_string()))?,
                    axon_core::DiffClassification::Unchanged
                )
            } else {
                stable_since.elapsed() >= stable_for
            };
            if satisfied || started.elapsed() >= timeout {
                return Ok(
                    json!({"wait":{"success":satisfied,"status":if satisfied {"satisfied"} else {"timeout"},"condition":condition,"elapsedMs":started.elapsed().as_millis(),"stableMs":stable_since.elapsed().as_millis(),"snapshot":snapshot}}),
                );
            }
            thread::sleep(interval.min(timeout.saturating_sub(started.elapsed())));
        }
    }

    fn resolve(
        &mut self,
        params: &Map<String, Value>,
    ) -> Result<(SnapshotHandle, axon_core::Resolution), JsonRpcError> {
        let target: axon_core::WireElementTarget =
            serde_json::from_value(params.get("target").cloned().unwrap_or(Value::Null))
                .map_err(|_| rpc_error(-32602, axon_core::SEMANTIC_TARGET_GUIDANCE))?;
        let target = target
            .validate()
            .map_err(|error| rpc_error(-32602, error.to_string()))?;
        let context = match self.semantic_names.select(&target) {
            SemanticSelection::Selected(context) => context,
            SemanticSelection::Missing { target } => {
                return Err(JsonRpcError {
                    code: -32002,
                    message: format!("semantic name not found: {} / {}", target.app, target.name),
                    data: Some(json!({"status":"missing","query":target})),
                });
            }
            SemanticSelection::Ambiguous { target, candidates } => {
                return Err(JsonRpcError {
                    code: -32002,
                    message: format!(
                        "semantic name is ambiguous: {} / {}",
                        target.app, target.name
                    ),
                    data: Some(
                        json!({"status":"ambiguous","query":target,"candidates":candidates}),
                    ),
                });
            }
        };
        let live = self
            .backend
            .capture(&AppQuery {
                process_id: context.process_id(),
                name: context.process_id().is_none().then(|| target.app.clone()),
                identifier: None,
            })
            .map_err(backend_error)?;
        let lookup = context.resolve(&live);
        self.snapshot = Some(live);
        match lookup {
            SemanticLookup::Unique { handle, resolution } => Ok((handle, resolution)),
            SemanticLookup::Missing { target } => Err(JsonRpcError {
                code: -32002,
                message: format!("semantic name not found: {} / {}", target.app, target.name),
                data: Some(json!({"status":"missing","query":target})),
            }),
            SemanticLookup::Ambiguous { target, candidates } => Err(JsonRpcError {
                code: -32002,
                message: format!(
                    "semantic name is ambiguous: {} / {}",
                    target.app, target.name
                ),
                data: Some(json!({"status":"ambiguous","query":target,"candidates":candidates})),
            }),
        }
    }

    fn run_axn(&mut self, params: &Map<String, Value>) -> Result<Value, JsonRpcError> {
        let prepared = prepare_run(params).map_err(|e| rpc_error(-32602, e.to_string()))?;
        let mut runner = AxnRunner::new(self);
        if let Some(healed_path) = prepared.healed_path {
            runner = runner.with_healed_output(prepared.source_path.clone(), healed_path);
        }
        let result = runner
            .run(&prepared.document, &prepared.arg_values, prepared.options)
            .map_err(|e| rpc_error(-32602, e.to_string()))?;
        serde_json::to_value(RunEnvelope { batch: result }).map_err(internal_error)
    }
}

impl<
    B: PointerTargetVerifier
        + TextRecognitionProvider
        + VisualObservationProvider
        + ReadableStateProvider
        + BackgroundPixelPointer,
> ToolDispatcher for Router<B>
{
    fn set_observation_redaction_context(
        &mut self,
        context: axon_core::ObservationRedactionContext,
    ) {
        self.observation_redaction = context;
    }

    fn register_replay_target(
        &mut self,
        app: &str,
        name: &str,
        locator: &axon_core::Locator,
    ) -> Result<(), String> {
        let target = axon_core::WireElementTarget {
            app: app.into(),
            name: name.into(),
        };
        let process_id = match self.semantic_names.select(&target) {
            SemanticSelection::Selected(context) => context.process_id(),
            _ => None,
        };
        self.semantic_names.register_replay_locator_for_process(
            target,
            locator.clone(),
            process_id,
        );
        Ok(())
    }

    fn dispatch(&mut self, tool: &str, params: &Map<String, Value>) -> DispatchOutcome {
        let primitive_params = primitive_dispatch_params(params);
        match self.dispatch_tool(tool, &primitive_params) {
            Ok(mut result) => {
                let dispatched_without_semantic_verification =
                    result.get("dispatchSuccess").and_then(Value::as_bool) == Some(true)
                        && result.get("success").and_then(Value::as_bool) == Some(false);
                let resolution = axon_core::replay_target_resolution(
                    params,
                    &self.semantic_names,
                    self.snapshot.as_ref(),
                );
                if let Some(resolution) = &resolution {
                    attach_target_resolution(&mut result, resolution);
                }
                DispatchOutcome {
                    success: result
                        .get("success")
                        .and_then(Value::as_bool)
                        .unwrap_or(true),
                    dispatched_without_semantic_verification,
                    resolution,
                    result,
                    error: None,
                }
            }
            Err(error) => DispatchOutcome {
                success: false,
                dispatched_without_semantic_verification: false,
                resolution: axon_core::replay_target_resolution(
                    params,
                    &self.semantic_names,
                    self.snapshot.as_ref(),
                ),
                result: Value::Null,
                error: Some(error.message),
            },
        }
    }
    fn verify(&mut self, fact: &ExpectedFact) -> Result<(), String> {
        let (app, locator) = axon_core::expected_fact_target(fact)?;
        let snapshot = self
            .backend
            .capture(&AppQuery {
                process_id: None,
                name: Some(app),
                identifier: None,
            })
            .map_err(|error| error.to_string())?;
        let resolution = axon_core::LocatorResolver::resolve(&locator, &snapshot);
        let candidate = axon_core::unique_expected_fact_candidate(fact, &resolution)?;
        let handle = snapshot.handle(candidate.index);
        let node = snapshot
            .node(candidate.index)
            .ok_or_else(|| format!("fact {} resolved outside snapshot", fact.id))?;
        let mut observed = serde_json::to_value(node)
            .map_err(|error| error.to_string())?
            .as_object()
            .cloned()
            .unwrap_or_default();
        observed.insert("exists".into(), Value::Bool(true));
        if matches!(axon_core::expected_fact_kind(fact)?, "value" | "selected")
            && let Some(value) = self
                .backend
                .read_value(&handle)
                .map_err(|error| error.to_string())?
        {
            observed.insert(
                axon_core::expected_fact_kind(fact)?.into(),
                Value::String(value),
            );
        }
        axon_core::verify_expected_fact_state(fact, &observed)
    }
    fn capture_changed_baseline(&mut self, fact: &ExpectedFact) -> Result<Value, String> {
        let app = axon_core::expected_fact_app(fact)?;
        let snapshot = self
            .backend
            .capture(&AppQuery {
                process_id: None,
                name: Some(app),
                identifier: None,
            })
            .map_err(|error| error.to_string())?;
        axon_core::changed_snapshot_baseline(&snapshot)
    }
}

fn bounded_ms(
    params: &Map<String, Value>,
    key: &str,
    default: u64,
    minimum: u64,
    maximum: u64,
) -> Result<Duration, JsonRpcError> {
    let value = match params.get(key) {
        None | Some(Value::Null) => default,
        Some(Value::Number(number)) => number
            .as_u64()
            .ok_or_else(|| rpc_error(-32602, format!("{key} must be a non-negative integer")))?,
        Some(_) => return Err(rpc_error(-32602, format!("{key} must be an integer"))),
    };
    if value < minimum {
        return Err(rpc_error(
            -32602,
            format!("{key} must be at least {minimum}"),
        ));
    }
    Ok(Duration::from_millis(value.min(maximum)))
}

fn app_query(params: &Map<String, Value>) -> AppQuery {
    let app = params.get("app").and_then(Value::as_str);
    let process_id = app.and_then(|value| value.strip_prefix("pid:").unwrap_or(value).parse().ok());
    AppQuery {
        process_id,
        name: process_id
            .is_none()
            .then(|| app.map(str::to_owned))
            .flatten(),
        identifier: params
            .get("identifier")
            .and_then(Value::as_str)
            .map(str::to_owned),
    }
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

fn number_param(params: &Map<String, Value>, key: &str, default: f64) -> Result<f64, JsonRpcError> {
    match params.get(key) {
        None => Ok(default),
        Some(value) => value
            .as_f64()
            .ok_or_else(|| rpc_error(-32602, format!("{key} must be a number"))),
    }
}

fn pointer_target_is_point(target: &Value) -> bool {
    target.get("point").is_some() || (target.get("x").is_some() && target.get("y").is_some())
}
/// Stamps the four stable delivery fields onto an action result.
fn delivered(mut result: Value, policy: DeliveryPolicy, rung: DeliveryRung) -> Value {
    let success = result
        .get("verification")
        .is_some_and(|verification| goal_success(verification, true));
    if let Some(object) = result.as_object_mut() {
        DeliveryOutcome::dispatched(policy, rung).merge_into(object);
        object.insert("success".into(), json!(success));
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
    match e {
        axon_core::BackendError::Capability {
            capability,
            reason,
            diagnostic,
        } => JsonRpcError {
            code: -32004,
            message: format!("capability {} is unavailable: {reason}", capability.key()),
            data: Some(
                json!({"kind":"capability-unavailable","capability":capability.key(),"reason":reason,"diagnostic":diagnostic}),
            ),
        },
        other => rpc_error(-32000, other.to_string()),
    }
}

fn capability_unavailable(tool: &str, capability: &str, reason: &str) -> JsonRpcError {
    JsonRpcError {
        code: -32004,
        message: format!("tool {tool} requires unavailable capability {capability}"),
        data: Some(
            json!({"code":"capability-unavailable","tool":tool,"capability":capability,"reason":reason}),
        ),
    }
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

    fn operation_failure() -> axon_core::BackendError {
        axon_core::BackendError::Operation {
            operation: "recognize screen text".into(),
            message: "Vision request failed".into(),
            diagnostic: None,
        }
    }

    #[test]
    fn screen_text_failure_is_observation_metadata_instead_of_a_top_level_error() {
        let (visuals, screenshot_unavailable, screen_text_unavailable) =
            visual_observation_result(Err(operation_failure()), false, true);

        assert!(visuals.is_none());
        assert!(screenshot_unavailable.is_none());
        assert_eq!(
            screen_text_unavailable.unwrap(),
            json!({
                "code": "ocr-failed",
                "reason": "operation recognize screen text failed: Vision request failed"
            })
        );
    }

    #[test]
    fn screenshot_only_failure_keeps_the_existing_unavailable_contract() {
        let (visuals, screenshot_unavailable, screen_text_unavailable) =
            visual_observation_result(Err(operation_failure()), true, false);

        assert!(visuals.is_none());
        assert!(screen_text_unavailable.is_none());
        let unavailable = screenshot_unavailable.unwrap();
        assert_eq!(unavailable.code, "capture-failed");
        assert_eq!(unavailable.reason, "Vision request failed");
    }

    #[test]
    fn combined_visual_failure_reports_both_missing_outputs() {
        let (visuals, screenshot_unavailable, screen_text_unavailable) =
            visual_observation_result(Err(operation_failure()), true, true);

        assert!(visuals.is_none());
        assert_eq!(screenshot_unavailable.unwrap().code, "capture-failed");
        assert_eq!(screen_text_unavailable.unwrap()["code"], "ocr-failed");
    }

    struct EnumerationBackend;

    impl PlatformBackend for EnumerationBackend {
        fn capabilities(&self) -> Result<Vec<axon_core::CapabilityInfo>, axon_core::BackendError> {
            Ok(vec![])
        }
        fn enumerate_applications(
            &self,
        ) -> Result<Vec<axon_core::Application>, axon_core::BackendError> {
            Ok(vec![])
        }
        fn capture(&mut self, _: &AppQuery) -> Result<Snapshot, axon_core::BackendError> {
            unreachable!()
        }
        fn invoke(&mut self, _: &SnapshotHandle, _: &str) -> Result<(), axon_core::BackendError> {
            unreachable!()
        }
        fn read_value(
            &self,
            _: &SnapshotHandle,
        ) -> Result<Option<String>, axon_core::BackendError> {
            unreachable!()
        }
        fn set_value(
            &mut self,
            _: &SnapshotHandle,
            _: &str,
        ) -> Result<(), axon_core::BackendError> {
            unreachable!()
        }
        fn focus(&mut self, _: &SnapshotHandle) -> Result<(), axon_core::BackendError> {
            unreachable!()
        }
        fn scroll(
            &mut self,
            _: &SnapshotHandle,
            _: (f64, f64),
        ) -> Result<(), axon_core::BackendError> {
            unreachable!()
        }
        fn observe(
            &mut self,
            _: &AppQuery,
            _: Duration,
        ) -> Result<axon_core::Observation, axon_core::BackendError> {
            unreachable!()
        }
        fn wait_for_value(
            &mut self,
            _: &SnapshotHandle,
            _: &Value,
            _: Duration,
        ) -> Result<axon_core::Observation, axon_core::BackendError> {
            unreachable!()
        }
        fn pointer_click(&mut self, _: (f64, f64)) -> Result<(), axon_core::BackendError> {
            unreachable!()
        }
        fn pointer_drag(
            &mut self,
            _: (f64, f64),
            _: (f64, f64),
            _: Duration,
        ) -> Result<(), axon_core::BackendError> {
            unreachable!()
        }
        fn keyboard(
            &mut self,
            _: &AppQuery,
            _: KeyboardIntent<'_>,
        ) -> Result<(), axon_core::BackendError> {
            unreachable!()
        }
        fn screenshot(
            &mut self,
            _: &AppQuery,
        ) -> Result<axon_core::Screenshot, axon_core::BackendError> {
            unreachable!()
        }
        fn hit_test(
            &mut self,
            _: (f64, f64),
        ) -> Result<Option<axon_core::Node>, axon_core::BackendError> {
            unreachable!()
        }
    }

    impl PointerTargetVerifier for EnumerationBackend {
        fn verify_pointer_target(
            &mut self,
            _: &SnapshotHandle,
            _: (f64, f64),
        ) -> Result<bool, axon_core::BackendError> {
            unreachable!()
        }
    }
    impl TextRecognitionProvider for EnumerationBackend {
        fn recognize_text(
            &mut self,
            _: &AppQuery,
        ) -> Result<Vec<axon_core::RecognizedText>, axon_core::BackendError> {
            unreachable!()
        }
    }
    impl VisualObservationProvider for EnumerationBackend {
        fn observe_visuals(
            &mut self,
            _: &AppQuery,
            _: bool,
            _: bool,
        ) -> Result<VisualObservation, axon_core::BackendError> {
            unreachable!()
        }
    }
    impl ReadableStateProvider for EnumerationBackend {
        fn readable_state(
            &self,
            _: &SnapshotHandle,
        ) -> Result<Map<String, Value>, axon_core::BackendError> {
            unreachable!()
        }
    }
    impl BackgroundPixelPointer for EnumerationBackend {
        fn plan_pixel_click(
            &mut self,
            _: &SnapshotHandle,
            _: (f64, f64),
        ) -> Result<PixelPlan, axon_core::BackendError> {
            unreachable!()
        }
        fn dispatch_pixel_click(
            &mut self,
            _: &PixelTarget,
        ) -> Result<PixelDispatch, PixelDispatchError> {
            unreachable!()
        }
    }

    #[test]
    fn look_application_enumeration_matches_shared_envelope() {
        let mut router = Router::new(EnumerationBackend);
        let response = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                "look",
                Some(json!({})),
            ))
            .unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!("look application enumeration must succeed")
        };
        let expected =
            include_str!("../../../schema/fixtures/look-applications-envelope.json").trim();
        assert_eq!(serde_json::to_string(&success.result).unwrap(), expected);
        let mcp = axon_core::mcp_tool_result(success.result, false);
        assert!(mcp["structuredContent"].is_object());
        assert_eq!(
            serde_json::to_string(&mcp["structuredContent"]).unwrap(),
            expected
        );
    }

    #[test]
    fn native_result_uses_structured_target_resolution() {
        let mut result = json!({"resolution":{"status":"unique"}});
        let resolution: axon_core::TargetResolution = serde_json::from_value(json!({
            "status":"missing","confidence":"none","path":"fullSnapshot","context":"complete"
        }))
        .unwrap();
        attach_target_resolution(&mut result, &resolution);
        assert!(result.get("resolution").is_none());
        assert_eq!(result["targetResolution"]["status"], "missing");
    }

    #[test]
    fn replay_metadata_is_stripped_from_semantic_targets_before_native_dispatch() {
        let params = json!({
            "target": {"app":"Notes", "name":"save", "locator":{"role":"button"}, "recordedAt":12},
            "from": {"x":1, "y":2, "recordedAt":12},
            "value": "draft"
        })
        .as_object()
        .unwrap()
        .clone();

        let primitive = primitive_dispatch_params(&params);
        assert_eq!(primitive["target"], json!({"app":"Notes", "name":"save"}));
        assert_eq!(primitive["from"], params["from"]);
        assert_eq!(primitive["value"], "draft");
    }

    fn validated_params(tool: &str, arguments: Value) -> Map<String, Value> {
        axon_core::validate_tool_arguments(axon_core::ToolBackend::Mac, tool, arguments)
            .unwrap()
            .as_object()
            .unwrap()
            .clone()
    }

    fn router_error(
        router: &mut Router<EnumerationBackend>,
        tool: &str,
        params: Map<String, Value>,
    ) -> JsonRpcError {
        let response = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                tool,
                Some(Value::Object(params)),
            ))
            .unwrap();
        let JsonRpcResponse::Failure(failure) = response else {
            panic!("{tool} must refuse before native dispatch")
        };
        failure.error
    }

    #[test]
    fn canonical_invoke_name_survives_validation_and_is_required_by_router() {
        let params = validated_params(
            "invoke",
            json!({"target":{"app":"Notes","name":"Save"},"name":"AXShowMenu"}),
        );
        assert_eq!(required_str(&params, "name").unwrap(), "AXShowMenu");

        let mut missing_name = params;
        missing_name.remove("name");
        let error = router_error(&mut Router::new(EnumerationBackend), "invoke", missing_name);
        assert_eq!(error.code, -32602);
    }

    #[test]
    fn legacy_type_text_alias_is_rejected_by_canonical_validation() {
        let error = axon_core::validate_tool_arguments(
            axon_core::ToolBackend::Mac,
            "type",
            json!({"target":{"app":"Notes","name":"Body"},"text":"draft"}),
        )
        .unwrap_err();
        assert_eq!(error.code, -32602);
        assert_eq!(error.data.unwrap()["path"], "params.arguments.value");
    }

    #[test]
    fn unsupported_click_forms_refuse_before_dispatch() {
        for target in [
            json!({"point":{"x":10,"y":20}}),
            json!({"x":10,"y":20,"coordinateSpace":"screen"}),
        ] {
            let params = validated_params("click", json!({"target":target}));
            let error = router_error(&mut Router::new(EnumerationBackend), "click", params);
            assert_eq!(error.code, -32004);
            assert_eq!(error.data.as_ref().unwrap()["capability"], "point-target");
            assert_eq!(error.data.as_ref().unwrap()["reason"], "not-implemented");
        }
    }

    #[test]
    fn canonical_scroll_defaults_and_unsupported_forms_refuse_before_dispatch() {
        let defaulted = validated_params("scroll", json!({"target":{"app":"Notes","name":"List"}}));
        assert_eq!(defaulted["deltaX"], 0);
        assert_eq!(defaulted["deltaY"], -120);
        let error = router_error(&mut Router::new(EnumerationBackend), "scroll", defaulted);
        assert_eq!(error.code, -32004);
        assert_eq!(
            error.data.as_ref().unwrap()["capability"],
            "directional-scroll"
        );

        for arguments in [
            json!({"app":"Notes","deltaX":0,"deltaY":0}),
            json!({"target":{"point":{"x":10,"y":20}},"deltaX":0,"deltaY":0}),
            json!({"target":{"location":{"app":"Notes","text":"Bottom"}},"deltaX":0,"deltaY":0}),
        ] {
            let params = validated_params("scroll", arguments);
            let error = router_error(&mut Router::new(EnumerationBackend), "scroll", params);
            assert_eq!(error.code, -32004);
            assert_eq!(error.data.as_ref().unwrap()["reason"], "not-implemented");
        }
    }

    #[test]
    fn excluded_tools_are_capability_errors_before_dispatch() {
        for tool in ["save", "drag", "permit"] {
            let (_, capability) = EXCLUDED.iter().find(|(name, _)| *name == tool).unwrap();
            assert!(!capability.is_empty());
        }
    }

    #[test]
    fn unavailable_tools_have_machine_readable_errors() {
        let error = capability_unavailable("drag", "PointerDrag", "not-implemented");
        assert_eq!(error.code, -32004);
        assert_eq!(
            error.data.as_ref().unwrap()["code"],
            "capability-unavailable"
        );
        assert_eq!(error.data.as_ref().unwrap()["tool"], "drag");
    }

    #[test]
    fn delivered_results_use_goal_success() {
        let verified = delivered(
            json!({"verification":{"verified":true}}),
            DeliveryPolicy::BackgroundOnly,
            DeliveryRung::Semantic,
        );
        assert_eq!(verified["success"], json!(true));

        let unverified = delivered(
            json!({"verification":{"verified":false,"reason":"no postcondition"}}),
            DeliveryPolicy::BackgroundOnly,
            DeliveryRung::Semantic,
        );
        assert_eq!(unverified["success"], json!(false));
    }

    #[test]
    fn refusal_success_is_not_inferred_from_json_construction() {
        let result = json!({"success":false,"dispatchSuccess":false});
        assert!(
            !result
                .get("success")
                .and_then(Value::as_bool)
                .unwrap_or(true)
        );
    }

    #[test]
    fn rust_facade_keeps_app_inside_structured_result() {
        let app = axon_core::Application {
            process_id: None,
            name: "Calculator".into(),
            identifier: Some("42".into()),
            windows: Vec::new(),
        };
        let snapshot = Snapshot::new(app);
        let value = serde_json::to_value(snapshot).unwrap();
        assert_eq!(value.pointer("/app/name"), Some(&json!("Calculator")));
        assert!(value.get("application").is_none());
    }
}
