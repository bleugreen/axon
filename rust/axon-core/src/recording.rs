//! Recording: the provider-neutral input seam, and the shared authoring of a v2 `.axn` document.
//!
//! One implementation lives here. A platform supplies only the evidence it alone can gather — what
//! the pointer hit, what holds focus, which application is frontmost — through
//! [`GlobalInputObserver`]; shared core owns ordering, grouping, semantic target construction,
//! history, redaction, and v2 authoring. macOS supplies CGEvent and Accessibility evidence today;
//! Windows UIA and Linux AT-SPI implement the same seam later without the recorder changing.
//!
//! Native handles never cross this boundary. Every element is described in portable terms so a
//! recording is a statement about the interface rather than about one process's pointers.

use crate::{
    AxnAction, AxnArgument, AxnDocument, ExpectedFact, LocatorResolver, ResolutionStatus,
    SemanticNameRegistry, Snapshot, WireElementTarget,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::time::Duration;

/// A physical point in the same screen coordinates a dispatch is aimed with.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct RecordedPoint {
    pub x: f64,
    pub y: f64,
}

fn point_fallback_warning(target: &Value) -> Option<String> {
    target.get("point").map(|_| "could not derive a canonical semantic target; recorded point fallback".into())
}

fn point_fallback_warnings(action: &RecordedUserAction) -> Vec<String> {
    match action {
        RecordedUserAction::Click { target } => point_fallback_warning(target).into_iter().collect(),
        RecordedUserAction::Drag { from, to, .. } => [from, to].into_iter().filter_map(point_fallback_warning).collect(),
        RecordedUserAction::Scroll { target: Some(target), .. } => point_fallback_warning(target).into_iter().collect(),
        _ => Vec::new(),
    }
}

/// Provider-neutral recorder state machine. Native backends only collect events and evidence;
/// ordering, grouping, target selection, and the append-before-settle invariant live here.
pub struct UserActionRecorder {
    registry: SemanticNameRegistry,
    scope: RecordingScope,
    groups: Vec<RecordedUserEventGroup>,
    pending_text: Option<(RecordedAppIdentity, String)>,
    mouse_down: Option<(RecordedTargetEvidence, u64)>,
    drag_end: Option<RecordedPoint>,
    secure_input: bool,
}

impl UserActionRecorder {
    pub fn start(provider: &mut dyn RecordingEvidenceProvider, scope: RecordingScope) -> Result<Self, crate::BackendError> {
        provider.start(&scope)?;
        Ok(Self {
            registry: SemanticNameRegistry::default(),
            scope,
            groups: Vec::new(),
            pending_text: None,
            mouse_down: None,
            drag_end: None,
            secure_input: false,
        })
    }

    pub fn poll(&mut self, provider: &mut dyn RecordingEvidenceProvider, timeout: Duration) -> Result<usize, crate::BackendError> {
        let events = provider.poll(timeout)?;
        let count = events.len();
        for event in events { self.consume(provider, event)?; }
        Ok(count)
    }

    pub fn finish(mut self, provider: &mut dyn RecordingEvidenceProvider) -> Result<Vec<RecordedUserEventGroup>, crate::BackendError> {
        let flush = self.flush_text(provider);
        let stop = provider.stop();
        flush?;
        stop?;
        Ok(self.groups)
    }

    pub fn groups(&self) -> &[RecordedUserEventGroup] { &self.groups }

    fn consume(&mut self, provider: &mut dyn RecordingEvidenceProvider, event: RecordedInputEvent) -> Result<(), crate::BackendError> {
        if let RecordedInputEvent::SecureInputChanged { active, .. } = event {
            self.secure_input = active;
            self.pending_text = None;
            self.mouse_down = None;
            self.drag_end = None;
            return Ok(());
        }
        if self.secure_input { return Ok(()); }
        match event {
            RecordedInputEvent::KeyDown { app, keystroke: RecordedKeystroke::Text { text }, .. } => {
                if !self.in_scope(&app) { return Ok(()); }
                match &mut self.pending_text {
                    Some((pending_app, pending)) if same_app(pending_app, &app) => pending.push_str(&text),
                    Some(_) => { self.flush_text(provider)?; self.pending_text = Some((app, text)); }
                    None => self.pending_text = Some((app, text)),
                }
            }
            RecordedInputEvent::KeyDown { app, keystroke: RecordedKeystroke::Key { key }, .. } => {
                if self.in_scope(&app) { self.flush_text(provider)?; self.append_and_settle(provider, RecordedUserAction::PressKey { app: app.name, key }, "press")?; }
            }
            RecordedInputEvent::MouseDown { evidence, timestamp_ms } => {
                if self.in_scope(&evidence.app) { self.flush_text(provider)?; self.mouse_down = Some((evidence, timestamp_ms)); self.drag_end = None; }
            }
            RecordedInputEvent::MouseDragged { at, .. } => self.drag_end = Some(at),
            RecordedInputEvent::MouseUp { evidence, timestamp_ms } => {
                if !self.in_scope(&evidence.app) { return Ok(()); }
                if let Some((down, started)) = self.mouse_down.take() {
                    let from = self.target(provider, &down)?;
                    let drag_end = self.drag_end.take();
                    let tool = if drag_end.is_some() { "drag" } else { "click" };
                    let action = if let Some(at) = drag_end {
                        RecordedUserAction::Drag { from, to: point_target(&evidence.app, at), app: Some(evidence.app.name), duration_ms: Some(timestamp_ms.saturating_sub(started) as i64) }
                    } else { RecordedUserAction::Click { target: from } };
                    let warnings = point_fallback_warnings(&action);
                    self.append_and_settle_with_warnings(provider, action, tool, warnings)?;
                }
            }
            RecordedInputEvent::Scroll { evidence, delta_x, delta_y, .. } => {
                if self.in_scope(&evidence.app) { self.flush_text(provider)?; let target = Some(self.target(provider, &evidence)?); let action = RecordedUserAction::Scroll { target, app: Some(evidence.app.name), delta_x, delta_y }; let warnings = point_fallback_warnings(&action); self.append_and_settle_with_warnings(provider, action, "scroll", warnings)?; }
            }
            RecordedInputEvent::Notification { app, notification, role, .. } => {
                if self.in_scope(&app) { if let Some(last) = self.groups.last_mut() { last.observed.push(serde_json::json!({"notification": notification, "role": role})); } }
            }
            RecordedInputEvent::SecureInputChanged { .. } => unreachable!(),
        }
        Ok(())
    }

    fn flush_text(&mut self, provider: &mut dyn RecordingEvidenceProvider) -> Result<(), crate::BackendError> {
        let Some((app, text)) = self.pending_text.take() else { return Ok(()); };
        // Clear pending state before the provider read: Accessibility callbacks may re-enter.
        let focused = provider.read_focused()?;
        let (action, warnings) = match focused {
            Some(focused) if !focused.target.candidates.iter().any(|candidate| candidate.sensitive) => {
                let target = self.target(provider, &focused.target)?;
                match focused.value {
                    Some(value) => {
                        let warnings = point_fallback_warning(&target).into_iter().collect();
                        (RecordedUserAction::SetValue { target: target.clone(), value, fact_target: Some(target) }, warnings)
                    }
                    None => (RecordedUserAction::TypeText { app: app.name, text }, vec!["focused element did not expose a value; recorded keyboard fallback".into()]),
                }
            }
            _ => (RecordedUserAction::TypeText { app: app.name, text }, vec!["focused element unavailable or sensitive; recorded keyboard fallback".into()]),
        };
        self.append_and_settle_with_warnings(provider, action, "type", warnings)
    }

    fn append_and_settle(&mut self, provider: &mut dyn RecordingEvidenceProvider, action: RecordedUserAction, tool: &str) -> Result<(), crate::BackendError> {
        self.append_and_settle_with_warnings(provider, action, tool, Vec::new())
    }

    fn append_and_settle_with_warnings(&mut self, provider: &mut dyn RecordingEvidenceProvider, action: RecordedUserAction, tool: &str, warnings: Vec<String>) -> Result<(), crate::BackendError> {
        let index = self.groups.len();
        self.groups.push(RecordedUserEventGroup::new(action).with_warnings(warnings));
        let settled = provider.settle(index, tool)?;
        self.groups[index].observed.extend(settled.observed);
        self.groups[index].observation = settled.observation;
        Ok(())
    }

    fn target(&mut self, provider: &mut dyn RecordingEvidenceProvider, evidence: &RecordedTargetEvidence) -> Result<Value, crate::BackendError> {
        if evidence.candidates.iter().any(|candidate| candidate.sensitive) {
            return Ok(point_target(&evidence.app, evidence.point));
        }
        let Some(snapshot) = provider.capture_snapshot(&evidence.app)? else { return Ok(point_target(&evidence.app, evidence.point)); };
        let names = self.registry.register(&snapshot);
        for candidate in &evidence.candidates {
            for name in &names {
                let Some(node) = snapshot.node(name.source_index) else { continue; };
                if node_matches(node, candidate) && name.collision_free {
                    let wire = WireElementTarget { app: evidence.app.bundle_identifier.clone().unwrap_or_else(|| evidence.app.name.clone()), name: name.name.clone() };
                    if let crate::SemanticSelection::Selected(context) = self.registry.select(&wire) {
                        if LocatorResolver::resolve(context.locator(), &snapshot).status == ResolutionStatus::Unique {
                            return Ok(serde_json::to_value(wire).expect("wire target serializes"));
                        }
                    }
                }
            }
        }
        Ok(point_target(&evidence.app, evidence.point))
    }

    fn in_scope(&self, app: &RecordedAppIdentity) -> bool {
        match &self.scope { RecordingScope::AllApplications => true, RecordingScope::Application { app: wanted } => same_app(wanted, app) }
    }
}

fn same_app(a: &RecordedAppIdentity, b: &RecordedAppIdentity) -> bool {
    match (&a.bundle_identifier, &b.bundle_identifier) { (Some(a), Some(b)) => a == b, _ => a.name == b.name }
}

fn node_matches(node: &crate::Node, candidate: &RecordedElementEvidence) -> bool {
    node.role == candidate.role
        && candidate.subrole.as_ref().is_none_or(|v| node.subrole.as_ref() == Some(v))
        && candidate.identifier.as_ref().is_none_or(|v| node.identifier.as_ref() == Some(v))
        && candidate.title.as_ref().is_none_or(|v| node.title.as_ref() == Some(v))
        && candidate.value.as_ref().is_none_or(|v| node.value.as_ref() == Some(v))
        && candidate.description.as_ref().is_none_or(|v| node.description.as_ref() == Some(v))
}

fn point_target(app: &RecordedAppIdentity, point: RecordedPoint) -> Value {
    serde_json::json!({"app": app.bundle_identifier.as_deref().unwrap_or(&app.name), "point": {"x": point.x, "y": point.y}})
}

/// Which application an event belongs to.
///
/// The name and bundle identifier are what a serialized artifact keeps, because they survive the
/// session; the process id is runtime-only scoping for the semantic-name registry.
///
/// That split is enforced by the model rather than asserted by this comment: `process_id` is
/// skipped by serde in both directions, so a pid cannot ride into an artifact, a history record,
/// or a diagnostic dump and later be mistaken for durable identity by a different session.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordedAppIdentity {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle_identifier: Option<String>,
    #[serde(skip)]
    pub process_id: Option<u32>,
}

/// One element the provider hit-tested, described only in portable terms.
///
/// This is evidence, not a target. Shared core re-resolves it against a fresh snapshot and emits a
/// semantic target only when that resolution is unique, which is why no native object identity is
/// carried here: two separately captured trees may never be joined by pointer equality.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordedElementEvidence {
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subrole: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identifier: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
    /// A secure field, or one whose description marks it as a password. Shared core refuses to
    /// build a target from it, and the provider must not report its value.
    #[serde(default)]
    pub sensitive: bool,
}

/// What the provider could see around one pointer event: the application, the physical point, and
/// the actionable ancestry nearest-first.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordedTargetEvidence {
    pub app: RecordedAppIdentity,
    pub point: RecordedPoint,
    /// Actionable ancestry, nearest first. Providers cap the depth they walk.
    #[serde(default)]
    pub candidates: Vec<RecordedElementEvidence>,
}

/// A keystroke, already classified by the provider into literal text or a named key.
///
/// No backend can tell the two apart after the fact — `End` is three characters as text and one
/// keystroke as a key — so the classification is made where the physical event is seen and carried
/// through rather than re-guessed during authoring.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum RecordedKeystroke {
    /// Literal characters the keystroke produced.
    Text { text: String },
    /// A recognized key or chord such as `Return`, `Tab`, or `cmd+s`.
    Key { key: String },
}

/// One native input event, provider-neutral.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "event")]
pub enum RecordedInputEvent {
    /// The pre-delivery read: what was under the pointer before the click landed.
    MouseDown {
        evidence: RecordedTargetEvidence,
        timestamp_ms: u64,
    },
    MouseDragged {
        at: RecordedPoint,
        timestamp_ms: u64,
    },
    /// The post-delivery observation: what the interface looked like once the click settled.
    MouseUp {
        evidence: RecordedTargetEvidence,
        timestamp_ms: u64,
    },
    Scroll {
        evidence: RecordedTargetEvidence,
        delta_x: f64,
        delta_y: f64,
        timestamp_ms: u64,
    },
    KeyDown {
        app: RecordedAppIdentity,
        keystroke: RecordedKeystroke,
        timestamp_ms: u64,
    },
    /// Secure event input became active or inactive. While active a provider must discard events
    /// rather than report them, and shared core drops anything pending.
    SecureInputChanged { active: bool, timestamp_ms: u64 },
    /// An Accessibility notification observed on the scoped application.
    Notification {
        app: RecordedAppIdentity,
        notification: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        role: Option<String>,
        timestamp_ms: u64,
    },
}

/// Which applications a session captures.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "scope")]
pub enum RecordingScope {
    /// Every application. No per-application notification observer is attached.
    AllApplications,
    /// One application; events outside it are discarded and its notifications are observed.
    Application { app: RecordedAppIdentity },
}

/// The native seam a platform implements to feed the shared recorder.
///
/// Exactly one session may be active. `start` on an already-running observer is a typed conflict,
/// and `stop` is required to release the native event hook, run-loop source, observers, and
/// buffers on every exit path — success, error, client disconnect, and daemon shutdown alike.
pub trait GlobalInputObserver {
    /// Begins one owned capture session.
    fn start(&mut self, scope: &RecordingScope) -> Result<(), crate::BackendError>;
    /// Drains the events captured so far, waiting up to `timeout` for the first one.
    fn poll(&mut self, timeout: Duration) -> Result<Vec<RecordedInputEvent>, crate::BackendError>;
    /// Ends the session and releases everything it owned. Idempotent.
    fn stop(&mut self) -> Result<(), crate::BackendError>;
    /// Whether a session is currently active.
    fn is_recording(&self) -> bool;
}

/// Bounded reads requested by shared core at semantic event boundaries.
///
/// This is deliberately separate from [`GlobalInputObserver`]: passive event collection has a
/// different lifetime and failure mode from Accessibility/UIA/AT-SPI reads, and providers that only
/// implement observation keep compiling while recording-capable providers opt into this contract.
pub trait RecordingEvidenceProvider: GlobalInputObserver {
    /// Captures the currently focused actionable element. Called at the beginning and end of a text
    /// burst; the latter read supplies the complete field value used by `setValue`.
    fn read_focused(&mut self) -> Result<Option<RecordedFocusedEvidence>, crate::BackendError>;

    /// Takes a fresh full-tree snapshot for semantic resolution. Native objects do not cross this
    /// boundary, and the snapshot must belong to the supplied stable application identity.
    fn capture_snapshot(
        &mut self,
        app: &RecordedAppIdentity,
    ) -> Result<Option<Snapshot>, crate::BackendError>;

    /// Waits for the action at `group_index` to settle and returns its post-delivery evidence.
    /// Core always appends the group before making this call.
    fn settle(
        &mut self,
        group_index: usize,
        tool: &str,
    ) -> Result<RecordedSettleEvidence, crate::BackendError>;
}

#[derive(Clone, Debug, PartialEq)]
pub struct RecordedFocusedEvidence {
    pub target: RecordedTargetEvidence,
    pub value: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct RecordedSettleEvidence {
    pub observed: Vec<Value>,
    pub observation: Option<crate::ActionObservation>,
}

/// A semantic action the recorder decided one or more native events amount to.
#[derive(Clone, Debug, PartialEq)]
pub enum RecordedUserAction {
    Click {
        target: Value,
    },
    SetValue {
        target: Value,
        value: String,
        fact_target: Option<Value>,
    },
    TypeText {
        app: String,
        text: String,
    },
    PressKey {
        app: String,
        key: String,
    },
    Scroll {
        target: Option<Value>,
        app: Option<String>,
        delta_x: f64,
        delta_y: f64,
    },
    Drag {
        from: Value,
        to: Value,
        app: Option<String>,
        duration_ms: Option<i64>,
    },
    PerformAction {
        target: Value,
        action: String,
    },
}

/// One recorded action together with the evidence gathered around it.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct RecordedUserEventGroup {
    pub action: Option<RecordedUserAction>,
    pub observed: Vec<Value>,
    pub warnings: Vec<String>,
    /// The before/after read taken around the recorded event, when the event had an observable
    /// target. This is what lets authoring run the same derived-postcondition compiler `save` runs;
    /// notification evidence alone cannot feed it.
    pub observation: Option<crate::ActionObservation>,
}

impl RecordedUserEventGroup {
    pub fn new(action: RecordedUserAction) -> Self {
        Self {
            action: Some(action),
            ..Default::default()
        }
    }

    pub fn with_observed(mut self, observed: Vec<Value>) -> Self {
        self.observed = observed;
        self
    }

    pub fn with_warnings(mut self, warnings: Vec<String>) -> Self {
        self.warnings = warnings;
        self
    }

    pub fn with_observation(mut self, observation: crate::ActionObservation) -> Self {
        self.observation = Some(observation);
        self
    }

    fn action(&self) -> &RecordedUserAction {
        self.action
            .as_ref()
            .expect("a translated group always carries an action")
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ScrollAxis {
    Horizontal,
    Vertical,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ScrollSignature {
    axis: ScrollAxis,
    sign: i32,
}

/// The scroll magnitude a coalesced burst is normalized to. A burst of small physical deltas is
/// one intent, and replay needs a delta large enough to actually move the surface.
const MINIMUM_SCROLL_MAGNITUDE: f64 = 120.0;

/// Terms that make a control look like it submits. A submit is the one step that both depends on
/// what was typed and is expected to change the application around it.
const SUBMIT_TERMS: [&str; 11] = [
    "search", "submit", "go", "continue", "confirm", "ok", "done", "save", "sign in", "log in",
    "login",
];

/// Turns recorded groups into a v2 `.axn` document.
#[derive(Debug, Default)]
pub struct UserRecordingTranslator;

impl UserRecordingTranslator {
    pub fn new() -> Self {
        Self
    }

    /// Authors the recorded groups as a v2 document, or refuses.
    ///
    /// The result is checked against the same replay contract `run` enforces, so authoring cannot
    /// hand back a file that its own replay would reject: a provider that emits a target without
    /// durable identity, or a malformed point fallback, fails here rather than at the moment
    /// someone tries to use the recording.
    ///
    /// `assertion_taint` decides which observed values are safe to *assert*, and nothing more.
    /// Redacting durable values is an upstream boundary: evidence is redacted before it enters a
    /// recorder buffer or a history record, so a credential has already become a
    /// `<redacted: …>` marker by the time it arrives here. Those markers are carried through on
    /// purpose — they are what keeps a recording of a password field readable and
    /// parameterizable — which is exactly why they must never be asserted back.
    pub fn axn_document(
        &self,
        groups: &[RecordedUserEventGroup],
        arguments: Vec<AxnArgument>,
        assertion_taint: &dyn crate::SecretTaint,
    ) -> Result<AxnDocument, crate::AxnError> {
        // Gathered across the whole recording before any step is compiled: an echo of typed text
        // can surface a step or two later, and every one of these strings is a parameterization
        // candidate no step may assert.
        let workflow_inputs: Vec<String> = groups
            .iter()
            .filter_map(|group| group.action.as_ref())
            .flat_map(input_strings)
            .collect();
        let semantic_groups = coalesced_scroll_bursts(groups);

        let mut actions: Vec<Value> = Vec::new();
        let mut last_value_fact_id: Option<String> = None;
        let mut guard_fact_ids: Vec<String> = Vec::new();
        let mut index = 0;
        let mut action_number = 1;

        while index < semantic_groups.len() {
            let group = &semantic_groups[index];
            let mut resolve: Option<Value> = None;
            let mut observed = group.observed.clone();
            let mut warnings = group.warnings.clone();
            let mut emitted = group;

            // A scroll that only exists to bring the next step's target into view becomes that
            // step's `resolve` hint rather than a step of its own.
            if let Some(scroll) = scroll_components(group.action())
                && let Some(next) = semantic_groups.get(index + 1)
                && target_bearing_action_target(next.action())
                    .is_some_and(|target| target.get("locator").is_some())
            {
                emitted = next;
                observed = uniqued_values(&[group.observed.clone(), next.observed.clone()]);
                warnings = uniqued_strings(&[group.warnings.clone(), next.warnings.clone()]);
                resolve = reveal_resolution(&scroll);
                index += 1;
            }

            let action_id = format!("a{action_number:03}");
            let mut object = action_object(emitted.action());
            object.insert("id".into(), Value::String(action_id.clone()));

            if let Some(resolve) = resolve {
                object.insert("resolve".into(), resolve);
            }

            if let Some(required) = last_value_fact_id.clone()
                && requires_recorded_value(emitted.action())
            {
                object.insert(
                    "requires".into(),
                    Value::Array(vec![Value::String(required)]),
                );
                last_value_fact_id = None;
            }

            let mut expected_facts: Vec<Value> = Vec::new();
            if let Some(observation) = emitted.observation.as_ref() {
                expected_facts.extend(
                    crate::DerivedPostconditionCompiler::new(assertion_taint).facts(
                        &crate::PostconditionInput {
                            action_id: &action_id,
                            tool: tool_name(emitted.action()),
                            observation,
                            workflow_inputs: &workflow_inputs,
                        },
                    ),
                );
            }

            // A redacted value is carried as the step's value but never becomes a guard. The field
            // holds the real credential at replay and never the marker, so a guard built from one
            // is unsatisfiable, and a following submit that required it could never run. Dropping
            // the guard leaves a valid, unverified step — the same outcome as any other transition
            // with nothing safe to say.
            if let RecordedUserAction::SetValue {
                target,
                value,
                fact_target,
            } = emitted.action()
                && !assertion_taint.is_tainted(value)
            {
                // The guard is indexed after any value facts the compiler derived for this step, so
                // a formatted field value (a derived `equals` fact) and the typed input (the
                // guard's `contains`) can coexist without colliding ids.
                let derived = expected_facts
                    .iter()
                    .filter(|fact| fact.get("kind") == Some(&Value::String("value".into())))
                    .count();
                let fact_id = format!("{action_id}.value.{derived}");
                expected_facts.push(value_fact(
                    &fact_id,
                    fact_target.as_ref().unwrap_or(target),
                    value,
                ));
                guard_fact_ids.push(fact_id.clone());
                last_value_fact_id = Some(fact_id);
            }

            if expects_app_change(emitted)
                && let Some(app) = app_name(emitted.action())
            {
                expected_facts.push(changed_fact(&format!("{action_id}.changed.0"), &app));
            }

            if !expected_facts.is_empty() {
                object.insert("expects".into(), Value::Array(expected_facts));
            }
            if !observed.is_empty() {
                object.insert("observed".into(), Value::Array(observed));
            }
            if !warnings.is_empty() {
                object.insert(
                    "warnings".into(),
                    Value::Array(warnings.into_iter().map(Value::String).collect()),
                );
            }

            actions.push(Value::Object(object));
            index += 1;
            action_number += 1;
        }

        let document = AxnDocument {
            version: 2,
            arguments,
            actions: prune_unrequired_guard_facts(actions, &guard_fact_ids)
                .into_iter()
                .map(into_axn_action)
                .collect(),
            flags: Map::new(),
        };
        crate::validate_replay_contract(&document)?;
        Ok(document)
    }

    pub fn yaml(
        &self,
        groups: &[RecordedUserEventGroup],
        arguments: Vec<AxnArgument>,
        assertion_taint: &dyn crate::SecretTaint,
    ) -> Result<String, crate::AxnError> {
        crate::AxnCodec::to_yaml(&self.axn_document(groups, arguments, assertion_taint)?)
    }
}

/// Rebuilds one authored action object as the typed document model, so authoring and replay share
/// one representation instead of the recorder inventing a second document shape.
fn into_axn_action(value: Value) -> AxnAction {
    let mut object = match value {
        Value::Object(object) => object,
        _ => Map::new(),
    };
    let id = object.remove("id").and_then(|v| match v {
        Value::String(id) => Some(id),
        _ => None,
    });
    let tool = object
        .remove("tool")
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default();
    let requires = match object.remove("requires") {
        Some(Value::Array(items)) => items
            .into_iter()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect(),
        _ => Vec::new(),
    };
    let expects = match object.remove("expects") {
        Some(Value::Array(items)) => items.into_iter().map(into_expected_fact).collect(),
        _ => Vec::new(),
    };
    AxnAction {
        id,
        tool,
        requires,
        expects,
        params: object,
    }
}

fn into_expected_fact(value: Value) -> ExpectedFact {
    let mut fields = match value {
        Value::Object(object) => object,
        _ => Map::new(),
    };
    let id = fields
        .remove("id")
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default();
    ExpectedFact { id, fields }
}

fn input_strings(action: &RecordedUserAction) -> Vec<String> {
    match action {
        RecordedUserAction::SetValue { value, .. } => vec![value.clone()],
        RecordedUserAction::TypeText { text, .. } => vec![text.clone()],
        RecordedUserAction::PressKey { key, .. } => vec![key.clone()],
        _ => Vec::new(),
    }
}

fn tool_name(action: &RecordedUserAction) -> &'static str {
    match action {
        RecordedUserAction::Click { .. } => "click",
        RecordedUserAction::SetValue { .. } => "type",
        RecordedUserAction::TypeText { .. } | RecordedUserAction::PressKey { .. } => "keyboard",
        RecordedUserAction::Scroll { .. } => "scroll",
        RecordedUserAction::Drag { .. } => "drag",
        RecordedUserAction::PerformAction { .. } => "invoke",
    }
}

/// Drops typed-value facts that nothing depends on.
///
/// This fact is not a derived postcondition; it is a dependency guard, which is why a following
/// submit-like step points a `requires` at it: do not press Return unless the field still holds
/// what was typed. Emitted on every text burst it would instead assert the input back at itself on
/// most steps, which is the input echo derived postconditions must never be. Keeping only the
/// consumed ones preserves the single real guarantee and drops the rest.
fn prune_unrequired_guard_facts(actions: Vec<Value>, guard_fact_ids: &[String]) -> Vec<Value> {
    let mut required: Vec<String> = Vec::new();
    for action in &actions {
        if let Some(Value::Array(items)) = action.get("requires") {
            required.extend(items.iter().filter_map(|v| v.as_str().map(str::to_owned)));
        }
    }

    actions
        .into_iter()
        .map(|action| {
            let Value::Object(mut object) = action else {
                return action;
            };
            let Some(Value::Array(facts)) = object.get("expects").cloned() else {
                return Value::Object(object);
            };
            // Only facts authoring emitted as dependency guards are prunable. A `value` fact the
            // compiler derived is a postcondition like any other and stays.
            let kept: Vec<Value> = facts
                .into_iter()
                .filter(|fact| {
                    let Some(id) = fact.get("id").and_then(Value::as_str) else {
                        return true;
                    };
                    if !guard_fact_ids.iter().any(|guard| guard == id) {
                        return true;
                    }
                    required.iter().any(|needed| needed == id)
                })
                .collect();
            if kept.is_empty() {
                object.remove("expects");
            } else {
                object.insert("expects".into(), Value::Array(kept));
            }
            Value::Object(object)
        })
        .collect()
}

struct ScrollComponents {
    target: Option<Value>,
    app: Option<String>,
    delta_x: f64,
    delta_y: f64,
}

fn scroll_components(action: &RecordedUserAction) -> Option<ScrollComponents> {
    match action {
        RecordedUserAction::Scroll {
            target,
            app,
            delta_x,
            delta_y,
        } => Some(ScrollComponents {
            target: target.clone(),
            app: app.clone(),
            delta_x: *delta_x,
            delta_y: *delta_y,
        }),
        _ => None,
    }
}

/// Collapses a burst of physical scroll events in one application into a single intent.
///
/// A trackpad flick is dozens of events; a workflow step is one. Direction is taken from the
/// aggregate rather than from each event, because a burst that overshoots and settles back is
/// still one scroll in the direction it net travelled.
fn coalesced_scroll_bursts(groups: &[RecordedUserEventGroup]) -> Vec<RecordedUserEventGroup> {
    let mut result = Vec::new();
    let mut index = 0;

    while index < groups.len() {
        let group = &groups[index];
        let Some(scroll) = group.action.as_ref().and_then(scroll_components) else {
            result.push(group.clone());
            index += 1;
            continue;
        };
        let Some(signature) = scroll_signature(scroll.delta_x, scroll.delta_y) else {
            result.push(group.clone());
            index += 1;
            continue;
        };

        let mut burst = vec![group.clone()];
        let mut observed = group.observed.clone();
        let mut warnings = group.warnings.clone();
        let mut total_x = scroll.delta_x;
        let mut total_y = scroll.delta_y;
        let mut last_signature = signature;
        let mut next_index = index + 1;

        while next_index < groups.len() {
            let Some(next) = groups[next_index]
                .action
                .as_ref()
                .and_then(scroll_components)
            else {
                break;
            };
            if scroll.app != next.app {
                break;
            }
            let Some(next_signature) = scroll_signature(next.delta_x, next.delta_y) else {
                break;
            };
            burst.push(groups[next_index].clone());
            total_x += next.delta_x;
            total_y += next.delta_y;
            last_signature = next_signature;
            observed.extend(groups[next_index].observed.clone());
            warnings.extend(groups[next_index].warnings.clone());
            next_index += 1;
        }

        let (delta_x, delta_y) = aggregate_scroll_delta(total_x, total_y, last_signature);
        result.push(
            RecordedUserEventGroup::new(RecordedUserAction::Scroll {
                target: scroll_surface_target(&burst),
                app: scroll.app.clone(),
                delta_x,
                delta_y,
            })
            .with_observed(uniqued_values(&[observed]))
            .with_warnings(uniqued_strings(&[warnings])),
        );
        index = next_index;
    }

    result
}

fn scroll_signature(delta_x: f64, delta_y: f64) -> Option<ScrollSignature> {
    if delta_x.abs() > delta_y.abs() && delta_x != 0.0 {
        return Some(ScrollSignature {
            axis: ScrollAxis::Horizontal,
            sign: if delta_x < 0.0 { -1 } else { 1 },
        });
    }
    if delta_y == 0.0 {
        return None;
    }
    Some(ScrollSignature {
        axis: ScrollAxis::Vertical,
        sign: if delta_y < 0.0 { -1 } else { 1 },
    })
}

fn aggregate_scroll_delta(total_x: f64, total_y: f64, fallback: ScrollSignature) -> (f64, f64) {
    let signature = scroll_signature(total_x, total_y).unwrap_or(fallback);
    match signature.axis {
        ScrollAxis::Horizontal => (signed_magnitude(total_x, signature.sign), 0.0),
        ScrollAxis::Vertical => (0.0, signed_magnitude(total_y, signature.sign)),
    }
}

fn signed_magnitude(value: f64, sign: i32) -> f64 {
    f64::from(sign) * value.abs().max(MINIMUM_SCROLL_MAGNITUDE)
}

/// The scrollable surface a burst happened over, when one of its events landed on one.
fn scroll_surface_target(groups: &[RecordedUserEventGroup]) -> Option<Value> {
    groups
        .iter()
        .filter_map(|group| group.action.as_ref().and_then(scroll_components))
        .filter_map(|scroll| scroll.target)
        .find(is_scroll_surface)
}

fn is_scroll_surface(target: &Value) -> bool {
    matches!(
        target
            .get("locator")
            .and_then(|locator| locator.get("role"))
            .and_then(Value::as_str),
        Some("AXScrollArea") | Some("AXWebArea")
    )
}

fn reveal_resolution(scroll: &ScrollComponents) -> Option<Value> {
    let signature = scroll_signature(scroll.delta_x, scroll.delta_y)?;
    let mut reveal = Map::new();
    reveal.insert(
        "direction".into(),
        Value::String(direction(signature).into()),
    );
    if scroll.delta_x != 0.0 {
        reveal.insert("deltaX".into(), number(scroll.delta_x));
    }
    if scroll.delta_y != 0.0 {
        reveal.insert("deltaY".into(), number(scroll.delta_y));
    }
    if let Some(target) = scroll.target.clone() {
        reveal.insert("surface".into(), target);
    } else if let Some(app) = scroll.app.clone() {
        reveal.insert("app".into(), Value::String(app));
    }
    let mut object = Map::new();
    object.insert("reveal".into(), Value::Object(reveal));
    Some(Value::Object(object))
}

/// The direction a reader would name, which is the direction content travels rather than the sign
/// of the physical delta.
fn direction(signature: ScrollSignature) -> &'static str {
    match signature.axis {
        ScrollAxis::Horizontal => {
            if signature.sign < 0 {
                "right"
            } else {
                "left"
            }
        }
        ScrollAxis::Vertical => {
            if signature.sign < 0 {
                "down"
            } else {
                "up"
            }
        }
    }
}

fn number(value: f64) -> Value {
    serde_json::Number::from_f64(value).map_or(Value::Null, Value::Number)
}

fn uniqued_strings(groups: &[Vec<String>]) -> Vec<String> {
    let mut result: Vec<String> = Vec::new();
    for value in groups.iter().flatten() {
        if !result.contains(value) {
            result.push(value.clone());
        }
    }
    result
}

fn uniqued_values(groups: &[Vec<Value>]) -> Vec<Value> {
    let mut result: Vec<Value> = Vec::new();
    for value in groups.iter().flatten() {
        if !result.contains(value) {
            result.push(value.clone());
        }
    }
    result
}

fn target_bearing_action_target(action: &RecordedUserAction) -> Option<&Value> {
    match action {
        RecordedUserAction::Click { target }
        | RecordedUserAction::SetValue { target, .. }
        | RecordedUserAction::PerformAction { target, .. } => Some(target),
        RecordedUserAction::Drag { to, .. } => Some(to),
        _ => None,
    }
}

fn action_object(action: &RecordedUserAction) -> Map<String, Value> {
    let mut object = Map::new();
    match action {
        RecordedUserAction::Click { target } => {
            object.insert("tool".into(), Value::String("click".into()));
            object.insert("target".into(), target.clone());
        }
        RecordedUserAction::SetValue { target, value, .. } => {
            object.insert("tool".into(), Value::String("type".into()));
            object.insert("target".into(), target.clone());
            object.insert("value".into(), Value::String(value.clone()));
        }
        RecordedUserAction::TypeText { app, text } => {
            object.insert("tool".into(), Value::String("keyboard".into()));
            object.insert("app".into(), Value::String(app.clone()));
            object.insert("text".into(), Value::String(text.clone()));
        }
        RecordedUserAction::PressKey { app, key } => {
            object.insert("tool".into(), Value::String("keyboard".into()));
            object.insert("app".into(), Value::String(app.clone()));
            object.insert("key".into(), Value::String(key.clone()));
        }
        RecordedUserAction::Scroll {
            target,
            app,
            delta_x,
            delta_y,
        } => {
            object.insert("tool".into(), Value::String("scroll".into()));
            object.insert("deltaX".into(), number(*delta_x));
            object.insert("deltaY".into(), number(*delta_y));
            if let Some(target) = target {
                object.insert("target".into(), target.clone());
            }
            if let Some(app) = app {
                object.insert("app".into(), Value::String(app.clone()));
            }
        }
        RecordedUserAction::Drag {
            from,
            to,
            app,
            duration_ms,
        } => {
            object.insert("tool".into(), Value::String("drag".into()));
            object.insert("from".into(), from.clone());
            object.insert("to".into(), to.clone());
            if let Some(app) = app {
                object.insert("app".into(), Value::String(app.clone()));
            }
            if let Some(duration_ms) = duration_ms {
                object.insert("durationMs".into(), Value::Number((*duration_ms).into()));
            }
        }
        RecordedUserAction::PerformAction { target, action } => {
            object.insert("tool".into(), Value::String("invoke".into()));
            object.insert("target".into(), target.clone());
            object.insert("name".into(), Value::String(action.clone()));
        }
    }
    object
}

fn requires_recorded_value(action: &RecordedUserAction) -> bool {
    match action {
        RecordedUserAction::PressKey { key, .. } => {
            matches!(key.as_str(), "Return" | "Enter" | "Tab")
        }
        RecordedUserAction::Click { target } | RecordedUserAction::PerformAction { target, .. } => {
            is_submit_target(target)
        }
        _ => false,
    }
}

fn expects_app_change(group: &RecordedUserEventGroup) -> bool {
    if is_submit_action(group.action()) {
        return true;
    }
    match group.action() {
        RecordedUserAction::Click { .. } | RecordedUserAction::PerformAction { .. } => {
            group.observed.iter().any(observed_navigation_evidence)
        }
        _ => false,
    }
}

fn is_submit_action(action: &RecordedUserAction) -> bool {
    match action {
        RecordedUserAction::PressKey { key, .. } => matches!(key.as_str(), "Return" | "Enter"),
        RecordedUserAction::Click { target } | RecordedUserAction::PerformAction { target, .. } => {
            is_submit_target(target)
        }
        _ => false,
    }
}

/// Evidence that a click went somewhere rather than merely landing.
fn observed_navigation_evidence(value: &Value) -> bool {
    let notification = value.get("notification").and_then(Value::as_str);
    if notification == Some("AXWindowCreated") {
        return true;
    }
    notification == Some("AXFocusedUIElementChanged")
        && value.get("role").and_then(Value::as_str) == Some("AXLink")
}

fn app_name(action: &RecordedUserAction) -> Option<String> {
    match action {
        RecordedUserAction::Click { target }
        | RecordedUserAction::SetValue { target, .. }
        | RecordedUserAction::PerformAction { target, .. } => app_name_in(target),
        RecordedUserAction::TypeText { app, .. } | RecordedUserAction::PressKey { app, .. } => {
            Some(app.clone())
        }
        RecordedUserAction::Scroll { app, .. } | RecordedUserAction::Drag { app, .. } => {
            app.clone()
        }
    }
}

fn app_name_in(target: &Value) -> Option<String> {
    target
        .get("app")
        .and_then(Value::as_str)
        .filter(|app| !app.is_empty())
        .map(str::to_owned)
}

fn is_submit_target(target: &Value) -> bool {
    let haystack = target_text_fragments(target).join(" ").to_lowercase();
    if haystack.is_empty() {
        return false;
    }
    SUBMIT_TERMS.iter().any(|term| haystack.contains(term))
}

fn target_text_fragments(value: &Value) -> Vec<String> {
    let Some(locator) = value.get("locator") else {
        return Vec::new();
    };
    let mut fragments = Vec::new();
    for key in [
        "role",
        "title",
        "label",
        "value",
        "description",
        "identifier",
    ] {
        append_text(locator.get(key), &mut fragments);
    }
    fragments
}

/// A locator field is either a literal string or a match object; both carry text worth reading.
fn append_text(value: Option<&Value>, fragments: &mut Vec<String>) {
    match value {
        Some(Value::String(text)) => fragments.push(text.clone()),
        Some(Value::Object(object)) => {
            for key in ["equals", "exact", "contains"] {
                if let Some(text) = object.get(key).and_then(Value::as_str) {
                    fragments.push(text.to_owned());
                }
            }
        }
        _ => {}
    }
}

fn value_fact(id: &str, target: &Value, value: &str) -> Value {
    let mut contains = Map::new();
    contains.insert("contains".into(), Value::String(value.to_owned()));
    let mut state = Map::new();
    state.insert("value".into(), Value::Object(contains));

    let mut object = Map::new();
    object.insert("id".into(), Value::String(id.to_owned()));
    object.insert("kind".into(), Value::String("value".into()));
    object.insert("target".into(), target.clone());
    object.insert("state".into(), Value::Object(state));
    Value::Object(object)
}

fn changed_fact(id: &str, app: &str) -> Value {
    let mut target = Map::new();
    target.insert("app".into(), Value::String(app.to_owned()));

    let mut object = Map::new();
    object.insert("id".into(), Value::String(id.to_owned()));
    object.insert("kind".into(), Value::String("changed".into()));
    object.insert("target".into(), Value::Object(target));
    Value::Object(object)
}
