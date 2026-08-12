//! Linux AT-SPI backend and v1 JSON-RPC tool router.

use axon_core::{
    AppQuery, AxnCodec, AxnRunner, Capability, DeliveryCandidate, DeliveryCapability,
    DeliveryOutcome, DeliveryPolicy, DeliveryRefusal, DeliveryRefusalReason, DeliveryRung,
    DeliverySelection, DispatchOutcome, ExpectedFact, ForegroundTarget, JsonRpcError, JsonRpcId,
    JsonRpcRequest, JsonRpcResponse, KeyboardIntent, PlatformBackend, Resolution, RunEnvelope,
    RunOptions, SemanticLookup, SemanticNameRegistry, Snapshot, SnapshotHandle, ToolDispatcher,
    dispatch_in_foreground, goal_success, select_delivery,
};
use serde_json::{Map, Value, json};

pub mod keys;
pub mod lifecycle;
/// The measured table of which toolkits act on background, window-targeted input. Pure, and public
/// so its entries can be read next to the fixtures they cite.
pub mod pixel;
/// The daemon's local socket transport, in the library so its resilience to hostile clients is
/// testable without a desktop or an AT-SPI bus.
#[cfg(unix)]
pub mod socket;

#[cfg(target_os = "linux")]
mod platform;
#[cfg(target_os = "linux")]
pub use platform::LinuxBackend;
/// The bound a withholding provider is given to publish, and the marker carried by a subtree it
/// never published. Public so the hermetic AT-SPI test asserts against the values the backend uses
/// rather than restating them, which is the kind of duplication that drifts silently.
#[cfg(target_os = "linux")]
pub use platform::{ACTIVATION_TIMEOUT, CHILD_NOT_PUBLISHED};
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

/// What the pixel rung reports as its mechanism: events sent to one window this backend resolved,
/// under the delivery variant the acceptance table names for that window's toolkit.
const PIXEL_MECHANISM: &str = "X11 window-targeted XSendEvent";

/// Why `drag` has no pixel rung, and will not get one in this shape.
///
/// A drag holds a button down across a whole gesture. Nothing in the acceptance table covers that:
/// the harness measured a press immediately followed by a release, and a toolkit that acts on one
/// says nothing about what it does with a button left held by a window it cannot see move.
const NO_DRAG_PIXEL: &str = "a drag holds a button down across a whole gesture, and the measured \
     toolkit acceptance covers only a press and release delivered together";

/// Why a `keyboard` request that names no application cannot travel the pixel rung.
const NO_KEYBOARD_TARGET: &str = "keyboard input naming no application is addressed at whatever \
     holds the foreground, so there is no target window to bind it to";

/// Why a resolved target with no owning application cannot travel the pixel rung either.
const NO_RESOLVED_APPLICATION: &str = "the resolved target's owning application could not be \
     identified, so no window can be bound to it and nothing can be revalidated before dispatch";

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
    semantic_names: SemanticNameRegistry,
}

/// Replay targets may carry recording-only locator evidence. Native tool decoding receives only
/// the primitive semantic target; the shared runner remains responsible for registering the
/// attached locator before crossing this boundary.
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

pub trait PointerTargetVerifier: PlatformBackend {
    fn verify_pointer_target(
        &mut self,
        handle: &SnapshotHandle,
        point: (f64, f64),
    ) -> Result<bool, axon_core::BackendError>;
}

/// A target-bound input mechanism: events delivered to one verified window, without activating the
/// application and without moving the real pointer.
///
/// This is the pixel rung's whole contract expressed as a seam. The router that decides *when* to
/// use it is platform-neutral and testable on any machine against a fake; the mechanism behind it
/// is an X11 conversation with a live toolkit and is not.
pub trait BackgroundPixelInput: PlatformBackend {
    /// Resolves a delivery plan for one click at a point inside a resolved element. Pure
    /// inspection with no native side effect, because the planner may discard the result and
    /// refuse before anything is allowed to happen.
    fn plan_pixel_click(
        &mut self,
        application: &str,
        handle: &SnapshotHandle,
        point: (f64, f64),
    ) -> Result<PixelPlan, axon_core::BackendError>;

    /// Resolves a delivery plan for keystrokes aimed at one application.
    ///
    /// Keyboard input names an application rather than an element, so this binds a window without
    /// converting any coordinates. The window is still resolved, verified against the application
    /// the caller named, and revalidated before dispatch: what the contract forbids is a target
    /// *inferred* from an unscoped point, and there is no point here to infer one from.
    fn plan_pixel_keyboard(
        &mut self,
        application: &str,
    ) -> Result<PixelPlan, axon_core::BackendError>;

    /// Revalidates the plan and delivers a click. A revalidation failure returns `Stale` and must
    /// send nothing: a window that moved or an element that is no longer where it was means the
    /// recorded coordinates now name somewhere else.
    fn dispatch_pixel_click(
        &mut self,
        target: &PixelTarget,
    ) -> Result<PixelDispatch, PixelDispatchError>;

    /// Revalidates the plan and delivers keystrokes, under the same rule.
    fn dispatch_pixel_keyboard(
        &mut self,
        target: &PixelTarget,
        intent: KeyboardIntent<'_>,
    ) -> Result<PixelDispatch, PixelDispatchError>;
}

/// Whether a target-bound mechanism exists for one specific action.
#[derive(Clone, Debug, PartialEq)]
pub enum PixelPlan {
    Bound(Box<PixelTarget>),
    /// No target-bound mechanism here. `reason` names the specific obstacle, because a caller told
    /// only "unsupported" cannot tell a GTK 4 window from an unmeasured Qt release from an
    /// application whose window is currently covered by someone else's.
    Unavailable {
        reason: String,
    },
}

impl PixelPlan {
    pub fn unavailable(reason: impl Into<String>) -> Self {
        PixelPlan::Unavailable {
            reason: reason.into(),
        }
    }
}

/// One window, bound to one application, with whatever the action needs to reach it.
#[derive(Clone, Debug, PartialEq)]
pub struct PixelTarget {
    /// The backend's own identity for the owning application: an AT-SPI bus name and object path.
    /// Revalidated before dispatch, because a restarted application owns a different bus name and
    /// a window id the kernel and the X server have both reused is a different window.
    pub application: String,
    pub process_identifier: u32,
    /// The X11 window that receives the events.
    pub window: u32,
    /// The window's origin on screen and its size: the transform itself, kept so it can be both
    /// revalidated and reported.
    pub window_origin: (f64, f64),
    pub window_size: (f64, f64),
    /// What the application declares about itself, and what that signature cleared it for.
    pub toolkit: pixel::Toolkit,
    pub variant: pixel::SendVariant,
    /// The fixture rows that cleared this toolkit, carried so a dispatch result can cite the
    /// measurement that authorized background input into someone's window.
    pub measured_by: &'static str,
    /// The element and the window-relative point its screen coordinates converted to. Present for
    /// a click; absent for keyboard input, which names an application rather than an element and
    /// therefore has no coordinates to convert.
    pub aim: Option<PixelAim>,
}

/// One element, and the point inside the bound window that its resolved geometry converted to.
#[derive(Clone, Debug, PartialEq)]
pub struct PixelAim {
    pub handle: SnapshotHandle,
    pub screen_point: (f64, f64),
    pub window_point: (f64, f64),
}

impl PixelTarget {
    /// The transform reported as evidence rather than implied.
    ///
    /// A dispatch that landed in the wrong place is only diagnosable after the fact if the window
    /// it went to, the arithmetic that chose the point, and the signature that authorized the
    /// whole thing are all on the wire.
    pub fn evidence(&self) -> Value {
        let mut evidence = json!({
            "nativeWindowHandle": format!("0x{:08X}", self.window),
            "windowOrigin": {"x": self.window_origin.0, "y": self.window_origin.1},
            "windowSize": {"width": self.window_size.0, "height": self.window_size.1},
            "toolkit": self.toolkit.name,
            "toolkitVersion": self.toolkit.version,
            "deliveryVariant": self.variant.key(),
            "measuredBy": self.measured_by,
        });
        if let (Some(object), Some(aim)) = (evidence.as_object_mut(), &self.aim) {
            object.insert(
                "windowPoint".into(),
                json!({"x": aim.window_point.0, "y": aim.window_point.1}),
            );
            object.insert("sourceCoordinateSpace".into(), json!("screen"));
        }
        evidence
    }
}

/// What a delivered sequence did, and the evidence that it stayed in the background.
#[derive(Clone, Debug, PartialEq)]
pub struct PixelDispatch {
    /// Whether the whole sequence reached the target's connection.
    ///
    /// Delivered, not acted on, and the gap is wider here than on any other backend. `XSendEvent`
    /// reports success as soon as the X server accepts the request, and every event it carries is
    /// flagged `send_event`, which a toolkit is free to drop in silence. Nothing on this side can
    /// tell acceptance from silence, which is why the acceptance table exists and why dispatch at
    /// this rung is evidence rather than goal success.
    pub complete: bool,
    /// Set when part of the sequence was sent and the rest was not, naming the state the target
    /// may have been left in. A partial dispatch never escalates.
    pub partial: Option<String>,
    /// Observed across the delivery. The frontmost window and the input focus are separate facts
    /// and both are read: the harness caught Qt acting on a background click while asking to be
    /// activated, which moved the input focus on a session with no window manager while
    /// `_NET_ACTIVE_WINDOW` — which only a manager maintains — stood still.
    pub frontmost_unchanged: bool,
    pub input_focus_unchanged: bool,
    pub pointer_unchanged: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PixelDispatchError {
    /// Revalidation failed between planning and dispatch. Nothing was sent.
    Stale(String),
    Backend(axon_core::BackendError),
}

struct ForegroundDispatch<'candidate, 'target> {
    policy: DeliveryPolicy,
    candidate: &'candidate DeliveryCandidate,
    target: ForegroundTarget<'target>,
    restores_pointer: bool,
    verification: Value,
    resolution: Option<Resolution>,
}

impl<B: PointerTargetVerifier + BackgroundPixelInput> Router<B> {
    pub fn new(backend: B) -> Self {
        Self {
            backend,
            snapshot: None,
            semantic_names: SemanticNameRegistry::default(),
        }
    }
    /// The backend this router drives, for the facts a daemon answers outside the tool surface.
    /// `health` is the whole of that today: the session's accessibility switch is a live reading,
    /// not a static capability, so it is asked for at the moment a health request arrives.
    pub fn backend(&self) -> &B {
        &self.backend
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
                self.dispatch_resolved_click(handle, resolution, policy)
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
                let app = app_query(params);
                // `keyboard` naming no application is explicitly addressed at whatever holds the
                // foreground: nothing to activate, nothing to restore, and nothing to bind a
                // target window to either. Naming one makes it aimed, and both rungs then work
                // from the backend's own identity for that application — not the display name or
                // caller-facing identifier the request carried, which no backend answers with.
                //
                // Resolved before the ladder rather than after it, because the pixel rung needs
                // that identity to bind a window, and a plan has to exist before the ladder can
                // offer the rung or refuse it by name.
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
                                    "the requested application could not be identified, so no \
                                     window can be bound to it and foreground delivery cannot \
                                     activate and prove it",
                                ),
                            ));
                        }
                    }
                } else {
                    None
                };
                let plan = match &target {
                    Some(identity) => Self::planned(self.backend.plan_pixel_keyboard(identity)),
                    None => PixelPlan::unavailable(NO_KEYBOARD_TARGET),
                };
                let ladder =
                    self.global_input_ladder(Capability::KeyboardInput, "XTest keyboard", &plan);
                let Some(candidate) = self.selected(&ladder, policy) else {
                    return Ok(self.refusal(&ladder, policy));
                };
                let verification = json!({
                    "verified": false,
                    "reason": "keyboard input has no declared postcondition",
                });
                if candidate.rung == DeliveryRung::Pixel {
                    let PixelPlan::Bound(bound) = plan else {
                        unreachable!("the pixel rung is only offered for a bound plan")
                    };
                    return self.dispatch_pixel(
                        policy,
                        &candidate,
                        &bound,
                        verification,
                        move |backend, bound| backend.dispatch_pixel_keyboard(bound, intent),
                    );
                }
                self.foreground_dispatch(
                    ForegroundDispatch {
                        policy,
                        candidate: &candidate,
                        target: target
                            .as_deref()
                            .map_or(ForegroundTarget::Frontmost, ForegroundTarget::Application),
                        // Keyboard input never touches the cursor, and capturing a pointer it does
                        // not move would report a restoration that never happened.
                        restores_pointer: false,
                        verification,
                        resolution: None,
                    },
                    move |backend| backend.keyboard(&app, intent),
                )
            }
            "drag" => {
                let ladder = self.global_input_ladder(
                    Capability::PointerInput,
                    "XTest pointer",
                    &PixelPlan::unavailable(NO_DRAG_PIXEL),
                );
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

    fn dispatch_resolved_click(
        &mut self,
        handle: SnapshotHandle,
        resolution: Resolution,
        policy: DeliveryPolicy,
    ) -> Result<Value, JsonRpcError> {
        let point = self.node_center(&handle)?;
        // Planning is pure inspection, so it happens before the ladder decides. The
        // planner may discard this plan and refuse, and by then nothing native may have
        // happened.
        let plan = match self.resolved_application() {
            Some(application) => {
                Self::planned(self.backend.plan_pixel_click(&application, &handle, point))
            }
            None => PixelPlan::unavailable(NO_RESOLVED_APPLICATION),
        };
        let ladder = self.global_input_ladder(Capability::PointerInput, "XTest pointer", &plan);
        let Some(candidate) = self.selected(&ladder, policy) else {
            return Ok(self.refusal(&ladder, policy));
        };
        let verification = json!({"verified":false,"reason":"click has no declared postcondition"});
        if candidate.rung == DeliveryRung::Pixel {
            let PixelPlan::Bound(target) = plan else {
                unreachable!("the pixel rung is only offered for a bound plan")
            };
            // The plan's own revalidation runs inside the dispatch, immediately before
            // anything is sent, and re-reads both the element and the window. Asking the
            // freshness check below for the same fact first would only widen the gap
            // between what was checked and what was delivered into.
            let mut result = self.dispatch_pixel(
                policy,
                &candidate,
                &target,
                verification,
                |backend, target| backend.dispatch_pixel_click(target),
            )?;
            if let Some(object) = result.as_object_mut() {
                object.insert("resolution".into(), json!(resolution));
            }
            return Ok(result);
        }
        if !self
            .backend
            .verify_pointer_target(&handle, point)
            .map_err(backend_error)?
        {
            return Err(rpc_error(
                -32003,
                "click target moved, was destroyed, or no longer matches the resolved \
                 element",
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
            ForegroundDispatch {
                policy,
                candidate: &candidate,
                target: ForegroundTarget::Application(&application),
                // A pointer click moves the real cursor, so the transaction puts it back.
                restores_pointer: true,
                verification,
                resolution: Some(resolution),
            },
            |backend| backend.pointer_click(point),
        )
    }

    /// The ladder for an action that can only travel as input: no semantic rung, a pixel rung the
    /// backend answers for per target, and a foreground rung only where the runtime has one.
    fn global_input_ladder(
        &self,
        capability: Capability,
        mechanism: &str,
        plan: &PixelPlan,
    ) -> Vec<DeliveryCandidate> {
        vec![
            match plan {
                PixelPlan::Bound(_) => DeliveryCandidate::available(
                    DeliveryRung::Pixel,
                    DeliveryCapability::BackgroundPixelInput,
                    PIXEL_MECHANISM,
                ),
                // The plan's own reason travels intact, which is the whole point of building one
                // before the ladder: a caller is owed the name of the toolkit that refused, not a
                // flat "unsupported" that hides whether re-measuring would change the answer.
                PixelPlan::Unavailable { reason } => DeliveryCandidate::unavailable(
                    DeliveryRung::Pixel,
                    DeliveryCapability::BackgroundPixelInput,
                    PIXEL_MECHANISM,
                    DeliveryRefusalReason::BackgroundPixelUnsupported,
                    reason.clone(),
                ),
            },
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
            },
        ]
    }

    /// Asks the backend to bind a target, turning an operational failure into an unavailable plan.
    ///
    /// A pixel rung that could not be planned must not take down an action that could still have
    /// travelled the foreground rung. The backend already answers every obstacle it can name as an
    /// `Unavailable` plan; this is for the calls underneath that simply failed — a bus timeout, an
    /// X server that dropped the connection — which are still an honest reason this rung is not
    /// available for this action right now.
    fn planned(plan: Result<PixelPlan, axon_core::BackendError>) -> PixelPlan {
        plan.unwrap_or_else(|error| {
            PixelPlan::unavailable(format!(
                "the target-bound delivery path could not be planned: {error}"
            ))
        })
    }

    /// Sends one bound sequence to one verified window, and reports what that proved.
    fn dispatch_pixel(
        &mut self,
        policy: DeliveryPolicy,
        candidate: &DeliveryCandidate,
        target: &PixelTarget,
        verification: Value,
        deliver: impl FnOnce(&mut B, &PixelTarget) -> Result<PixelDispatch, PixelDispatchError>,
    ) -> Result<Value, JsonRpcError> {
        let dispatch = match deliver(&mut self.backend, target) {
            Ok(dispatch) => dispatch,
            // Revalidation failed, so nothing was sent and the plan now names somewhere else.
            // That is the same stale target a moved element produces, and it reads the same way.
            Err(PixelDispatchError::Stale(reason)) => return Err(rpc_error(-32003, reason)),
            Err(PixelDispatchError::Backend(error)) => return Err(backend_error(error)),
        };
        // This rung is defined by what it does not do. A dispatch that changed the foreground or
        // moved the real pointer was not background delivery, whatever it managed to deliver, so
        // these gate success as well as being reported.
        let mut problems = Vec::new();
        if let Some(partial) = &dispatch.partial {
            problems.push(partial.clone());
        }
        if !dispatch.frontmost_unchanged {
            problems.push("the frontmost window changed across the dispatch".to_string());
        }
        if !dispatch.input_focus_unchanged {
            problems.push("the X input focus moved across the dispatch".to_string());
        }
        if !dispatch.pointer_unchanged {
            problems.push("the real pointer moved across the dispatch".to_string());
        }
        // Mechanism acceptance and goal success are kept apart because at this rung the gap between
        // them is the whole problem. A completed send proves the events reached the target's
        // connection; every one of them carries `send_event`, and a toolkit that drops them does so
        // in silence that nothing on this side can distinguish from delivery. Collapsing the two
        // would hollow out the acceptance table's own defence: a future Chromium that began
        // filtering these events would produce an accepted send, intact invariants, and a report
        // that the caller's click had worked.
        let mut result = json!({
            "success": goal_success(&verification, dispatch.complete && problems.is_empty()),
            "dispatch": {"success": dispatch.complete, "mechanism": candidate.mechanism},
            "verification": verification,
            "backgroundDelivery": {
                "targetApplication": target.application,
                "targetProcessIdentifier": target.process_identifier,
                "frontmostAppUnchanged": dispatch.frontmost_unchanged,
                "inputFocusUnchanged": dispatch.input_focus_unchanged,
                "pointerUnchanged": dispatch.pointer_unchanged,
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
        request: ForegroundDispatch<'_, '_>,
        body: impl FnOnce(&mut B) -> Result<(), axon_core::BackendError>,
    ) -> Result<Value, JsonRpcError> {
        let dispatch = dispatch_in_foreground(
            &mut self.backend,
            request.target,
            request.restores_pointer,
            body,
        );
        if let Some(refusal) = dispatch.refusal {
            let mut result = DeliveryOutcome::refusal_result(request.policy, refusal);
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

        let mut result = json!({
            // Two separate things have to hold here, and this rung is the one that adds the second.
            // Dispatch evidence survives a failed restoration, but the action as a whole did not
            // succeed if the user's session was not put back where they left it — a cursor left
            // where the click dropped it counts as much as a window that never came forward again.
            // And a session handed back immaculately still says nothing about whether the target
            // acted on what XTest posted, so the verification has to hold as well.
            "success": goal_success(&request.verification, dispatch.cleanup.session_restored()),
            "dispatch": {"success": true, "mechanism": request.candidate.mechanism},
            "verification": request.verification,
            "foreground": dispatch.cleanup,
        });
        if let (Some(object), Some(resolution)) = (result.as_object_mut(), request.resolution) {
            object.insert("resolution".into(), json!(resolution));
        }
        Ok(delivered(result, request.policy, request.candidate.rung))
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
        let app = app_query(params);
        let snapshot = self.backend.capture(&app).map_err(backend_error)?;
        let names = self.semantic_names.register(&snapshot);
        let mut value = serde_json::to_value(axon_core::render_semantic_names(&snapshot, &names))
            .map_err(internal_error)?;
        let wants_screenshot = axon_core::screenshot_requested(
            params.get("screenshot").and_then(Value::as_bool),
            axon_core::LookObservationKind::FullApp,
        );
        if wants_screenshot {
            match self.backend.screenshot(&app) {
                Ok(screenshot) => {
                    value
                        .as_object_mut()
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
                Err(error) => {
                    let unavailable = axon_core::ScreenshotUnavailable::from_backend_error(error);
                    value
                        .as_object_mut()
                        .expect("snapshots serialize as objects")
                        .insert(
                            "screenshotUnavailable".into(),
                            serde_json::to_value(unavailable).map_err(internal_error)?,
                        );
                }
            }
        }
        self.snapshot = Some(snapshot);
        Ok(value)
    }

    fn resolve(
        &mut self,
        params: &Map<String, Value>,
    ) -> Result<(SnapshotHandle, axon_core::Resolution), JsonRpcError> {
        #[cfg(test)]
        if params
            .get("target")
            .and_then(Value::as_object)
            .is_some_and(|target| target.contains_key("x") && target.contains_key("y"))
        {
            let snapshot = self
                .snapshot
                .as_ref()
                .ok_or_else(|| rpc_error(-32002, "no active snapshot; call look first"))?;
            let handle = snapshot.handle(0);
            let node = self.node(&handle)?;
            let candidate = axon_core::Candidate {
                index: 0,
                handle: handle.clone(),
                role: node.role.clone(),
                title: node.title.clone(),
                frame: node.frame,
                score: 0,
                reasons: vec!["explicit point intent".into()],
            };
            return Ok((
                handle,
                Resolution {
                    status: axon_core::ResolutionStatus::Unique,
                    snapshot_id: snapshot.id.clone(),
                    confidence: axon_core::Confidence::High,
                    best: Some(candidate.clone()),
                    candidates: vec![candidate],
                },
            ));
        }
        let target: axon_core::WireElementTarget =
            serde_json::from_value(params.get("target").cloned().unwrap_or(Value::Null))
                .map_err(|_| rpc_error(-32602, "element target must be an {app, name} object"))?;
        let target = target
            .validate()
            .map_err(|error| rpc_error(-32602, error.to_string()))?;
        let live = self
            .backend
            .capture(&AppQuery {
                name: Some(target.app.clone()),
                identifier: None,
            })
            .map_err(backend_error)?;
        let lookup = self.semantic_names.resolve(&target, &live);
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

impl<B: PointerTargetVerifier + BackgroundPixelInput> ToolDispatcher for Router<B> {
    fn register_replay_target(
        &mut self,
        app: &str,
        name: &str,
        locator: &axon_core::Locator,
    ) -> Result<(), String> {
        self.semantic_names.register_replay_locator(
            axon_core::WireElementTarget { app: app.into(), name: name.into() },
            locator.clone(),
        );
        Ok(())
    }

    fn dispatch(&mut self, tool: &str, params: &Map<String, Value>) -> DispatchOutcome {
        let params = primitive_dispatch_params(params);
        match self.dispatch_tool(tool, &params) {
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

    #[test]
    fn replay_metadata_is_stripped_from_semantic_targets_before_native_dispatch() {
        let params = json!({
            "target": {"app":"Editor", "name":"save", "locator":{"role":"button"}, "recordedAt":12},
            "to": {"x":1, "y":2, "recordedAt":12},
            "value": "draft"
        })
        .as_object()
        .unwrap()
        .clone();

        let primitive = primitive_dispatch_params(&params);
        assert_eq!(primitive["target"], json!({"app":"Editor", "name":"save"}));
        assert_eq!(primitive["to"], params["to"]);
        assert_eq!(primitive["value"], "draft");
    }

    #[derive(Clone)]
    struct FakeBackend {
        snapshot: Snapshot,
        pointer_target_matches: bool,
        verified_handles: Rc<RefCell<Vec<SnapshotHandle>>>,
        value: Rc<RefCell<Option<String>>>,
        clicks: Rc<RefCell<usize>>,
        keystrokes: Rc<RefCell<usize>>,
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
        /// What the planner answers for any target. Unavailable by default, which is the state
        /// every case that is not about the pixel rung wants.
        click_plan: Rc<RefCell<Result<PixelPlan, BackendError>>>,
        keyboard_plan: Rc<RefCell<Result<PixelPlan, BackendError>>>,
        pixel_result: Rc<RefCell<Result<PixelDispatch, PixelDispatchError>>>,
        /// What was asked to be planned, and what was actually delivered. Recorded so a test can
        /// prove the identity the router bound with, and that a refusal sent nothing.
        planned: Rc<RefCell<Vec<PlanRequest>>>,
        pixel_dispatches: Rc<RefCell<Vec<PixelTarget>>>,
    }
    /// One planning request the router made: the application identity it bound against, and the
    /// element and point when the action had one.
    #[derive(Clone, Debug)]
    struct PlanRequest {
        application: String,
        handle: Option<SnapshotHandle>,
        point: Option<(f64, f64)>,
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
    impl BackgroundPixelInput for FakeBackend {
        fn plan_pixel_click(
            &mut self,
            application: &str,
            handle: &SnapshotHandle,
            point: (f64, f64),
        ) -> Result<PixelPlan, BackendError> {
            self.planned.borrow_mut().push(PlanRequest {
                application: application.into(),
                handle: Some(handle.clone()),
                point: Some(point),
            });
            self.click_plan.borrow().clone()
        }
        fn plan_pixel_keyboard(&mut self, application: &str) -> Result<PixelPlan, BackendError> {
            self.planned.borrow_mut().push(PlanRequest {
                application: application.into(),
                handle: None,
                point: None,
            });
            self.keyboard_plan.borrow().clone()
        }
        fn dispatch_pixel_click(
            &mut self,
            target: &PixelTarget,
        ) -> Result<PixelDispatch, PixelDispatchError> {
            let outcome = self.pixel_result.borrow().clone();
            if outcome.is_ok() {
                self.pixel_dispatches.borrow_mut().push(target.clone());
            }
            outcome
        }
        fn dispatch_pixel_keyboard(
            &mut self,
            target: &PixelTarget,
            _: KeyboardIntent<'_>,
        ) -> Result<PixelDispatch, PixelDispatchError> {
            let outcome = self.pixel_result.borrow().clone();
            if outcome.is_ok() {
                self.pixel_dispatches.borrow_mut().push(target.clone());
            }
            outcome
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
            *self.keystrokes.borrow_mut() += 1;
            Ok(())
        }
        fn screenshot(&mut self, _: &AppQuery) -> Result<Screenshot, BackendError> {
            Err(BackendError::Capability {
                capability: Capability::Screenshot,
                reason: "requires desktop portal authorization".into(),
                diagnostic: None,
            })
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
        /// The display name and the identity are deliberately different strings, as they are in the
        /// real backend: a router that hands one where the other is meant activates nothing.
        fn resolve_application(&mut self, app: &AppQuery) -> Result<Option<String>, BackendError> {
            let by_name = app
                .name
                .as_deref()
                .is_some_and(|name| name.eq_ignore_ascii_case("App"));
            let by_identifier = app.identifier.as_deref() == Some(APP_IDENTITY);
            Ok((by_name || by_identifier).then(|| APP_IDENTITY.to_string()))
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

    /// What the backend answers with and activates by, which is not what a request carries. On
    /// Linux this is an AT-SPI bus name and object path, and the display name is "App".
    const APP_IDENTITY: &str = ":1.7/org/a11y/atspi/accessible/root";

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
                identifier: Some(APP_IDENTITY.into()),
                windows: vec![Window { title: None, root }],
            }),
            pointer_target_matches: true,
            verified_handles: Rc::new(RefCell::new(vec![])),
            value: Rc::new(RefCell::new(value.map(str::to_owned))),
            clicks: Rc::new(RefCell::new(0)),
            keystrokes: Rc::new(RefCell::new(0)),
            focuses: Rc::new(RefCell::new(0)),
            pointer: Rc::new(RefCell::new(POINTER_ORIGIN)),
            foreground_readable: true,
            refuses_pointer_move: false,
            pointer_capability_usable: false,
            foreground_transaction: false,
            frontmost: Rc::new(RefCell::new(Some("Prior".into()))),
            refuses_activation: Rc::new(RefCell::new(vec![])),
            activations: Rc::new(RefCell::new(vec![])),
            click_plan: Rc::new(RefCell::new(Ok(PixelPlan::unavailable(
                "this fake backend was given no click plan for this target",
            )))),
            keyboard_plan: Rc::new(RefCell::new(Ok(PixelPlan::unavailable(
                "this fake backend was given no keyboard plan for this application",
            )))),
            pixel_result: Rc::new(RefCell::new(Ok(PixelDispatch {
                complete: true,
                partial: None,
                frontmost_unchanged: true,
                input_focus_unchanged: true,
                pointer_unchanged: true,
            }))),
            planned: Rc::new(RefCell::new(vec![])),
            pixel_dispatches: Rc::new(RefCell::new(vec![])),
        }
    }

    /// A bound plan, standing in for what the real backend builds from a Chromium window.
    fn pixel_target(aimed: bool) -> PixelTarget {
        PixelTarget {
            application: APP_IDENTITY.into(),
            process_identifier: 4242,
            window: 0x0060_0003,
            window_origin: (100.0, 80.0),
            window_size: (480.0, 320.0),
            toolkit: pixel::Toolkit {
                name: "Chromium".into(),
                version: "1.0".into(),
            },
            variant: pixel::SendVariant::Targeted,
            measured_by: "a fixture citation",
            aim: aimed.then(|| PixelAim {
                handle: SnapshotHandle("snapshot:1".into()),
                screen_point: (110.0, 90.0),
                window_point: (10.0, 10.0),
            }),
        }
    }
    fn request(method: &str, params: Value) -> JsonRpcRequest {
        JsonRpcRequest::new(Some(JsonRpcId::Integer(1)), method, Some(params))
    }

    #[test]
    fn look_defaults_to_honest_screenshot_absence_and_opt_out_omits_the_claim() {
        let mut default_router = Router::new(backend(vec![], None));
        let response = default_router
            .request(request("look", json!({"app":"App"})))
            .unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!()
        };
        assert_eq!(
            success.result["screenshotUnavailable"]["code"],
            "portal-authorization-required"
        );
        assert!(success.result.get("screenshot").is_none());

        let mut opted_out_router = Router::new(backend(vec![], None));
        let response = opted_out_router
            .request(request("look", json!({"app":"App","screenshot":false})))
            .unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!()
        };
        assert!(success.result.get("screenshotUnavailable").is_none());
        assert!(success.result.get("screenshot").is_none());
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
        let _handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request("click", json!({"target": {"x": 10.0, "y": 10.0}})))
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
        let _handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        for policy in ["backgroundOnly", "foregroundPermitted"] {
            let response = router
                .request(request(
                    "click",
                    json!({"target": {"x": 10.0, "y": 10.0}, "deliveryPolicy": policy}),
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
        let _handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let activations = backend.activations.clone();
        let frontmost = backend.frontmost.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let refused = router
            .request(request("click", json!({"target": {"x": 10.0, "y": 10.0}})))
            .unwrap();
        let result = refusal(&refused);
        assert_eq!(result["refusal"]["reason"], json!("foregroundNotPermitted"));
        assert_eq!(*clicks.borrow(), 0);
        assert!(activations.borrow().is_empty());

        let permitted = router
            .request(request(
                "click",
                json!({"target": {"x": 10.0, "y": 10.0},
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
        // Activated by the identity the backend answers with, not the display name the request
        // carried: the two are different strings, and only one of them can be compared or raised.
        assert_eq!(
            *activations.borrow(),
            vec![APP_IDENTITY.to_string(), "Prior".to_string()]
        );
        assert_eq!(frontmost.borrow().as_deref(), Some("Prior"));
    }

    #[test]
    fn foreground_escalation_refuses_without_dispatching_when_activation_is_not_proved() {
        let backend = transactional_backend();
        backend
            .refuses_activation
            .borrow_mut()
            .push(APP_IDENTITY.into());
        let _handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let frontmost = backend.frontmost.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({"target": {"x": 10.0, "y": 10.0},
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
        let _handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({"target": {"x": 10.0, "y": 10.0},
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

        // Asserted again with the verification satisfied, because an unverified click fails for
        // its own reason and would report exactly the same thing if restoration stopped counting
        // at all. Here it is the only variable left. The first dispatch left the target forward,
        // so the foreground is put back by hand first: a target that already holds it activates
        // nothing and has nothing to restore, which is a different case than the one under test.
        *router.backend.frontmost.borrow_mut() = Some("Prior".into());
        let candidate = DeliveryCandidate::available(
            DeliveryRung::Foreground,
            DeliveryCapability::GlobalInput,
            "XTest pointer",
        );
        let verified = router
            .foreground_dispatch(
                ForegroundDispatch {
                    policy: DeliveryPolicy::ForegroundPermitted,
                    candidate: &candidate,
                    target: ForegroundTarget::Application(APP_IDENTITY),
                    restores_pointer: false,
                    verification: json!({"verified": true, "observed": "anything"}),
                    resolution: None,
                },
                |backend| backend.pointer_click((10.0, 10.0)),
            )
            .expect("a proved activation dispatches");
        assert_eq!(verified["foreground"]["restored"], json!(false));
        assert_eq!(verified["dispatchSuccess"], json!(true));
        assert_eq!(
            verified["success"],
            json!(false),
            "a verified goal does not excuse a session that was not handed back"
        );
    }

    #[test]
    fn an_opted_in_click_puts_the_pointer_back_where_it_found_it() {
        // XTest moves the real cursor, so a click that lands but leaves the pointer in the target
        // has taken something from the user it did not give back.
        let backend = transactional_backend();
        let _handle = backend.snapshot.handle(0);
        let pointer = backend.pointer.clone();
        let frontmost = backend.frontmost.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({"target": {"x": 10.0, "y": 10.0},
                    "app": "App",
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

        let JsonRpcResponse::Success(success) = response else {
            panic!("an opted-in click dispatches")
        };
        assert_eq!(success.result["delivery"], json!("foreground"));
        assert_eq!(success.result["foreground"]["pointerRestored"], json!(true));
        assert_eq!(success.result["foreground"]["restored"], json!(true));
        // Both halves of the session are as the user left them.
        assert_eq!(*pointer.borrow(), POINTER_ORIGIN);
        assert_eq!(frontmost.borrow().as_deref(), Some("Prior"));
        // What the transaction kept is its own promise, and that is not the whole of success.
        // See the dedicated case below.
        assert_eq!(success.result["dispatchSuccess"], json!(true));
        assert_eq!(success.result["success"], json!(false));
    }

    #[test]
    fn a_restored_session_is_not_by_itself_goal_success() {
        // The foreground rung's own condition and the action's verification are separate, and this
        // rung is where they are most easily confused: a transaction that captured, activated,
        // proved, dispatched and handed the session back has done everything it promised, and
        // still knows nothing about whether the target acted on the events XTest posted. `click`
        // declares no postcondition, so nothing here can say that it did.
        let backend = transactional_backend();
        let _handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({"target": {"x": 10.0, "y": 10.0},
                    "app": "App",
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

        let JsonRpcResponse::Success(success) = response else {
            panic!("an opted-in click dispatches")
        };
        assert_eq!(*clicks.borrow(), 1, "the events went out");
        assert_eq!(success.result["foreground"]["restored"], json!(true));
        assert_eq!(success.result["dispatchSuccess"], json!(true));
        assert_eq!(success.result["dispatch"]["success"], json!(true));
        assert_eq!(
            success.result["success"],
            json!(false),
            "a dispatch that verified nothing is not a successful action, however cleanly the \
             session was handed back"
        );
        assert_eq!(
            success.result["verification"]["reason"],
            json!("click has no declared postcondition"),
            "the caller is told what is missing rather than left to infer it"
        );
    }

    #[test]
    fn a_verified_goal_is_what_makes_a_foreground_dispatch_successful() {
        // The other half of the same rule, so the assertion above cannot be satisfied by a
        // `success` that is simply hardwired false. A postcondition that verified promotes the
        // action, and the transaction's own condition still gates it.
        let mut router = Router::new(transactional_backend());
        let candidate = DeliveryCandidate::available(
            DeliveryRung::Foreground,
            DeliveryCapability::GlobalInput,
            "XTest pointer",
        );

        let promoted = router
            .foreground_dispatch(
                ForegroundDispatch {
                    policy: DeliveryPolicy::ForegroundPermitted,
                    candidate: &candidate,
                    target: ForegroundTarget::Application(APP_IDENTITY),
                    restores_pointer: false,
                    verification: json!({"verified": true, "observed": "anything"}),
                    resolution: None,
                },
                |backend| {
                    backend.keyboard(
                        &AppQuery {
                            name: Some("App".into()),
                            identifier: None,
                        },
                        KeyboardIntent::Text("x"),
                    )
                },
            )
            .expect("a proved activation dispatches");

        assert_eq!(promoted["success"], json!(true));
        assert_eq!(promoted["dispatchSuccess"], json!(true));
        assert_eq!(promoted["foreground"]["restored"], json!(true));
    }

    #[test]
    fn keyboard_reports_no_pointer_to_restore_rather_than_a_restoration() {
        // null means the dispatch never moved the cursor. Reporting `true` would claim a
        // restoration that never happened, and `false` would claim a failure that never happened.
        let mut router = Router::new(transactional_backend());

        let response = router
            .request(request(
                "keyboard",
                json!({
                    "key": "Return",
                    "app": "App",
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

        let JsonRpcResponse::Success(success) = response else {
            panic!("an opted-in keystroke dispatches")
        };
        assert_eq!(success.result["delivery"], json!("foreground"));
        assert_eq!(success.result["foreground"]["pointerRestored"], Value::Null);
        // Nothing to put back is not the same as nothing to prove: keyboard input declares no
        // postcondition either, so the dispatch is evidence and the action is unverified.
        assert_eq!(success.result["dispatchSuccess"], json!(true));
        assert_eq!(success.result["success"], json!(false));
    }

    #[test]
    fn a_backend_that_cannot_read_the_foreground_dispatches_nothing() {
        // Not the same as nothing being frontmost. A backend that cannot read what holds the
        // foreground cannot promise to give it back, so it must not take it in the first place.
        let mut backend = transactional_backend();
        backend.foreground_readable = false;
        let _handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let activations = backend.activations.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({"target": {"x": 10.0, "y": 10.0},
                    "app": "App",
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

        let result = refusal(&response);
        assert_eq!(result["refusal"]["reason"], json!("activationNotProved"));
        assert_eq!(result["dispatchSuccess"], json!(false));
        assert_eq!(result["delivery"], Value::Null);
        assert_eq!(*clicks.borrow(), 0);
        assert!(activations.borrow().is_empty());
    }

    #[test]
    fn a_pointer_that_cannot_be_put_back_fails_the_click_and_keeps_the_evidence() {
        let mut backend = transactional_backend();
        backend.refuses_pointer_move = true;
        let _handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let frontmost = backend.frontmost.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        let response = router
            .request(request(
                "click",
                json!({"target": {"x": 10.0, "y": 10.0},
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
        assert_eq!(
            success.result["foreground"]["pointerRestored"],
            json!(false)
        );
        // The window came back and the events went out; the cursor did not, so the action failed.
        assert_eq!(success.result["foreground"]["restored"], json!(true));
        assert_eq!(success.result["success"], json!(false));
        assert_eq!(*clicks.borrow(), 1);
        assert_eq!(frontmost.borrow().as_deref(), Some("Prior"));
    }

    #[test]
    fn an_aimed_keystroke_activates_the_application_the_request_named() {
        // The request carries a display name; the backend answers and activates by its own
        // identity. A router that passed the name straight through would compare two strings that
        // can never be equal and refuse every aimed keystroke.
        for naming in [json!({"app": "App"}), json!({"identifier": APP_IDENTITY})] {
            let backend = transactional_backend();
            let keystrokes = backend.keystrokes.clone();
            let activations = backend.activations.clone();
            let frontmost = backend.frontmost.clone();
            let mut router = Router::new(backend);

            let mut params = naming.as_object().unwrap().clone();
            params.insert("text".into(), json!("x"));
            params.insert("deliveryPolicy".into(), json!("foregroundPermitted"));
            let response = router
                .request(request("keyboard", Value::Object(params)))
                .unwrap();

            let JsonRpcResponse::Success(success) = response else {
                panic!("an aimed keystroke dispatches: {naming}")
            };
            assert_eq!(success.result["delivery"], json!("foreground"), "{naming}");
            assert_eq!(
                success.result["foreground"]["activationProved"],
                json!(true),
                "{naming}"
            );
            assert_eq!(*keystrokes.borrow(), 1, "{naming}");
            assert_eq!(
                *activations.borrow(),
                vec![APP_IDENTITY.to_string(), "Prior".to_string()],
                "{naming}"
            );
            assert_eq!(frontmost.borrow().as_deref(), Some("Prior"), "{naming}");
        }
    }

    #[test]
    fn a_keystroke_aimed_at_an_unknown_application_never_falls_through_to_the_frontmost() {
        // Posting these keystrokes at whatever the user is working in, having been asked for an
        // application that could not be found, is the worst available answer.
        let backend = transactional_backend();
        let keystrokes = backend.keystrokes.clone();
        let activations = backend.activations.clone();
        let mut router = Router::new(backend);

        let response = router
            .request(request(
                "keyboard",
                json!({
                    "app": "Nothing By That Name",
                    "text": "x",
                    "deliveryPolicy": "foregroundPermitted"
                }),
            ))
            .unwrap();

        let result = refusal(&response);
        assert_eq!(
            result["refusal"]["reason"],
            json!("targetIdentityUnavailable")
        );
        assert_eq!(result["dispatchSuccess"], json!(false));
        assert_eq!(*keystrokes.borrow(), 0);
        assert!(activations.borrow().is_empty());
    }

    #[test]
    fn a_keystroke_naming_no_application_addresses_the_frontmost_without_activating() {
        // The one case where dispatching without activation is correct: the caller asked for
        // whatever holds the foreground, so there is nothing to bring forward and nothing to undo.
        let backend = transactional_backend();
        let keystrokes = backend.keystrokes.clone();
        let activations = backend.activations.clone();
        let mut router = Router::new(backend);

        let response = router
            .request(request(
                "keyboard",
                json!({"text": "x", "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();

        let JsonRpcResponse::Success(success) = response else {
            panic!("an unaimed keystroke dispatches")
        };
        assert_eq!(success.result["delivery"], json!("foreground"));
        assert_eq!(
            success.result["foreground"]["alreadyFrontmost"],
            json!(true)
        );
        assert_eq!(*keystrokes.borrow(), 1);
        assert!(activations.borrow().is_empty());
    }

    #[test]
    fn a_keyboard_request_naming_both_intents_is_a_transport_error() {
        // text is entered literally and key names a keystroke: `End` is three characters as one
        // and a single key as the other, so a request carrying both has not said what it wants.
        let mut router = Router::new(transactional_backend());

        let response = router
            .request(request(
                "keyboard",
                json!({"text": "End", "key": "End", "deliveryPolicy": "foregroundPermitted"}),
            ))
            .unwrap();

        let JsonRpcResponse::Failure(failure) = response else {
            panic!("an ambiguous keyboard request is malformed, not refused")
        };
        assert_eq!(failure.error.code, -32602);
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
    fn unknown_semantic_names_fail_closed_without_backend_dispatch() {
        let backend = backend(vec![], Some("before"));
        let focuses = backend.focuses.clone();
        let value = backend.value.clone();
        let mut router = Router::new(backend);

        for (method, params) in [
            (
                "invoke",
                json!({"target": {"app": "App", "name": "Button"}, "name": "Invoke"}),
            ),
            (
                "type",
                json!({"target": {"app": "App", "name": "Field"}, "value": "after"}),
            ),
            (
                "scroll",
                json!({"target": {"app": "App", "name": "List"}, "deltaY": -120.0}),
            ),
        ] {
            let response = router.request(request(method, params)).unwrap();
            let JsonRpcResponse::Failure(failure) = response else {
                panic!("{method} must fail for an unknown semantic name")
            };
            assert_eq!(failure.error.code, -32002, "{method}");
            assert_eq!(
                failure
                    .error
                    .data
                    .as_ref()
                    .and_then(|v| v["status"].as_str()),
                Some("missing")
            );
        }
        assert_eq!(*focuses.borrow(), 0);
        assert_eq!(value.borrow().as_deref(), Some("before"));
    }

    #[test]
    fn an_unknown_policy_fails_before_resolution_or_dispatch() {
        let backend = backend(vec![], None);
        let _handle = backend.snapshot.handle(0);
        let clicks = backend.clicks.clone();
        let focuses = backend.focuses.clone();
        let mut router = Router::new(backend);
        router.snapshot = Some(router.backend.snapshot.clone());

        for method in ["click", "type", "keyboard", "scroll", "invoke", "drag"] {
            let response = router
                .request(request(
                    method,
                    json!({"target": {"x": 10.0, "y": 10.0},
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
    fn obsolete_locator_target_is_rejected_without_dispatch() {
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
        assert_eq!(error.error.code, -32602);
        assert!(error.error.message.contains("{app, name}"));
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
            batch["trace"][0]["error"]
                .as_str()
                .unwrap()
                .contains("{app, name}")
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

    /// The pixel rung's router half: which rung an action takes, what a refusal names, and what a
    /// delivered result reports. Every case here runs against a fake, because the decision is the
    /// part that is the same on any machine — the X11 conversation underneath it is exercised by
    /// `tests/x11_pixel.rs` against a real server.
    mod pixel_rung {
        use super::*;
        use crate::pixel::{PixelAction, Toolkit};

        /// A backend whose click plan is bound, and which can also reach the foreground rung, so
        /// each case shows the pixel rung being *chosen* rather than being all that was left.
        fn bound_backend(aimed: bool) -> FakeBackend {
            let backend = transactional_backend();
            let plan = Ok(PixelPlan::Bound(Box::new(pixel_target(aimed))));
            *backend.click_plan.borrow_mut() = plan.clone();
            *backend.keyboard_plan.borrow_mut() = plan;
            backend
        }

        fn router_for(backend: FakeBackend) -> Router<FakeBackend> {
            let mut router = Router::new(backend);
            router.snapshot = Some(router.backend.snapshot.clone());
            router
        }

        #[test]
        fn a_bound_click_takes_the_pixel_rung_under_the_default_policy() {
            let backend = bound_backend(true);
            let _handle = backend.snapshot.handle(0);
            let clicks = backend.clicks.clone();
            let activations = backend.activations.clone();
            let dispatches = backend.pixel_dispatches.clone();
            let mut router = router_for(backend);

            let response = router
                .request(request("click", json!({"target": {"x": 10.0, "y": 10.0}})))
                .unwrap();

            let result = refusal(&response);
            assert_eq!(result["delivery"], json!("pixel"));
            assert_eq!(result["dispatchSuccess"], json!(true));
            // Delivered, and not thereby successful. See the dedicated case below.
            assert_eq!(result["success"], json!(false));
            assert_eq!(result["deliveryPolicy"], json!("backgroundOnly"));
            assert_eq!(result["refusal"], Value::Null);
            // The rung is defined by what it does not do, so the two things it must not have
            // touched are asserted rather than assumed.
            assert_eq!(*clicks.borrow(), 0, "the pixel rung is not XTest");
            assert!(
                activations.borrow().is_empty(),
                "the pixel rung activates nothing"
            );
            assert_eq!(dispatches.borrow().len(), 1);
            // A caller who resolved a target still gets the resolution back, exactly as at the
            // foreground rung.
            assert_eq!(result["resolution"]["status"], json!("unique"));
        }

        #[test]
        fn a_delivered_result_reports_the_window_the_transform_and_the_measurement() {
            let backend = bound_backend(true);
            let _handle = backend.snapshot.handle(0);
            let mut router = router_for(backend);

            let response = router
                .request(request("click", json!({"target": {"x": 10.0, "y": 10.0}})))
                .unwrap();

            let result = refusal(&response);
            let window = &result["targetWindow"];
            assert_eq!(window["nativeWindowHandle"], json!("0x00600003"));
            assert_eq!(window["windowOrigin"], json!({"x": 100.0, "y": 80.0}));
            assert_eq!(window["windowPoint"], json!({"x": 10.0, "y": 10.0}));
            assert_eq!(window["sourceCoordinateSpace"], json!("screen"));
            // The signature that authorized this, and the delivery variant it was measured under:
            // a dispatch into someone's window should say on what evidence it was allowed.
            assert_eq!(window["toolkit"], json!("Chromium"));
            assert_eq!(window["toolkitVersion"], json!("1.0"));
            assert_eq!(window["deliveryVariant"], json!("targeted"));
            assert_eq!(window["measuredBy"], json!("a fixture citation"));
            let background = &result["backgroundDelivery"];
            assert_eq!(background["targetProcessIdentifier"], json!(4242));
            assert_eq!(background["frontmostAppUnchanged"], json!(true));
            assert_eq!(background["inputFocusUnchanged"], json!(true));
            assert_eq!(background["pointerUnchanged"], json!(true));
            // Delivered is not verified. The contract is explicit that acceptance is evidence and
            // that goal success needs a readback or a declared postcondition.
            assert_eq!(result["verification"]["verified"], json!(false));
        }

        #[test]
        fn a_clean_delivery_is_dispatch_evidence_and_not_goal_success() {
            // The distinction this rung exists inside. `XSendEvent` reports success as soon as the
            // X server accepts the request, and every event it carries is flagged `send_event`,
            // which a toolkit may drop in silence — so a completed delivery proves the events
            // reached the target and never proves the application acted. Neither `click` nor
            // `keyboard` declares a postcondition, so nothing here verifies the goal and `success`
            // says so.
            //
            // Collapsing the two would hollow out the acceptance table's whole defence: a future
            // Chromium that began filtering these events is undetectable by signature, and would
            // otherwise produce an accepted send, intact invariants, and a report that the
            // caller's click had worked.
            let backend = bound_backend(true);
            let _handle = backend.snapshot.handle(0);
            let dispatches = backend.pixel_dispatches.clone();
            let mut router = router_for(backend);

            let response = router
                .request(request("click", json!({"target": {"x": 10.0, "y": 10.0}})))
                .unwrap();

            let result = refusal(&response);
            assert_eq!(dispatches.borrow().len(), 1, "the events were delivered");
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
            let backend = bound_backend(true);
            let _handle = backend.snapshot.handle(0);
            let mut router = router_for(backend);

            let response = router
                .request(request("click", json!({"target": {"x": 10.0, "y": 10.0}})))
                .unwrap();
            let delivered = refusal(&response).clone();

            let verified = json!({"verified": true, "observed": "anything"});
            let candidate = DeliveryCandidate::available(
                DeliveryRung::Pixel,
                DeliveryCapability::BackgroundPixelInput,
                PIXEL_MECHANISM,
            );
            let promoted = router
                .dispatch_pixel(
                    DeliveryPolicy::BackgroundOnly,
                    &candidate,
                    &pixel_target(true),
                    verified,
                    |backend, target| backend.dispatch_pixel_click(target),
                )
                .expect("a bound target dispatches");

            assert_eq!(delivered["success"], json!(false));
            assert_eq!(promoted["success"], json!(true));
            assert_eq!(promoted["dispatchSuccess"], json!(true));
        }

        #[test]
        fn a_dispatch_that_moved_the_focus_is_not_a_background_delivery() {
            // Qt's click is refused by the acceptance table for exactly this, and the table is the
            // defence. This is the backstop underneath it: a toolkit that acts on a delivered
            // event by asking to be activated does not get to have that reported as success.
            let backend = bound_backend(true);
            *backend.pixel_result.borrow_mut() = Ok(PixelDispatch {
                complete: true,
                partial: None,
                frontmost_unchanged: true,
                input_focus_unchanged: false,
                pointer_unchanged: true,
            });
            let _handle = backend.snapshot.handle(0);
            let mut router = router_for(backend);

            let response = router
                .request(request("click", json!({"target": {"x": 10.0, "y": 10.0}})))
                .unwrap();

            let result = refusal(&response);
            assert_eq!(result["delivery"], json!("pixel"));
            // The evidence that the events were delivered survives; the claim that the session was
            // left alone does not. `success` was already false for want of a postcondition, so the
            // message is what carries this, and it has to.
            assert_eq!(result["dispatchSuccess"], json!(true));
            assert_eq!(result["success"], json!(false));
            assert!(
                result["message"]
                    .as_str()
                    .unwrap()
                    .contains("X input focus moved"),
                "{}",
                result["message"]
            );
        }

        #[test]
        fn a_stale_target_aborts_before_delivery_as_an_error_rather_than_a_refusal() {
            // Revalidation failing is not the daemon declining to act: the request was fine and
            // the target is no longer what it was, which a caller has to be able to tell apart
            // from a policy or capability decision.
            let backend = bound_backend(true);
            *backend.pixel_result.borrow_mut() = Err(PixelDispatchError::Stale(
                "the resolved element no longer covers the point this plan aimed at".into(),
            ));
            let _handle = backend.snapshot.handle(0);
            let clicks = backend.clicks.clone();
            let mut router = router_for(backend);

            let response = router
                .request(request("click", json!({"target": {"x": 10.0, "y": 10.0}})))
                .unwrap();

            let JsonRpcResponse::Failure(failure) = response else {
                panic!("a stale target is a transport error, not an action result")
            };
            assert_eq!(failure.error.code, -32003);
            assert!(
                failure.error.message.contains("no longer covers the point"),
                "{}",
                failure.error.message
            );
            // Nothing escalated to the loud rung behind the caller's back.
            assert_eq!(*clicks.borrow(), 0);
        }

        #[test]
        fn the_pixel_candidate_carries_the_toolkits_own_refusal() {
            // Each of these is the message the acceptance table itself produces, so this asserts
            // the whole path from a measured verdict to what a caller is told, rather than a
            // string the test invented.
            let router = Router::new(backend(vec![], None));
            let cases = [
                // Measured and refused: GTK 4 receives neither event.
                (
                    PixelAction::Click,
                    Toolkit {
                        name: "GTK".into(),
                        version: "4.20.3".into(),
                    },
                    "4.20.3",
                ),
                // A version series nobody measured, naming the series that was.
                (
                    PixelAction::Keyboard,
                    Toolkit {
                        name: "Qt".into(),
                        version: "6.12.0".into(),
                    },
                    "6.11.x",
                ),
                // Measured, accepted, and still refused: Qt asks to be activated on a click.
                (
                    PixelAction::Click,
                    Toolkit {
                        name: "Qt".into(),
                        version: "6.11.1".into(),
                    },
                    "requests activation",
                ),
            ];
            for (action, toolkit, expected) in cases {
                let reason = pixel::accepts(action, &toolkit)
                    .expect_err("none of these toolkits accept this action in the background");
                let ladder = router.global_input_ladder(
                    Capability::PointerInput,
                    "XTest pointer",
                    &PixelPlan::unavailable(reason),
                );

                let candidate = &ladder[0];
                assert_eq!(candidate.rung, DeliveryRung::Pixel);
                assert_eq!(
                    candidate.unavailable,
                    Some(DeliveryRefusalReason::BackgroundPixelUnsupported)
                );
                let message = candidate.unavailable_message.clone().unwrap();
                assert!(message.contains(&toolkit.name), "{message}");
                assert!(message.contains(expected), "{message}");
            }
        }

        #[test]
        fn a_point_no_window_of_the_application_owns_refuses_by_name() {
            // The geometry half of the binding. A target whose toolkit was cleared still has no
            // pixel rung when its window is not the one on top at the resolved point, and the
            // caller is told which of the two it was.
            let backend = transactional_backend();
            *backend.click_plan.borrow_mut() = Ok(PixelPlan::unavailable(
                "no top-level window of the Chromium 1.0 application running as process 4242 owns \
                 the point the resolved element sits at; it is either off-screen or covered by \
                 another window there",
            ));
            let _handle = backend.snapshot.handle(0);
            let dispatches = backend.pixel_dispatches.clone();
            let mut router = router_for(backend);

            let response = router
                .request(request("click", json!({"target": {"x": 10.0, "y": 10.0}})))
                .unwrap();

            let result = refusal(&response);
            // The policy boundary outranks it in the reason a caller is given, because opting in
            // is the thing they can act on and it would work. The geometry obstacle it outranks
            // still travels, so the caller learns which of the two halves of the binding failed.
            assert_eq!(result["refusal"]["reason"], json!("foregroundNotPermitted"));
            assert_eq!(result["delivery"], Value::Null);
            assert!(
                result["refusal"]["alsoRefused"][0]["message"]
                    .as_str()
                    .unwrap()
                    .contains("owns the point the resolved element sits at"),
                "{}",
                result["refusal"]["alsoRefused"][0]["message"]
            );
            assert!(dispatches.borrow().is_empty(), "nothing was delivered");
        }

        #[test]
        fn the_toolkits_own_refusal_reaches_the_caller_beside_the_policy_refusal() {
            // The whole path, from the measured acceptance table to what a caller reads. The
            // reported reason is the policy boundary, and the toolkit sentence rides beside it —
            // without which a caller cannot tell a GTK 3 window, which will never take a
            // background click, from one where opting in is all that stands in the way.
            let toolkit = Toolkit {
                name: "gtk".into(),
                version: "3.24.51".into(),
            };
            let measured = pixel::accepts(PixelAction::Click, &toolkit)
                .expect_err("GTK 3 does not accept a background click");
            let backend = transactional_backend();
            *backend.click_plan.borrow_mut() = Ok(PixelPlan::unavailable(measured.clone()));
            let _handle = backend.snapshot.handle(0);
            let clicks = backend.clicks.clone();
            let dispatches = backend.pixel_dispatches.clone();
            let mut router = router_for(backend);

            let response = router
                .request(request("click", json!({"target": {"x": 10.0, "y": 10.0}})))
                .unwrap();

            let result = refusal(&response);
            assert_eq!(result["refusal"]["reason"], json!("foregroundNotPermitted"));
            let obstacle = &result["refusal"]["alsoRefused"][0];
            assert_eq!(obstacle["rung"], json!("pixel"));
            assert_eq!(obstacle["reason"], json!("backgroundPixelUnsupported"));
            // Byte for byte the acceptance table's own sentence, naming the toolkit and version.
            assert_eq!(obstacle["message"], json!(measured));
            assert!(
                obstacle["message"]
                    .as_str()
                    .unwrap()
                    .contains("gtk 3.24.51"),
                "{}",
                obstacle["message"]
            );
            assert_eq!(*clicks.borrow(), 0);
            assert!(dispatches.borrow().is_empty(), "nothing was delivered");
        }

        #[test]
        fn a_planner_that_failed_leaves_the_foreground_rung_reachable() {
            // A bus timeout while planning is not a reason to fail a click that could still have
            // travelled the loud rung, so it becomes an unavailable plan carrying its own cause.
            let backend = transactional_backend();
            *backend.click_plan.borrow_mut() = Err(BackendError::Operation {
                operation: "toolkit name".into(),
                message: "timed out".into(),
                diagnostic: None,
            });
            let _handle = backend.snapshot.handle(0);
            let clicks = backend.clicks.clone();
            let mut router = router_for(backend);

            let response = router
                .request(request(
                    "click",
                    json!({"target": {"x": 10.0, "y": 10.0}, "deliveryPolicy": "foregroundPermitted"}),
                ))
                .unwrap();

            let result = refusal(&response);
            assert_eq!(result["delivery"], json!("foreground"));
            assert_eq!(*clicks.borrow(), 1);
        }

        #[test]
        fn an_aimed_keyboard_request_binds_the_application_it_named() {
            let backend = bound_backend(false);
            let keystrokes = backend.keystrokes.clone();
            let planned = backend.planned.clone();
            let dispatches = backend.pixel_dispatches.clone();
            let mut router = router_for(backend);

            let response = router
                .request(request("keyboard", json!({"app": "App", "text": "axon"})))
                .unwrap();

            let result = refusal(&response);
            assert_eq!(result["delivery"], json!("pixel"));
            assert_eq!(result["dispatchSuccess"], json!(true));
            // Bound by the backend's own identity for the application, not by the display name the
            // request carried — which is the distinction that decides which window is typed into.
            let planned = planned.borrow();
            let request = planned.first().expect("the router planned the pixel rung");
            assert_eq!(request.application, APP_IDENTITY);
            assert!(
                request.handle.is_none() && request.point.is_none(),
                "keyboard input names an application rather than an element"
            );
            assert_eq!(*keystrokes.borrow(), 0, "the pixel rung is not XTest");
            // Keystrokes name an application rather than an element, so the bound target carries
            // a window and no converted point.
            assert!(dispatches.borrow()[0].aim.is_none());
            assert!(result["targetWindow"].get("windowPoint").is_none());
        }

        #[test]
        fn keyboard_naming_no_application_has_no_target_window_to_bind() {
            // Not a gap being papered over: a request addressed at whatever holds the foreground
            // is a request with no target, and the pixel rung is target-bound by definition.
            let backend = bound_backend(false);
            let planned = backend.planned.clone();
            let keystrokes = backend.keystrokes.clone();
            let mut router = router_for(backend);

            let response = router
                .request(request(
                    "keyboard",
                    json!({"text": "axon", "deliveryPolicy": "foregroundPermitted"}),
                ))
                .unwrap();

            let result = refusal(&response);
            assert_eq!(result["delivery"], json!("foreground"));
            assert_eq!(*keystrokes.borrow(), 1);
            assert!(
                planned.borrow().is_empty(),
                "an unaimed request has no application to plan against"
            );
        }

        #[test]
        fn drag_has_no_pixel_rung_because_nothing_measured_a_held_button() {
            let router = Router::new(backend(vec![], None));
            let ladder = router.global_input_ladder(
                Capability::PointerInput,
                "XTest pointer",
                &PixelPlan::unavailable(NO_DRAG_PIXEL),
            );

            assert_eq!(
                ladder[0].unavailable,
                Some(DeliveryRefusalReason::BackgroundPixelUnsupported)
            );
            let message = ladder[0].unavailable_message.clone().unwrap();
            assert!(message.contains("holds a button down"), "{message}");
        }
    }
}
