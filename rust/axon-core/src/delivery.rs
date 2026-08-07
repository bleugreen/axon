//! The per-action delivery contract, shared by every backend.
//!
//! These names are wire vocabulary: they appear verbatim in tool parameters and action results on
//! macOS, Linux, and Windows alike, and the fixtures under `schema/fixtures/delivery` lock them so
//! the Swift and Rust sides cannot drift apart.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::time::{Duration, Instant};

/// What a single mutating action is allowed to do to the user's session.
///
/// Per action and never daemon state: it is decoded from the request that carries it and is never
/// inherited by anything that runs later.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DeliveryPolicy {
    /// Forbids application activation, system-focus changes, movement of the real pointer, global
    /// keyboard input, and clipboard access. What a caller gets when it says nothing.
    #[default]
    BackgroundOnly,
    /// Permits the backend to escalate this one action to the foreground rung.
    ForegroundPermitted,
}

impl DeliveryPolicy {
    pub const ALL: [DeliveryPolicy; 2] = [
        DeliveryPolicy::BackgroundOnly,
        DeliveryPolicy::ForegroundPermitted,
    ];

    pub fn key(&self) -> &'static str {
        match self {
            DeliveryPolicy::BackgroundOnly => "backgroundOnly",
            DeliveryPolicy::ForegroundPermitted => "foregroundPermitted",
        }
    }

    pub fn permits_foreground(&self) -> bool {
        matches!(self, DeliveryPolicy::ForegroundPermitted)
    }

    /// Decodes the optional `deliveryPolicy` parameter, defaulting to `backgroundOnly`.
    ///
    /// An unknown value fails here, before a target is resolved and before any native side effect,
    /// because a policy the backend does not understand cannot be honoured safely.
    pub fn from_params(params: &Map<String, Value>) -> Result<Self, String> {
        let Some(value) = params.get("deliveryPolicy") else {
            return Ok(DeliveryPolicy::default());
        };
        if value.is_null() {
            return Ok(DeliveryPolicy::default());
        }
        let raw = value
            .as_str()
            .ok_or_else(|| "deliveryPolicy must be a string".to_string())?;
        DeliveryPolicy::ALL
            .into_iter()
            .find(|policy| policy.key() == raw)
            .ok_or_else(|| {
                let known: Vec<&str> = DeliveryPolicy::ALL
                    .iter()
                    .map(DeliveryPolicy::key)
                    .collect();
                format!("deliveryPolicy must be one of: {}", known.join(", "))
            })
    }
}

/// The mechanism that actually delivered an action, classified by observable side effect rather
/// than by the name of the API that produced it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DeliveryRung {
    /// An accessibility-level mutation (AX, UIA, AT-SPI) that neither focused nor activated.
    Semantic,
    /// Target-bound input derived from verified window geometry, delivered without activating the
    /// application and without moving the real pointer.
    Pixel,
    /// Global input devices: CGEvent on the HID tap, SendInput, XTest, or a virtual pointer.
    Foreground,
}

impl DeliveryRung {
    pub const ALL: [DeliveryRung; 3] = [
        DeliveryRung::Semantic,
        DeliveryRung::Pixel,
        DeliveryRung::Foreground,
    ];

    pub fn key(&self) -> &'static str {
        match self {
            DeliveryRung::Semantic => "semantic",
            DeliveryRung::Pixel => "pixel",
            DeliveryRung::Foreground => "foreground",
        }
    }

    /// Ladder position. Candidates are always enumerated in this order.
    pub fn order(&self) -> u8 {
        match self {
            DeliveryRung::Semantic => 0,
            DeliveryRung::Pixel => 1,
            DeliveryRung::Foreground => 2,
        }
    }

    pub fn requires_foreground_opt_in(&self) -> bool {
        matches!(self, DeliveryRung::Foreground)
    }
}

/// The mechanism class a candidate depends on, so a refusal can name the missing faculty rather
/// than only the blocked rung.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DeliveryCapability {
    /// Performing a named accessibility action on a resolved element.
    SemanticAction,
    /// Setting an accessibility value directly on a resolved element.
    SemanticValue,
    /// Process- or window-targeted input that never touches global devices.
    BackgroundPixelInput,
    /// Global input devices shared with the human at the keyboard.
    GlobalInput,
    /// The system clipboard. Modelled so a future fallback cannot silently introduce it; no ladder
    /// in Axon contains a clipboard candidate, and the planner refuses one on sight.
    Clipboard,
}

impl DeliveryCapability {
    pub const ALL: [DeliveryCapability; 5] = [
        DeliveryCapability::SemanticAction,
        DeliveryCapability::SemanticValue,
        DeliveryCapability::BackgroundPixelInput,
        DeliveryCapability::GlobalInput,
        DeliveryCapability::Clipboard,
    ];

    pub fn key(&self) -> &'static str {
        match self {
            DeliveryCapability::SemanticAction => "semanticAction",
            DeliveryCapability::SemanticValue => "semanticValue",
            DeliveryCapability::BackgroundPixelInput => "backgroundPixelInput",
            DeliveryCapability::GlobalInput => "globalInput",
            DeliveryCapability::Clipboard => "clipboard",
        }
    }

    /// Capabilities Axon will never dispatch through, at any policy.
    pub fn is_forbidden(&self) -> bool {
        matches!(self, DeliveryCapability::Clipboard)
    }
}

/// Why delivery stopped before any native side effect.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DeliveryRefusalReason {
    /// The only remaining rung was foreground and the action did not permit it.
    ForegroundNotPermitted,
    /// No target-bound mechanism on this platform, compositor, toolkit, or window could carry the
    /// action without global input.
    BackgroundPixelUnsupported,
    /// The request named coordinates that cannot be bound to an application and window.
    TargetIdentityUnavailable,
    /// A clipboard-backed candidate was offered. Always refused.
    ClipboardForbidden,
    /// Foreground escalation could not prove the target became frontmost, so nothing was posted.
    ActivationNotProved,
    /// This rung's mechanism does not exist on this backend, so the action has no way to run.
    NoDeliveryCandidate,
}

impl DeliveryRefusalReason {
    pub const ALL: [DeliveryRefusalReason; 6] = [
        DeliveryRefusalReason::ForegroundNotPermitted,
        DeliveryRefusalReason::BackgroundPixelUnsupported,
        DeliveryRefusalReason::TargetIdentityUnavailable,
        DeliveryRefusalReason::ClipboardForbidden,
        DeliveryRefusalReason::ActivationNotProved,
        DeliveryRefusalReason::NoDeliveryCandidate,
    ];

    pub fn key(&self) -> &'static str {
        match self {
            DeliveryRefusalReason::ForegroundNotPermitted => "foregroundNotPermitted",
            DeliveryRefusalReason::BackgroundPixelUnsupported => "backgroundPixelUnsupported",
            DeliveryRefusalReason::TargetIdentityUnavailable => "targetIdentityUnavailable",
            DeliveryRefusalReason::ClipboardForbidden => "clipboardForbidden",
            DeliveryRefusalReason::ActivationNotProved => "activationNotProved",
            DeliveryRefusalReason::NoDeliveryCandidate => "noDeliveryCandidate",
        }
    }
}

/// A refusal is an action result, not a transport error: the request was well formed and the
/// target resolved, and the backend declined.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryRefusal {
    pub reason: DeliveryRefusalReason,
    /// The rung the action would have needed to reach to be delivered.
    pub required_rung: DeliveryRung,
    /// The mechanism class that was missing or forbidden, when one is responsible.
    pub capability: Option<DeliveryCapability>,
    pub message: String,
}

impl DeliveryRefusal {
    pub fn new(
        reason: DeliveryRefusalReason,
        required_rung: DeliveryRung,
        capability: Option<DeliveryCapability>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            reason,
            required_rung,
            capability,
            message: message.into(),
        }
    }
}

/// Evidence that a foreground escalation was transactional: what held the foreground before, what
/// the backend did to it, and whether the session was handed back.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ForegroundCleanup {
    pub prior_app: Option<String>,
    pub prior_app_process_identifier: Option<i64>,
    /// True when the target already held the foreground, so no activation was performed.
    pub already_frontmost: bool,
    /// True when the target was observed frontmost before anything was posted.
    pub activation_proved: bool,
    /// True when the prior application was observed frontmost again afterwards.
    pub restored: bool,
    /// None when the dispatch never moved the pointer, so there was nothing to put back.
    pub pointer_restored: Option<bool>,
    pub message: Option<String>,
}

impl ForegroundCleanup {
    /// Whether the user's session was handed back whole. A cursor left where synthetic input
    /// dropped it is a failed restoration as surely as a window that never came back, so an action
    /// that leaves either behind did not succeed however well its dispatch went.
    pub fn session_restored(&self) -> bool {
        self.restored && self.pointer_restored != Some(false)
    }
}

/// One rung of an action's delivery ladder.
///
/// A candidate the runtime cannot satisfy right now still belongs in the ladder, carrying the
/// reason it is unavailable, so a refusal names the missing faculty instead of falling silently
/// through to a louder mechanism.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeliveryCandidate {
    pub rung: DeliveryRung,
    pub capability: DeliveryCapability,
    /// The mechanism reported when this candidate dispatches, for example `UIA Invoke` or
    /// `SendInput`.
    pub mechanism: String,
    /// Set when this candidate exists in principle but cannot run against this target right now.
    pub unavailable: Option<DeliveryRefusalReason>,
    pub unavailable_message: Option<String>,
}

impl DeliveryCandidate {
    pub fn available(
        rung: DeliveryRung,
        capability: DeliveryCapability,
        mechanism: impl Into<String>,
    ) -> Self {
        Self {
            rung,
            capability,
            mechanism: mechanism.into(),
            unavailable: None,
            unavailable_message: None,
        }
    }

    pub fn unavailable(
        rung: DeliveryRung,
        capability: DeliveryCapability,
        mechanism: impl Into<String>,
        reason: DeliveryRefusalReason,
        message: impl Into<String>,
    ) -> Self {
        Self {
            rung,
            capability,
            mechanism: mechanism.into(),
            unavailable: Some(reason),
            unavailable_message: Some(message.into()),
        }
    }

    pub fn is_available(&self) -> bool {
        self.unavailable.is_none() && !self.capability.is_forbidden()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeliverySelection {
    Candidate(DeliveryCandidate),
    Refusal(DeliveryRefusal),
}

/// Chooses the rung an action will use before anything native happens.
///
/// The ladder is fixed per action and ordered semantic, then pixel, then foreground. The planner's
/// only job is to answer which of those the caller's policy and the current runtime allow, and to
/// explain the answer when it is none of them.
pub fn select_delivery(
    candidates: &[DeliveryCandidate],
    policy: DeliveryPolicy,
    after: Option<DeliveryRung>,
) -> DeliverySelection {
    let mut ordered: Vec<&DeliveryCandidate> = candidates.iter().collect();
    ordered.sort_by_key(|candidate| candidate.rung.order());

    let mut blocked: Option<DeliveryRefusal> = None;
    for candidate in ordered {
        if after.is_some_and(|after| candidate.rung.order() <= after.order()) {
            continue;
        }
        if candidate.capability.is_forbidden() {
            blocked = Some(DeliveryRefusal::new(
                DeliveryRefusalReason::ClipboardForbidden,
                candidate.rung,
                Some(candidate.capability),
                format!(
                    "{} would deliver through the {} capability, which Axon never uses",
                    candidate.mechanism,
                    candidate.capability.key()
                ),
            ));
            continue;
        }
        // A rung the runtime cannot offer is reported as missing whatever the policy says:
        // telling a caller to opt in to a mechanism that does not exist would be a lie.
        if let Some(unavailable) = candidate.unavailable {
            blocked = Some(DeliveryRefusal::new(
                unavailable,
                candidate.rung,
                Some(candidate.capability),
                candidate.unavailable_message.clone().unwrap_or_else(|| {
                    format!("{} is unavailable for this target", candidate.mechanism)
                }),
            ));
            continue;
        }
        if candidate.rung.requires_foreground_opt_in() && !policy.permits_foreground() {
            // Among rungs that would otherwise work, the policy boundary is the most actionable
            // thing a caller can be told, so it outranks any capability gap below it.
            blocked = Some(DeliveryRefusal::new(
                DeliveryRefusalReason::ForegroundNotPermitted,
                candidate.rung,
                Some(candidate.capability),
                format!(
                    "{} requires foreground delivery; this action ran under {}",
                    candidate.mechanism,
                    policy.key()
                ),
            ));
            continue;
        }
        return DeliverySelection::Candidate(candidate.clone());
    }

    DeliverySelection::Refusal(blocked.unwrap_or_else(|| {
        DeliveryRefusal::new(
            DeliveryRefusalReason::NoDeliveryCandidate,
            match after {
                Some(DeliveryRung::Semantic) => DeliveryRung::Pixel,
                Some(_) => DeliveryRung::Foreground,
                None => DeliveryRung::Semantic,
            },
            None,
            "No delivery mechanism remains for this action",
        )
    }))
}

/// The four stable fields every action result carries, whatever the backend.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeliveryOutcome {
    pub policy: DeliveryPolicy,
    pub delivery: Option<DeliveryRung>,
    pub dispatch_success: bool,
    pub refusal: Option<DeliveryRefusal>,
}

impl DeliveryOutcome {
    /// A rung carried the action. Dispatch is evidence, not goal success.
    pub fn dispatched(policy: DeliveryPolicy, delivery: DeliveryRung) -> Self {
        Self {
            policy,
            delivery: Some(delivery),
            dispatch_success: true,
            refusal: None,
        }
    }

    /// Nothing was dispatched, and the refusal says why.
    pub fn refused(policy: DeliveryPolicy, refusal: DeliveryRefusal) -> Self {
        Self {
            policy,
            delivery: None,
            dispatch_success: false,
            refusal: Some(refusal),
        }
    }

    /// Renders the outcome as the top-level result fields, leaving any sibling keys alone.
    pub fn merge_into(&self, object: &mut Map<String, Value>) {
        object.insert("deliveryPolicy".into(), json!(self.policy.key()));
        object.insert(
            "delivery".into(),
            match self.delivery {
                Some(rung) => json!(rung.key()),
                None => Value::Null,
            },
        );
        object.insert("dispatchSuccess".into(), json!(self.dispatch_success));
        object.insert(
            "refusal".into(),
            match &self.refusal {
                Some(refusal) => serde_json::to_value(refusal).unwrap_or(Value::Null),
                None => Value::Null,
            },
        );
    }

    /// The complete action-result object for a refusal, ready to return from a tool.
    pub fn refusal_result(policy: DeliveryPolicy, refusal: DeliveryRefusal) -> Value {
        let outcome = DeliveryOutcome::refused(policy, refusal.clone());
        let mut object = Map::new();
        object.insert("success".into(), json!(false));
        object.insert("strategy".into(), json!("refused"));
        object.insert("message".into(), json!(refusal.message));
        object.insert(
            "dispatch".into(),
            json!({"success": false, "mechanism": Value::Null}),
        );
        object.insert(
            "verification".into(),
            json!({"verified": false, "reason": refusal.message}),
        );
        outcome.merge_into(&mut object);
        Value::Object(object)
    }
}

/// What a foreground escalation produced, alongside the evidence that it was transactional.
pub struct ForegroundDispatch<T> {
    /// None when nothing was dispatched, which happens only when activation could not be proved.
    pub value: Option<T>,
    pub cleanup: ForegroundCleanup,
    pub refusal: Option<DeliveryRefusal>,
}

/// Who a foreground escalation is aimed at.
///
/// Deliberately not an `Option<&str>`. "I could not work out which application owns this target"
/// and "the caller explicitly addressed whatever is frontmost" are different requests with
/// different correct behaviour, and collapsing them into `None` is how an action that resolved a
/// specific element ends up dispatching global input with no activation and no proof.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ForegroundTarget<'a> {
    /// Bring this application forward and prove it came forward before dispatching anything.
    Application(&'a str),
    /// The caller addressed whatever holds the foreground, so there is nothing to activate and
    /// nothing to restore. Only correct for an action that named no target of its own.
    Frontmost,
}

/// How far the pointer may sit from where it started and still count as never having moved. The
/// same half-pixel tolerance the macOS executor uses, so the two report `pointerRestored`
/// identically.
const POINTER_TOLERANCE: f64 = 0.5;

/// How long an observable session change is given to happen, and how often it is looked for.
///
/// Activation is asynchronous on every platform: the request goes to a window manager or window
/// server that changes the focus in its own time, and under X11 it is a client message that has not
/// even been delivered when the request returns. Reading the foreground back once, immediately,
/// would report almost every real activation as unproved and refuse to dispatch. The macOS executor
/// settles on the same budget for the same reason.
const SETTLE_TIMEOUT: Duration = Duration::from_millis(750);
const SETTLE_INTERVAL: Duration = Duration::from_millis(25);

/// Bounded wait for a session change to become observable. Never blocks past the budget, so a
/// window manager that refuses to cooperate produces an unproved activation rather than a hung
/// daemon.
fn settle(mut observed: impl FnMut() -> bool) -> bool {
    if observed() {
        return true;
    }
    let deadline = Instant::now() + SETTLE_TIMEOUT;
    while Instant::now() < deadline {
        std::thread::sleep(SETTLE_INTERVAL);
        if observed() {
            return true;
        }
    }
    false
}

fn pointer_matches(observed: (f64, f64), origin: (f64, f64)) -> bool {
    (observed.0 - origin.0).abs() < POINTER_TOLERANCE
        && (observed.1 - origin.1).abs() < POINTER_TOLERANCE
}

/// The transaction stopped before dispatching. Nothing was posted, and `restored` says whether the
/// session is as the user left it.
fn not_dispatched<T>(
    prior_app: Option<String>,
    restored: bool,
    cleanup_message: &str,
    refusal_message: &str,
) -> ForegroundDispatch<T> {
    ForegroundDispatch {
        value: None,
        cleanup: ForegroundCleanup {
            prior_app,
            prior_app_process_identifier: None,
            already_frontmost: false,
            activation_proved: false,
            restored,
            pointer_restored: None,
            message: Some(cleanup_message.into()),
        },
        refusal: Some(DeliveryRefusal::new(
            DeliveryRefusalReason::ActivationNotProved,
            DeliveryRung::Foreground,
            Some(DeliveryCapability::GlobalInput),
            refusal_message,
        )),
    }
}

/// Puts the pointer back where the dispatch found it.
///
/// `None` means the dispatch never moved it, so there was nothing to put back — which is why the
/// field is an `Option<bool>` rather than a bool that would have to lie in that case.
fn restore_pointer<B>(backend: &mut B, origin: Option<(f64, f64)>) -> Option<bool>
where
    B: crate::PlatformBackend + ?Sized,
{
    let origin = origin?;
    let at_origin = |backend: &mut B| {
        backend
            .pointer_location()
            .ok()
            .flatten()
            .is_some_and(|now| pointer_matches(now, origin))
    };
    // A location that cannot be read is treated as moved. Warping a pointer that never left is
    // harmless; leaving one where synthetic input put it is not.
    if at_origin(backend) {
        return None;
    }
    if !backend.move_pointer(origin).unwrap_or(false) {
        return Some(false);
    }
    Some(settle(|| at_origin(backend)))
}

/// Runs one action in the foreground and hands the session back.
///
/// The order is fixed and is the whole point: capture the prior foreground, activate the target,
/// **prove** it came forward, dispatch exactly once, then restore. If activation cannot be proved,
/// nothing is dispatched at all — posting global input at that moment would send it wherever the
/// user happens to be working. Restoration runs whether or not the dispatch succeeded, and puts the
/// pointer back before the window, so the cursor is home by the time the user's application returns.
///
/// `restores_pointer` is the caller's statement that this dispatch moves the real cursor. A pointer
/// click sets it; keyboard input does not, and capturing a pointer it never touches would report a
/// restoration that did not happen.
pub fn dispatch_in_foreground<B, T>(
    backend: &mut B,
    target: ForegroundTarget<'_>,
    restores_pointer: bool,
    body: impl FnOnce(&mut B) -> T,
) -> ForegroundDispatch<T>
where
    B: crate::PlatformBackend + ?Sized,
{
    let target = match target {
        ForegroundTarget::Frontmost => None,
        ForegroundTarget::Application(app) => Some(app),
    };
    // "The foreground could not be read" and "nothing holds the foreground" are different answers,
    // and collapsing them is how an escalation activates a target with no idea what to put back.
    // `Frontmost` is exempt because it activates nothing and so has nothing to restore.
    let prior = match backend.frontmost_application() {
        Ok(prior) => prior,
        Err(_) if target.is_none() => None,
        Err(_) => {
            return not_dispatched(
                None,
                true,
                "The prior foreground application could not be read; no events were posted",
                "Foreground delivery could not read the application it would have to restore, so \
                 nothing was posted",
            );
        }
    };
    let already_frontmost = match target {
        None => true,
        Some(target) => prior.as_deref() == Some(target),
    };

    let frontmost_is = |backend: &mut B, expected: &str| {
        backend.frontmost_application().ok().flatten().as_deref() == Some(expected)
    };

    let mut activation_proved = already_frontmost;
    if let (false, Some(target)) = (already_frontmost, target) {
        let accepted = backend.activate_application(target).unwrap_or(false);
        activation_proved = accepted && settle(|| frontmost_is(backend, target));
    }

    let restore = |backend: &mut B| -> bool {
        match (&prior, already_frontmost) {
            (_, true) | (None, _) => true,
            (Some(prior), false) => {
                if frontmost_is(backend, prior) {
                    return true;
                }
                backend.activate_application(prior).unwrap_or(false)
                    && settle(|| frontmost_is(backend, prior))
            }
        }
    };

    let prior_identity = prior.clone();
    if !activation_proved {
        let restored = restore(backend);
        return not_dispatched(
            prior_identity,
            restored,
            "No events were posted",
            "Foreground delivery could not prove the target became frontmost, so nothing was posted",
        );
    }

    // Captured only for a dispatch that moves the cursor. `Ok(None)` is a backend with no pointer;
    // an `Err` is a backend that has one and cannot read it, and posting input we could not undo is
    // the behaviour this transaction exists to prevent.
    let pointer_before = if restores_pointer {
        match backend.pointer_location() {
            Ok(location) => location,
            Err(_) => {
                // The target is already forward by now, so this refusal has a proved activation to
                // report and a foreground to undo. Reusing the unproved shape here would describe
                // an event that did not happen.
                let restored = restore(backend);
                return ForegroundDispatch {
                    value: None,
                    cleanup: ForegroundCleanup {
                        prior_app: prior_identity,
                        prior_app_process_identifier: None,
                        already_frontmost,
                        activation_proved: true,
                        restored,
                        pointer_restored: None,
                        message: Some(
                            "The pointer could not be read; no events were posted".into(),
                        ),
                    },
                    refusal: Some(DeliveryRefusal::new(
                        DeliveryRefusalReason::ActivationNotProved,
                        DeliveryRung::Foreground,
                        Some(DeliveryCapability::GlobalInput),
                        "Foreground delivery could not read the pointer it would have to restore, \
                         so nothing was posted",
                    )),
                };
            }
        }
    } else {
        None
    };

    let value = body(backend);
    let pointer_restored = restore_pointer(backend, pointer_before);
    let restored = restore(backend);
    ForegroundDispatch {
        value: Some(value),
        cleanup: ForegroundCleanup {
            prior_app: prior_identity,
            prior_app_process_identifier: None,
            already_frontmost,
            activation_proved: true,
            restored,
            pointer_restored,
            message: match (restored, pointer_restored) {
                (false, _) => Some("The prior application did not return to the foreground".into()),
                (true, Some(false)) => {
                    Some("The pointer did not return to where the dispatch found it".into())
                }
                (true, _) => None,
            },
        },
        refusal: None,
    }
}
