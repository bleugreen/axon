//! macOS Accessibility backend and v1 JSON-RPC tool router.

use axon_core::{
    AppQuery, AxnRunner, Capability, DeliveryCandidate, DeliveryCapability, DeliveryOutcome,
    DeliveryPolicy, DeliveryRefusal, DeliveryRefusalReason, DeliveryRung, DeliverySelection,
    DiffPolicy, DispatchOutcome, ExpectedFact, ForegroundTarget, JsonRpcError, JsonRpcId,
    JsonRpcRequest, JsonRpcResponse, KeyboardIntent, PlatformBackend, PointSpace, PointTarget,
    PointerContract, ResolutionStatus, RunEnvelope, SemanticElementName, SemanticLookup,
    SemanticNameRegistry, SemanticRegistrationCoverage, SemanticSelection, SinceToken, Snapshot,
    SnapshotHandle, TextLocationResolver, TextLocationSource, TextLocationTarget,
    TextRecognitionProvider, ToolDispatcher, classify_semantic_diff, dispatch_in_foreground,
    goal_success, look_since_response, pointer_target_is_point, prepare_run, select_delivery,
};
use serde_json::{Map, Value, json};
use std::{
    collections::HashMap,
    thread,
    time::{Duration, Instant},
};

#[cfg(target_os = "macos")]
pub mod socket;

pub mod launcher;

#[cfg(target_os = "macos")]
pub mod probe;

#[cfg(target_os = "macos")]
mod accessibility;
// The daemon that sends Apple events and answers consent is macOS-only; elsewhere these modules
// are compiled for their hermetic tests, which drive the verb and ledger logic against a scripted
// browser.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod apple_events;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod automation;
mod background;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod browser;
#[cfg(target_os = "macos")]
mod core_foundation;
#[cfg(target_os = "macos")]
mod global_input;
mod input;
#[cfg(target_os = "macos")]
mod platform;
#[cfg(target_os = "macos")]
mod workspace;
pub use background::{ApplicationPlan, ApplicationProcess, DenylistEntry};
#[cfg(target_os = "macos")]
pub use platform::MacBackend;

/// Tools this backend does not implement at all. These are not delivery decisions: the request
/// names something the macOS daemon has no code path for, which stays a JSON-RPC error.
const EXCLUDED: &[(&str, &str)] = &[
    ("drag", "PointerDrag"),
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

/// The pixel rung's mechanism, which macOS has for no action. Named so a refusal says what is
/// missing rather than only which rung.
const PIXEL_MECHANISM: &str = "window-bound background input";

/// The application rung's mechanism: input posted to one process.
const APPLICATION_MECHANISM: &str = "CGEventPostToPid";

/// The foreground rung's mechanism: global input routed by the window server like a real device.
const FOREGROUND_MECHANISM: &str = "CGEventPost(kCGHIDEventTap)";

/// Why `keyboard` has no pixel rung, and never will in this shape.
///
/// The pixel rung is target-bound input derived from verified window geometry. `keyboard` names an
/// application and an input string; there is no element, so there is no window to bind to and no
/// transform to report. Its background home is the application rung, which binds to a process
/// rather than a window.
const NO_KEYBOARD_GEOMETRY: &str = "keyboard input names an application rather than an element, so \
     there is no verified window geometry to bind it to";

/// Why a pointer action has no pixel rung on macOS: no mechanism delivers a mouse or wheel event to
/// one window without the window server's hit testing.
const NO_WINDOW_BOUND_POINTER: &str = "macOS has no mechanism that delivers pointer input to one \
     window without the window server's hit testing, so there is no verified window to bind it to";

/// Why a scroll that carries a delta has no semantic rung.
const NO_SEMANTIC_SCROLL_DELTA: &str =
    "AXScrollToVisible scrolls an element into view and cannot carry a scroll delta";

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
    daemon: axon_core::NativeDaemonState,
    recorder: Option<axon_core::UserActionRecorder>,
    /// The browser verbs. Absent, they refuse as an unavailable capability: the daemon installs
    /// the service, and a router built without one has no browser to talk to.
    browser: Option<Box<dyn browser::BrowserVerbs>>,
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

/// The native pointer input the router drives beyond the shared backend trait.
///
/// A seam so the router that decides *when* each is used stays testable anywhere; the mechanisms
/// behind it are Core Graphics and Accessibility and are not.
pub trait NativeInput: PlatformBackend {
    /// The process owning whatever is on screen at `point`, by Accessibility hit test.
    fn point_owner(&mut self, point: (f64, f64)) -> Result<Option<i32>, axon_core::BackendError>;

    /// The frame of an application's focused window, in screen points.
    fn focused_window_frame(
        &mut self,
        app: &AppQuery,
    ) -> Result<Option<axon_core::Rect>, axon_core::BackendError>;

    /// Posts a pixel-unit wheel burst at `point` through the HID tap, returning the `(x, y)` steps
    /// that were posted. Distinct from `PlatformBackend::scroll`, which stays the semantic
    /// AXScrollToVisible.
    fn scroll_wheel(
        &mut self,
        point: (f64, f64),
        delta: (f64, f64),
    ) -> Result<Vec<(i32, i32)>, axon_core::BackendError>;

    /// What the activation calls since the last take did: each primitive's name and the value it
    /// returned. Taken once per foreground transaction so it can ride on that transaction's
    /// cleanup evidence; an acknowledgement is not proof, and the readback still decides.
    fn take_activation_evidence(&mut self) -> Option<String> {
        None
    }

    /// The session's modifier state as the window server holds it, read around every keyboard
    /// dispatch. `None` from a backend that cannot read it, which reports the invariant as unknown
    /// rather than as held.
    fn modifier_state(&mut self) -> Option<ModifierState> {
        None
    }

    /// The actions a resolved element advertises right now, asked of the element itself.
    ///
    /// The captured node's `actions` on macOS come from a role table, which knows six roles; a
    /// pop-up button, disclosure triangle, or outline row that supports `AXPress` is not among
    /// them. `Ok(None)` means this backend cannot ask, and the router falls back to the capture.
    fn advertised_actions(
        &mut self,
        handle: &SnapshotHandle,
    ) -> Result<Option<Vec<String>>, axon_core::BackendError> {
        let _ = handle;
        Ok(None)
    }
}

/// The window server's modifier flags, in both states a later event can inherit them from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ModifierState {
    /// `kCGEventSourceStateCombinedSessionState`.
    pub combined_session: u64,
    /// `kCGEventSourceStateHIDSystemState`.
    pub hid_system: u64,
}

impl ModifierState {
    /// The four modifiers a chord presses. The non-coalesced bit, and the numeric-pad and function
    /// bits arrow keys carry, are not keys anyone holds, so they are not compared.
    pub const HELD: u64 =
        input::FLAG_SHIFT | input::FLAG_CONTROL | input::FLAG_OPTION | input::FLAG_COMMAND;

    fn held(self) -> (u64, u64) {
        (
            self.combined_session & Self::HELD,
            self.hid_system & Self::HELD,
        )
    }
}

/// How long the after-reading waits for the window server to apply a dispatch's releases.
const MODIFIER_SETTLE: Duration = Duration::from_millis(300);

/// The modifier state after a dispatch, read once the window server has caught up.
///
/// Posted events are applied asynchronously, so a reading taken the instant a chord's final
/// release is posted can still show the modifier held; on bgsrv-mac (axn/230) it did, while a
/// reading a moment later showed it released. The reading is retried until it matches `before` or
/// the bound passes, and only a state still changed at the bound is a held modifier.
fn settled_modifier_state<B: NativeInput>(
    backend: &mut B,
    before: Option<ModifierState>,
) -> Option<ModifierState> {
    let deadline = Instant::now() + MODIFIER_SETTLE;
    loop {
        let after = backend.modifier_state();
        let settled = match (before, after) {
            (Some(before), Some(after)) => before.held() == after.held(),
            _ => true,
        };
        if settled || Instant::now() >= deadline {
            return after;
        }
        thread::sleep(Duration::from_millis(10));
    }
}

/// Stamps the modifier invariant onto a keyboard result's `section` (`foreground` or
/// `backgroundDelivery`), beside the pointer's.
///
/// A keyboard dispatch must leave the session's modifiers as it found them. One that does not has
/// left a key logically held for every later keystroke on the machine, the user's included, so a
/// changed state means the rung did not hold and `success` is false. `dispatchSuccess` stays true:
/// the events were posted, and a caller told otherwise would retry and type them twice.
fn stamp_modifier_readback(
    result: &mut Value,
    section: &str,
    readback: Option<(Option<ModifierState>, Option<ModifierState>)>,
) {
    let Some(object) = result.as_object_mut() else {
        return;
    };
    let restored = match readback {
        Some((Some(before), Some(after))) => Some(before.held() == after.held()),
        _ => None,
    };
    if let Some(Value::Object(evidence)) = object.get_mut(section) {
        evidence.insert("modifiersRestored".into(), json!(restored));
    }
    if restored == Some(false) {
        let Some((Some(before), Some(after))) = readback else {
            unreachable!("a comparison needs both readings")
        };
        let problem = format!(
            "the session's modifier state changed across the dispatch, so a modifier is still \
             logically held: combined-session {:#x} before and {:#x} after, HID-system {:#x} \
             before and {:#x} after",
            before.combined_session, after.combined_session, before.hid_system, after.hid_system
        );
        let message = match object.get("message").and_then(Value::as_str) {
            Some(existing) => format!("{existing}; {problem}"),
            None => problem,
        };
        object.insert("message".into(), json!(message));
        object.insert("success".into(), json!(false));
    }
}

/// The application rung for keyboard input: keystrokes posted to one process, without activating
/// it and without touching the pointer.
///
/// Availability is decided by [`background::application_keyboard_availability`], which is a
/// property of the mechanism rather than of the application; the seam only supplies the process
/// and posts to it.
pub trait BackgroundApplicationKeyboard: PlatformBackend {
    /// The one live application process a query names, with the identity foreground delivery
    /// would compare. `Ok(None)` when no application, or more than one, matched.
    fn application_process(
        &mut self,
        app: &AppQuery,
    ) -> Result<Option<ApplicationProcess>, axon_core::BackendError>;

    /// The applications measured not to act on application-rung keystrokes.
    fn application_keyboard_denylist(&self) -> &'static [DenylistEntry] {
        background::DENYLIST
    }

    /// Decides the rung for one request. Pure inspection, because the planner may discard the
    /// answer and refuse before anything native happens.
    fn plan_application_keyboard(
        &self,
        process: Option<ApplicationProcess>,
        intent: KeyboardIntent<'_>,
    ) -> ApplicationPlan {
        background::application_keyboard_availability(
            process,
            intent,
            self.application_keyboard_denylist(),
        )
    }

    /// Revalidates the process and posts to it. A process that exited, or whose bundle changed,
    /// between planning and dispatch returns `Stale` and must post nothing: the pid now names
    /// something else, or nothing.
    fn dispatch_application_keyboard(
        &mut self,
        process: &ApplicationProcess,
        intent: KeyboardIntent<'_>,
    ) -> Result<ApplicationDispatch, BackgroundDispatchError>;
}

/// What an application-rung dispatch observed around itself.
#[derive(Clone, Debug, PartialEq)]
pub struct ApplicationDispatch {
    /// Read before and after the post. A target that activated itself in response is still
    /// reported, because a delivery that changed the foreground was not background delivery.
    pub frontmost_unchanged: bool,
    /// Reported, never asserted: keystrokes touch no pointing device, so motion around them is
    /// the person at the machine.
    pub pointer_unchanged: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum BackgroundDispatchError {
    /// Revalidation failed between planning and dispatch. Nothing was posted.
    Stale(String),
    Backend(axon_core::BackendError),
}

/// What a pointer action resolved to, and therefore how it is verified before it is posted.
enum ClickTarget {
    Element(SnapshotHandle),
    /// A point inside a frame of recognized screen text, with no element behind it.
    Recognized(AppQuery, axon_core::Rect),
    /// A caller-supplied point, and the application it named, if any.
    Point(Option<String>),
}

/// The pointer actions this router posts, each through the same ladder and transaction.
#[derive(Clone, Copy)]
enum PointerAction {
    Click,
    /// A wheel burst carrying this `(x, y)` pixel delta.
    Wheel((f64, f64)),
}

impl PointerAction {
    fn tool(self) -> &'static str {
        match self {
            PointerAction::Click => "click",
            PointerAction::Wheel(_) => "scroll",
        }
    }
}

/// Which application a pointer escalation activates, and which process the point must belong to.
struct PointerAim {
    identity: String,
    process_identifier: i32,
}

impl<
    B: PointerTargetVerifier
        + TextRecognitionProvider
        + VisualObservationProvider
        + ReadableStateProvider
        + NativeInput
        + BackgroundApplicationKeyboard
        + axon_core::RecordingEvidenceProvider,
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
            daemon: Default::default(),
            recorder: None,
            browser: None,
        }
    }

    /// Serves `navigate`, `windows`, and `tabs` through `browser`. Only the macOS daemon installs
    /// one outside the tests.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub(crate) fn with_browser(mut self, browser: Box<dyn browser::BrowserVerbs>) -> Self {
        self.browser = Some(browser);
        self
    }

    /// One browser verb. The parameter errors are worded as Swift's `ToolParamDecoder` words them,
    /// and every other refusal comes from the service already in its wire shape.
    fn browser_verb(
        &mut self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, JsonRpcError> {
        let Some(service) = self.browser.as_deref() else {
            return Err(capability_unavailable(
                method,
                "BrowserScripting",
                "not-implemented",
            ));
        };
        let app = browser_string(params, "app")?;
        match method {
            "navigate" => {
                let url = browser_string(params, "url")?;
                let result = service
                    .navigate(app, url)
                    .map_err(axon_core::BrowserError::into_rpc)?;
                serde_json::to_value(result).map_err(internal_error)
            }
            "windows" => {
                let windows = service
                    .windows(app)
                    .map_err(axon_core::BrowserError::into_rpc)?;
                let scripted: Vec<String> =
                    windows.iter().map(|window| window.title.clone()).collect();
                // Accessibility is the cross-check, never the authority: a capture that fails
                // leaves the scripted answer standing and says why it went unchecked.
                let cross_check = match self.backend.capture(&query_for_app(app)) {
                    Ok(snapshot) => axon_core::window_cross_check(
                        &scripted,
                        &snapshot
                            .app
                            .windows
                            .iter()
                            .filter_map(|window| window.title.clone())
                            .collect::<Vec<_>>(),
                    ),
                    Err(error) => axon_core::CrossCheck::Unavailable {
                        reason: format!("Accessibility cross-check unavailable: {error}"),
                    },
                };
                serde_json::to_value(axon_core::WindowsReport {
                    windows,
                    authority: axon_core::ScriptingAuthority::ApplicationScripting,
                    cross_check,
                })
                .map_err(internal_error)
            }
            _ => {
                let window = browser_integer(params, "window")?;
                let tabs = service
                    .tabs(app, window)
                    .map_err(axon_core::BrowserError::into_rpc)?;
                serde_json::to_value(axon_core::TabsReport::new(tabs)).map_err(internal_error)
            }
        }
    }

    fn register_snapshot(
        &mut self,
        snapshot: &Snapshot,
        coverage: SemanticRegistrationCoverage,
    ) -> Vec<axon_core::SemanticElementName> {
        let live_processes = self.backend.live_process_ids().ok();
        self.semantic_names
            .register_with_liveness(snapshot, coverage, |pid| {
                live_processes
                    .as_ref()
                    .is_none_or(|processes| processes.contains(&pid))
            })
    }

    /// Resolves a text location to the point a pointer action aims at, and what stands behind it.
    fn resolve_text_location(
        &mut self,
        value: &Value,
    ) -> Result<(ClickTarget, (f64, f64), Value), JsonRpcError> {
        let target: TextLocationTarget = serde_json::from_value(value.clone())
            .map_err(|error| rpc_error(-32602, error.to_string()))?;
        if target.app.is_empty() {
            return Err(rpc_error(-32602, "location app must not be empty"));
        }
        let app = query_for_app(&target.app);
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
        let resolution = json!(resolution);
        // The snapshot becomes the router's before the ladder runs, so foreground delivery recovers
        // the same canonical identity a handle click does. Handing the caller's raw app string to
        // the transaction instead would compare a display name against whatever identity the
        // backend reports for the foreground window, and the two can never match.
        self.snapshot = Some(snapshot);
        Ok((click_target, point, resolution))
    }

    /// A point target converted to screen coordinates, with the application it named.
    fn point_target(
        &mut self,
        tool: &str,
        target: &Value,
        params: &Map<String, Value>,
    ) -> Result<(ClickTarget, (f64, f64)), JsonRpcError> {
        let point = PointTarget::parse(target, params.get("app").and_then(Value::as_str))
            .map_err(|error| rpc_error(-32602, error))?;
        let screen = match point.space {
            PointSpace::Screen => (point.x, point.y),
            PointSpace::Window => {
                let app = point.app.as_deref().expect("a window point names its app");
                let frame = self
                    .backend
                    .focused_window_frame(&query_for_app(app))
                    .map_err(backend_error)?
                    .ok_or_else(|| {
                        rpc_error(
                            -32002,
                            format!("{app} has no focused window to measure a window point from"),
                        )
                    })?;
                (frame.x + point.x, frame.y + point.y)
            }
            // Screenshot pixels convert by the encoded image's size against the window it
            // photographed, which needs the capture the point was measured on. Recorded artifacts
            // only ever carry screen points.
            PointSpace::Screenshot => {
                return Err(capability_unavailable(
                    tool,
                    "screenshot-coordinate-space",
                    "not-implemented",
                ));
            }
        };
        Ok((ClickTarget::Point(point.app), screen))
    }

    /// Where a pointer action aims at a resolved element: the centre of the part of it that is
    /// actually on screen.
    ///
    /// Not the centre of its frame. A document view inside a scroll area reports the frame of the
    /// whole document, thousands of points tall, and its centre is somewhere nobody can see; the
    /// hit test there finds another window or nothing. Clipping by every ancestor's frame is what
    /// the scroll area and the window do to it on screen.
    fn element_point(&self, handle: &SnapshotHandle) -> Result<(f64, f64), JsonRpcError> {
        let snapshot = self.snapshot.as_ref().ok_or_else(|| {
            rpc_error(-32003, "the resolved element is not in the current capture")
        })?;
        let index = snapshot
            .index_for_handle(handle)
            .map_err(|error| rpc_error(-32003, error.to_string()))?;
        let frame = visible_frame(snapshot, index).ok_or_else(|| {
            rpc_error(
                -32003,
                "the resolved element exposes no frame, or none of it is visible, to aim a \
                 pointer at",
            )
        })?;
        Ok((frame.x + frame.width / 2.0, frame.y + frame.height / 2.0))
    }

    fn snapshot_node(&self, handle: &SnapshotHandle) -> Option<&axon_core::Node> {
        let snapshot = self.snapshot.as_ref()?;
        snapshot.node(snapshot.index_for_handle(handle).ok()?)
    }

    /// One pointer action, whatever resolved it, travelling the whole ladder exactly once.
    ///
    /// macOS has no background rung for a pointer action, so the ladder refuses or escalates to
    /// the foreground. The target is verified inside the transaction, after activation and
    /// immediately before the post: before activation, a window that the escalation is about to
    /// raise is still covered, and a check made then says nothing about where the event will land.
    fn deliver_pointer(
        &mut self,
        policy: DeliveryPolicy,
        action: PointerAction,
        target: ClickTarget,
        point: (f64, f64),
        resolution: Value,
    ) -> Result<Value, JsonRpcError> {
        let ladder = self.pointer_ladder(action);
        let Some(candidate) = self.selected(&ladder, policy) else {
            return Ok(self.refusal(&ladder, policy));
        };
        let aim = match &target {
            ClickTarget::Element(_) | ClickTarget::Recognized(..) => Some(self.snapshot_aim()?),
            ClickTarget::Point(Some(app)) => Some(
                self.backend
                    .application_process(&query_for_app(app))
                    .map_err(backend_error)?
                    .map(|process| PointerAim {
                        identity: process.identity,
                        process_identifier: process.process_identifier,
                    }),
            ),
            // A point naming no application is addressed at whatever holds the foreground.
            ClickTarget::Point(None) => None,
        };
        let (foreground, owner) = match &aim {
            Some(Some(aim)) => (
                ForegroundTarget::Application(aim.identity.as_str()),
                Some(aim.process_identifier),
            ),
            // Falling through to the frontmost here would post global input into whatever the
            // user is working in, having been asked for something else.
            Some(None) => {
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
            }
            None => (ForegroundTarget::Frontmost, None),
        };
        let tool = action.tool();
        let verification =
            json!({"verified": false, "reason": format!("{tool} has no declared postcondition")});
        let mut result = self.foreground_dispatch(
            policy,
            &candidate,
            foreground,
            // The HID tap drives the real cursor, so the transaction puts it back.
            true,
            verification,
            move |backend| {
                let (fresh, stale) = match &target {
                    ClickTarget::Element(handle) => (
                        backend.verify_pointer_target(handle, point),
                        "target moved, is covered, or no longer matches the resolved element",
                    ),
                    ClickTarget::Recognized(app, frame) => (
                        backend.verify_ocr_target(app, point, *frame),
                        "target moved, is covered, or no longer matches the resolved text",
                    ),
                    ClickTarget::Point(_) => (
                        point_belongs(backend, point, owner),
                        "the point is not over a window of the application it was aimed at",
                    ),
                };
                if !fresh.map_err(backend_error)? {
                    return Err(rpc_error(-32003, format!("{tool} {stale}")));
                }
                match action {
                    PointerAction::Click => backend
                        .pointer_click(point)
                        .map(|_| Value::Null)
                        .map_err(backend_error),
                    PointerAction::Wheel(delta) => backend
                        .scroll_wheel(point, delta)
                        .map(|steps| {
                            json!({"eventPath": {
                                "units": "pixel",
                                "at": {"x": point.0, "y": point.1, "coordinateSpace": "screen"},
                                "steps": steps
                                    .iter()
                                    .map(|(x, y)| json!({"deltaX": x, "deltaY": y}))
                                    .collect::<Vec<_>>(),
                            }})
                        })
                        .map_err(backend_error),
                }
            },
        )?;
        if let (Some(object), false) = (result.as_object_mut(), resolution.is_null()) {
            object.insert("resolution".into(), resolution);
        }
        Ok(result)
    }

    /// Posts one keyboard request to one application process, and reports what that proved.
    fn dispatch_application(
        &mut self,
        policy: DeliveryPolicy,
        candidate: &DeliveryCandidate,
        process: &ApplicationProcess,
        intent: KeyboardIntent<'_>,
        verification: Value,
    ) -> Result<Value, JsonRpcError> {
        let modifiers_before = self.backend.modifier_state();
        let dispatched = self.backend.dispatch_application_keyboard(process, intent);
        let readback = Some((
            modifiers_before,
            settled_modifier_state(&mut self.backend, modifiers_before),
        ));
        let dispatch = match dispatched {
            Ok(dispatch) => dispatch,
            // Revalidation failed, so nothing was posted and the pid now names something else.
            Err(BackgroundDispatchError::Stale(reason)) => return Err(rpc_error(-32003, reason)),
            Err(BackgroundDispatchError::Backend(error)) => return Err(backend_error(error)),
        };
        // This rung is defined by what it does not do. A dispatch across which the foreground
        // changed was not background delivery, whatever it managed to deliver. The pointer is
        // reported and not judged: keystrokes touch no pointing device.
        let held = dispatch.frontmost_unchanged;
        let mut result = json!({
            "success": goal_success(&verification, held),
            "dispatch": {"success": true, "mechanism": candidate.mechanism},
            "verification": verification,
            "backgroundDelivery": {
                "targetApplication": process.identity,
                "targetProcessIdentifier": process.process_identifier,
                "frontmostAppUnchanged": dispatch.frontmost_unchanged,
                "pointerUnchanged": dispatch.pointer_unchanged,
                "pointerAsserted": PointerContract::Observed.is_asserted(),
                // What licenses this rung: the measured rows and the exact event construction
                // they measured, one hop from the dispatch they authorize.
                "variant": background::KEYBOARD_VARIANT,
                "evidence": background::KEYBOARD_EVIDENCE,
            },
        });
        let object = result
            .as_object_mut()
            .expect("a JSON object literal is an object");
        if !held {
            object.insert(
                "message".into(),
                json!("the foreground application changed across the dispatch"),
            );
        }
        DeliveryOutcome::dispatched(policy, DeliveryRung::Application).merge_into(object);
        stamp_modifier_readback(&mut result, "backgroundDelivery", readback);
        Ok(result)
    }

    /// The application that owns the currently resolved target, spelled the way foreground
    /// delivery compares it, and its process.
    ///
    /// Foreground delivery has to activate the application the *target* belongs to, not whichever
    /// app string the request happened to carry. A handle-only request carries no app string at
    /// all, and treating that as "already frontmost" would dispatch global input with no
    /// activation and no proof — the exact bug this contract exists to close.
    fn snapshot_aim(&mut self) -> Result<Option<PointerAim>, JsonRpcError> {
        let Some(app) = self.snapshot.as_ref().map(|snapshot| &snapshot.app) else {
            return Ok(None);
        };
        let query = match app.process_id {
            Some(process_id) => AppQuery {
                process_id: Some(process_id),
                name: None,
                identifier: None,
            },
            None => AppQuery {
                process_id: None,
                name: app.identifier.is_none().then(|| app.name.clone()),
                identifier: app.identifier.clone(),
            },
        };
        Ok(self
            .backend
            .application_process(&query)
            .map_err(backend_error)?
            .map(|process| PointerAim {
                identity: process.identity,
                process_identifier: process.process_identifier,
            }))
    }

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
        // Browser verbs deliver nothing to a window, so they take no delivery policy.
        if matches!(method, "navigate" | "windows" | "tabs") {
            return self.browser_verb(method, params);
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
                if let Some(location) = text_location(params) {
                    let (target, point, resolution) = self.resolve_text_location(&location)?;
                    // A resolved text location is a click like any other. It travels the same
                    // ladder and the same transaction; a separate path here is how a caller ends up
                    // with global pointer input under a policy that forbids it.
                    return self.deliver_pointer(
                        policy,
                        PointerAction::Click,
                        target,
                        point,
                        resolution,
                    );
                }
                if let Some(target) = params.get("target").filter(|t| pointer_target_is_point(t)) {
                    let (target, point) = self.point_target("click", &target.clone(), params)?;
                    return self.deliver_pointer(
                        policy,
                        PointerAction::Click,
                        target,
                        point,
                        Value::Null,
                    );
                }
                let (handle, resolution) = self.resolve(params)?;
                // The semantic rung is offered only to an element that advertises the action.
                // Discovering its absence from the AX error instead leaked kAXErrorActionUnsupported
                // to the caller for every text area and window that was ever clicked.
                let advertised = match self
                    .backend
                    .advertised_actions(&handle)
                    .map_err(backend_error)?
                {
                    Some(actions) => actions,
                    None => self
                        .snapshot_node(&handle)
                        .map(|node| node.actions.clone())
                        .unwrap_or_default(),
                };
                let presses = advertised.iter().any(|action| action == "AXPress");
                if !presses {
                    let point = self.element_point(&handle)?;
                    return self.deliver_pointer(
                        policy,
                        PointerAction::Click,
                        ClickTarget::Element(handle),
                        point,
                        json!(resolution),
                    );
                }
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
                if let KeyboardIntent::Key(spec) = intent {
                    input::stroke(spec).map_err(|error| rpc_error(-32602, error))?;
                }
                let app = app_query(params);
                // `keyboard` naming no application is explicitly addressed at whatever holds the
                // foreground: nothing to activate, nothing to restore, and no process to post to.
                // Naming one makes it aimed, and both the application rung and the transaction
                // use the backend's own identity for that application rather than the display
                // name the request carried.
                let aimed =
                    app.name.is_some() || app.identifier.is_some() || app.process_id.is_some();
                let process = if aimed {
                    match self
                        .backend
                        .application_process(&app)
                        .map_err(backend_error)?
                    {
                        Some(process) => Some(process),
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
                let plan = self
                    .backend
                    .plan_application_keyboard(process.clone(), intent);
                let ladder = self.keyboard_ladder(&plan);
                let Some(candidate) = self.selected(&ladder, policy) else {
                    return Ok(self.refusal(&ladder, policy));
                };
                let verification = json!({"verified":false,"reason":"keyboard input has no declared postcondition"});
                if candidate.rung == DeliveryRung::Application {
                    let ApplicationPlan::Bound(bound) = plan else {
                        unreachable!("the application rung is only offered for a bound plan")
                    };
                    return self.dispatch_application(
                        policy,
                        &candidate,
                        &bound,
                        intent,
                        verification,
                    );
                }
                let mut readback = None;
                let slot = &mut readback;
                let mut result = self.foreground_dispatch(
                    policy,
                    &candidate,
                    process
                        .as_ref()
                        .map_or(ForegroundTarget::Frontmost, |process| {
                            ForegroundTarget::Application(&process.identity)
                        }),
                    // Keyboard input never touches the cursor, and capturing a pointer it does not
                    // move would report a restoration that never happened.
                    false,
                    verification,
                    move |backend| {
                        let before = backend.modifier_state();
                        let posted = backend.keyboard(&app, intent);
                        *slot = Some((before, settled_modifier_state(backend, before)));
                        posted.map(|_| Value::Null).map_err(backend_error)
                    },
                )?;
                if result
                    .get("delivery")
                    .is_some_and(|delivery| !delivery.is_null())
                {
                    stamp_modifier_readback(&mut result, "foreground", readback);
                }
                Ok(result)
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
                // These defaults mirror the generated public schema: pixels, with -120 one notch.
                let dx = number_param(params, "deltaX", 0.0)?;
                let dy = number_param(params, "deltaY", -120.0)?;
                if !(dx.is_finite() && dy.is_finite()) {
                    return Err(rpc_error(-32602, "deltaX and deltaY must be finite"));
                }
                if dx != 0.0 || dy != 0.0 {
                    return self.scroll_wheel(params, policy, (dx, dy));
                }
                // A zero delta asks for the semantic scroll: bring an element into view.
                let semantic = params.get("target").filter(|target| {
                    !pointer_target_is_point(target) && target.get("location").is_none()
                });
                if semantic.is_none() {
                    return Err(rpc_error(
                        -32602,
                        "a scroll with no delta brings a semantic target into view, so it requires \
                         one; a point, a text location, or an app scrolls only by a nonzero delta",
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

    /// A wheel scroll, aimed at whatever the request named.
    ///
    /// The point is resolved in a fixed order: a semantic target's element centre, a point target,
    /// a text location's resolved point, or the centre of `app`'s focused window. A request naming
    /// none of them has nowhere to scroll.
    fn scroll_wheel(
        &mut self,
        params: &Map<String, Value>,
        policy: DeliveryPolicy,
        delta: (f64, f64),
    ) -> Result<Value, JsonRpcError> {
        let action = PointerAction::Wheel(delta);
        if let Some(location) = text_location(params) {
            let (target, point, resolution) = self.resolve_text_location(&location)?;
            return self.deliver_pointer(policy, action, target, point, resolution);
        }
        match params.get("target") {
            Some(target) if pointer_target_is_point(target) => {
                let (target, point) = self.point_target("scroll", &target.clone(), params)?;
                self.deliver_pointer(policy, action, target, point, Value::Null)
            }
            Some(_) => {
                let (handle, resolution) = self.resolve(params)?;
                let point = self.element_point(&handle)?;
                self.deliver_pointer(
                    policy,
                    action,
                    ClickTarget::Element(handle),
                    point,
                    json!(resolution),
                )
            }
            None => {
                let Some(app) = params
                    .get("app")
                    .and_then(Value::as_str)
                    .filter(|app| !app.is_empty())
                else {
                    return Err(rpc_error(
                        -32602,
                        "scroll requires a target or an app to aim the wheel at",
                    ));
                };
                let frame = self
                    .backend
                    .focused_window_frame(&query_for_app(app))
                    .map_err(backend_error)?
                    .ok_or_else(|| {
                        rpc_error(-32002, format!("{app} has no focused window to scroll"))
                    })?;
                let point = (frame.x + frame.width / 2.0, frame.y + frame.height / 2.0);
                self.deliver_pointer(
                    policy,
                    action,
                    ClickTarget::Point(Some(app.to_owned())),
                    point,
                    Value::Null,
                )
            }
        }
    }

    /// The ladder for a pointer action: no background rung, for reasons that are properties of
    /// macOS rather than of the target, and the HID tap behind the explicit opt-in.
    fn pointer_ladder(&self, action: PointerAction) -> Vec<DeliveryCandidate> {
        let mut ladder = Vec::with_capacity(4);
        if let PointerAction::Wheel(_) = action {
            ladder.push(DeliveryCandidate::unavailable(
                DeliveryRung::Semantic,
                DeliveryCapability::SemanticAction,
                "AXScrollToVisible",
                DeliveryRefusalReason::NoDeliveryCandidate,
                NO_SEMANTIC_SCROLL_DELTA,
            ));
        }
        ladder.extend([
            DeliveryCandidate::unavailable(
                DeliveryRung::Pixel,
                DeliveryCapability::BackgroundPixelInput,
                PIXEL_MECHANISM,
                DeliveryRefusalReason::BackgroundPixelUnsupported,
                NO_WINDOW_BOUND_POINTER,
            ),
            DeliveryCandidate::unavailable(
                DeliveryRung::Application,
                DeliveryCapability::BackgroundPixelInput,
                APPLICATION_MECHANISM,
                DeliveryRefusalReason::BackgroundPixelUnsupported,
                background::PID_POINTER_REFUSED,
            ),
            self.foreground_candidate(Capability::PointerInput, FOREGROUND_MECHANISM),
        ]);
        ladder
    }

    /// The ladder for keyboard input: no pixel rung by construction, the application rung as
    /// the plan answers it, and the HID tap behind the explicit opt-in.
    fn keyboard_ladder(&self, plan: &ApplicationPlan) -> Vec<DeliveryCandidate> {
        vec![
            DeliveryCandidate::unavailable(
                DeliveryRung::Pixel,
                DeliveryCapability::BackgroundPixelInput,
                PIXEL_MECHANISM,
                DeliveryRefusalReason::BackgroundPixelUnsupported,
                NO_KEYBOARD_GEOMETRY,
            ),
            match (plan, self.capability_restriction(Capability::KeyboardInput)) {
                // Posting to a process needs the same Accessibility grant the HID tap does.
                (ApplicationPlan::Bound(_), Some(restriction)) => DeliveryCandidate::unavailable(
                    DeliveryRung::Application,
                    DeliveryCapability::BackgroundPixelInput,
                    APPLICATION_MECHANISM,
                    DeliveryRefusalReason::NoDeliveryCandidate,
                    restriction,
                ),
                (ApplicationPlan::Bound(_), None) => DeliveryCandidate::available(
                    DeliveryRung::Application,
                    DeliveryCapability::BackgroundPixelInput,
                    APPLICATION_MECHANISM,
                ),
                // The plan's own reason travels intact, so a caller can tell a chord nobody
                // measured from a request that named no application.
                (ApplicationPlan::Unavailable(reason), _) => DeliveryCandidate::unavailable(
                    DeliveryRung::Application,
                    DeliveryCapability::BackgroundPixelInput,
                    APPLICATION_MECHANISM,
                    DeliveryRefusalReason::BackgroundPixelUnsupported,
                    reason.clone(),
                ),
            },
            self.foreground_candidate(Capability::KeyboardInput, FOREGROUND_MECHANISM),
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

    /// Dispatches one action inside a foreground transaction.
    ///
    /// `body` runs only after activation is proved. It may still decline with an error, such as a
    /// target that moved, and it returns any detail of its own to merge into the result. Either way
    /// the transaction hands the session back, and its cleanup evidence travels with what the
    /// caller receives.
    fn foreground_dispatch(
        &mut self,
        policy: DeliveryPolicy,
        candidate: &DeliveryCandidate,
        target: ForegroundTarget<'_>,
        restores_pointer: bool,
        verification: Value,
        body: impl FnOnce(&mut B) -> Result<Value, JsonRpcError>,
    ) -> Result<Value, JsonRpcError> {
        let dispatch = dispatch_in_foreground(&mut self.backend, target, restores_pointer, body);
        let mut cleanup = dispatch.cleanup;
        if let Some(evidence) = self.backend.take_activation_evidence() {
            cleanup.message = Some(match cleanup.message.take() {
                Some(message) => format!("{message}; {evidence}"),
                None => evidence,
            });
        }
        if let Some(refusal) = dispatch.refusal {
            let mut result = DeliveryOutcome::refusal_result(policy, refusal);
            if let Some(object) = result.as_object_mut() {
                object.insert("foreground".into(), json!(cleanup));
            }
            return Ok(result);
        }
        let detail = match dispatch.value.expect("a proved activation dispatches") {
            Ok(detail) => detail,
            Err(mut failure) => {
                // The transaction activated and then handed the session back around this failure,
                // so its cleanup evidence is the only record of what happened to the user's
                // foreground. It rides on the error rather than being dropped.
                let mut data = match failure.data.take() {
                    Some(Value::Object(data)) => data,
                    _ => Map::new(),
                };
                data.insert("foreground".into(), json!(cleanup));
                failure.data = Some(Value::Object(data));
                return Err(failure);
            }
        };

        let mut result = json!({
            // This rung promises proved activation and exactly one dispatch. The hand-back remains
            // reported cleanup evidence, while verification proves whether the target acted.
            "success": goal_success(&verification, cleanup.activation_proved),
            "dispatch": {"success": true, "mechanism": candidate.mechanism},
            "verification": verification,
            "foreground": cleanup,
        });
        if let (Some(object), Value::Object(detail)) = (result.as_object_mut(), detail) {
            object.extend(detail);
        }
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
            context.recorded_handle().ok_or_else(|| {
                rpc_error(
                    -32002,
                    "semantic target has no live retained capture; call look for its app first",
                )
            })?;
            // Native captures replace the handle cache, so retained provenance cannot authorize
            // paging directly. Resolve against a fresh capture pinned to the selected process.
            let (handle, _) = self.resolve(params)?;
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
                    name: context.app_name().to_owned(),
                    process_id: context.process_id(),
                    identifier: context.app_identifier().map(str::to_owned),
                    windows: vec![axon_core::Window {
                        title: None,
                        root: parent,
                    }],
                },
            };
            let names = self.register_snapshot(&snapshot, SemanticRegistrationCoverage::Partial);
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
        let coverage = SemanticRegistrationCoverage::for_capture(&snapshot, child_depth);
        let names = self.register_snapshot(&snapshot, coverage);
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
        let coverage = SemanticRegistrationCoverage::for_capture(&first, None);
        let first_names = self.register_snapshot(&first, coverage);
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
            let coverage = SemanticRegistrationCoverage::for_capture(&snapshot, None);
            let names = self.register_snapshot(&snapshot, coverage);
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
        + NativeInput
        + BackgroundApplicationKeyboard
        + axon_core::RecordingEvidenceProvider,
> ToolDispatcher for Router<B>
{
    fn set_observation_redaction_context(
        &mut self,
        context: axon_core::ObservationRedactionContext,
    ) {
        self.daemon.recording.set_redaction_context(context.clone());
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
    let mut query = params
        .get("app")
        .and_then(Value::as_str)
        .map(query_for_app)
        .unwrap_or(AppQuery {
            process_id: None,
            name: None,
            identifier: None,
        });
    query.identifier = params
        .get("identifier")
        .and_then(Value::as_str)
        .map(str::to_owned);
    query
}

/// The query one `app` string makes: a process id when it is one (bare or as `pid:<n>`), and
/// otherwise a name the backend matches against both display names and bundle identifiers, which
/// is what lets a recorded `{app: "com.apple.TextEdit", point}` replay.
fn query_for_app(app: &str) -> AppQuery {
    let process_id = app.strip_prefix("pid:").unwrap_or(app).parse().ok();
    AppQuery {
        process_id,
        name: process_id.is_none().then(|| app.to_owned()),
        identifier: None,
    }
}

/// The part of the node at `index` (in the flattened order handles use) that its ancestors leave
/// visible: its frame intersected with every ancestor frame. `None` when it has no frame or the
/// intersection is empty.
fn visible_frame(snapshot: &Snapshot, index: usize) -> Option<axon_core::Rect> {
    fn clip(a: axon_core::Rect, b: axon_core::Rect) -> Option<axon_core::Rect> {
        let (left, top) = (a.x.max(b.x), a.y.max(b.y));
        let (right, bottom) = (
            (a.x + a.width).min(b.x + b.width),
            (a.y + a.height).min(b.y + b.height),
        );
        (right > left && bottom > top).then_some(axon_core::Rect {
            x: left,
            y: top,
            width: right - left,
            height: bottom - top,
        })
    }
    /// Walks in the same pre-order `Snapshot::node` numbers nodes in, carrying the clip.
    fn find(
        node: &axon_core::Node,
        clip_to: Option<axon_core::Rect>,
        next: &mut usize,
        wanted: usize,
    ) -> Option<Option<axon_core::Rect>> {
        let here = *next;
        *next += 1;
        let visible = match (node.frame, clip_to) {
            (Some(frame), Some(bound)) => clip(frame, bound),
            (Some(frame), None) => Some(frame),
            (None, bound) => bound,
        };
        if here == wanted {
            return Some(node.frame.and(visible));
        }
        node.children
            .iter()
            .find_map(|child| find(child, visible.or(clip_to), next, wanted))
    }
    let mut next = 0;
    snapshot
        .app
        .windows
        .iter()
        .find_map(|window| find(&window.root, None, &mut next, index))
        .flatten()
}

/// The text location a pointer request carries, inside its target or beside it.
fn text_location(params: &Map<String, Value>) -> Option<Value> {
    params
        .get("target")
        .and_then(|target| target.get("location"))
        .or_else(|| params.get("location"))
        .cloned()
}

/// Whether `point` is over a window of the expected process: the one the action was aimed at, or
/// for an unaimed point, whichever application holds the foreground.
fn point_belongs<B: NativeInput>(
    backend: &mut B,
    point: (f64, f64),
    expected: Option<i32>,
) -> Result<bool, axon_core::BackendError> {
    let expected = match expected {
        Some(process) => Some(process as i64),
        None => backend
            .frontmost_application()?
            .and_then(|identity| backend.application_process_identifier(&identity)),
    };
    let owner = backend.point_owner(point)?;
    Ok(owner.is_some() && owner.map(i64::from) == expected)
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

/// A required string, refused in Swift's words: absent and mistyped are different mistakes.
fn browser_string<'a>(params: &'a Map<String, Value>, key: &str) -> Result<&'a str, JsonRpcError> {
    match params.get(key) {
        None | Some(Value::Null) => Err(rpc_error(
            -32602,
            format!("Missing string parameter: {key}"),
        )),
        Some(Value::String(value)) => Ok(value),
        Some(_) => Err(rpc_error(-32602, format!("{key} must be a string"))),
    }
}

fn browser_integer(params: &Map<String, Value>, key: &str) -> Result<Option<i64>, JsonRpcError> {
    match params.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_i64()
            .map(Some)
            .ok_or_else(|| rpc_error(-32602, format!("{key} must be an integer"))),
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
        // Same family as `Capability`, plus the stable `code` that names *which* refusal it is.
        // Without this arm a typed refusal would fall through to the catch-all and reach the wire
        // as an untyped -32000, which is exactly how `accessibility-denied` used to be lost.
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

    /// The fake this module routes against: it enumerates nothing and records synthetic events.
    ///
    /// `global_input` is what the observer seam answers with, so one fake covers both a backend
    /// that can record and a backend whose Accessibility grant is denied.
    struct EnumerationBackend {
        global_input: bool,
        /// The window titles a capture reports, for the browser cross-check. A capture of a
        /// backend without them is a test asking for more than it set up.
        window_titles: Option<Vec<String>>,
    }

    impl EnumerationBackend {
        fn new() -> Self {
            Self {
                global_input: true,
                window_titles: None,
            }
        }
        fn without_global_input() -> Self {
            Self {
                global_input: false,
                window_titles: None,
            }
        }
        fn with_windows(titles: &[&str]) -> Self {
            Self {
                global_input: true,
                window_titles: Some(titles.iter().map(|title| (*title).to_owned()).collect()),
            }
        }
    }

    impl PlatformBackend for EnumerationBackend {
        fn capabilities(&self) -> Result<Vec<axon_core::CapabilityInfo>, axon_core::BackendError> {
            Ok(vec![])
        }
        /// This fake records, so by default it must claim the observer seam. Without the override
        /// it would inherit the core default that refuses, and `recording.start`'s capability
        /// preflight would turn every recording test here into a capability refusal.
        fn global_input_observer(
            &mut self,
        ) -> Result<&mut dyn axon_core::GlobalInputObserver, axon_core::BackendError> {
            if !self.global_input {
                return Err(axon_core::BackendError::CapabilityReason {
                    capability: Capability::ObserveGlobalInput,
                    code: "accessibility-denied",
                    reason: "Accessibility permission is not granted".into(),
                    diagnostic: None,
                });
            }
            Ok(self)
        }
        fn enumerate_applications(
            &self,
        ) -> Result<Vec<axon_core::Application>, axon_core::BackendError> {
            Ok(vec![])
        }
        fn capture(&mut self, _: &AppQuery) -> Result<Snapshot, axon_core::BackendError> {
            let titles = self.window_titles.clone().expect("no capture was set up");
            Ok(Snapshot::new(axon_core::Application {
                name: "Safari".into(),
                process_id: Some(42),
                identifier: Some("com.apple.Safari".into()),
                windows: titles
                    .into_iter()
                    .map(|title| axon_core::Window {
                        title: Some(title.clone()),
                        root: axon_core::Node {
                            role: "AXWindow".into(),
                            subrole: None,
                            name: None,
                            title: Some(title),
                            label: None,
                            value: None,
                            description: None,
                            identifier: None,
                            actions: Vec::new(),
                            frame: None,
                            editable: false,
                            focused: None,
                            enabled: None,
                            children: Vec::new(),
                            child_count: None,
                            truncation_reason: None,
                        },
                    })
                    .collect(),
            }))
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
    impl NativeInput for EnumerationBackend {
        fn point_owner(&mut self, _: (f64, f64)) -> Result<Option<i32>, axon_core::BackendError> {
            unreachable!()
        }
        fn focused_window_frame(
            &mut self,
            _: &AppQuery,
        ) -> Result<Option<axon_core::Rect>, axon_core::BackendError> {
            unreachable!()
        }
        fn scroll_wheel(
            &mut self,
            _: (f64, f64),
            _: (f64, f64),
        ) -> Result<Vec<(i32, i32)>, axon_core::BackendError> {
            unreachable!()
        }
    }
    impl BackgroundApplicationKeyboard for EnumerationBackend {
        fn application_process(
            &mut self,
            _: &AppQuery,
        ) -> Result<Option<ApplicationProcess>, axon_core::BackendError> {
            unreachable!()
        }
        fn dispatch_application_keyboard(
            &mut self,
            _: &ApplicationProcess,
            _: KeyboardIntent<'_>,
        ) -> Result<ApplicationDispatch, BackgroundDispatchError> {
            unreachable!()
        }
    }

    impl axon_core::GlobalInputObserver for EnumerationBackend {
        fn start(&mut self, _: &axon_core::RecordingScope) -> Result<(), axon_core::BackendError> {
            Ok(())
        }
        fn poll(
            &mut self,
            _: Duration,
        ) -> Result<Vec<axon_core::RecordedInputEvent>, axon_core::BackendError> {
            Ok(vec![axon_core::RecordedInputEvent::KeyDown {
                app: axon_core::RecordedAppIdentity {
                    name: "Notes".into(),
                    bundle_identifier: Some("com.example.Notes".into()),
                    process_id: None,
                },
                keystroke: axon_core::RecordedKeystroke::Key {
                    key: "Return".into(),
                },
                timestamp_ms: 1,
            }])
        }
        fn stop(&mut self) -> Result<(), axon_core::BackendError> {
            Ok(())
        }
        fn is_recording(&self) -> bool {
            true
        }
    }

    impl axon_core::RecordingEvidenceProvider for EnumerationBackend {
        fn read_focused(
            &mut self,
        ) -> Result<Option<axon_core::RecordedFocusedEvidence>, axon_core::BackendError> {
            Ok(None)
        }
        fn capture_snapshot(
            &mut self,
            _: &axon_core::RecordedAppIdentity,
        ) -> Result<Option<Snapshot>, axon_core::BackendError> {
            Ok(None)
        }
        fn settle(
            &mut self,
            _: usize,
            _: &str,
        ) -> Result<axon_core::RecordedSettleEvidence, axon_core::BackendError> {
            Ok(Default::default())
        }
    }

    /// A backend that cannot observe global input refuses `recording.start` before any session
    /// exists, and the refusal keeps its typed shape all the way to the wire.
    ///
    /// Both halves are the bug. The refusal used to surface from inside
    /// `UserActionRecorder::start_with_redaction`, after the daemon had already opened a recording
    /// it then had to abandon; and `backend_error` had no arm for the typed variant, so a caller
    /// saw `-32000 operation observeGlobalInput failed` with nothing to key on.
    #[test]
    fn recording_start_refuses_typed_when_global_input_is_unavailable() {
        let mut router = Router::new(EnumerationBackend::without_global_input());
        let response = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                "recording.start",
                Some(json!({"scope":{"scope":"allApplications"}})),
            ))
            .unwrap();
        let JsonRpcResponse::Failure(failure) = response else {
            panic!("a backend without a usable observer must refuse recording.start")
        };
        assert_eq!(failure.error.code, -32004);
        let data = failure
            .error
            .data
            .clone()
            .expect("a typed refusal carries data");
        assert_eq!(data["kind"], "capability-unavailable");
        assert_eq!(data["capability"], "observeGlobalInput");
        assert_eq!(data["code"], "accessibility-denied");

        // Refused before dispatch: nothing was started, so nothing had to be abandoned.
        assert!(router.recorder.is_none());
        assert!(!router.daemon.recording.status().recording);

        // The menu shell keys its "request Accessibility" alert on exactly this error, so its
        // whole shape is shell-v1 contract (`schema/fixtures/shell`).
        let pinned: Value = serde_json::from_str(include_str!(
            "../../../schema/fixtures/shell/error-accessibility-denied.json"
        ))
        .unwrap();
        assert_eq!(serde_json::to_value(&failure.error).unwrap(), pinned);
    }

    #[test]
    fn a_typed_capability_refusal_reaches_the_wire_with_its_code() {
        let error = backend_error(axon_core::BackendError::CapabilityReason {
            capability: Capability::ObserveGlobalInput,
            code: "accessibility-denied",
            reason: "Accessibility permission is not granted".into(),
            diagnostic: Some("kAXErrorAPIDisabled (-25211)".into()),
        });
        assert_eq!(error.code, -32004);
        assert_eq!(
            error.message,
            "capability observeGlobalInput is unavailable: Accessibility permission is not granted"
        );
        assert_eq!(
            error.data.unwrap(),
            json!({
                "kind": "capability-unavailable",
                "capability": "observeGlobalInput",
                "code": "accessibility-denied",
                "reason": "Accessibility permission is not granted",
                "diagnostic": "kAXErrorAPIDisabled (-25211)",
            })
        );
    }

    #[test]
    fn recording_routes_ingest_native_events_before_stop() {
        let mut router = Router::new(EnumerationBackend::new());
        let start = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                "recording.start",
                Some(json!({"scope":{"scope":"allApplications"}})),
            ))
            .unwrap();
        assert!(matches!(start, JsonRpcResponse::Success(_)));

        let status = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(2)),
                "recording.status",
                Some(json!({})),
            ))
            .unwrap();
        assert!(matches!(status, JsonRpcResponse::Success(_)));

        let stop = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(3)),
                "recording.stop",
                Some(json!({})),
            ))
            .unwrap();
        let JsonRpcResponse::Success(stop) = stop else {
            panic!("recording.stop must author the drained native events")
        };
        assert!(stop.result["actionCount"].as_u64().unwrap() > 0);
        assert!(stop.result["script"].as_str().unwrap().contains("Return"));
    }

    #[test]
    fn invalid_recording_stop_preserves_native_and_daemon_session_state() {
        let mut router = Router::new(EnumerationBackend::new());
        let start = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(1)),
                "recording.start",
                Some(json!({"scope":{"scope":"allApplications"}})),
            ))
            .unwrap();
        assert!(matches!(start, JsonRpcResponse::Success(_)));

        let invalid = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(2)),
                "recording.stop",
                Some(json!({"extra":true})),
            ))
            .unwrap();
        assert!(matches!(invalid, JsonRpcResponse::Failure(_)));
        assert!(router.recorder.is_some());
        assert!(router.daemon.recording.status().recording);

        let stop = router
            .request(JsonRpcRequest::new(
                Some(JsonRpcId::Integer(3)),
                "recording.stop",
                Some(json!({})),
            ))
            .unwrap();
        let JsonRpcResponse::Success(stop) = stop else {
            panic!("valid stop must still drain and author native events")
        };
        assert!(stop.result["actionCount"].as_u64().unwrap() > 0);
    }

    #[test]
    fn look_application_enumeration_matches_shared_envelope() {
        let mut router = Router::new(EnumerationBackend::new());
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
        let error = router_error(
            &mut Router::new(EnumerationBackend::new()),
            "invoke",
            missing_name,
        );
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

    /// Every tool this backend has no code path for refuses through the router, typed, before
    /// anything is dispatched.
    #[test]
    fn excluded_tools_are_capability_errors_through_the_router() {
        let mut router = Router::new(EnumerationBackend::new());
        for (tool, capability) in EXCLUDED {
            let error = router_error(&mut router, tool, Map::new());
            assert_eq!(error.code, -32004, "{tool}");
            let data = error.data.unwrap();
            assert_eq!(data["code"], "capability-unavailable", "{tool}");
            assert_eq!(data["capability"], *capability, "{tool}");
        }
    }

    /// The tool surface and the exclusion list are two declarations of one fact, so a tool the
    /// surface advertises on this backend can never also be one it refuses outright.
    #[test]
    fn no_tool_advertised_on_mac_is_excluded() {
        let advertised = axon_core::backend_tools(axon_core::ToolBackend::Mac).unwrap();
        for tool in advertised {
            let name = tool["name"].as_str().unwrap();
            assert!(
                EXCLUDED.iter().all(|(excluded, _)| *excluded != name),
                "{name} is advertised on mac and excluded"
            );
        }
    }

    /// A router without a browser service refuses the verbs the same typed way.
    #[test]
    fn browser_verbs_without_a_service_are_unavailable() {
        let error = router_error(
            &mut Router::new(EnumerationBackend::new()),
            "windows",
            Map::from_iter([("app".to_owned(), json!("Safari"))]),
        );
        assert_eq!(error.code, -32004);
        assert_eq!(error.data.unwrap()["capability"], "BrowserScripting");
    }

    /// Every fixture in `schema/fixtures/browser` is the (now deleted) Swift router's answer to one
    /// request, a frozen corpus. The Rust router, over the real service and settle against a
    /// scripted browser and consent host, gives exactly the same answer to the same request.
    #[test]
    fn the_router_answers_every_browser_fixture_exactly_as_swift_does() {
        use crate::apple_events::AeError;
        use crate::automation::{EVENT_NOT_PERMITTED, NO_ERR, WOULD_REQUIRE_CONSENT};
        use crate::browser::{Dictionary, fake};

        let directory =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../schema/fixtures/browser");
        let mut names: Vec<String> = std::fs::read_dir(&directory)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .filter(|name| name.ends_with(".json") && name != "url-cases.json")
            .collect();
        names.sort();
        assert_eq!(
            names.len(),
            17,
            "a fixture without a scenario here is unpinned"
        );

        for name in names {
            let fixture: Value =
                serde_json::from_str(&std::fs::read_to_string(directory.join(&name)).unwrap())
                    .unwrap();
            let navigation = || fake::navigation_state("navigate-verified.json");
            let (dictionary, status, running, state, ax): (_, _, _, _, &[&str]) = match name
                .as_str()
            {
                "navigate-verified.json" | "navigate-redirect.json" | "navigate-unsettled.json" => {
                    let (dictionary, state) = fake::navigation_state(&name);
                    (dictionary, NO_ERR, true, state, &[])
                }
                "windows-matched.json" => (
                    Dictionary::SAFARI,
                    NO_ERR,
                    true,
                    fake::State {
                        windows: vec![
                            fake::window("Example Domain", &[], 1),
                            fake::window("Second", &[], 1),
                        ],
                        ..fake::State::default()
                    },
                    &["Second", "Example Domain"],
                ),
                "windows-partial.json" => (
                    Dictionary::SAFARI,
                    NO_ERR,
                    true,
                    fake::State {
                        windows: vec![fake::window("Same", &[], 1), fake::window("Same", &[], 1)],
                        ..fake::State::default()
                    },
                    &["Same", "Different"],
                ),
                "tabs.json" => (Dictionary::CHROME, NO_ERR, true, fake::tabs_state(), &[]),
                "error-not-determined-checked.json" => (
                    Dictionary::CHROME,
                    WOULD_REQUIRE_CONSENT,
                    true,
                    navigation().1,
                    &[],
                ),
                "error-denied-checked.json" => (
                    Dictionary::SAFARI,
                    EVENT_NOT_PERMITTED,
                    true,
                    navigation().1,
                    &[],
                ),
                "error-denied-executed.json" => (
                    Dictionary::SAFARI,
                    NO_ERR,
                    true,
                    fake::State {
                        refuse: Some(AeError::NotPermitted),
                        ..navigation().1
                    },
                    &[],
                ),
                "error-not-running.json" => {
                    (Dictionary::SAFARI, NO_ERR, false, navigation().1, &[])
                }
                _ => (
                    Dictionary::SAFARI,
                    NO_ERR,
                    true,
                    fake::State::default(),
                    &[],
                ),
            };
            let rig = fake::rig_with(dictionary, status, running, state);
            let mut router = Router::new(EnumerationBackend::with_windows(ax))
                .with_browser(Box::new(rig.service));
            let response = serde_json::to_value(
                router
                    .request(JsonRpcRequest::new(
                        Some(JsonRpcId::Integer(1)),
                        fixture["method"].as_str().unwrap(),
                        Some(fixture["params"].clone()),
                    ))
                    .unwrap(),
            )
            .unwrap();
            let key = if fixture.get("error").is_some() {
                "error"
            } else {
                "result"
            };
            assert_eq!(response.get(key), fixture.get(key), "{name}");
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

    /// The macOS delivery table, end to end through the router against a backend that records
    /// every activation and every post. Nothing here touches Core Graphics, so each assertion about
    /// what was posted is an assertion about what the router asked for.
    mod native_delivery {
        use super::*;

        const TEXTEDIT: i32 = 4242;
        const PRIOR: i32 = 1000;
        const OTHER: i32 = 5150;

        /// The window, a text area that advertises no press, and a button that does, in the
        /// flattened order handles index them.
        const WINDOW: usize = 0;
        const TEXT_AREA: usize = 1;
        const BUTTON: usize = 2;
        /// A role the capture's role table does not know, which advertises `AXPress` anyway.
        const POPUP: usize = 3;

        fn node(
            role: &str,
            title: Option<&str>,
            actions: &[&str],
            frame: axon_core::Rect,
        ) -> axon_core::Node {
            axon_core::Node {
                role: role.into(),
                subrole: None,
                name: None,
                title: title.map(str::to_owned),
                label: None,
                value: None,
                description: None,
                identifier: None,
                actions: actions.iter().map(|action| action.to_string()).collect(),
                frame: Some(frame),
                editable: role == "AXTextArea",
                focused: None,
                enabled: Some(true),
                children: Vec::new(),
                child_count: None,
                truncation_reason: None,
            }
        }

        fn rect(x: f64, y: f64, width: f64, height: f64) -> axon_core::Rect {
            axon_core::Rect {
                x,
                y,
                width,
                height,
            }
        }

        struct NativeFake {
            snapshot: Snapshot,
            apps: Vec<(i32, &'static str, &'static str)>,
            frontmost: Option<String>,
            pointer: (f64, f64),
            activations: Vec<String>,
            /// Every post, in order: the only record of what reached the session.
            dispatches: Vec<String>,
            invokes: Vec<String>,
            invoked_handles: Vec<SnapshotHandle>,
            capture_sequence: usize,
            capture_queries: Vec<AppQuery>,
            last_capture: Option<Snapshot>,
            page_handles: Vec<SnapshotHandle>,
            deep_paging: bool,
            fail_handle_query: bool,
            fail_page: bool,
            point_owner: Option<i32>,
            window_origin: (f64, f64),
            target_alive: bool,
            denylist: &'static [DenylistEntry],
            /// The window server's modifier state, and whether a keyboard post leaves Command
            /// logically held in it, the way a chord with flags but no modifier keys did.
            modifiers: ModifierState,
            leaks_command: bool,
        }

        impl NativeFake {
            fn new() -> Self {
                let mut window = node(
                    "AXWindow",
                    Some("Untitled"),
                    &[],
                    rect(0.0, 0.0, 800.0, 600.0),
                );
                window.children = vec![
                    node(
                        "AXTextArea",
                        Some("Body"),
                        &[],
                        rect(100.0, 100.0, 200.0, 100.0),
                    ),
                    node(
                        "AXButton",
                        Some("Save"),
                        &["AXPress"],
                        rect(10.0, 10.0, 40.0, 20.0),
                    ),
                    node(
                        "AXPopUpButton",
                        Some("Format"),
                        &[],
                        rect(60.0, 10.0, 80.0, 20.0),
                    ),
                ];
                Self {
                    snapshot: Snapshot::new(axon_core::Application {
                        name: "TextEdit".into(),
                        process_id: Some(TEXTEDIT as u32),
                        identifier: Some("com.apple.TextEdit".into()),
                        windows: vec![axon_core::Window {
                            title: Some("Untitled".into()),
                            root: window,
                        }],
                    }),
                    apps: vec![
                        (TEXTEDIT, "TextEdit", "com.apple.TextEdit"),
                        (PRIOR, "Prior", "com.example.Prior"),
                        (OTHER, "Other", "com.example.Other"),
                    ],
                    frontmost: Some("com.example.Prior".into()),
                    pointer: (5.0, 5.0),
                    activations: Vec::new(),
                    dispatches: Vec::new(),
                    invokes: Vec::new(),
                    invoked_handles: Vec::new(),
                    capture_sequence: 0,
                    capture_queries: Vec::new(),
                    last_capture: None,
                    page_handles: Vec::new(),
                    deep_paging: false,
                    fail_handle_query: false,
                    fail_page: false,
                    point_owner: Some(TEXTEDIT),
                    window_origin: (0.0, 0.0),
                    target_alive: true,
                    denylist: background::DENYLIST,
                    // The non-coalesced bit an idle session reports, which is not a held key.
                    modifiers: ModifierState {
                        combined_session: 0x2000_0000,
                        hid_system: 0x2000_0000,
                    },
                    leaks_command: false,
                }
            }

            fn find(&self, app: &AppQuery) -> Option<(i32, &'static str)> {
                let mut matches = self.apps.iter().filter(|(pid, name, bundle)| {
                    app.process_id.is_none_or(|wanted| wanted == *pid as u32)
                        && app
                            .identifier
                            .as_deref()
                            .is_none_or(|wanted| wanted == *bundle)
                        && app.name.as_deref().is_none_or(|wanted| {
                            wanted.eq_ignore_ascii_case(name) || wanted == *bundle
                        })
                });
                match (matches.next(), matches.next()) {
                    (Some((pid, _, bundle)), None) => Some((*pid, *bundle)),
                    _ => None,
                }
            }
        }

        impl PlatformBackend for NativeFake {
            fn capabilities(
                &self,
            ) -> Result<Vec<axon_core::CapabilityInfo>, axon_core::BackendError> {
                Ok(Capability::ALL
                    .into_iter()
                    .map(|capability| axon_core::CapabilityInfo {
                        capability,
                        usable: true,
                        restriction: None,
                    })
                    .collect())
            }
            fn enumerate_applications(
                &self,
            ) -> Result<Vec<axon_core::Application>, axon_core::BackendError> {
                Ok(self
                    .apps
                    .iter()
                    .map(|(pid, name, bundle)| axon_core::Application {
                        name: (*name).into(),
                        process_id: Some(*pid as u32),
                        identifier: Some((*bundle).into()),
                        windows: Vec::new(),
                    })
                    .collect())
            }
            fn capture(&mut self, app: &AppQuery) -> Result<Snapshot, axon_core::BackendError> {
                assert!(
                    self.find(app).is_some(),
                    "capture must select the intended process"
                );
                self.capture_queries.push(app.clone());
                self.capture_sequence += 1;
                let mut snapshot = self.snapshot.clone();
                snapshot.id =
                    axon_core::SnapshotId(format!("mac-capture-{}", self.capture_sequence));
                if self.deep_paging {
                    let boundary = &mut snapshot.app.windows[0].root.children[1];
                    boundary.children.clear();
                    boundary.truncation_reason = Some("native app depth cap".into());
                }
                self.last_capture = Some(snapshot.clone());
                Ok(snapshot)
            }
            fn retains_handle(&mut self, target: &SnapshotHandle) -> Result<bool, axon_core::BackendError> {
                if self.fail_handle_query {
                    return Err(operation_failure());
                }
                Ok(self.last_capture.as_ref().is_some_and(|active| {
                    active.index_for_handle(target).ok().is_some_and(|index| active.node(index).is_some())
                }))
            }
            fn capture_child_page(
                &mut self,
                target: &SnapshotHandle,
                request: axon_core::ChildPageRequest,
            ) -> Result<axon_core::ChildPageCapture, axon_core::BackendError> {
                let active = self
                    .last_capture
                    .as_ref()
                    .expect("paging needs an active capture");
                let index = active.index_for_handle(target).expect("paging must reject stale cache handles");
                let title = active.node(index).expect("paging needs valid native index").title.clone();
                fn find<'a>(node: &'a axon_core::Node, title: &Option<String>) -> Option<&'a axon_core::Node> {
                    if &node.title == title { return Some(node); }
                    node.children.iter().find_map(|child| find(child, title))
                }
                let mut parent = find(&self.snapshot.app.windows[0].root, &title).unwrap().clone();
                let mut children = parent.children.clone();
                if !request.include_descendants {
                    for child in &mut children {
                        if !child.children.is_empty() {
                            child.truncation_reason = Some("page-local depth cap".into());
                            child.children.clear();
                        }
                    }
                }
                parent.children.clear();
                self.page_handles.push(target.clone());
                if self.fail_page {
                    return Err(operation_failure());
                }
                self.capture_sequence += 1;
                let page = axon_core::ChildPageCapture {
                    snapshot: axon_core::SnapshotId(format!("mac-page-{}", self.capture_sequence)),
                    parent,
                    offset: request.offset,
                    limit: request.limit.unwrap_or(1),
                    total: Some(children.len()),
                    children,
                };
                let mut active = self.snapshot.clone();
                active.id = page.snapshot.clone();
                active.app.windows[0].root = page.parent.clone();
                active.app.windows[0].root.children = page.children.clone();
                self.last_capture = Some(active);
                Ok(page)
            }
            fn invoke(
                &mut self,
                target: &SnapshotHandle,
                action: &str,
            ) -> Result<(), axon_core::BackendError> {
                self.last_capture
                    .as_ref()
                    .expect("invoke needs active capture")
                    .index_for_handle(target)
                    .expect("invoke must reject stale cache handles");
                self.invoked_handles.push(target.clone());
                self.invokes.push(action.into());
                Ok(())
            }
            fn read_value(
                &self,
                _: &SnapshotHandle,
            ) -> Result<Option<String>, axon_core::BackendError> {
                Ok(None)
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
                self.invokes.push("AXScrollToVisible".into());
                Ok(())
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
            fn pointer_click(&mut self, point: (f64, f64)) -> Result<(), axon_core::BackendError> {
                self.dispatches
                    .push(format!("click {},{}", point.0, point.1));
                self.pointer = point;
                Ok(())
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
                intent: KeyboardIntent<'_>,
            ) -> Result<(), axon_core::BackendError> {
                self.dispatches.push(format!("hid {}", intent.as_str()));
                if self.leaks_command {
                    self.modifiers.combined_session |= input::FLAG_COMMAND;
                    self.modifiers.hid_system |= input::FLAG_COMMAND;
                }
                Ok(())
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
                Ok(None)
            }
            fn supports_foreground_transaction(&self) -> bool {
                true
            }
            fn frontmost_application(&mut self) -> Result<Option<String>, axon_core::BackendError> {
                Ok(self.frontmost.clone())
            }
            fn activate_application(
                &mut self,
                identity: &str,
            ) -> Result<bool, axon_core::BackendError> {
                self.activations.push(identity.into());
                self.frontmost = Some(identity.into());
                Ok(true)
            }
            fn application_process_identifier(&mut self, identity: &str) -> Option<i64> {
                self.apps
                    .iter()
                    .find(|(_, _, bundle)| *bundle == identity)
                    .map(|(pid, _, _)| *pid as i64)
            }
            fn pointer_location(&mut self) -> Result<Option<(f64, f64)>, axon_core::BackendError> {
                Ok(Some(self.pointer))
            }
            fn move_pointer(&mut self, to: (f64, f64)) -> Result<bool, axon_core::BackendError> {
                self.pointer = to;
                Ok(true)
            }
        }

        impl PointerTargetVerifier for NativeFake {
            fn verify_pointer_target(
                &mut self,
                _: &SnapshotHandle,
                _: (f64, f64),
            ) -> Result<bool, axon_core::BackendError> {
                Ok(self.point_owner == Some(TEXTEDIT))
            }
        }
        impl TextRecognitionProvider for NativeFake {
            fn recognize_text(
                &mut self,
                _: &AppQuery,
            ) -> Result<Vec<axon_core::RecognizedText>, axon_core::BackendError> {
                Ok(Vec::new())
            }
        }
        impl VisualObservationProvider for NativeFake {
            fn observe_visuals(
                &mut self,
                _: &AppQuery,
                _: bool,
                _: bool,
            ) -> Result<VisualObservation, axon_core::BackendError> {
                unreachable!()
            }
        }
        impl ReadableStateProvider for NativeFake {
            fn readable_state(
                &self,
                _: &SnapshotHandle,
            ) -> Result<Map<String, Value>, axon_core::BackendError> {
                unreachable!()
            }
        }
        impl NativeInput for NativeFake {
            fn point_owner(
                &mut self,
                _: (f64, f64),
            ) -> Result<Option<i32>, axon_core::BackendError> {
                Ok(self.point_owner)
            }
            fn focused_window_frame(
                &mut self,
                app: &AppQuery,
            ) -> Result<Option<axon_core::Rect>, axon_core::BackendError> {
                Ok(self
                    .find(app)
                    .map(|_| rect(self.window_origin.0, self.window_origin.1, 800.0, 600.0)))
            }
            fn scroll_wheel(
                &mut self,
                point: (f64, f64),
                delta: (f64, f64),
            ) -> Result<Vec<(i32, i32)>, axon_core::BackendError> {
                self.dispatches.push(format!(
                    "wheel {},{} by {},{}",
                    point.0, point.1, delta.0, delta.1
                ));
                self.pointer = point;
                Ok(input::wheel_steps(delta.0, delta.1))
            }
            fn modifier_state(&mut self) -> Option<ModifierState> {
                Some(self.modifiers)
            }
            /// What the element itself answers: the pop-up button advertises a press that the
            /// capture's role table never inferred, and everything else answers as captured.
            fn advertised_actions(
                &mut self,
                handle: &SnapshotHandle,
            ) -> Result<Option<Vec<String>>, axon_core::BackendError> {
                let index = self.snapshot.index_for_handle(handle).unwrap();
                if index == POPUP {
                    return Ok(Some(vec!["AXPress".into(), "AXShowMenu".into()]));
                }
                Ok(self.snapshot.node(index).map(|node| node.actions.clone()))
            }
        }
        impl BackgroundApplicationKeyboard for NativeFake {
            fn application_process(
                &mut self,
                app: &AppQuery,
            ) -> Result<Option<ApplicationProcess>, axon_core::BackendError> {
                Ok(self.find(app).map(|(pid, bundle)| ApplicationProcess {
                    process_identifier: pid,
                    identity: bundle.into(),
                }))
            }
            fn application_keyboard_denylist(&self) -> &'static [DenylistEntry] {
                self.denylist
            }
            fn dispatch_application_keyboard(
                &mut self,
                process: &ApplicationProcess,
                intent: KeyboardIntent<'_>,
            ) -> Result<ApplicationDispatch, BackgroundDispatchError> {
                if !self.target_alive {
                    return Err(BackgroundDispatchError::Stale(format!(
                        "{} is no longer running as process {}, so nothing was posted",
                        process.identity, process.process_identifier
                    )));
                }
                self.dispatches.push(format!(
                    "pid {} {}",
                    process.process_identifier,
                    intent.as_str()
                ));
                Ok(ApplicationDispatch {
                    frontmost_unchanged: true,
                    pointer_unchanged: true,
                })
            }
        }
        impl axon_core::GlobalInputObserver for NativeFake {
            fn start(
                &mut self,
                _: &axon_core::RecordingScope,
            ) -> Result<(), axon_core::BackendError> {
                unreachable!()
            }
            fn poll(
                &mut self,
                _: Duration,
            ) -> Result<Vec<axon_core::RecordedInputEvent>, axon_core::BackendError> {
                unreachable!()
            }
            fn stop(&mut self) -> Result<(), axon_core::BackendError> {
                Ok(())
            }
            fn is_recording(&self) -> bool {
                false
            }
        }
        impl axon_core::RecordingEvidenceProvider for NativeFake {
            fn read_focused(
                &mut self,
            ) -> Result<Option<axon_core::RecordedFocusedEvidence>, axon_core::BackendError>
            {
                Ok(None)
            }
            fn capture_snapshot(
                &mut self,
                _: &axon_core::RecordedAppIdentity,
            ) -> Result<Option<Snapshot>, axon_core::BackendError> {
                Ok(None)
            }
            fn settle(
                &mut self,
                _: usize,
                _: &str,
            ) -> Result<axon_core::RecordedSettleEvidence, axon_core::BackendError> {
                Ok(Default::default())
            }
        }

        fn router(backend: NativeFake) -> Router<NativeFake> {
            Router::new(backend)
        }

        fn call(
            router: &mut Router<NativeFake>,
            tool: &str,
            arguments: Value,
        ) -> Result<Value, JsonRpcError> {
            match router
                .request(JsonRpcRequest::new(
                    Some(JsonRpcId::Integer(1)),
                    tool,
                    Some(arguments),
                ))
                .unwrap()
            {
                JsonRpcResponse::Success(success) => Ok(success.result),
                JsonRpcResponse::Failure(failure) => Err(failure.error),
            }
        }

        fn ok(router: &mut Router<NativeFake>, tool: &str, arguments: Value) -> Value {
            call(router, tool, arguments.clone())
                .unwrap_or_else(|error| panic!("{tool} {arguments} failed: {error:?}"))
        }

        /// The semantic target for one element of the fake's snapshot, registered the way a
        /// `look` registers it.
        fn element(router: &mut Router<NativeFake>, index: usize) -> Value {
            let snapshot = router.backend.snapshot.clone();
            let coverage = SemanticRegistrationCoverage::for_capture(&snapshot, None);
            let names = router.register_snapshot(&snapshot, coverage);
            let name = names
                .iter()
                .find(|name| name.source_index == index)
                .unwrap_or_else(|| panic!("element {index} has a semantic name"))
                .name
                .clone();
            json!({"app": "TextEdit", "name": name})
        }

        fn observed_save(router: &mut Router<NativeFake>) -> Value {
            let result = ok(router, "look", json!({"app":"TextEdit","screenshot":false}));
            let name = result
                .pointer("/app/windows/0/root/children/1/name")
                .and_then(Value::as_str)
                .expect("full look emits Save's semantic name");
            json!({"app":"TextEdit","name":name})
        }

        fn invoke_observed_save(router: &mut Router<NativeFake>, target: Value) {
            let result = ok(router, "invoke", json!({"target":target,"name":"AXPress"}));
            assert_eq!(result["resolution"]["status"], "unique");
            assert_eq!(result["dispatchSuccess"], true);
            assert_eq!(router.backend.invokes, ["AXPress"]);
            assert_eq!(router.backend.invoked_handles.len(), 1);
            let fresh = router.backend.last_capture.as_ref().unwrap();
            assert_eq!(
                fresh
                    .index_for_handle(&router.backend.invoked_handles[0])
                    .unwrap(),
                BUTTON
            );
            assert_eq!(
                router.backend.capture_queries.last().unwrap().process_id,
                Some(TEXTEDIT as u32)
            );
        }

        fn empty_save_page(router: &mut Router<NativeFake>, target: Value) {
            let before = router.backend.capture_sequence;
            let result = ok(
                router,
                "look",
                json!({
                    "target":target,"offset":0,"limit":1,"direct":true
                }),
            );
            assert_eq!(result["children"]["parent"], target);
            assert_eq!(result["children"]["total"], 0);
            assert_eq!(result["children"]["tree"], "[]");
            assert_eq!(
                router.backend.page_handles.last(),
                Some(&SnapshotHandle(format!("mac-capture-{}:2", before + 1)))
            );
            assert_eq!(
                router.backend.capture_queries.last().unwrap().process_id,
                Some(TEXTEDIT as u32)
            );
            assert_eq!(router.backend.capture_sequence, before + 2);
        }

        #[test]
        fn semantic_coverage_shallow_look_retains_original_name() {
            let mut router = router(NativeFake::new());
            let target = observed_save(&mut router);
            ok(
                &mut router,
                "look",
                json!({
                    "app":"TextEdit","screenshot":false,"depth":0,"childDepth":0,"frames":false
                }),
            );
            invoke_observed_save(&mut router, target);
        }

        #[test]
        fn semantic_coverage_empty_leaf_page_retains_original_name() {
            let mut router = router(NativeFake::new());
            let target = observed_save(&mut router);
            empty_save_page(&mut router, target.clone());
            invoke_observed_save(&mut router, target);
        }

        #[test]
        fn semantic_coverage_combined_alias_page_preserves_canonical_identity() {
            for alias in ["4242", "com.apple.TextEdit"] {
                let mut router = router(NativeFake::new());
                let target = observed_save(&mut router);
                ok(
                    &mut router,
                    "look",
                    json!({
                        "app":"TextEdit","screenshot":false,"depth":0,"childDepth":0,"frames":false
                    }),
                );
                let mut alias_target = target.clone();
                alias_target["app"] = json!(alias);
                empty_save_page(&mut router, alias_target);
                let page = router.snapshot.as_ref().unwrap();
                assert_eq!(page.app.name, "TextEdit");
                assert_eq!(page.app.identifier.as_deref(), Some("com.apple.TextEdit"));
                assert_eq!(page.app.process_id, Some(TEXTEDIT as u32));
                invoke_observed_save(&mut router, target);
            }
        }

        #[test]
        fn semantic_coverage_display_controls_do_not_preserve_omitted_names() {
            for display in [
                json!({"depth":0}),
                json!({"frames":false}),
                json!({"tree":false}),
                json!({"format":"debug"}),
            ] {
                let mut router = router(NativeFake::new());
                let target = observed_save(&mut router);
                router.backend.snapshot.app.windows[0].root.children.clear();
                let mut params = display;
                params["app"] = json!("TextEdit");
                params["screenshot"] = json!(false);
                ok(&mut router, "look", params);
                let error = call(
                    &mut router,
                    "invoke",
                    json!({"target":target,"name":"AXPress"}),
                )
                .unwrap_err();
                assert_eq!(error.code, -32002);
                assert!(router.backend.invokes.is_empty());
            }
        }

        #[test]
        fn semantic_coverage_partial_intent_and_native_truncation_retain_names() {
            for child_depth in [Some(0), Some(1), Some(100), None] {
                let mut router = router(NativeFake::new());
                let target = observed_save(&mut router);
                let original = router.backend.snapshot.clone();
                let root = &mut router.backend.snapshot.app.windows[0].root;
                root.children.clear();
                let mut params = json!({"app":"TextEdit","screenshot":false});
                if let Some(depth) = child_depth {
                    // The backend returns no marker: capture intent alone still makes it partial.
                    params["childDepth"] = json!(depth);
                } else {
                    // A marker below the root must be noticed even without a request bound.
                    let mut child = original.app.windows[0].root.children[0].clone();
                    child.truncation_reason = Some("native safety limit".into());
                    root.children.push(child);
                }
                ok(&mut router, "look", params);
                router.backend.snapshot = original;
                invoke_observed_save(&mut router, target.clone());
                router.backend.snapshot.app.windows[0].root.children.clear();
                ok(
                    &mut router,
                    "look",
                    json!({"app":"TextEdit","screenshot":false}),
                );
                let error = call(
                    &mut router,
                    "invoke",
                    json!({"target":target,"name":"AXPress"}),
                )
                .unwrap_err();
                assert_eq!(
                    error.code, -32002,
                    "a later complete capture revokes the retained name"
                );
                assert_eq!(router.backend.invokes.len(), 1);
            }
        }

        #[test]
        fn semantic_coverage_stability_captures_use_native_coverage() {
            for truncated in [true, false] {
                let mut router = router(NativeFake::new());
                let target = observed_save(&mut router);
                let original = router.backend.snapshot.clone();
                let root = &mut router.backend.snapshot.app.windows[0].root;
                root.children.clear();
                root.truncation_reason = truncated.then(|| "native safety limit".into());
                let result = ok(
                    &mut router,
                    "wait_for_stability",
                    json!({
                        "app":"TextEdit","stableMs":0,"timeoutMs":100,"intervalMs":10
                    }),
                );
                assert_eq!(result["wait"]["success"], true);
                router.backend.snapshot = original;
                if truncated {
                    invoke_observed_save(&mut router, target);
                } else {
                    let error = call(
                        &mut router,
                        "invoke",
                        json!({"target":target,"name":"AXPress"}),
                    )
                    .unwrap_err();
                    assert_eq!(error.code, -32002);
                    assert!(router.backend.invokes.is_empty());
                }
            }
        }

        #[test]
        fn semantic_coverage_all_children_page_is_still_partial() {
            let mut router = router(NativeFake::new());
            let target = observed_save(&mut router);
            let page = ok(&mut router, "look", json!({"target":target,"all":true}));
            assert_eq!(page["children"]["total"], 0);
            assert_eq!(page["children"]["tree"], "[]");
            invoke_observed_save(&mut router, target);
        }

        #[test]
        fn semantic_coverage_display_depth_keeps_captured_descendants_and_app_list_does_not_register()
         {
            let mut router = router(NativeFake::new());
            let target = observed_save(&mut router);
            ok(
                &mut router,
                "look",
                json!({
                    "app":"TextEdit","screenshot":false,"depth":0,"frames":false
                }),
            );
            let capture_count = router.backend.capture_sequence;
            ok(&mut router, "look", json!({}));
            assert_eq!(router.backend.capture_sequence, capture_count);
            invoke_observed_save(&mut router, target);
        }

        #[test]
        fn semantic_coverage_change_check_respects_capture_bound() {
            for bounded in [true, false] {
                let mut router = router(NativeFake::new());
                let target = observed_save(&mut router);
                let since = router.observations.keys().next().unwrap().clone();
                let original = router.backend.snapshot.clone();
                router.backend.snapshot.app.windows[0].root.children.clear();
                let mut params = json!({"app":"TextEdit","since":since,"screenshot":false});
                if bounded {
                    params["childDepth"] = json!(0);
                }
                ok(&mut router, "look", params);
                router.backend.snapshot = original;
                if bounded {
                    invoke_observed_save(&mut router, target);
                } else {
                    let error = call(
                        &mut router,
                        "invoke",
                        json!({"target":target,"name":"AXPress"}),
                    )
                    .unwrap_err();
                    assert_eq!(error.code, -32002);
                    assert!(router.backend.invokes.is_empty());
                }
            }
        }

        #[test]
        fn semantic_coverage_paging_after_action_and_previous_page_uses_fresh_handles() {
            let mut router = router(NativeFake::new());
            let target = observed_save(&mut router);
            // Finding the target performs a new capture and invalidates the observed handle.
            let found = ok(&mut router, "find", json!({"target":target}));
            assert_eq!(found["resolution"]["status"], "unique");
            empty_save_page(&mut router, target.clone());
            // Paging also replaces the active native cache.
            empty_save_page(&mut router, target.clone());
            invoke_observed_save(&mut router, target);
        }

        fn deep_paging_router() -> Router<NativeFake> {
            let mut backend = NativeFake::new();
            backend.deep_paging = true;
            let mut child = node("AXGroup", Some("Deep"), &[], rect(1.0, 1.0, 10.0, 10.0));
            child.children.push(node("AXButton", Some("End"), &["AXPress"], rect(2.0, 2.0, 5.0, 5.0)));
            backend.snapshot.app.windows[0].root.children[1].children.push(child);
            router(backend)
        }

        fn page_deep_child(router: &mut Router<NativeFake>, target: Value) -> Value {
            let page = ok(router, "look", json!({"target":target,"direct":true,"offset":0,"limit":1}));
            let children: Value = serde_json::from_str(page["children"]["tree"].as_str().unwrap()).unwrap();
            assert_eq!(page["children"]["total"], 1);
            assert_eq!(children[0]["title"], "Deep");
            json!({"app":"TextEdit","name":children[0]["name"]})
        }

        #[test]
        fn semantic_coverage_active_page_only_child_stays_pageable_without_full_capture() {
            let mut router = deep_paging_router();
            let target = observed_save(&mut router);
            assert!(router.backend.last_capture.as_ref().unwrap().node(BUTTON).unwrap().children.is_empty());
            let deep = page_deep_child(&mut router, target);
            let captures = router.backend.capture_queries.len();
            let result = ok(&mut router, "look", json!({"target":deep,"direct":true}));
            let children: Value = serde_json::from_str(result["children"]["tree"].as_str().unwrap()).unwrap();
            assert_eq!(children[0]["title"], "End");
            assert_eq!(router.backend.capture_queries.len(), captures, "active page must not require full-app visibility");
        }

        #[test]
        fn semantic_coverage_invalidated_page_only_name_is_missing_not_stale() {
            let mut router = deep_paging_router();
            let target = observed_save(&mut router);
            let deep = page_deep_child(&mut router, target);
            ok(&mut router, "look", json!({"app":"TextEdit","screenshot":false}));
            let pages = router.backend.page_handles.len();
            let error = call(&mut router, "look", json!({"target":deep,"direct":true})).unwrap_err();
            assert_eq!(error.code, -32002);
            assert_eq!(error.data.unwrap()["status"], "missing");
            assert_eq!(router.backend.page_handles.len(), pages);
        }

        #[test]
        fn semantic_coverage_paging_operational_errors_are_not_retried() {
            for query_failure in [true, false] {
                let mut router = router(NativeFake::new());
                let target = observed_save(&mut router);
                router.backend.fail_handle_query = query_failure;
                router.backend.fail_page = !query_failure;
                let captures = router.backend.capture_queries.len();
                let error = call(&mut router, "look", json!({"target":target,"direct":true})).unwrap_err();
                assert!(error.message.contains("recognize screen text"));
                assert_eq!(router.backend.capture_queries.len(), captures);
                assert_eq!(router.backend.page_handles.len(), usize::from(!query_failure));
            }
        }

        fn also_refused(result: &Value) -> String {
            result["refusal"]["alsoRefused"].to_string()
        }

        const DEAF: DenylistEntry = DenylistEntry {
            bundle_id: "com.apple.TextEdit",
            reason: "its view reads only window-server routed key events",
            evidence: &["textedit-keyboard-2099-01-01"],
        };

        #[test]
        fn text_into_an_application_nobody_measured_is_delivered_at_the_application_rung() {
            let mut router = router(NativeFake::new());
            let result = ok(
                &mut router,
                "keyboard",
                json!({"app": "TextEdit", "text": "hi"}),
            );

            assert_eq!(result["deliveryPolicy"], "backgroundOnly");
            assert_eq!(result["delivery"], "application");
            assert_eq!(result["dispatchSuccess"], true);
            // Dispatch is not delivery: keyboard declares no postcondition.
            assert_eq!(result["success"], false);
            assert_eq!(result["dispatch"]["mechanism"], "CGEventPostToPid");
            assert_eq!(
                result["backgroundDelivery"]["targetApplication"],
                "com.apple.TextEdit"
            );
            assert_eq!(result["backgroundDelivery"]["pointerAsserted"], false);
            assert_eq!(
                result["backgroundDelivery"]["variant"],
                background::KEYBOARD_VARIANT
            );
            assert!(
                router.backend.activations.is_empty(),
                "nothing was activated"
            );
            assert_eq!(
                router.backend.dispatches,
                vec![format!("pid {TEXTEDIT} hi")]
            );
        }

        #[test]
        fn a_named_key_without_modifiers_also_travels_the_application_rung() {
            let mut router = router(NativeFake::new());
            let result = ok(
                &mut router,
                "keyboard",
                json!({"app": "TextEdit", "key": "Return"}),
            );
            assert_eq!(result["delivery"], "application");
            assert_eq!(
                router.backend.dispatches,
                vec![format!("pid {TEXTEDIT} Return")]
            );
        }

        #[test]
        fn a_denylisted_application_refuses_with_its_row_and_posts_nothing() {
            let mut backend = NativeFake::new();
            backend.denylist = &[DEAF];
            let mut router = router(backend);
            let result = ok(
                &mut router,
                "keyboard",
                json!({"app": "TextEdit", "text": "hi"}),
            );

            assert_eq!(result["delivery"], Value::Null);
            assert_eq!(result["refusal"]["reason"], "foregroundNotPermitted");
            let obstacles = also_refused(&result);
            assert!(
                obstacles.contains("textedit-keyboard-2099-01-01"),
                "{obstacles}"
            );
            assert!(obstacles.contains("\"application\""), "{obstacles}");
            assert!(router.backend.dispatches.is_empty());
        }

        #[test]
        fn a_chord_skips_the_application_rung_and_needs_the_foreground() {
            let mut router = router(NativeFake::new());
            let refused = ok(
                &mut router,
                "keyboard",
                json!({"app": "TextEdit", "key": "cmd+s"}),
            );
            assert_eq!(refused["refusal"]["reason"], "foregroundNotPermitted");
            assert!(
                also_refused(&refused).contains("modified keystrokes were not measured"),
                "{}",
                also_refused(&refused)
            );
            assert!(router.backend.dispatches.is_empty());
            assert!(router.backend.activations.is_empty());

            let permitted = ok(
                &mut router,
                "keyboard",
                json!({"app": "TextEdit", "key": "cmd+s", "deliveryPolicy": "foregroundPermitted"}),
            );
            assert_eq!(permitted["delivery"], "foreground");
            assert_eq!(
                permitted["dispatch"]["mechanism"],
                "CGEventPost(kCGHIDEventTap)"
            );
            assert_eq!(permitted["foreground"]["activationProved"], true);
            assert_eq!(permitted["foreground"]["restored"], true);
            assert_eq!(permitted["foreground"]["priorApp"], "com.example.Prior");
            assert_eq!(permitted["foreground"]["priorAppProcessIdentifier"], PRIOR);
            // Keystrokes never move the pointer, so there was nothing to put back.
            assert_eq!(permitted["foreground"]["pointerRestored"], Value::Null);
            assert_eq!(
                router.backend.activations,
                vec![
                    "com.apple.TextEdit".to_string(),
                    "com.example.Prior".to_string()
                ]
            );
            assert_eq!(router.backend.dispatches, vec!["hid cmd+s".to_string()]);
        }

        /// Every keyboard dispatch reports whether it left the session's modifiers as it found
        /// them, at either rung, beside the pointer's own restoration.
        #[test]
        fn every_keyboard_dispatch_reports_that_it_restored_the_modifiers() {
            let mut router = router(NativeFake::new());
            let background = ok(
                &mut router,
                "keyboard",
                json!({"app": "TextEdit", "text": "hi"}),
            );
            assert_eq!(background["backgroundDelivery"]["modifiersRestored"], true);
            let chord = ok(
                &mut router,
                "keyboard",
                json!({"app": "TextEdit", "key": "cmd+s", "deliveryPolicy": "foregroundPermitted"}),
            );
            assert_eq!(chord["foreground"]["modifiersRestored"], true);
            assert_eq!(chord["dispatchSuccess"], true);
        }

        /// A chord that leaves Command logically held has turned every later keystroke on the
        /// machine into a shortcut. The rung did not hold, so the action fails, and the masks say
        /// what was left; the events were still posted, so `dispatchSuccess` says so.
        #[test]
        fn a_chord_that_leaves_a_modifier_held_fails_its_rung_but_reports_the_post() {
            let mut backend = NativeFake::new();
            backend.leaks_command = true;
            let mut router = router(backend);
            let result = ok(
                &mut router,
                "keyboard",
                json!({"app": "TextEdit", "key": "cmd+s", "deliveryPolicy": "foregroundPermitted"}),
            );
            assert_eq!(result["delivery"], "foreground");
            assert_eq!(result["dispatchSuccess"], true);
            assert_eq!(result["success"], false);
            assert_eq!(result["foreground"]["modifiersRestored"], false);
            let message = result["message"].as_str().unwrap();
            assert!(
                message.contains("0x20000000 before and 0x20100000 after"),
                "{message}"
            );
        }

        #[test]
        fn a_process_that_exits_between_plan_and_dispatch_is_stale_and_posts_nothing() {
            let mut backend = NativeFake::new();
            backend.target_alive = false;
            let mut router = router(backend);
            let error = call(
                &mut router,
                "keyboard",
                json!({"app": "TextEdit", "text": "hi"}),
            )
            .unwrap_err();
            assert_eq!(error.code, -32003);
            assert!(router.backend.dispatches.is_empty());
        }

        #[test]
        fn an_unaimed_keyboard_request_has_only_the_frontmost_and_only_when_permitted() {
            let mut router = router(NativeFake::new());
            let refused = ok(&mut router, "keyboard", json!({"text": "hi"}));
            assert_eq!(refused["refusal"]["reason"], "foregroundNotPermitted");
            assert!(
                also_refused(&refused).contains("no process to post it to"),
                "{}",
                also_refused(&refused)
            );
            assert!(router.backend.dispatches.is_empty());

            let permitted = ok(
                &mut router,
                "keyboard",
                json!({"text": "hi", "deliveryPolicy": "foregroundPermitted"}),
            );
            assert_eq!(permitted["delivery"], "foreground");
            assert_eq!(permitted["foreground"]["alreadyFrontmost"], true);
            assert!(router.backend.activations.is_empty());
            assert_eq!(router.backend.dispatches, vec!["hid hi".to_string()]);
        }

        #[test]
        fn a_key_this_backend_cannot_press_is_malformed_rather_than_refused() {
            let mut router = router(NativeFake::new());
            for key in ["Insert", "cmd+é", "hyper+a"] {
                let error = call(
                    &mut router,
                    "keyboard",
                    json!({"app": "TextEdit", "key": key}),
                )
                .unwrap_err();
                assert_eq!(error.code, -32602, "{key}");
            }
            assert!(router.backend.dispatches.is_empty());
        }

        #[test]
        fn every_pointer_form_refuses_by_mechanism_under_background_only() {
            let mut router = router(NativeFake::new());
            let text_area = element(&mut router, TEXT_AREA);
            for arguments in [
                json!({"target": {"app": "com.apple.TextEdit", "point": {"x": 150, "y": 150}}}),
                json!({"target": text_area}),
                json!({"target": {"location": {"app": "TextEdit", "text": "Save"}}}),
            ] {
                let result = ok(&mut router, "click", arguments.clone());
                assert_eq!(result["delivery"], Value::Null, "{arguments}");
                assert_eq!(
                    result["refusal"]["reason"], "foregroundNotPermitted",
                    "{arguments}"
                );
                let obstacles = also_refused(&result);
                assert!(obstacles.contains("window number 0"), "{obstacles}");
                assert!(
                    obstacles.contains("without the window server's hit testing"),
                    "{obstacles}"
                );
            }
            assert!(router.backend.dispatches.is_empty());
            assert!(router.backend.activations.is_empty());
            assert!(router.backend.invokes.is_empty());
        }

        #[test]
        fn a_recorded_point_fallback_resolves_its_bundle_identifier_and_restores_the_pointer() {
            let mut router = router(NativeFake::new());
            let result = ok(
                &mut router,
                "click",
                json!({
                    "target": {"app": "com.apple.TextEdit", "point": {"x": 150, "y": 150}},
                    "deliveryPolicy": "foregroundPermitted"
                }),
            );
            assert_eq!(result["delivery"], "foreground");
            assert_eq!(result["dispatchSuccess"], true);
            assert_eq!(result["success"], false);
            assert_eq!(result["foreground"]["activationProved"], true);
            assert_eq!(result["foreground"]["pointerRestored"], true);
            assert_eq!(router.backend.pointer, (5.0, 5.0));
            assert_eq!(
                router.backend.activations,
                vec![
                    "com.apple.TextEdit".to_string(),
                    "com.example.Prior".to_string()
                ]
            );
            assert_eq!(router.backend.dispatches, vec!["click 150,150".to_string()]);
        }

        #[test]
        fn a_window_point_is_offset_by_the_focused_window_and_a_screenshot_point_is_refused() {
            let mut backend = NativeFake::new();
            backend.window_origin = (100.0, 50.0);
            let mut router = router(backend);
            ok(
                &mut router,
                "click",
                json!({
                    "target": {"app": "TextEdit", "coordinateSpace": "window", "point": {"x": 10, "y": 20}},
                    "deliveryPolicy": "foregroundPermitted"
                }),
            );
            assert_eq!(router.backend.dispatches, vec!["click 110,70".to_string()]);

            let error = call(
                &mut router,
                "click",
                json!({"target": {"app": "TextEdit", "coordinateSpace": "screenshot", "x": 1, "y": 2}}),
            )
            .unwrap_err();
            assert_eq!(error.code, -32004);
            assert_eq!(
                error.data.unwrap()["capability"],
                "screenshot-coordinate-space"
            );
        }

        #[test]
        fn a_point_over_another_application_is_stale_and_posts_nothing() {
            let mut backend = NativeFake::new();
            backend.point_owner = Some(OTHER);
            let mut router = router(backend);
            let error = call(
                &mut router,
                "click",
                json!({
                    "target": {"app": "TextEdit", "point": {"x": 150, "y": 150}},
                    "deliveryPolicy": "foregroundPermitted"
                }),
            )
            .unwrap_err();
            assert_eq!(error.code, -32003);
            // The session was still handed back, and the error says so.
            assert_eq!(error.data.unwrap()["foreground"]["restored"], true);
            assert!(router.backend.dispatches.is_empty());
        }

        #[test]
        fn an_element_that_advertises_no_press_is_clicked_at_its_centre() {
            let mut router = router(NativeFake::new());
            let text_area = element(&mut router, TEXT_AREA);
            let result = ok(
                &mut router,
                "click",
                json!({"target": text_area, "deliveryPolicy": "foregroundPermitted"}),
            );
            assert_eq!(result["delivery"], "foreground");
            assert!(result["resolution"].is_object());
            assert!(
                router.backend.invokes.is_empty(),
                "no AXPress was attempted"
            );
            assert_eq!(router.backend.dispatches, vec!["click 200,150".to_string()]);
        }

        /// A document view reports the whole document's frame. Its centre is off screen, so the
        /// click aims at the centre of what the window actually shows of it.
        #[test]
        fn an_element_taller_than_its_window_is_clicked_where_it_is_visible() {
            let mut backend = NativeFake::new();
            backend.snapshot.app.windows[0].root.children[0].frame =
                Some(rect(100.0, 100.0, 200.0, 5000.0));
            let mut router = router(backend);
            let text_area = element(&mut router, TEXT_AREA);
            ok(
                &mut router,
                "click",
                json!({"target": text_area, "deliveryPolicy": "foregroundPermitted"}),
            );
            assert_eq!(router.backend.dispatches, vec!["click 200,350".to_string()]);
        }

        #[test]
        fn an_element_scrolled_entirely_out_of_view_is_stale_and_posts_nothing() {
            let mut backend = NativeFake::new();
            backend.snapshot.app.windows[0].root.children[0].frame =
                Some(rect(100.0, 900.0, 200.0, 100.0));
            let mut router = router(backend);
            let text_area = element(&mut router, TEXT_AREA);
            let error = call(
                &mut router,
                "click",
                json!({"target": text_area, "deliveryPolicy": "foregroundPermitted"}),
            )
            .unwrap_err();
            assert_eq!(error.code, -32003);
            assert!(router.backend.dispatches.is_empty());
            assert!(
                router.backend.activations.is_empty(),
                "refused before the transaction"
            );
        }

        #[test]
        fn an_element_that_advertises_press_stays_semantic() {
            let mut router = router(NativeFake::new());
            let button = element(&mut router, BUTTON);
            let result = ok(&mut router, "click", json!({"target": button}));
            assert_eq!(result["delivery"], "semantic");
            assert_eq!(result["dispatch"]["mechanism"], "AXPress");
            assert_eq!(router.backend.invokes, vec!["AXPress".to_string()]);
            assert!(router.backend.dispatches.is_empty());
        }

        /// The press is decided by what the element advertises, not by a role table: a pop-up
        /// button the table does not know still presses semantically, in the background.
        #[test]
        fn an_element_outside_the_role_table_that_advertises_press_stays_semantic() {
            let mut router = router(NativeFake::new());
            let popup = element(&mut router, POPUP);
            let result = ok(&mut router, "click", json!({"target": popup}));
            assert_eq!(result["delivery"], "semantic");
            assert_eq!(result["deliveryPolicy"], "backgroundOnly");
            assert_eq!(router.backend.invokes, vec!["AXPress".to_string()]);
            assert!(router.backend.dispatches.is_empty());
            assert!(router.backend.activations.is_empty());
        }

        #[test]
        fn the_default_scroll_refuses_by_mechanism_under_background_only() {
            let mut router = router(NativeFake::new());
            let text_area = element(&mut router, TEXT_AREA);
            let params = validated_params("scroll", json!({"target": text_area}));
            assert_eq!(params["deltaY"], -120);
            let result = ok(&mut router, "scroll", Value::Object(params));

            assert_eq!(result["refusal"]["reason"], "foregroundNotPermitted");
            let obstacles = also_refused(&result);
            assert!(
                obstacles.contains("cannot carry a scroll delta"),
                "{obstacles}"
            );
            assert!(obstacles.contains("window number 0"), "{obstacles}");
            assert!(!obstacles.contains("directional-scroll"), "{obstacles}");
            assert!(router.backend.dispatches.is_empty());
        }

        #[test]
        fn a_permitted_wheel_scroll_reports_its_pixel_steps() {
            let mut router = router(NativeFake::new());
            let result = ok(
                &mut router,
                "scroll",
                json!({"app": "TextEdit", "deltaY": -400, "deliveryPolicy": "foregroundPermitted"}),
            );
            assert_eq!(result["delivery"], "foreground");
            assert_eq!(result["foreground"]["pointerRestored"], true);
            assert_eq!(result["eventPath"]["units"], "pixel");
            let steps = result["eventPath"]["steps"].as_array().unwrap();
            assert_eq!(steps.len(), 4);
            let total: i64 = steps
                .iter()
                .map(|step| step["deltaY"].as_i64().unwrap())
                .sum();
            assert_eq!(total, -400);
            assert_eq!(
                router.backend.dispatches,
                vec!["wheel 400,300 by 0,-400".to_string()]
            );
        }

        #[test]
        fn a_zero_delta_with_a_semantic_target_stays_scroll_to_visible() {
            let mut router = router(NativeFake::new());
            let text_area = element(&mut router, TEXT_AREA);
            let result = ok(
                &mut router,
                "scroll",
                json!({"target": text_area, "deltaX": 0, "deltaY": 0}),
            );
            assert_eq!(result["delivery"], "semantic");
            assert_eq!(
                router.backend.invokes,
                vec!["AXScrollToVisible".to_string()]
            );
            assert!(router.backend.dispatches.is_empty());
        }

        #[test]
        fn a_scroll_with_nowhere_to_aim_is_malformed() {
            let mut router = router(NativeFake::new());
            for arguments in [
                json!({"deltaY": -120}),
                json!({"target": {"point": {"x": 1, "y": 2}}, "deltaX": 0, "deltaY": 0}),
                json!({"app": "TextEdit", "deltaX": 0, "deltaY": 0}),
            ] {
                let error = call(&mut router, "scroll", arguments.clone()).unwrap_err();
                assert_eq!(error.code, -32602, "{arguments}");
            }
            assert!(router.backend.dispatches.is_empty());
        }

        #[test]
        fn the_window_handle_is_registered_too() {
            // A guard on the fixture itself: the indices above name the elements they claim to.
            let mut router = router(NativeFake::new());
            assert_eq!(element(&mut router, WINDOW)["app"], "TextEdit");
        }
    }
}
