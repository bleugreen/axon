//! Windows UI Automation backend and v1 JSON-RPC tool router.

use axon_core::{
    AppQuery, AxnRunner, Capability, DeliveryCandidate, DeliveryCapability, DeliveryOutcome,
    DeliveryPolicy, DeliveryRefusal, DeliveryRefusalReason, DeliveryRung, DeliverySelection,
    DiffPolicy, DispatchOutcome, ExpectedFact, ForegroundTarget, JsonRpcError, JsonRpcId,
    JsonRpcRequest, JsonRpcResponse, KeyboardIntent, PlatformBackend, PointerContract,
    ResolutionStatus, RunEnvelope, SemanticLookup, SemanticNameRegistry, SemanticSelection,
    Snapshot, SnapshotHandle, TextLocationResolver, TextLocationSource, TextLocationTarget,
    TextRecognitionProvider, ToolDispatcher, classify_semantic_diff, dispatch_in_foreground,
    goal_success, prepare_run, select_delivery,
};
use serde_json::{Map, Value, json};
use std::{
    thread,
    time::{Duration, Instant},
};

#[cfg(windows)]
pub mod daemon;
mod handback;
mod keys;
pub mod lifecycle;
#[cfg(windows)]
pub mod pipe;
mod recording;
#[cfg(windows)]
pub mod scheduler;

#[cfg(windows)]
mod platform;
#[cfg(windows)]
pub use platform::{IntegrationProbe, WindowsBackend};

/// Tools this backend does not implement at all. These are not delivery decisions: the request
/// names something the Windows daemon has no code path for, which stays a JSON-RPC error.
const EXCLUDED: &[(&str, &str)] = &[
    ("navigate", "BrowserScripting"),
    ("windows", "BrowserScripting"),
    ("tabs", "BrowserScripting"),
    ("drag", "PointerDrag"),
    ("permit", "PermissionPrompt"),
];

/// What the pixel rung reports as its mechanism: window messages carrying client coordinates,
/// posted to one leaf window resolved through verified UIA ancestry.
const PIXEL_MECHANISM: &str = "HWND client-coordinate message";

/// Why `keyboard` has no pixel rung, and never will in this shape.
///
/// The pixel rung is target-bound input derived from verified window geometry. `keyboard` names an
/// application and an input string; there is no element, so there is no window to bind to and no
/// transform to report. Key delivery gets an honest home as a `type` fallback, below ValuePattern,
/// once the pointer path is proven on real targets.
const NO_KEYBOARD_GEOMETRY: &str = "keyboard input names an application rather than an element, so \
     there is no verified window geometry to bind it to; for literal text into a known field use \
     type with a named editable element, or for shortcuts and named keys opt in with \
     deliveryPolicy: foregroundPermitted";

/// Why a text location that resolved from screen text alone cannot travel the pixel rung.
const NO_RECOGNIZED_TEXT_GEOMETRY: &str = "this text location resolved from recognized screen text \
     rather than an accessibility element, so there is no ancestry to bind a window to";

const NO_FOREGROUND_TRANSACTION: &str = "this backend cannot capture the foreground, activate the \
     requested target, and prove that activation before dispatch";

pub use axon_core::ObserverQuiescence;

pub struct Router<B> {
    backend: B,
    snapshot: Option<Snapshot>,
    semantic_names: SemanticNameRegistry,
    observation_redaction: axon_core::ObservationRedactionContext,
    daemon: axon_core::NativeDaemonState,
    recorder: Option<axon_core::UserActionRecorder>,
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

#[derive(Clone, Debug, PartialEq)]
pub struct ScrollDispatch {
    pub mechanism: &'static str,
    pub verification: Value,
}

/// Reports the native Windows scroll mechanism and any position readback.
pub trait WindowsScrollProvider: PlatformBackend {
    fn scroll_windows(
        &mut self,
        target: &SnapshotHandle,
        delta: (f64, f64),
    ) -> Result<ScrollDispatch, axon_core::BackendError>;
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
        /// Windows silently drops — dressed up as a successful one. The obstacle has to be named
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
        + BackgroundPixelPointer
        + WindowsScrollProvider
        + axon_core::RecordingEvidenceProvider
        + ObserverQuiescence,
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
            observation_redaction: Default::default(),
            daemon: Default::default(),
            recorder: None,
        }
    }

    /// Drains whatever the observer has seen into the daemon's recording session.
    ///
    /// Called on `recording.status` and `recording.stop` and nowhere else, which is why the
    /// observer reads its evidence at event time rather than here: an event may have been waiting
    /// since long before this call, and the interface it describes has moved on.
    fn pump_recording(&mut self) -> Result<(), JsonRpcError> {
        let Some(recorder) = self.recorder.as_mut() else {
            return Ok(());
        };
        recorder
            .poll(&mut self.backend, Duration::ZERO)
            .map_err(backend_error)?;
        for group in recorder.take_groups() {
            self.daemon.recording.push_group(group)?;
        }
        Ok(())
    }

    fn dispatch_recording(
        &mut self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Option<Result<Value, JsonRpcError>> {
        Some(match method {
            "recording.start" | "editor.recordFromHere" => {
                // Refuse on capability before the daemon opens a session. The observer seam is the
                // one place that knows whether this process can actually watch input, and asking
                // it first means a denied start never creates a recording it has to abandon.
                if let Err(error) = self.backend.global_input_observer() {
                    return Some(Err(backend_error(error)));
                }
                let started = self.daemon.dispatch(method, params)?;
                match started {
                    Ok(value) => {
                        let scope = self
                            .daemon
                            .recording
                            .status()
                            .scope
                            .expect("active recording has scope");
                        match axon_core::UserActionRecorder::start_with_redaction(
                            &mut self.backend,
                            scope,
                            self.observation_redaction.clone(),
                        ) {
                            Ok(recorder) => {
                                self.recorder = Some(recorder);
                                Ok(value)
                            }
                            Err(error) => {
                                self.daemon.recording.abandon();
                                Err(backend_error(error))
                            }
                        }
                    }
                    Err(error) => Err(error),
                }
            }
            "recording.status" => self.pump_recording().and_then(|_| {
                self.daemon
                    .dispatch(method, params)
                    .expect("recording route")
            }),
            "recording.stop" => {
                if !params.is_empty() {
                    return Some(
                        self.daemon
                            .dispatch(method, params)
                            .expect("recording route"),
                    );
                }
                // Quiesced before the final poll, because that poll is the last one there will
                // be: `UserActionRecorder::finish` flushes and calls the provider's `stop`, and
                // nothing reads from the provider afterwards. A backend enriching behind its hook
                // has not yet produced the events of the last moment or two when this route is
                // reached, so polling first and quiescing later would author a recording that
                // stops short of its own ending -- and by a wide margin under a fast burst, which
                // is exactly when a recording matters most.
                self.backend.quiesce_global_input();
                if let Err(error) = self.pump_recording() {
                    let _ = axon_core::GlobalInputObserver::stop(&mut self.backend);
                    self.recorder = None;
                    self.daemon.recording.abandon();
                    Err(error)
                } else if let Some(recorder) = self.recorder.take() {
                    match recorder.finish(&mut self.backend) {
                        Ok(groups) => groups
                            .into_iter()
                            .try_for_each(|group| self.daemon.recording.push_group(group))
                            .and_then(|_| {
                                self.daemon
                                    .dispatch(method, params)
                                    .expect("recording route")
                            }),
                        Err(error) => {
                            self.daemon.recording.abandon();
                            Err(backend_error(error))
                        }
                    }
                } else {
                    self.daemon
                        .dispatch(method, params)
                        .expect("recording route")
                }
            }
            _ => return None,
        })
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
        let app = app_query_from_parts(Some(&target.app), None);
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
    /// pixel rung on Windows: `keyboard` names an application rather than an element, so it has no
    /// window geometry to bind to and never reaches this path.
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
        app.process_id
            .map(|process_id| process_id.to_string())
            .or_else(|| app.identifier.clone())
            .or_else(|| (!app.name.is_empty()).then(|| app.name.clone()))
    }

    pub fn request(&mut self, request: JsonRpcRequest) -> Option<JsonRpcResponse> {
        let id = request.id.clone()?;
        let context = self.daemon.history.context(&request);
        if matches!(
            context.request.method.as_str(),
            "save"
                | "recording.start"
                | "recording.status"
                | "recording.stop"
                | "editor.recordFromHere"
        ) && context
            .request
            .params
            .as_ref()
            .is_some_and(|params| !params.is_object())
        {
            return Some(JsonRpcResponse::failure(
                id,
                JsonRpcError {
                    code: -32602,
                    message: "Invalid params: expected object".into(),
                    data: Some(json!({"path":"params","reason":"expected object"})),
                },
            ));
        }
        let params = context
            .request
            .params
            .as_ref()
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default();
        let outcome = self
            .dispatch_recording(&context.request.method, &params)
            .or_else(|| self.daemon.dispatch(&context.request.method, &params))
            .unwrap_or_else(|| self.dispatch_tool(&context.request.method, &params));
        let response = match outcome {
            Ok(result) => JsonRpcResponse::success(id, result),
            Err(error) => JsonRpcResponse::failure(id, error),
        };
        self.daemon.history.record_redacted_with_locator(
            &context.request,
            &response,
            &context.session_id,
            |app, name| self.semantic_names.durable_locator(app, name),
            &self.observation_redaction,
        );
        Some(response)
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
                    let location = location.clone();
                    return self.click_text_location(&location, policy);
                }
                // The target is resolved first, so an absent, malformed, or stale target is a
                // JSON-RPC error. A refusal means the request was well formed and the target
                // resolved, and the daemon declined to act; the two must not be confused.
                let (handle, resolution) = self.resolve(params)?;
                let point = self.node_center(&handle)?;
                self.deliver_click(
                    policy,
                    ClickTarget::Element(handle),
                    point,
                    json!(resolution),
                )
            }
            "type" => {
                let value = required_str(params, "value")?;
                let (handle, resolution) = self.resolve(params)?;
                // UIA ValuePattern does not require focus, and calling SetFocus would make this a
                // foreground action wearing a semantic name.
                self.backend
                    .set_value(&handle, value)
                    .map_err(backend_error)?;
                let observed = self.backend.read_value(&handle).map_err(backend_error)?;
                Ok(delivered(
                    json!({"dispatch":{"success":true,"mechanism":"UIA ValuePattern"},"verification":{"verified":observed.as_deref()==Some(value),"observed":observed},"resolution":resolution}),
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
                let aimed =
                    app.process_id.is_some() || app.name.is_some() || app.identifier.is_some();
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
                if action != "Invoke" {
                    return Err(capability_unavailable(
                        "invoke",
                        "named-action",
                        "not-implemented",
                    ));
                }
                let (handle, resolution) = self.resolve(params)?;
                self.backend
                    .invoke(&handle, action)
                    .map_err(backend_error)?;
                Ok(delivered(
                    json!({"dispatch":{"success":true,"mechanism":"UIA InvokePattern"},"verification":{"verified":false,"reason":"invoke has no declared postcondition"},"resolution":resolution}),
                    policy,
                    DeliveryRung::Semantic,
                ))
            }
            "scroll" => {
                let dx = number_param(params, "deltaX", 0.0)?;
                let dy = number_param(params, "deltaY", -120.0)?;
                let (handle, resolution) = self.resolve(params)?;
                let scroll = self
                    .backend
                    .scroll_windows(&handle, (dx, dy))
                    .map_err(backend_error)?;
                Ok(delivered(
                    json!({"dispatch":{"success":true,"mechanism":scroll.mechanism},"verification":scroll.verification,"resolution":resolution}),
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
                // that would buy a dispatch Windows discards.
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
        match request.mode.clone() {
            axon_core::LookMode::AppList { all } => {
                if all {
                    return Err(rpc_error(
                        -32602,
                        "all-process application listing is unavailable on this backend",
                    ));
                }
                Ok(application_enumeration(
                    self.backend
                        .enumerate_applications()
                        .map_err(backend_error)?,
                ))
            }
            axon_core::LookMode::ChildPage {
                target,
                offset,
                limit,
                direct,
            } => {
                let context = match self.semantic_names.select(&target) {
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
                let handle = context.recorded_handle().ok_or_else(|| rpc_error(-32002, "semantic target has no live retained capture; call look for its app first"))?.clone();
                let page = self
                    .backend
                    .capture_child_page(
                        &handle,
                        axon_core::ChildPageRequest {
                            offset,
                            limit,
                            include_descendants: !direct,
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
                Ok(json!({
                    "children": axon_core::format_child_page(
                        &page,
                        &target,
                        &rendered,
                        &request.display,
                    )
                }))
            }
            axon_core::LookMode::ChangeCheck { .. } => Err(rpc_error(
                -32602,
                "since change checks are unavailable on this backend",
            )),
            axon_core::LookMode::FullApp { app, child_depth } => {
                let snapshot = self
                    .backend
                    .capture_bounded(&app, axon_core::CaptureBounds { child_depth })
                    .map_err(backend_error)?;
                let names = self.register_snapshot(&snapshot);
                let rendered = axon_core::render_semantic_names(&snapshot, &names);
                let mut value = axon_core::format_snapshot(&rendered, &request.display);
                let wants_screenshot = axon_core::screenshot_requested(
                    request.screenshot,
                    axon_core::LookObservationKind::FullApp,
                );
                let (visuals, screenshot_unavailable) = if wants_screenshot || request.screen_text {
                    match self
                        .backend
                        .observe_visuals(&app, wants_screenshot, request.screen_text)
                    {
                        Ok(visuals) => (Some(visuals), None),
                        Err(error) if wants_screenshot && !request.screen_text => (
                            None,
                            Some(axon_core::ScreenshotUnavailable::from_backend_error(error)),
                        ),
                        Err(error) => return Err(backend_error(error)),
                    }
                } else {
                    (None, None)
                };
                let object = if request.display.format == axon_core::LookFormat::Debug {
                    value.get_mut("observation").and_then(Value::as_object_mut)
                } else {
                    value.as_object_mut()
                }
                .expect("observation serializes as object");
                if let Some(screenshot) = visuals.as_ref().and_then(|v| v.screenshot.as_ref()) {
                    object.insert("screenshot".into(), json!({
                        "mediaType": screenshot.media_type,
                        "base64Data": base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &screenshot.bytes),
                        "width": screenshot.width, "height": screenshot.height
                    }));
                }
                if let Some(text) = visuals.and_then(|v| v.recognized_text) {
                    object.insert(
                        "screenText".into(),
                        axon_core::format_screen_text(
                            &text,
                            request.display.frames,
                            &self.observation_redaction,
                        ),
                    );
                }
                if let Some(unavailable) = screenshot_unavailable {
                    object.insert(
                        "screenshotUnavailable".into(),
                        serde_json::to_value(unavailable).map_err(internal_error)?,
                    );
                }
                self.snapshot = Some(snapshot);
                Ok(value)
            }
        }
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
                    let observed = self.readable_state(&handle)?;
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
        let condition = match params.get("condition") {
            None | Some(Value::Null) => "stable",
            Some(Value::String(condition)) => condition.as_str(),
            Some(_) => return Err(rpc_error(-32602, "condition must be a string")),
        };
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

    fn readable_state(&self, handle: &SnapshotHandle) -> Result<Map<String, Value>, JsonRpcError> {
        let node = self.node(handle)?;
        let mut state = Map::new();
        for (field, value) in [
            ("title", node.title.as_ref().or(node.name.as_ref())),
            ("identifier", node.identifier.as_ref()),
            // UIA exposes HelpText independently, but has no AXDescription equivalent.
            ("help", node.description.as_ref()),
        ] {
            if let Some(value) = value.filter(|value| !value.is_empty()) {
                state.insert(field.into(), Value::String(value.clone()));
            }
        }
        if let Some(value) = self.backend.read_value(handle).map_err(backend_error)?
            && !value.is_empty()
        {
            state.insert("value".into(), Value::String(value));
        } else if let Some(value) = node.value.as_ref().filter(|value| !value.is_empty()) {
            state.insert("value".into(), Value::String(value.clone()));
        }
        Ok(state)
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
        + BackgroundPixelPointer
        + WindowsScrollProvider
        + axon_core::RecordingEvidenceProvider
        + ObserverQuiescence,
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
    app_query_from_parts(
        params.get("app").and_then(Value::as_str),
        params.get("identifier").and_then(Value::as_str),
    )
}

fn app_query_from_parts(app: Option<&str>, identifier: Option<&str>) -> AppQuery {
    let process_id = app.and_then(|value| value.strip_prefix("pid:").unwrap_or(value).parse().ok());
    AppQuery {
        process_id,
        name: process_id
            .is_none()
            .then(|| app.map(str::to_owned))
            .flatten(),
        identifier: identifier.map(str::to_owned),
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
fn number_param(params: &Map<String, Value>, key: &str, default: f64) -> Result<f64, JsonRpcError> {
    match params.get(key) {
        None => Ok(default),
        Some(value) => value
            .as_f64()
            .ok_or_else(|| rpc_error(-32602, format!("{key} must be a number"))),
    }
}

fn required_str<'a>(p: &'a Map<String, Value>, key: &str) -> Result<&'a str, JsonRpcError> {
    p.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| rpc_error(-32602, format!("missing string parameter {key}")))
}
/// Stamps the four stable delivery fields onto an action result.
fn delivered(mut result: Value, policy: DeliveryPolicy, rung: DeliveryRung) -> Value {
    let rung_held = result
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let success = result
        .get("verification")
        .is_some_and(|verification| goal_success(verification, rung_held));
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
        // Same family as `Capability`, plus the stable `code` that names *which* refusal it is.
        // Without this arm a typed refusal would fall through to the catch-all and reach the wire
        // as an untyped -32000, which is how macOS lost `accessibility-denied` (axn/220).
        axon_core::BackendError::CapabilityReason {
            capability,
            code,
            reason,
            diagnostic,
        } => JsonRpcError {
            code: -32004,
            message: format!("capability {} is unavailable: {reason}", capability.key()),
            data: Some(
                json!({"kind":"capability-unavailable","capability":capability.key(),"code":code,"reason":reason,"diagnostic":diagnostic}),
            ),
        },
        other => rpc_error(-32000, other.to_string()),
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
    use axon_core::{
        Application, BackendError, CapabilityInfo, Node, Observation, Rect, Screenshot, Window,
    };
    use std::{cell::RefCell, rc::Rc, time::Duration};

    #[test]
    fn recording_start_refuses_when_native_observer_is_unavailable() {
        let mut backend = backend(vec![node("Save")], None);
        backend.observer_refusal = Some("session-not-interactive");
        let starts = Rc::clone(&backend.observer_starts);
        let mut router = Router::new(backend);

        let response = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                "recording.start",
                Some(json!({"scope":{"scope":"allApplications"}})),
            ))
            .unwrap();
        let JsonRpcResponse::Failure(failure) = response else {
            panic!("windows recording.start must not return empty success")
        };
        assert_eq!(failure.error.code, -32004);
        let data = failure.error.data.expect("a typed refusal carries data");
        // The whole point of the typed shape: which refusal it is survives to the wire. A caller
        // that only learned "unavailable" could not tell a session-0 daemon from a denied grant.
        assert_eq!(data["kind"], "capability-unavailable");
        assert_eq!(data["capability"], "observeGlobalInput");
        assert_eq!(data["code"], "session-not-interactive");

        // Refused before dispatch: nothing was started, so nothing had to be abandoned.
        assert_eq!(*starts.borrow(), 0);
        assert!(router.recorder.is_none());
        assert!(!router.daemon.recording.status().recording);

        let save = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(2)),
                "save",
                Some(json!({})),
            ))
            .unwrap();
        assert!(
            !matches!(save, JsonRpcResponse::Failure(ref failure) if failure.error.data.as_ref().is_some_and(|data| data["kind"] == "capability-unavailable"))
        );
    }

    /// A recording keeps the events its observer had not finished producing when the stop arrived.
    ///
    /// This is the failure mode a backend that reads the interface behind its hook has and a
    /// synchronous one does not: at the moment `recording.stop` is dispatched, the last events of
    /// the session exist only as unenriched raw input, and the bench measured that backlog at
    /// nearly a whole 400-event burst. Polling before observation has been brought to a stop, and
    /// then finishing, authors a recording that stops short of its own ending -- and does so
    /// silently, because the count is plausible and only the tail is missing.
    #[test]
    fn stopping_keeps_the_events_the_observer_had_not_yet_produced() {
        let backend = backend(vec![node("Save")], None);
        let pending = Rc::clone(&backend.pending_until_quiesce);
        let mut router = Router::new(backend);

        router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                "recording.start",
                Some(json!({"scope":{"scope":"allApplications"}})),
            ))
            .unwrap();

        pending
            .borrow_mut()
            .push(axon_core::RecordedInputEvent::KeyDown {
                app: axon_core::RecordedAppIdentity {
                    name: "Notepad".into(),
                    bundle_identifier: None,
                    process_id: None,
                },
                keystroke: axon_core::RecordedKeystroke::Key {
                    key: "return".into(),
                },
                timestamp_ms: 11,
            });

        // A status poll cannot see it yet, which is what makes this a real backlog rather than an
        // event the test simply queued late.
        let status = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(2)),
                "recording.status",
                Some(json!({})),
            ))
            .unwrap();
        assert!(matches!(status, JsonRpcResponse::Success(_)));
        assert_eq!(pending.borrow().len(), 1, "still behind");

        let JsonRpcResponse::Success(stopped) = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(3)),
                "recording.stop",
                Some(json!({})),
            ))
            .unwrap()
        else {
            panic!("a stop that quiesced its observer authors what it was still producing")
        };
        assert_eq!(
            stopped.result["actionCount"], 1,
            "the recording lost the action its observer produced while stopping"
        );
        assert!(
            stopped.result["script"]
                .as_str()
                .unwrap()
                .contains("return")
        );
    }

    /// The route this issue exists to open: a start that is allowed records real events and stops
    /// into an authored document, with the observer released exactly once on the way out.
    #[test]
    fn recording_records_observed_input_and_stops_into_an_authored_document() {
        let backend = backend(vec![node("Save")], None);
        let observed = Rc::clone(&backend.observed_input);
        let starts = Rc::clone(&backend.observer_starts);
        let stops = Rc::clone(&backend.observer_stops);
        let mut router = Router::new(backend);

        let started = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                "recording.start",
                Some(json!({"scope":{"scope":"allApplications"}})),
            ))
            .unwrap();
        assert!(matches!(started, JsonRpcResponse::Success(_)));
        assert_eq!(*starts.borrow(), 1);
        assert!(router.daemon.recording.status().recording);

        observed
            .borrow_mut()
            .push(axon_core::RecordedInputEvent::KeyDown {
                app: axon_core::RecordedAppIdentity {
                    name: "Notepad".into(),
                    bundle_identifier: None,
                    process_id: None,
                },
                keystroke: axon_core::RecordedKeystroke::Key {
                    key: "return".into(),
                },
                timestamp_ms: 7,
            });

        let status = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(2)),
                "recording.status",
                Some(json!({})),
            ))
            .unwrap();
        assert!(matches!(status, JsonRpcResponse::Success(_)));

        let JsonRpcResponse::Success(stopped) = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(3)),
                "recording.stop",
                Some(json!({})),
            ))
            .unwrap()
        else {
            panic!("a stop with an observed action authors a document")
        };
        assert_eq!(stopped.result["actionCount"], 1);
        let script = stopped.result["script"]
            .as_str()
            .expect("an authored script");
        assert!(script.contains("keyboard"), "{script}");
        assert!(script.contains("return"), "{script}");
        assert!(router.recorder.is_none());
        assert!(!router.daemon.recording.status().recording);
        assert_eq!(*stops.borrow(), 1, "the observer is released exactly once");
    }

    #[test]
    fn semantic_resolution_captures_selected_pid_on_first_try() {
        let mut backend = backend(vec![node("Save")], None);
        backend.snapshot.app.process_id = Some(4101);
        let queries = backend.capture_queries.clone();
        let mut router = Router::new(backend);
        let names = router.register_snapshot(&router.backend.snapshot.clone());
        let name = names
            .into_iter()
            .find(|name| name.label == "Save")
            .unwrap()
            .name;

        let result = router.resolve(
            json!({"target":{"app":"4101","name":name}})
                .as_object()
                .unwrap(),
        );
        assert!(result.is_ok());
        assert_eq!(
            queries.borrow().as_slice(),
            &[AppQuery {
                process_id: Some(4101),
                name: None,
                identifier: None,
            }]
        );
    }

    #[test]
    fn name_record_recapture_stays_on_its_recorded_pid() {
        let mut backend = backend(vec![node("Save")], None);
        backend.snapshot.app.process_id = Some(4101);
        backend.snapshot.app.name = "Shared".into();
        backend.snapshot.app.identifier = Some("com.example.shared".into());
        let queries = backend.capture_queries.clone();
        let mut router = Router::new(backend);
        let names = router.register_snapshot(&router.backend.snapshot.clone());
        let name = names
            .into_iter()
            .find(|name| name.label == "Save")
            .unwrap()
            .name;

        let mut newer = Snapshot::new(Application {
            process_id: Some(4202),
            name: "Shared".into(),
            identifier: Some("com.example.shared".into()),
            windows: vec![Window {
                title: None,
                root: node("Other"),
            }],
        });
        newer.id = axon_core::SnapshotId("newer".into());
        router.semantic_names.register(&newer);

        let result = router.resolve(
            json!({"target":{"app":"Shared","name":name}})
                .as_object()
                .unwrap(),
        );
        assert!(result.is_ok());
        assert_eq!(queries.borrow().last().unwrap().process_id, Some(4101));
    }

    #[test]
    fn native_result_uses_structured_target_resolution() {
        let mut result = json!({"resolution":{"status":"unique"}});
        let resolution: axon_core::TargetResolution = serde_json::from_value(json!({
            "status":"unique","confidence":"high","path":"fullSnapshot","context":"complete",
            "evidence":[{"field":"value","outcome":"changed"}],
            "observedLocator":{"role":"button","value":{"exact":"new"}}
        }))
        .unwrap();
        attach_target_resolution(&mut result, &resolution);
        assert!(result.get("resolution").is_none());
        assert_eq!(
            result["targetResolution"]["evidence"][0]["outcome"],
            "changed"
        );
    }

    #[test]
    fn replay_metadata_is_stripped_from_semantic_targets_before_native_dispatch() {
        let params = json!({
            "target": {"app":"Notepad", "name":"save", "locator":{"role":"button"}, "recordedAt":12},
            "from": {"x":1, "y":2, "recordedAt":12},
            "value": "draft"
        })
        .as_object()
        .unwrap()
        .clone();

        let primitive = primitive_dispatch_params(&params);
        assert_eq!(primitive["target"], json!({"app":"Notepad", "name":"save"}));
        assert_eq!(primitive["from"], params["from"]);
        assert_eq!(primitive["value"], "draft");
    }

    #[test]
    fn save_exports_durable_locators_for_semantic_click_and_type() {
        let mut router = Router::new(backend(vec![node("Field")], Some("before")));
        let name = router.register_snapshot(&router.backend.snapshot.clone())[0]
            .name
            .clone();
        for (method, extra) in [("click", json!({})), ("type", json!({"value":"after"}))] {
            let mut params = extra.as_object().unwrap().clone();
            params.insert("target".into(), json!({"app":"App","name":name}));
            router
                .request(request(method, Value::Object(params)))
                .unwrap();
        }

        let export = router
            .daemon
            .history
            .export_script("default", false, None, None, None)
            .unwrap();
        let document = axon_core::AxnCodec::parse(&export.script).unwrap();
        assert_eq!(document.actions.len(), 2);
        assert!(
            document
                .actions
                .iter()
                .all(|action| { action.params["target"].get("locator").is_some() })
        );
    }

    #[derive(Clone)]
    struct FakeBackend {
        snapshot: Snapshot,
        capture_queries: Rc<RefCell<Vec<AppQuery>>>,
        pointer_target_matches: bool,
        verified_handles: Rc<RefCell<Vec<SnapshotHandle>>>,
        value: Rc<RefCell<Option<String>>>,
        value_reads: Rc<RefCell<Vec<Option<String>>>>,
        clicks: Rc<RefCell<usize>>,
        keyboard_dispatches: Rc<RefCell<usize>>,
        recognized: Vec<axon_core::RecognizedText>,
        ocr_calls: Rc<RefCell<usize>>,
        visual_captures: Rc<RefCell<usize>>,
        ocr_hit_target: Option<Node>,
        focuses: Rc<RefCell<usize>>,
        /// Whether this session can reach the global input devices at all. Session 0, a
        /// noninteractive window station, and an integrity boundary all present as false.
        global_input_usable: bool,
        /// Whether this backend can capture, activate, and prove the foreground target.
        foreground_transaction: bool,
        post_dispatch_restoration_restriction: Option<&'static str>,
        frontmost: Rc<RefCell<Option<String>>>,
        /// Applications that refuse to come forward, so activation cannot be proved.
        refuses_activation: Rc<RefCell<Vec<String>>>,
        activations: Rc<RefCell<Vec<String>>>,
        /// What the pixel planner answers for any target. Unavailable by default, which is the
        /// honest shape for a fake: a bound plan has to be scripted deliberately.
        pixel_plan: Rc<RefCell<PixelPlan>>,
        pixel_result: Rc<RefCell<Result<PixelDispatch, PixelDispatchError>>>,
        /// Sequences actually posted, which is not the same as calls made: a revalidation failure
        /// posts nothing, and a counter of calls could not tell the two apart.
        pixel_dispatches: Rc<RefCell<usize>>,
        /// Why this backend cannot observe global input, if it cannot.
        ///
        /// A code rather than a flag, because the wire contract this pins is that the *specific*
        /// refusal survives to the caller. A boolean would let a test pass while the daemon
        /// flattened every reason into one.
        observer_refusal: Option<&'static str>,
        /// Events the observer hands over on the next poll, drained as they are taken.
        observed_input: Rc<RefCell<Vec<axon_core::RecordedInputEvent>>>,
        /// Events this observer only surrenders once observation has been quiesced, standing in
        /// for an enrichment thread still working through its backlog when `recording.stop`
        /// arrives. Without a fake that can be *behind*, no route test can tell a recording that
        /// keeps its ending from one that drops it.
        pending_until_quiesce: Rc<RefCell<Vec<axon_core::RecordedInputEvent>>>,
        observer_starts: Rc<RefCell<usize>>,
        observer_stops: Rc<RefCell<usize>>,
    }

    impl ObserverQuiescence for FakeBackend {
        fn quiesce_global_input(&mut self) {
            let caught_up = std::mem::take(&mut *self.pending_until_quiesce.borrow_mut());
            self.observed_input.borrow_mut().extend(caught_up);
        }
    }
    impl BackgroundPixelPointer for FakeBackend {
        fn plan_pixel_click(
            &mut self,
            _: &SnapshotHandle,
            _: (f64, f64),
        ) -> Result<PixelPlan, BackendError> {
            Ok(self.pixel_plan.borrow().clone())
        }
        fn dispatch_pixel_click(
            &mut self,
            _: &PixelTarget,
        ) -> Result<PixelDispatch, PixelDispatchError> {
            let outcome = self.pixel_result.borrow().clone();
            if outcome.is_ok() {
                *self.pixel_dispatches.borrow_mut() += 1;
            }
            outcome
        }
    }
    impl WindowsScrollProvider for FakeBackend {
        fn scroll_windows(
            &mut self,
            _: &SnapshotHandle,
            delta: (f64, f64),
        ) -> Result<ScrollDispatch, BackendError> {
            Ok(if delta == (0.0, 0.0) {
                ScrollDispatch {
                    mechanism: "UIA ScrollItemPattern.ScrollIntoView",
                    verification: json!({"verified":false,"reason":"bring-into-view has no readable target-position postcondition"}),
                }
            } else {
                ScrollDispatch {
                    mechanism: "UIA ScrollPattern.Scroll",
                    verification: json!({
                        "verified": true,
                        "before": {"horizontalPercent": 0.0, "verticalPercent": 0.0},
                        "after": {"horizontalPercent": delta.0.abs(), "verticalPercent": delta.1.abs()}
                    }),
                }
            })
        }
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
                    width: 640,
                    height: 480,
                    frame: Rect {
                        x: 4.0,
                        y: 5.0,
                        width: 640.0,
                        height: 480.0,
                    },
                }),
                recognized_text: screen_text.then(|| self.recognized.clone()),
            })
        }
    }
    impl axon_core::GlobalInputObserver for FakeBackend {
        fn start(&mut self, _: &axon_core::RecordingScope) -> Result<(), BackendError> {
            *self.observer_starts.borrow_mut() += 1;
            Ok(())
        }
        fn poll(
            &mut self,
            _: Duration,
        ) -> Result<Vec<axon_core::RecordedInputEvent>, BackendError> {
            Ok(std::mem::take(&mut *self.observed_input.borrow_mut()))
        }
        fn stop(&mut self) -> Result<(), BackendError> {
            *self.observer_stops.borrow_mut() += 1;
            Ok(())
        }
        fn is_recording(&self) -> bool {
            *self.observer_starts.borrow() > *self.observer_stops.borrow()
        }
    }

    impl axon_core::RecordingEvidenceProvider for FakeBackend {
        fn read_focused(
            &mut self,
        ) -> Result<Option<axon_core::RecordedFocusedEvidence>, BackendError> {
            Ok(None)
        }
        fn capture_snapshot(
            &mut self,
            _: &axon_core::RecordedAppIdentity,
        ) -> Result<Option<Snapshot>, BackendError> {
            Ok(None)
        }
        fn settle(
            &mut self,
            _: usize,
            _: &str,
        ) -> Result<axon_core::RecordedSettleEvidence, BackendError> {
            Ok(Default::default())
        }
    }

    impl PlatformBackend for FakeBackend {
        /// This fake records, so by default it claims the observer seam. Without the override it
        /// would inherit the core default that refuses, and `recording.start`'s capability
        /// preflight would turn every recording test here into a capability refusal.
        fn global_input_observer(
            &mut self,
        ) -> Result<&mut dyn axon_core::GlobalInputObserver, BackendError> {
            match self.observer_refusal {
                Some(code) => Err(BackendError::CapabilityReason {
                    capability: Capability::ObserveGlobalInput,
                    code,
                    reason: "session 0 has no interactive window station".into(),
                    diagnostic: None,
                }),
                None => Ok(self),
            }
        }
        fn capabilities(&self) -> Result<Vec<CapabilityInfo>, BackendError> {
            Ok(vec![
                CapabilityInfo {
                    capability: Capability::PointerInput,
                    usable: self.global_input_usable,
                    restriction: (!self.global_input_usable)
                        .then(|| "session 0 has no interactive window station".to_string()),
                },
                CapabilityInfo {
                    capability: Capability::KeyboardInput,
                    usable: self.global_input_usable,
                    restriction: (!self.global_input_usable)
                        .then(|| "session 0 has no interactive window station".to_string()),
                },
            ])
        }
        fn enumerate_applications(&self) -> Result<Vec<Application>, BackendError> {
            Ok(vec![Application {
                process_id: Some(4242),
                name: self.snapshot.app.name.clone(),
                identifier: self.snapshot.app.identifier.clone(),
                windows: vec![],
            }])
        }
        /// Resolved through this backend's own enumeration rather than echoed back, so a request
        /// naming an application that is not running actually misses. A fake that answered every
        /// name would make the unidentifiable-target refusal unreachable.
        fn resolve_application(&mut self, app: &AppQuery) -> Result<Option<String>, BackendError> {
            if let Some(wanted) = app.process_id {
                return Ok(self
                    .enumerate_applications()?
                    .into_iter()
                    .find(|running| running.process_id == Some(wanted))
                    .map(|running| running.identifier.unwrap_or_else(|| wanted.to_string())));
            }
            let wanted = app.name.as_deref().or(app.identifier.as_deref());
            Ok(self
                .enumerate_applications()?
                .into_iter()
                .find(|running| Some(running.name.as_str()) == wanted)
                .map(|running| running.identifier.unwrap_or(running.name)))
        }
        fn capture(&mut self, query: &AppQuery) -> Result<Snapshot, BackendError> {
            self.capture_queries.borrow_mut().push(query.clone());
            Ok(self.snapshot.clone())
        }
        fn invoke(&mut self, _: &SnapshotHandle, _: &str) -> Result<(), BackendError> {
            Ok(())
        }
        fn read_value(&self, _: &SnapshotHandle) -> Result<Option<String>, BackendError> {
            if !self.value_reads.borrow().is_empty() {
                return Ok(self.value_reads.borrow_mut().remove(0));
            }
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
        fn keyboard(&mut self, _: &AppQuery, _: KeyboardIntent<'_>) -> Result<(), BackendError> {
            *self.keyboard_dispatches.borrow_mut() += 1;
            Ok(())
        }
        fn screenshot(&mut self, _: &AppQuery) -> Result<Screenshot, BackendError> {
            unreachable!()
        }
        fn hit_test(&mut self, _: (f64, f64)) -> Result<Option<Node>, BackendError> {
            Ok(self.ocr_hit_target.clone())
        }
        fn supports_foreground_transaction(&self) -> bool {
            self.foreground_transaction
        }
        fn post_dispatch_restoration_restriction(&self) -> Option<&'static str> {
            self.post_dispatch_restoration_restriction
        }
        fn frontmost_application(&mut self) -> Result<Option<String>, BackendError> {
            Ok(self.frontmost.borrow().clone())
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
            focused: None,
            enabled: None,
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
            capture_queries: Rc::new(RefCell::new(vec![])),
            snapshot: Snapshot::new(Application {
                process_id: None,
                name: "App".into(),
                identifier: None,
                windows: vec![Window { title: None, root }],
            }),
            pointer_target_matches: true,
            verified_handles: Rc::new(RefCell::new(vec![])),
            value: Rc::new(RefCell::new(value.map(str::to_owned))),
            value_reads: Rc::new(RefCell::new(vec![])),
            clicks: Rc::new(RefCell::new(0)),
            keyboard_dispatches: Rc::new(RefCell::new(0)),
            recognized: vec![],
            ocr_calls: Rc::new(RefCell::new(0)),
            visual_captures: Rc::new(RefCell::new(0)),
            ocr_hit_target: Some(node("hit")),
            focuses: Rc::new(RefCell::new(0)),
            global_input_usable: true,
            foreground_transaction: true,
            post_dispatch_restoration_restriction: None,
            frontmost: Rc::new(RefCell::new(Some("Prior".into()))),
            refuses_activation: Rc::new(RefCell::new(vec![])),
            activations: Rc::new(RefCell::new(vec![])),
            pixel_plan: Rc::new(RefCell::new(PixelPlan::unavailable(
                "this fake backend was given no pixel plan for this target",
            ))),
            pixel_result: Rc::new(RefCell::new(Ok(PixelDispatch {
                complete: true,
                partial: None,
                frontmost_unchanged: true,
                pointer_unchanged: true,
            }))),
            pixel_dispatches: Rc::new(RefCell::new(0)),
            observer_refusal: None,
            observed_input: Rc::new(RefCell::new(vec![])),
            pending_until_quiesce: Rc::new(RefCell::new(vec![])),
            observer_starts: Rc::new(RefCell::new(0)),
            observer_stops: Rc::new(RefCell::new(0)),
        }
    }

    /// A plan bound to a leaf window inside a captured root, with a transform that reconstructs
    /// the screen point exactly.
    fn pixel_target() -> PixelTarget {
        PixelTarget {
            handle: SnapshotHandle("s1:0".into()),
            window: 0x0004_07AE,
            window_class: "Chrome_RenderWidgetHostHWND".into(),
            dpi_awareness: "perMonitorAware",
            root_window: 0x0003_0B12,
            process_identifier: 4812,
            screen_point: (204.0, 279.0),
            client_origin: (120.0, 248.0),
            client_point: (84.0, 31.0),
        }
    }
    fn request(method: &str, params: Value) -> JsonRpcRequest {
        JsonRpcRequest::new(Some(JsonRpcId::Integer(1)), method, Some(params))
    }
    fn validated_params(tool: &str, arguments: Value) -> Map<String, Value> {
        axon_core::validate_tool_arguments(axon_core::ToolBackend::Windows, tool, arguments)
            .unwrap()
            .as_object()
            .unwrap()
            .clone()
    }
    #[test]
    fn look_application_enumeration_matches_shared_envelope() {
        let mut router = Router::new(backend(vec![], None));
        let response = router.request(request("look", json!({}))).unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!("look application enumeration must succeed")
        };
        assert!(success.result.is_object());
        assert!(success.result["apps"].is_array());
        let mcp = axon_core::mcp_tool_result(success.result, false);
        assert!(mcp["structuredContent"].is_object());
        assert!(mcp["structuredContent"]["apps"].is_array());

        assert_eq!(
            serde_json::to_string(&application_enumeration(Vec::<Value>::new())).unwrap(),
            include_str!("../../../schema/fixtures/look-applications-envelope.json").trim()
        );
    }
    #[test]

    fn excluded_tools_have_structured_errors_before_backend_dispatch() {
        let backend = backend(vec![], None);
        let captures = backend.capture_queries.clone();
        let mut router = Router::new(backend);
        for (tool, capability) in EXCLUDED {
            let response = router
                .request(request(
                    tool,
                    json!({"target":{"app":"missing","name":"missing"},"deliveryPolicy":"invalid"}),
                ))
                .unwrap();
            let JsonRpcResponse::Failure(failure) = response else {
                panic!("{tool} must be a JSON-RPC error")
            };
            assert_eq!(failure.error.code, -32004, "{tool}");
            assert_eq!(
                failure.error.data,
                Some(json!({
                    "code":"capability-unavailable",
                    "tool":tool,
                    "capability":capability,
                    "reason":"not-implemented"
                })),
                "{tool}"
            );
        }
        assert!(captures.borrow().is_empty());
    }

    #[test]
    fn canonical_invoke_name_survives_validation_and_is_required_by_router() {
        let params = validated_params(
            "invoke",
            json!({"target":{"app":"App","name":"root"},"name":"Invoke"}),
        );
        assert_eq!(required_str(&params, "name").unwrap(), "Invoke");

        let backend = backend(vec![], None);
        let captures = backend.capture_queries.clone();
        let mut router = Router::new(backend);
        let mut missing_name = params;
        missing_name.remove("name");
        let response = router
            .request(request("invoke", Value::Object(missing_name)))
            .unwrap();
        let JsonRpcResponse::Failure(failure) = response else {
            panic!("invoke without a name must fail")
        };
        assert_eq!(failure.error.code, -32602);
        assert!(captures.borrow().is_empty());
    }

    #[test]
    fn unsupported_invoke_names_refuse_before_native_dispatch() {
        let params = validated_params(
            "invoke",
            json!({"target":{"app":"App","name":"root"},"name":"Expand"}),
        );
        let backend = backend(vec![], None);
        let captures = backend.capture_queries.clone();
        let mut router = Router::new(backend);
        let response = router
            .request(request("invoke", Value::Object(params)))
            .unwrap();
        let JsonRpcResponse::Failure(failure) = response else {
            panic!("unsupported named actions must fail")
        };
        assert_eq!(failure.error.code, -32004);
        assert_eq!(
            failure.error.data,
            Some(json!({
                "code":"capability-unavailable",
                "tool":"invoke",
                "capability":"named-action",
                "reason":"not-implemented"
            }))
        );
        assert!(captures.borrow().is_empty());
    }

    #[test]
    fn legacy_type_text_alias_is_rejected_by_canonical_validation() {
        let error = axon_core::validate_tool_arguments(
            axon_core::ToolBackend::Windows,
            "type",
            json!({"target":{"app":"App","name":"root"},"text":"draft"}),
        )
        .unwrap_err();
        assert_eq!(error.code, -32602);
        assert_eq!(error.data.unwrap()["path"], "params.arguments.value");
    }

    #[test]
    fn waits_poll_captures_and_report_satisfied_and_timeout_results() {
        let backend = backend(vec![], Some("Ready"));
        *backend.value_reads.borrow_mut() = vec![Some("Loading".into()), Some("Ready".into())];
        let mut router = Router::new(backend);
        let look = router
            .request(request("look", json!({"app":"App","screenshot":false})))
            .unwrap();
        assert!(matches!(look, JsonRpcResponse::Success(_)));

        let value = router
            .request(request(
                "wait_for_value",
                json!({
                    "target":{"app":"App","name":"root"},
                    "equals":"Ready",
                    "timeoutMs":100,
                    "intervalMs":10
                }),
            ))
            .unwrap();
        let JsonRpcResponse::Success(value) = value else {
            panic!()
        };
        assert_eq!(value.result["wait"]["success"], true);
        assert_eq!(value.result["wait"]["matched"]["field"], "value");
        assert!(router.backend.value_reads.borrow().is_empty());

        let timeout = router
            .request(request(
                "wait_for_value",
                json!({
                    "target":{"app":"App","name":"root"},
                    "contains":"never",
                    "timeoutMs":0,
                    "intervalMs":10
                }),
            ))
            .unwrap();
        let JsonRpcResponse::Success(timeout) = timeout else {
            panic!()
        };
        assert_eq!(timeout.result["wait"]["success"], false);
        assert_eq!(timeout.result["wait"]["status"], "predicate_timeout");

        let stable = router
            .request(request(
                "wait_for_stability",
                json!({"app":"App","stableMs":0,"timeoutMs":0,"intervalMs":10}),
            ))
            .unwrap();
        let JsonRpcResponse::Success(stable) = stable else {
            panic!()
        };
        assert_eq!(stable.result["wait"]["success"], true);

        let changed = router
            .request(request(
                "wait_for_stability",
                json!({"app":"App","condition":"changed","timeoutMs":0,"intervalMs":10}),
            ))
            .unwrap();
        let JsonRpcResponse::Success(changed) = changed else {
            panic!()
        };
        assert_eq!(changed.result["wait"]["success"], false);
        assert_eq!(changed.result["wait"]["status"], "timeout");
    }

    #[test]
    fn wait_for_value_matches_every_available_readable_state_field() {
        let mut backend = backend(vec![], None);
        let root = &mut backend.snapshot.app.windows[0].root;
        root.title = Some("Window title".into());
        root.description = Some("Helpful text".into());
        root.identifier = Some("stable-id".into());
        let mut router = Router::new(backend);
        let look = router
            .request(request("look", json!({"app":"App","screenshot":false})))
            .unwrap();
        assert!(matches!(look, JsonRpcResponse::Success(_)));

        for (predicate, field) in [
            (json!({"equals":"Window title"}), "title"),
            (json!({"matches":"stable-.+"}), "identifier"),
            (json!({"equals":"Helpful text"}), "help"),
        ] {
            let mut params = predicate.as_object().unwrap().clone();
            params.insert("target".into(), json!({"app":"App","name":"window-title"}));
            params.insert("timeoutMs".into(), json!(0));
            params.insert("intervalMs".into(), json!(10));
            let response = router
                .request(request("wait_for_value", Value::Object(params)))
                .unwrap();
            let JsonRpcResponse::Success(success) = response else {
                panic!()
            };
            assert_eq!(
                success.result["wait"]["success"], true,
                "{:?}",
                success.result
            );
            assert_eq!(success.result["wait"]["matched"]["field"], field);
        }
    }

    #[test]
    fn waits_validate_predicates_patterns_and_durations_before_polling() {
        assert_eq!(
            bounded_ms(&Map::new(), "stableMs", 300, 0, 10_000).unwrap(),
            Duration::from_millis(300)
        );
        assert_eq!(
            bounded_ms(
                json!({"stableMs": 50_000}).as_object().unwrap(),
                "stableMs",
                300,
                0,
                10_000,
            )
            .unwrap(),
            Duration::from_millis(10_000)
        );

        let mut router = Router::new(backend(vec![], None));
        let condition = router
            .request(request(
                "wait_for_stability",
                json!({"app":"App","condition":7,"timeoutMs":0,"intervalMs":10}),
            ))
            .unwrap();
        let JsonRpcResponse::Failure(condition) = condition else {
            panic!()
        };
        assert_eq!(condition.error.code, -32602);

        for params in [
            json!({"target":{"app":"App","name":"root"},"timeoutMs":0}),
            json!({"target":{"app":"App","name":"root"},"equals":"x","contains":"x","timeoutMs":0}),
            json!({"target":{"app":"App","name":"root"},"matches":"[","timeoutMs":0}),
            json!({"target":{"app":"App","name":"root"},"equals":"x","timeoutMs":-1}),
        ] {
            let response = router.request(request("wait_for_value", params)).unwrap();
            let JsonRpcResponse::Failure(failure) = response else {
                panic!()
            };
            assert_eq!(failure.error.code, -32602);
        }
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
    fn legacy_locator_target_is_rejected_without_dispatch() {
        let mut router = Router::new(backend(vec![node("same"), node("same")], None));
        let response = router
            .request(request(
                "click",
                json!({"target":{"app":"App","locator":{"role":"Button"}}, "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();
        let JsonRpcResponse::Failure(error) = response else {
            panic!("legacy locators must be rejected at the wire boundary")
        };
        assert_eq!(error.error.code, -32602);
        assert_eq!(error.error.message, axon_core::SEMANTIC_TARGET_GUIDANCE);
        assert_eq!(*router.backend.clicks.borrow(), 0);
    }
    #[test]
    fn click_rejects_mismatched_immediate_hit_before_send_input() {
        let mut backend = backend(vec![], None);
        backend.pointer_target_matches = false;
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());
        let response = router
            .request(request(
                "click",
                json!({"target":{"location":{"app":"App","text":"root"}}, "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();
        assert!(matches!(response, JsonRpcResponse::Failure(_)));
        assert_eq!(*clicks.borrow(), 0);
    }
    #[test]
    fn legacy_handle_target_is_rejected_without_dispatch() {
        let backend = backend(vec![node("duplicate"), node("duplicate")], None);
        let target = backend.snapshot.handle(1);
        let verified_handles = backend.verified_handles.clone();
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({"target":target.0, "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();

        let JsonRpcResponse::Failure(error) = response else {
            panic!("legacy handles must be rejected at the wire boundary")
        };
        assert_eq!(error.error.code, -32602);
        assert_eq!(error.error.message, axon_core::SEMANTIC_TARGET_GUIDANCE);
        assert!(verified_handles.borrow().is_empty());
        assert_eq!(*clicks.borrow(), 0);
    }
    fn recognized(text: &str, x: f64) -> axon_core::RecognizedText {
        axon_core::RecognizedText {
            text: text.into(),
            frame: Rect {
                x,
                y: 10.0,
                width: 40.0,
                height: 20.0,
            },
            confidence: Some(0.9),
        }
    }
    #[test]
    fn unique_text_location_click_returns_macos_shaped_resolution() {
        let mut router = Router::new(backend(vec![node("Save")], None));
        let response = router
            .request(request(
                "click",
                json!({"target":{"location":{"app":"App","text":"save"}}, "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!()
        };
        assert_eq!(success.result["resolution"]["status"], "unique");
        assert_eq!(success.result["resolution"]["best"]["source"], "ax");
        assert_eq!(success.result["resolution"]["point"]["x"], 10.0);
        let keys = success.result["resolution"].as_object().unwrap();
        assert!(keys.contains_key("snapshotID"));
        assert!(!keys.contains_key("snapshotId"));
        assert_eq!(*router.backend.clicks.borrow(), 1);
    }
    #[test]
    fn look_defaults_to_screenshot_and_explicit_false_opts_out() {
        let default_backend = backend(vec![], None);
        let default_captures = default_backend.visual_captures.clone();
        let mut default_router = Router::new(default_backend);
        let response = default_router
            .request(request("look", json!({"app":"App"})))
            .unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!()
        };
        assert_eq!(success.result["screenshot"]["mediaType"], "image/png");
        assert_eq!(*default_captures.borrow(), 1);

        let opted_out_backend = backend(vec![], None);
        let opted_out_captures = opted_out_backend.visual_captures.clone();
        let mut opted_out_router = Router::new(opted_out_backend);
        let response = opted_out_router
            .request(request("look", json!({"app":"App","screenshot":false})))
            .unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!()
        };
        assert!(success.result.get("screenshot").is_none());
        assert_eq!(*opted_out_captures.borrow(), 0);
    }

    #[test]
    fn look_screenshot_and_text_share_one_capture_and_use_canonical_keys() {
        let mut backend = backend(vec![], None);
        backend.recognized = vec![recognized("Save", 100.0)];
        let captures = backend.visual_captures.clone();
        let mut router = Router::new(backend);
        let response = router
            .request(request(
                "look",
                json!({"app":"App","screenshot":true,"screenText":true}),
            ))
            .unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!()
        };
        let screenshot = success.result["screenshot"].as_object().unwrap();
        let keys = screenshot
            .keys()
            .map(String::as_str)
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            keys,
            ["base64Data", "height", "mediaType", "width"]
                .into_iter()
                .collect()
        );
        assert_eq!(screenshot["mediaType"], "image/png");
        assert_eq!(screenshot["base64Data"], "AQID");
        assert_eq!(screenshot["width"], 640);
        assert_eq!(screenshot["height"], 480);
        assert_eq!(success.result["screenText"][0]["text"], "Save");
        assert!(success.result["screenText"][0].get("frame").is_none());
        assert_eq!(*captures.borrow(), 1);
    }

    #[test]
    fn look_screen_text_includes_frames_only_when_requested() {
        let mut backend = backend(vec![], None);
        backend.recognized = vec![recognized("Save", 100.0)];
        let captures = backend.visual_captures.clone();
        let mut router = Router::new(backend);
        let response = router
            .request(request(
                "look",
                json!({
                    "app":"App",
                    "screenshot":false,
                    "screenText":true,
                    "frames":true
                }),
            ))
            .unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!()
        };
        assert!(success.result.get("screenshot").is_none());
        assert_eq!(
            success.result["screenText"][0]["frame"],
            json!({"x":100.0,"y":10.0,"width":40.0,"height":20.0})
        );
        assert_eq!(*captures.borrow(), 1);
    }

    #[test]
    fn ambiguous_text_location_fails_closed() {
        let mut router = Router::new(backend(vec![node("Save"), node("Save")], None));
        let response = router
            .request(request(
                "click",
                json!({"target":{"location":{"app":"App","text":"save"}}, "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();
        assert!(matches!(response, JsonRpcResponse::Failure(_)));
        assert_eq!(*router.backend.clicks.borrow(), 0);
    }
    #[test]
    fn auto_prefers_uia_without_running_ocr() {
        let mut backend = backend(vec![node("Save")], None);
        backend.recognized = vec![recognized("Save", 100.0)];
        let calls = backend.ocr_calls.clone();
        let mut router = Router::new(backend);
        let response = router
            .request(request(
                "click",
                json!({"target":{"location":{"app":"App","text":"save","source":"auto"}}, "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();
        assert!(matches!(response, JsonRpcResponse::Success(_)));
        assert_eq!(*calls.borrow(), 0);
    }
    #[test]
    fn text_location_uses_the_canonical_bare_pid_app_query() {
        let backend = backend(vec![node("Save")], None);
        let queries = backend.capture_queries.clone();
        let mut router = Router::new(backend);
        let response = router
            .request(request(
                "click",
                json!({"target":{"location":{"app":"12336","text":"save","source":"auto"}}, "deliveryPolicy":"foregroundPermitted"}),
            ))
            .unwrap();

        assert!(matches!(response, JsonRpcResponse::Success(_)));
        assert_eq!(queries.borrow()[0].process_id, Some(12336));
        assert_eq!(queries.borrow()[0].name, None);
    }

    #[test]
    fn forced_screenshot_uses_ocr_even_when_uia_matches() {
        let mut backend = backend(vec![node("Save")], None);
        backend.recognized = vec![recognized("Save", 100.0)];
        let calls = backend.ocr_calls.clone();
        let mut router = Router::new(backend);
        let response = router
            .request(request(
                "click",
                json!({"target":{"location":{"app":"App","text":"save","source":"screenshot"}}, "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!()
        };
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
        let response = router
            .request(request(
                "click",
                json!({"target":{"location":{"app":"App","text":"save","source":"screenshot"}}, "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();
        assert!(matches!(response, JsonRpcResponse::Failure(_)));
        assert_eq!(*clicks.borrow(), 0);
    }
    fn action_result(response: &JsonRpcResponse) -> &Value {
        let JsonRpcResponse::Success(success) = response else {
            panic!("a policy or capability denial is an action result, not a transport error")
        };
        &success.result
    }

    #[test]
    fn a_text_location_click_travels_the_same_ladder_as_any_other_click() {
        // A resolved text location is still a click. A separate dispatch path here is how a caller
        // ends up with global pointer input under a policy that forbids it.
        let mut backend = backend(vec![node("save")], None);
        backend.recognized = vec![];
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);

        let refused = router
            .request(request(
                "click",
                json!({"target": {"location": {"app": "App", "text": "save"}}}),
            ))
            .unwrap();
        let result = action_result(&refused);
        assert_eq!(result["refusal"]["reason"], json!("foregroundNotPermitted"));
        assert_eq!(result["delivery"], Value::Null);
        assert_eq!(result["dispatchSuccess"], json!(false));
        assert_eq!(
            *clicks.borrow(),
            0,
            "the default policy must not emit global pointer input"
        );
    }

    #[test]
    fn a_text_location_click_is_refused_when_the_foreground_rung_is_withheld() {
        let mut backend = backend(vec![node("save")], None);
        backend.foreground_transaction = false;
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);

        let response = router
            .request(request(
                "click",
                json!({
                    "target": {"location": {"app": "App", "text": "save"}},
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

        let result = action_result(&response);
        assert_eq!(result["refusal"]["reason"], json!("noDeliveryCandidate"));
        assert_eq!(*clicks.borrow(), 0, "a withheld rung dispatches nothing");
    }

    #[test]
    fn a_text_location_click_activates_and_restores_when_opted_in() {
        let backend = backend(vec![node("save")], None);
        let clicks = backend.clicks.clone();
        let activations = backend.activations.clone();
        let mut router = Router::new(backend);

        let response = router
            .request(request(
                "click",
                json!({
                    "target": {"location": {"app": "App", "text": "save"}},
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

        let result = action_result(&response);
        assert_eq!(result["delivery"], json!("foreground"));
        assert_eq!(result["dispatchSuccess"], json!(true));
        assert_eq!(result["foreground"]["activationProved"], json!(true));
        assert_eq!(result["foreground"]["restored"], json!(true));
        assert!(result["resolution"]["status"] != Value::Null);
        assert_eq!(*clicks.borrow(), 1);
        assert_eq!(
            *activations.borrow(),
            vec!["App".to_string(), "Prior".to_string()]
        );
    }

    #[test]
    fn a_handle_only_click_activates_the_resolved_targets_application() {
        // The canonical form carries no app string. Foreground delivery must recover the owning
        // application from the resolution rather than treating the absence as already-frontmost,
        // which would dispatch global input with no activation and no proof.
        let backend = backend(vec![], None);
        let clicks = backend.clicks.clone();
        let activations = backend.activations.clone();
        let frontmost = backend.frontmost.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({"target": {"location": {"app": "App", "text": "root"}}, "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();

        let result = action_result(&response);
        assert_eq!(result["delivery"], json!("foreground"));
        assert_eq!(result["foreground"]["alreadyFrontmost"], json!(false));
        assert_eq!(result["foreground"]["activationProved"], json!(true));
        assert_eq!(result["foreground"]["restored"], json!(true));
        assert_eq!(
            *activations.borrow(),
            vec!["App".to_string(), "Prior".to_string()],
            "the resolved target's own application is activated, then the prior one restored"
        );
        assert_eq!(*clicks.borrow(), 1);
        assert_eq!(frontmost.borrow().as_deref(), Some("Prior"));
    }

    #[test]
    fn a_backend_that_cannot_prove_activation_never_offers_the_rung() {
        // A backend that cannot prove the target is frontmost cannot safely dispatch global input.
        let mut backend = backend(vec![], None);
        backend.foreground_transaction = false;
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        for policy in ["backgroundOnly", "foregroundPermitted"] {
            let response = router
                .request(request(
                    "click",
                    json!({"target": {"location": {"app": "App", "text": "root"}}, "deliveryPolicy": policy}),
                ))
                .unwrap();
            let result = action_result(&response);
            assert_eq!(
                result["refusal"]["reason"],
                json!("noDeliveryCandidate"),
                "{policy}"
            );
            assert!(
                result["refusal"]["message"]
                    .as_str()
                    .unwrap()
                    .contains("prove that activation"),
                "the refusal names the proof the backend cannot provide, under {policy}"
            );
        }
        assert_eq!(*clicks.borrow(), 0);
    }

    #[test]
    fn foreground_escalation_captures_activates_dispatches_once_and_restores() {
        let backend = backend(vec![], None);
        let clicks = backend.clicks.clone();
        let activations = backend.activations.clone();
        let frontmost = backend.frontmost.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({
                    "target": {"location": {"app": "App", "text": "root"}},
                    "app": "App",
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

        let result = action_result(&response);
        assert_eq!(result["delivery"], json!("foreground"));
        assert_eq!(result["dispatchSuccess"], json!(true));
        assert_eq!(result["foreground"]["priorApp"], json!("Prior"));
        assert_eq!(result["foreground"]["alreadyFrontmost"], json!(false));
        assert_eq!(result["foreground"]["activationProved"], json!(true));
        assert_eq!(result["foreground"]["restored"], json!(true));
        // This fake overrides neither pointer seam, so the transaction cannot say where the
        // pointer started and reports null rather than claiming it handed something back.
        assert_eq!(result["foreground"]["pointerRestored"], Value::Null);
        assert_eq!(*clicks.borrow(), 1, "exactly one dispatch");
        assert_eq!(
            *activations.borrow(),
            vec!["App".to_string(), "Prior".to_string()],
            "activate the target, then hand the session back"
        );
        assert_eq!(frontmost.borrow().as_deref(), Some("Prior"));
        // What the transaction kept is its own promise, and that is not the whole of success.
        // See the dedicated case below.
        assert_eq!(result["success"], json!(false));
    }

    #[test]
    fn a_backend_can_withhold_post_dispatch_restoration_to_preserve_delivery() {
        let mut backend = backend(vec![], None);
        backend.post_dispatch_restoration_restriction =
            Some("input stream has no completion fence");
        let activations = backend.activations.clone();
        let frontmost = backend.frontmost.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "keyboard",
                json!({
                    "app": "App",
                    "text": "delivered",
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();
        let result = action_result(&response);

        assert_eq!(result["dispatchSuccess"], json!(true));
        assert_eq!(result["foreground"]["restored"], json!(false));
        assert_eq!(
            result["foreground"]["message"],
            json!("input stream has no completion fence")
        );
        assert_eq!(*frontmost.borrow(), Some("App".into()));
        assert_eq!(*activations.borrow(), vec!["App".to_string()]);
    }

    #[test]
    fn a_restored_session_is_not_by_itself_goal_success() {
        // The foreground rung's own condition and the action's verification are separate, and this
        // rung is where they are most easily confused: a transaction that captured, activated,
        // proved and dispatched has done everything the rung promised, and still knows nothing
        // about whether the target acted on what `SendInput` posted. The reported hand-back does
        // not supply that missing verification. `click`
        // declares no postcondition, so nothing here can say that it did.
        let backend = backend(vec![], None);
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({
                    "target": {"location": {"app": "App", "text": "root"}},
                    "app": "App",
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

        let result = action_result(&response);
        assert_eq!(*clicks.borrow(), 1, "the events went out");
        assert_eq!(result["foreground"]["restored"], json!(true));
        assert_eq!(result["dispatchSuccess"], json!(true));
        assert_eq!(result["dispatch"]["success"], json!(true));
        assert_eq!(
            result["success"],
            json!(false),
            "a dispatch that verified nothing is not a successful action, however cleanly the \
             session was handed back"
        );
        assert_eq!(
            result["verification"]["reason"],
            json!("click has no declared postcondition"),
            "the caller is told what is missing rather than left to infer it"
        );
    }

    #[test]
    fn a_verified_goal_is_what_makes_a_foreground_dispatch_successful() {
        // The other half of the same rule, so the assertion above cannot be satisfied by a
        // `success` that is simply hardwired false. A postcondition that verified promotes the
        // action, and the transaction's own condition still gates it.
        let mut router = Router::new(backend(vec![], None));
        let candidate = DeliveryCandidate::available(
            DeliveryRung::Foreground,
            DeliveryCapability::GlobalInput,
            "SendInput",
        );

        let promoted = router
            .foreground_dispatch(
                DeliveryPolicy::ForegroundPermitted,
                &candidate,
                ForegroundTarget::Application("App"),
                false,
                json!({"verified": true, "observed": "anything"}),
                |backend| backend.pointer_click((10.0, 10.0)),
            )
            .expect("a proved activation dispatches");

        assert_eq!(promoted["success"], json!(true));
        assert_eq!(promoted["dispatchSuccess"], json!(true));
        assert_eq!(promoted["foreground"]["restored"], json!(true));
    }

    #[test]
    fn resolved_application_prefers_the_captured_process_over_the_window_title() {
        let mut router = Router::new(backend(vec![], None));
        router.backend.snapshot.app.process_id = Some(3024);
        router.backend.snapshot.app.name = "Continue - Microsoft Edge".into();
        router.snapshot = Some(router.backend.snapshot.clone());

        assert_eq!(router.resolved_application().as_deref(), Some("3024"));
    }

    #[test]
    fn foreground_escalation_refuses_without_dispatching_when_activation_is_not_proved() {
        let backend = backend(vec![], None);
        backend.refuses_activation.borrow_mut().push("App".into());
        let clicks = backend.clicks.clone();
        let frontmost = backend.frontmost.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "keyboard",
                json!({"text": "x", "app": "App", "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();

        let result = action_result(&response);
        assert_eq!(result["refusal"]["reason"], json!("activationNotProved"));
        assert_eq!(result["dispatchSuccess"], json!(false));
        assert_eq!(result["delivery"], Value::Null);
        // Posting global keystrokes at this moment would send them wherever the user is working.
        assert_eq!(*clicks.borrow(), 0);
        assert_eq!(frontmost.borrow().as_deref(), Some("Prior"));
    }

    #[test]
    fn a_failed_hand_back_is_reported_and_does_not_fail_a_verified_action() {
        let backend = backend(vec![], None);
        backend.refuses_activation.borrow_mut().push("Prior".into());
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({
                    "target": {"location": {"app": "App", "text": "root"}},
                    "app": "App",
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

        let result = action_result(&response);
        assert_eq!(result["dispatchSuccess"], json!(true));
        assert_eq!(result["delivery"], json!("foreground"));
        assert_eq!(result["foreground"]["restored"], json!(false));
        // The unverified action still fails for its own reason; cleanup is reported independently.
        assert_eq!(result["success"], json!(false));

        // Asserted again with verification satisfied to show that failed cleanup does not downgrade
        // the action. The first dispatch left the target forward,
        // so the foreground is put back by hand first: a target that already holds it activates
        // nothing and has nothing to restore, which is a different case than the one under test.
        *router.backend.frontmost.borrow_mut() = Some("Prior".into());
        let candidate = DeliveryCandidate::available(
            DeliveryRung::Foreground,
            DeliveryCapability::GlobalInput,
            "SendInput",
        );
        let verified = router
            .foreground_dispatch(
                DeliveryPolicy::ForegroundPermitted,
                &candidate,
                ForegroundTarget::Application("App"),
                false,
                json!({"verified": true, "observed": "anything"}),
                |backend| backend.pointer_click((10.0, 10.0)),
            )
            .expect("a proved activation dispatches");
        assert_eq!(verified["foreground"]["restored"], json!(false));
        assert_eq!(verified["dispatchSuccess"], json!(true));
        assert_eq!(
            verified["success"],
            json!(true),
            "a verified foreground action succeeds while failed cleanup remains reported"
        );
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
        let mut backend = backend(vec![], None);
        backend.global_input_usable = false;
        let mut router = Router::new(backend);

        for params in [json!({}), json!({"text": "x", "key": "Return"})] {
            let response = router.request(request("keyboard", params.clone())).unwrap();

            let JsonRpcResponse::Failure(failure) = response else {
                panic!("a keyboard request carrying neither or both intents is malformed: {params}")
            };
            assert_eq!(failure.error.code, -32602, "{params}");
        }
    }

    #[test]
    fn keyboard_aimed_at_an_application_that_is_not_running_refuses_rather_than_typing_elsewhere() {
        // Falling through to the frontmost here would post keystrokes into whatever the user
        // happens to be working in, having been asked for something else entirely.
        let backend = backend(vec![], None);
        let activations = backend.activations.clone();
        let mut router = Router::new(backend);

        let response = router
            .request(request(
                "keyboard",
                json!({"text": "x", "app": "Absent", "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();

        let result = action_result(&response);
        assert_eq!(
            result["refusal"]["reason"],
            json!("targetIdentityUnavailable")
        );
        assert_eq!(result["dispatchSuccess"], json!(false));
        assert!(activations.borrow().is_empty(), "nothing was activated");
    }

    #[test]
    fn send_input_requires_the_foreground_opt_in_and_refuses_without_it() {
        let backend = backend(vec![], None);
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let refused = router
            .request(request(
                "click",
                json!({"target": {"location": {"app": "App", "text": "root"}}}),
            ))
            .unwrap();
        let result = action_result(&refused);
        assert_eq!(result["success"], json!(false));
        assert_eq!(result["strategy"], json!("refused"));
        assert_eq!(result["delivery"], Value::Null);
        assert_eq!(result["dispatchSuccess"], json!(false));
        assert_eq!(result["refusal"]["reason"], json!("foregroundNotPermitted"));
        assert_eq!(result["refusal"]["requiredRung"], json!("foreground"));
        assert_eq!(result["refusal"]["capability"], json!("globalInput"));
        assert_eq!(*clicks.borrow(), 0, "a refusal reaches no backend call");

        let permitted = router
            .request(request(
                "click",
                json!({"target": {"location": {"app": "App", "text": "root"}}, "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();
        let result = action_result(&permitted);
        assert_eq!(result["delivery"], json!("foreground"));
        assert_eq!(result["dispatchSuccess"], json!(true));
        assert_eq!(result["refusal"], Value::Null);
        assert_eq!(result["dispatch"]["mechanism"], json!("SendInput"));
        assert_eq!(*clicks.borrow(), 1);
    }

    #[test]
    fn keyboard_requires_opt_in_and_dispatches_once_to_a_named_application() {
        let backend = backend(vec![], None);
        let dispatches = backend.keyboard_dispatches.clone();
        let activations = backend.activations.clone();
        let mut router = Router::new(backend);

        let refused = router
            .request(request("keyboard", json!({"app":"App", "key":"ctrl+l"})))
            .unwrap();
        let refused = action_result(&refused);
        assert_eq!(
            refused["refusal"]["reason"],
            json!("foregroundNotPermitted")
        );
        assert_eq!(refused["dispatchSuccess"], json!(false));
        assert_eq!(*dispatches.borrow(), 0);
        assert!(
            refused["refusal"]["alsoRefused"]
                .to_string()
                .contains("named editable element")
        );

        let permitted = router
            .request(request(
                "keyboard",
                json!({"app":"App", "key":"ctrl+l", "deliveryPolicy":"foregroundPermitted"}),
            ))
            .unwrap();
        let permitted = action_result(&permitted);
        assert_eq!(permitted["delivery"], json!("foreground"));
        assert_eq!(permitted["dispatchSuccess"], json!(true));
        assert_eq!(permitted["foreground"]["activationProved"], json!(true));
        assert_eq!(*dispatches.borrow(), 1);
        assert_eq!(
            *activations.borrow(),
            vec!["App".to_string(), "Prior".to_string()]
        );
    }

    #[test]
    fn keyboard_without_an_application_targets_the_frontmost_without_activation() {
        let backend = backend(vec![], None);
        let dispatches = backend.keyboard_dispatches.clone();
        let activations = backend.activations.clone();
        let mut router = Router::new(backend);
        let response = router
            .request(request(
                "keyboard",
                json!({"key":"Return", "deliveryPolicy":"foregroundPermitted"}),
            ))
            .unwrap();
        let result = action_result(&response);
        assert_eq!(result["dispatchSuccess"], json!(true));
        assert_eq!(result["foreground"]["alreadyFrontmost"], json!(true));
        assert_eq!(result["foreground"]["restored"], json!(true));
        assert_eq!(*dispatches.borrow(), 1);
        assert!(activations.borrow().is_empty());
    }

    #[test]
    fn keyboard_targeted_by_process_id_activates_and_dispatches_once() {
        let backend = backend(vec![], None);
        let dispatches = backend.keyboard_dispatches.clone();
        let activations = backend.activations.clone();
        let mut router = Router::new(backend);
        let response = router
            .request(request(
                "keyboard",
                json!({"app":"4242", "key":"ctrl+l", "deliveryPolicy":"foregroundPermitted"}),
            ))
            .unwrap();
        let result = action_result(&response);
        assert_eq!(result["dispatchSuccess"], json!(true));
        assert_eq!(result["foreground"]["activationProved"], json!(true));
        assert_eq!(*dispatches.borrow(), 1);
        assert_eq!(
            *activations.borrow(),
            vec!["4242".to_string(), "Prior".to_string()]
        );
    }

    #[test]
    fn a_session_without_global_input_refuses_even_with_the_opt_in() {
        let mut backend = backend(vec![], None);
        // Session 0 and noninteractive window stations arrive here as an unusable capability.
        backend.global_input_usable = false;
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        for policy in ["backgroundOnly", "foregroundPermitted"] {
            let response = router
                .request(request(
                    "keyboard",
                    json!({"text": "x", "deliveryPolicy": policy}),
                ))
                .unwrap();
            let result = action_result(&response);
            // Opting in cannot conjure a device, so the refusal names the missing mechanism
            // rather than sending the caller after a permission that changes nothing.
            assert_eq!(
                result["refusal"]["reason"],
                json!("noDeliveryCandidate"),
                "{policy}"
            );
            assert_eq!(
                result["refusal"]["message"],
                json!("session 0 has no interactive window station"),
                "{policy}"
            );
            assert_eq!(result["dispatchSuccess"], json!(false), "{policy}");
        }
        assert_eq!(*clicks.borrow(), 0);
    }

    #[test]
    fn scroll_uses_canonical_defaults_and_rejects_malformed_deltas_before_capture() {
        let backend = backend(vec![node("save")], None);
        let captures = backend.capture_queries.clone();
        let mut router = Router::new(backend);
        let name = router
            .register_snapshot(&router.backend.snapshot.clone())
            .into_iter()
            .find(|name| name.label == "save")
            .unwrap()
            .name;

        let malformed = router
            .request(request(
                "scroll",
                json!({"target": {"app": "App", "name": name}, "deltaY": "down"}),
            ))
            .unwrap();
        let JsonRpcResponse::Failure(error) = malformed else {
            panic!("malformed delta must fail")
        };
        assert_eq!(error.error.code, -32602);
        assert!(error.error.message.contains("deltaY must be a number"));
        assert!(captures.borrow().is_empty());

        let defaulted = router
            .request(request(
                "scroll",
                json!({"target": {"app": "App", "name": name}}),
            ))
            .unwrap();
        let JsonRpcResponse::Success(success) = defaulted else {
            panic!("canonical defaults must route")
        };
        assert_eq!(
            success.result["dispatch"]["mechanism"],
            json!("UIA ScrollPattern.Scroll")
        );
    }

    #[test]
    fn delta_scroll_reports_position_verification_and_goal_success() {
        let backend = backend(vec![node("save")], None);
        let mut router = Router::new(backend);
        let name = router
            .register_snapshot(&router.backend.snapshot.clone())
            .into_iter()
            .find(|name| name.label == "save")
            .unwrap()
            .name;

        let response = router
            .request(request(
                "scroll",
                json!({"target": {"app": "App", "name": name}, "deltaY": -120.0}),
            ))
            .unwrap();
        let JsonRpcResponse::Success(success) = &response else {
            panic!("{response:?}")
        };
        let result = &success.result;

        assert_eq!(
            result["dispatch"]["mechanism"],
            json!("UIA ScrollPattern.Scroll")
        );
        assert_eq!(result["dispatchSuccess"], json!(true));
        assert_eq!(result["verification"]["verified"], json!(true));
        assert_eq!(result["success"], json!(true));
    }

    #[test]
    fn bring_into_view_names_its_distinct_mechanism_and_stays_unverified() {
        let backend = backend(vec![node("save")], None);
        let mut router = Router::new(backend);
        let name = router
            .register_snapshot(&router.backend.snapshot.clone())
            .into_iter()
            .find(|name| name.label == "save")
            .unwrap()
            .name;

        let response = router
            .request(request(
                "scroll",
                json!({"target": {"app": "App", "name": name}, "deltaX": 0.0, "deltaY": 0.0}),
            ))
            .unwrap();
        let JsonRpcResponse::Success(success) = &response else {
            panic!("{response:?}")
        };
        let result = &success.result;

        assert_eq!(
            result["dispatch"]["mechanism"],
            json!("UIA ScrollItemPattern.ScrollIntoView")
        );
        assert_eq!(result["verification"]["verified"], json!(false));
        assert_eq!(result["success"], json!(false));
    }

    #[test]
    fn unknown_semantic_names_fail_closed_without_dispatch() {
        let backend = backend(vec![], Some("before"));
        let focuses = backend.focuses.clone();
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);

        for (method, params) in [
            (
                "invoke",
                json!({"target": {"app": "App", "name": "root"}, "name": "Invoke"}),
            ),
            (
                "type",
                json!({"target": {"app": "App", "name": "root"}, "value": "after"}),
            ),
            (
                "scroll",
                json!({"target": {"app": "App", "name": "root"}, "deltaY": -120.0}),
            ),
        ] {
            let response = router.request(request(method, params)).unwrap();
            let JsonRpcResponse::Failure(error) = response else {
                panic!("{method} must fail for an unknown semantic name")
            };
            assert_eq!(error.error.code, -32002, "{method}");
            assert_eq!(
                error.error.data.as_ref().and_then(|v| v["status"].as_str()),
                Some("missing")
            );
        }
        assert_eq!(*clicks.borrow(), 0);
        assert_eq!(*focuses.borrow(), 0);
    }

    #[test]
    fn an_unknown_policy_fails_before_resolution_or_dispatch() {
        let backend = backend(vec![], None);
        let clicks = backend.clicks.clone();
        let focuses = backend.focuses.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        for method in ["click", "type", "keyboard", "scroll", "invoke"] {
            let response = router
                .request(request(
                    method,
                    json!({
                        "target": {"location": {"app": "App", "text": "root"}},
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
    fn axn_unknown_semantic_name_fails_closed_without_dispatch() {
        let backend = backend(vec![], Some("ready now"));
        let clicks = backend.clicks.clone();
        let focuses = backend.focuses.clone();
        let mut router = Router::new(backend);
        let actions = json!([{
            "tool": "invoke",
            "name": "Invoke",
            "target": {"app": "App", "name": "missing", "locator": {"role": "definitely-missing"}}
        }]);

        let response = router
            .request(request("run", json!({"actions": actions})))
            .unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!("the .axn run itself returns a batch result")
        };
        let batch = &success.result["batch"];
        assert_eq!(batch["success"], json!(false));
        assert_eq!(batch["trace"].as_array().unwrap().len(), 1);
        assert!(
            batch["trace"][0]["error"]
                .as_str()
                .unwrap()
                .contains("semantic name not found")
        );
        assert_eq!(*clicks.borrow(), 0);
        assert_eq!(*focuses.borrow(), 0);

        let dry = router
            .request(request("run", json!({"actions":actions,"dryRun":true})))
            .unwrap();
        let JsonRpcResponse::Success(dry) = dry else {
            panic!("dry-run returns a batch result")
        };
        assert_eq!(dry.result["batch"]["dryRun"], json!(true));
        assert_eq!(dry.result["batch"]["success"], json!(true));
        assert_eq!(
            dry.result["batch"]["trace"][0]["result"]["target"],
            json!({"app": "App", "name": "missing"})
        );
        assert_eq!(*clicks.borrow(), 0);
        assert_eq!(*focuses.borrow(), 0);
    }

    /// The pixel rung's router half: which rung a click takes, what a refusal names, and what a
    /// dispatch is allowed to claim. All of it runs against fakes, so it is verified on the
    /// machine this backend is developed on rather than only on the machine it ships to.
    mod pixel {
        use super::*;

        fn bound(backend: &FakeBackend) {
            *backend.pixel_plan.borrow_mut() = PixelPlan::Bound(pixel_target());
        }

        #[test]
        fn a_bound_plan_delivers_at_the_pixel_rung_under_the_default_policy() {
            // The whole point of the rung: the default policy, which forbids activation and global
            // input, now carries a click all the way to the target.
            let backend = backend(vec![], None);
            bound(&backend);
            let clicks = backend.clicks.clone();
            let activations = backend.activations.clone();
            let dispatches = backend.pixel_dispatches.clone();
            let mut router = Router::new(backend);
            router.snapshot = Some(router.backend.snapshot.clone());

            let response = router
                .request(request(
                    "click",
                    json!({"target": {"location": {"app": "App", "text": "root"}}}),
                ))
                .unwrap();

            let result = action_result(&response);
            assert_eq!(result["delivery"], json!("pixel"));
            assert_eq!(result["dispatchSuccess"], json!(true));
            // Delivered, and not thereby successful. See the dedicated case below.
            assert_eq!(result["success"], json!(false));
            assert_eq!(result["refusal"], Value::Null);
            assert_eq!(result["deliveryPolicy"], json!("backgroundOnly"));
            assert_eq!(
                result["dispatch"]["mechanism"],
                json!("HWND client-coordinate message")
            );
            assert_eq!(result["verification"]["verified"], json!(false));
            assert_eq!(*dispatches.borrow(), 1);
            assert_eq!(*clicks.borrow(), 0, "the pixel rung is not SendInput");
            assert!(
                activations.borrow().is_empty(),
                "the pixel rung activates nothing"
            );
        }

        #[test]
        fn a_clean_delivery_is_dispatch_evidence_and_not_goal_success() {
            // The distinction this rung exists inside, and the one `PIXEL_MESSAGE_CLASSES` is
            // built to defend. A window procedure that examines a message and does nothing
            // returns from it exactly like one that acts on it, so a completed post proves the
            // handler ran and never proves it did anything. `click` declares no postcondition, so
            // nothing here verifies the goal and `success` says so.
            //
            // Collapsing the two would hollow out that table: a class that regressed, or one that
            // behaved differently in a context nobody probed, would otherwise produce an accepted
            // post, intact invariants, and a report that the caller's click had worked.
            let backend = backend(vec![], None);
            bound(&backend);
            let dispatches = backend.pixel_dispatches.clone();
            let mut router = Router::new(backend);
            router.snapshot = Some(router.backend.snapshot.clone());

            let response = router
                .request(request(
                    "click",
                    json!({"target": {"location": {"app": "App", "text": "root"}}}),
                ))
                .unwrap();

            let result = action_result(&response);
            assert_eq!(*dispatches.borrow(), 1, "the messages were posted");
            assert_eq!(result["dispatchSuccess"], json!(true));
            assert_eq!(result["dispatch"]["success"], json!(true));
            assert_eq!(
                result["success"],
                json!(false),
                "a delivered dispatch that verified nothing is not a successful action"
            );
            assert_eq!(result["verification"]["verified"], json!(false));
            assert_eq!(
                result["verification"]["reason"],
                json!("click has no declared postcondition"),
                "the caller is told what is missing rather than left to infer it"
            );
        }

        #[test]
        fn a_verified_goal_is_what_makes_a_pixel_dispatch_successful() {
            // The other half of the same rule, so the assertion above cannot be satisfied by a
            // `success` that is simply hardwired false. A postcondition that verified promotes the
            // action, and the rung's own invariants still gate it.
            let backend = backend(vec![], None);
            bound(&backend);
            let mut router = Router::new(backend);
            router.snapshot = Some(router.backend.snapshot.clone());

            let response = router
                .request(request(
                    "click",
                    json!({"target": {"location": {"app": "App", "text": "root"}}}),
                ))
                .unwrap();
            let delivered = action_result(&response).clone();

            let candidate = DeliveryCandidate::available(
                DeliveryRung::Pixel,
                DeliveryCapability::BackgroundPixelInput,
                PIXEL_MECHANISM,
            );
            let promoted = router
                .dispatch_pixel(
                    DeliveryPolicy::BackgroundOnly,
                    &candidate,
                    &pixel_target(),
                    PointerContract::Asserted,
                    json!({"verified": true, "observed": "anything"}),
                )
                .expect("a bound target dispatches");

            assert_eq!(delivered["success"], json!(false));
            assert_eq!(promoted["success"], json!(true));
            assert_eq!(promoted["dispatchSuccess"], json!(true));
        }

        #[test]
        fn a_pixel_result_reports_the_window_and_the_transform_that_reached_it() {
            // A dispatch into the wrong window is only diagnosable afterwards if both the window and
            // the arithmetic that chose the point are on the wire.
            let backend = backend(vec![], None);
            bound(&backend);
            let mut router = Router::new(backend);
            router.snapshot = Some(router.backend.snapshot.clone());

            let response = router
                .request(request(
                    "click",
                    json!({"target": {"location": {"app": "App", "text": "root"}}}),
                ))
                .unwrap();

            let result = action_result(&response);
            let window = &result["targetWindow"];
            assert_eq!(window["nativeWindowHandle"], json!("0x000407AE"));
            assert_eq!(window["rootNativeWindowHandle"], json!("0x00030B12"));
            assert_eq!(window["windowClass"], json!("Chrome_RenderWidgetHostHWND"));
            assert_eq!(window["sourceCoordinateSpace"], json!("screen"));
            let target = pixel_target();
            assert_eq!(
                (
                    window["clientOrigin"]["x"].as_f64().unwrap()
                        + window["windowPoint"]["x"].as_f64().unwrap(),
                    window["clientOrigin"]["y"].as_f64().unwrap()
                        + window["windowPoint"]["y"].as_f64().unwrap(),
                ),
                target.screen_point,
                "the reported transform reconstructs the screen point"
            );
            assert_eq!(
                result["backgroundDelivery"],
                json!({
                    "targetProcessIdentifier": 4812,
                    "frontmostAppUnchanged": true,
                    "pointerUnchanged": true,
                    // A click sends pointer messages, so where the cursor ended up is a promise
                    // this dispatch made rather than a reading taken beside it.
                    "pointerAsserted": true
                })
            );
        }

        #[test]
        fn the_pixel_candidate_carries_the_plans_own_obstacle() {
            let router = Router::new(backend(vec![], None));
            let ladder = router.pointer_ladder(&PixelPlan::unavailable(
                "window class Widget has no probe-verified client-coordinate message path",
            ));

            let pixel = &ladder[0];
            assert_eq!(pixel.rung, DeliveryRung::Pixel);
            assert_eq!(
                pixel.unavailable,
                Some(DeliveryRefusalReason::BackgroundPixelUnsupported)
            );
            assert_eq!(
                pixel.unavailable_message.as_deref(),
                Some("window class Widget has no probe-verified client-coordinate message path")
            );
            assert!(
                ladder[1].is_available(),
                "a rung-specific obstacle leaves the louder rung alone"
            );
        }

        #[test]
        fn keyboard_has_no_pixel_rung_because_it_names_no_element() {
            // Not scope being trimmed: the rung is target-bound input derived from verified window
            // geometry, and `keyboard` carries an app name and a string.
            let router = Router::new(backend(vec![], None));
            let ladder = router.keyboard_ladder();

            assert_eq!(
                ladder[0].unavailable,
                Some(DeliveryRefusalReason::BackgroundPixelUnsupported)
            );
            let message = ladder[0].unavailable_message.clone().unwrap();
            assert!(
                message.contains("names an application rather than an element"),
                "{message}"
            );
            assert!(message.contains("window geometry"), "{message}");
        }

        #[test]
        fn an_unavailable_plan_under_the_default_policy_dispatches_nothing() {
            let backend = backend(vec![], None);
            let clicks = backend.clicks.clone();
            let dispatches = backend.pixel_dispatches.clone();
            let mut router = Router::new(backend);
            router.snapshot = Some(router.backend.snapshot.clone());

            let response = router
                .request(request(
                    "click",
                    json!({"target": {"location": {"app": "App", "text": "root"}}}),
                ))
                .unwrap();

            let result = action_result(&response);
            // The policy boundary outranks the capability gap below it: opting in is the actionable
            // thing this caller can do, and it would work.
            assert_eq!(result["refusal"]["reason"], json!("foregroundNotPermitted"));
            assert_eq!(result["dispatchSuccess"], json!(false));
            assert_eq!(*clicks.borrow(), 0);
            assert_eq!(*dispatches.borrow(), 0);
        }

        #[test]
        fn the_plans_own_obstacle_reaches_the_caller_beside_the_policy_refusal() {
            // The whole path, from the plan this backend built to what a caller reads. The window
            // class with no verified message path is the product of the probe work, and the policy
            // boundary above it is the reported reason. Both have to arrive: one says what to do
            // next, the other says whether the quiet rung would ever carry this target at all.
            let backend = backend(vec![], None);
            *backend.pixel_plan.borrow_mut() = PixelPlan::unavailable(
                "window class Widget has no probe-verified client-coordinate message path",
            );
            let clicks = backend.clicks.clone();
            let dispatches = backend.pixel_dispatches.clone();
            let mut router = Router::new(backend);
            router.snapshot = Some(router.backend.snapshot.clone());

            let response = router
                .request(request(
                    "click",
                    json!({"target": {"location": {"app": "App", "text": "root"}}}),
                ))
                .unwrap();

            let result = action_result(&response);
            assert_eq!(result["refusal"]["reason"], json!("foregroundNotPermitted"));
            let obstacle = &result["refusal"]["alsoRefused"][0];
            assert_eq!(obstacle["rung"], json!("pixel"));
            assert_eq!(obstacle["reason"], json!("backgroundPixelUnsupported"));
            assert_eq!(
                obstacle["message"],
                json!("window class Widget has no probe-verified client-coordinate message path")
            );
            assert_eq!(*clicks.borrow(), 0);
            assert_eq!(*dispatches.borrow(), 0);
        }

        #[test]
        fn an_unavailable_plan_escalates_to_the_foreground_when_permitted() {
            let backend = backend(vec![], None);
            let clicks = backend.clicks.clone();
            let dispatches = backend.pixel_dispatches.clone();
            let mut router = Router::new(backend);
            router.snapshot = Some(router.backend.snapshot.clone());

            let response = router
                .request(request(
                    "click",
                    json!({"target": {"location": {"app": "App", "text": "root"}}, "deliveryPolicy": "foregroundPermitted"}),
                ))
                .unwrap();

            let result = action_result(&response);
            assert_eq!(result["delivery"], json!("foreground"));
            assert_eq!(result["foreground"]["activationProved"], json!(true));
            assert_eq!(*clicks.borrow(), 1);
            assert_eq!(*dispatches.borrow(), 0);
        }

        #[test]
        fn an_obstacle_that_blocks_all_input_refuses_both_rungs_and_names_itself() {
            // An elevated target is the case. Answering it with foregroundNotPermitted would send the
            // caller after an opt-in that buys a dispatch UIPI discards.
            let backend = backend(vec![], None);
            *backend.pixel_plan.borrow_mut() = PixelPlan::blocked(
                "the target window runs at a higher integrity level than the daemon; UIPI discards \
             posted input",
            );
            let clicks = backend.clicks.clone();
            let dispatches = backend.pixel_dispatches.clone();
            let activations = backend.activations.clone();
            let mut router = Router::new(backend);
            router.snapshot = Some(router.backend.snapshot.clone());

            for policy in ["backgroundOnly", "foregroundPermitted"] {
                let response = router
                    .request(request(
                        "click",
                        json!({"target": {"location": {"app": "App", "text": "root"}}, "deliveryPolicy": policy}),
                    ))
                    .unwrap();
                let result = action_result(&response);
                assert_eq!(
                    result["refusal"]["reason"],
                    json!("noDeliveryCandidate"),
                    "{policy}"
                );
                assert!(
                    result["refusal"]["message"]
                        .as_str()
                        .unwrap()
                        .contains("integrity level"),
                    "{policy}: {}",
                    result["refusal"]["message"]
                );
            }
            assert_eq!(*clicks.borrow(), 0);
            assert_eq!(*dispatches.borrow(), 0);
            assert!(activations.borrow().is_empty());
        }

        #[test]
        fn a_broken_ancestry_between_planning_and_dispatch_posts_nothing() {
            for reason in [
                "the resolved element is no longer inside the captured window",
                "the receiving window moved between planning and dispatch",
            ] {
                let backend = backend(vec![], None);
                bound(&backend);
                *backend.pixel_result.borrow_mut() =
                    Err(PixelDispatchError::Stale(reason.to_string()));
                let clicks = backend.clicks.clone();
                let dispatches = backend.pixel_dispatches.clone();
                let activations = backend.activations.clone();
                let mut router = Router::new(backend);
                router.snapshot = Some(router.backend.snapshot.clone());

                let response = router
                    .request(request(
                        "click",
                        json!({"target": {"location": {"app": "App", "text": "root"}}}),
                    ))
                    .unwrap();

                // A target that changed under the request is stale, not refused: the request was
                // answerable when it arrived and is not answerable now.
                let JsonRpcResponse::Failure(failure) = response else {
                    panic!("a failed revalidation is a stale-target error: {reason}")
                };
                assert_eq!(failure.error.code, -32003, "{reason}");
                assert_eq!(failure.error.message, reason);
                assert_eq!(*dispatches.borrow(), 0, "{reason}");
                assert_eq!(*clicks.borrow(), 0, "{reason}");
                assert!(activations.borrow().is_empty(), "{reason}");
            }
        }

        #[test]
        fn a_partial_dispatch_fails_without_falling_through_to_a_louder_rung() {
            // Half a sequence may have left the target believing the button is held. A second attempt
            // at another rung would compound that rather than recover from it.
            let backend = backend(vec![], None);
            bound(&backend);
            *backend.pixel_result.borrow_mut() = Ok(PixelDispatch {
            complete: false,
            partial: Some("the button-up message was refused twice; the target may still consider the left button held".into()),
            frontmost_unchanged: true,
            pointer_unchanged: true,
        });
            let clicks = backend.clicks.clone();
            let mut router = Router::new(backend);
            router.snapshot = Some(router.backend.snapshot.clone());

            let response = router
                .request(request(
                    "click",
                    json!({"target": {"location": {"app": "App", "text": "root"}}, "deliveryPolicy": "foregroundPermitted"}),
                ))
                .unwrap();

            let result = action_result(&response);
            assert_eq!(result["delivery"], json!("pixel"), "the rung did run");
            assert_eq!(result["dispatchSuccess"], json!(false));
            assert_eq!(result["success"], json!(false));
            assert_eq!(result["dispatch"]["success"], json!(false));
            assert!(
                result["message"]
                    .as_str()
                    .unwrap()
                    .contains("still consider the left button held"),
                "{}",
                result["message"]
            );
            assert_eq!(
                *clicks.borrow(),
                0,
                "a rung that delivered anything never escalates, opt-in or not"
            );
        }

        #[test]
        fn a_dispatch_that_broke_the_rungs_own_invariants_fails_with_its_evidence_intact() {
            for (frontmost, pointer, expected) in [
                (false, true, "foreground window changed"),
                (true, false, "real pointer moved"),
            ] {
                let backend = backend(vec![], None);
                bound(&backend);
                *backend.pixel_result.borrow_mut() = Ok(PixelDispatch {
                    complete: true,
                    partial: None,
                    frontmost_unchanged: frontmost,
                    pointer_unchanged: pointer,
                });
                let mut router = Router::new(backend);
                router.snapshot = Some(router.backend.snapshot.clone());

                let response = router
                    .request(request(
                        "click",
                        json!({"target": {"location": {"app": "App", "text": "root"}}}),
                    ))
                    .unwrap();

                let result = action_result(&response);
                assert_eq!(result["success"], json!(false), "{expected}");
                // The messages went out; they just did not go out quietly. Both facts are reported.
                assert_eq!(result["dispatchSuccess"], json!(true), "{expected}");
                assert_eq!(result["delivery"], json!("pixel"), "{expected}");
                assert!(
                    result["message"].as_str().unwrap().contains(expected),
                    "{expected}: {}",
                    result["message"]
                );
                assert_eq!(
                    result["backgroundDelivery"]["frontmostAppUnchanged"],
                    json!(frontmost)
                );
                assert_eq!(
                    result["backgroundDelivery"]["pointerUnchanged"],
                    json!(pointer)
                );
            }
        }

        #[test]
        fn a_text_location_click_travels_the_pixel_rung_when_its_element_binds() {
            // The same ladder, reached through the other target form.
            let backend = backend(vec![node("save")], None);
            bound(&backend);
            let clicks = backend.clicks.clone();
            let dispatches = backend.pixel_dispatches.clone();
            let mut router = Router::new(backend);

            let response = router
                .request(request(
                    "click",
                    json!({"target": {"location": {"app": "App", "text": "save"}}}),
                ))
                .unwrap();

            let result = action_result(&response);
            assert_eq!(result["delivery"], json!("pixel"));
            assert_eq!(result["resolution"]["status"], json!("unique"));
            assert_eq!(*dispatches.borrow(), 1);
            assert_eq!(*clicks.borrow(), 0);
        }

        #[test]
        fn a_click_on_recognized_text_alone_never_binds_a_window() {
            // Screen text gives a point, not an element, so there is no ancestry to bind a window to
            // however willing the backend is to plan one. Inferring a window from a bare screen point
            // is precisely what the rung forbids.
            let mut backend = backend(vec![], None);
            backend.recognized = vec![recognized("Save", 100.0)];
            bound(&backend);
            let clicks = backend.clicks.clone();
            let dispatches = backend.pixel_dispatches.clone();
            let mut router = Router::new(backend);

            let response = router
            .request(request(
                "click",
                json!({
                    "target": {"location": {"app": "App", "text": "save", "source": "screenshot"}},
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

            let result = action_result(&response);
            assert_eq!(result["resolution"]["best"]["source"], json!("screenshot"));
            assert_eq!(result["delivery"], json!("foreground"));
            assert_eq!(*dispatches.borrow(), 0);
            assert_eq!(*clicks.borrow(), 1);
        }
    }
}
