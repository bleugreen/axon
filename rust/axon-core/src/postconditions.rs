//! Observed action state, and the shared rules that turn it into `expects` facts.
//!
//! Ported from the Swift `ActionObservation` / `DerivedPostconditions` pair so recording and `save`
//! compile postconditions through one implementation rather than two that drift. Pure by
//! construction: no Accessibility access, no I/O, and no clock, so every rule that decides what a
//! saved workflow claims is reachable from a hand-built observation.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::HashMap;

/// Roles whose value reads as a chosen option rather than as free text. A change on one of these
/// is a selection, and a `selected` fact checks the same underlying value a `value` fact would.
pub const SELECTION_ROLES: [&str; 5] = [
    "AXCheckBox",
    "AXComboBox",
    "AXMenuItem",
    "AXPopUpButton",
    "AXRadioButton",
];

/// Locator keys that already prove themselves by resolving. An assertion repeating one of them
/// verifies nothing.
const IDENTITY_LOCATOR_KEYS: [&str; 4] = ["title", "value", "description", "identifier"];

/// Below this length a substring comparison stops meaning anything: a one-letter keystroke would
/// otherwise exclude every assertion that happens to contain that letter.
const MINIMUM_SUBSTRING_LENGTH: usize = 3;

/// The marker a redacted string carries. Its presence alone proves taint.
pub const REDACTION_MARKER: &str = "<redacted:";

fn normalized(value: &str) -> String {
    value.trim().to_lowercase()
}

/// Whether an assertion candidate carries one of the workflow's own inputs forward.
///
/// Both directions matter. The direct case is a `type` whose field reads back exactly what was
/// typed; the downstream case is a preview label or window title that quotes it. Either way the
/// user is expected to parameterize the input, and `expects` is not a substitutable field, so the
/// assertion would either go stale or make the whole file unrunnable.
pub fn echoes_input(candidate: &str, inputs: &[String]) -> bool {
    let needle = normalized(candidate);
    if needle.is_empty() {
        return false;
    }
    let needle_len = needle.chars().count();
    inputs.iter().any(|input| {
        let hay = normalized(input);
        if hay.is_empty() {
            return false;
        }
        if hay == needle {
            return true;
        }
        if needle_len >= MINIMUM_SUBSTRING_LENGTH && hay.contains(&needle) {
            return true;
        }
        hay.chars().count() >= MINIMUM_SUBSTRING_LENGTH && needle.contains(&hay)
    })
}

/// Whether an assertion merely restates identity the fact's own locator already carries.
///
/// Clicking a button labelled `Submit` and then asserting the button still reads `Submit` proves
/// nothing: the locator resolving at all already proved it.
pub fn restates_locator(candidate: &str, locator: &Map<String, Value>) -> bool {
    let needle = normalized(candidate);
    if needle.is_empty() {
        return false;
    }
    IDENTITY_LOCATOR_KEYS.iter().any(|key| {
        locator
            .get(*key)
            .and_then(Value::as_str)
            .is_some_and(|value| normalized(value) == needle)
    })
}

/// Decides whether a candidate assertion is secret-tainted and must never reach a saved file.
///
/// This is a seam rather than a constant because the full verdict needs the deterministic pattern
/// set that lives with the redaction boundary. Requiring a policy at construction keeps a caller
/// from silently getting the weaker half.
pub trait SecretTaint {
    fn is_tainted(&self, candidate: &str) -> bool;
}

/// The redaction-marker half of the verdict, and only that half.
///
/// Observations are redacted before they are stored, which is what makes the marker check
/// load-bearing. It is not a substitute for the deterministic pattern rules: a caller that has
/// them should supply a policy that runs both.
pub struct RedactionMarkerTaint;

impl SecretTaint for RedactionMarkerTaint {
    fn is_tainted(&self, candidate: &str) -> bool {
        candidate.contains(REDACTION_MARKER)
    }
}

impl<F: Fn(&str) -> bool> SecretTaint for F {
    fn is_tainted(&self, candidate: &str) -> bool {
        self(candidate)
    }
}

/// One element's state as read at a single moment, carrying the durable identity a later session
/// would need to find it again.
///
/// `locator` is `None` when the element has no identity that survives the snapshot it was captured
/// in. Such an element can still be observed — its before/after values are real — but nothing may
/// be asserted about it, because a postcondition needs a target a replay can resolve.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObservedElementState {
    pub app: String,
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub locator: Option<Map<String, Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focused: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    /// True when `value` was produced by this action's own input parameters.
    ///
    /// Computed at capture time against the live, unredacted request. History params and
    /// observations are redacted afterwards, so a comparison made later could not tell a typed
    /// secret from an unrelated string and would let it through as an assertion.
    #[serde(default)]
    pub value_derived_from_input: bool,
}

impl ObservedElementState {
    /// Stamps the capture-time verdict an observer cannot reach on its own: whether this value
    /// merely echoes the action's input.
    pub fn resolving(mut self, inputs: &[String]) -> Self {
        self.value_derived_from_input = self
            .value
            .as_deref()
            .is_some_and(|value| echoes_input(value, inputs));
        self
    }
}

/// App-scoped state read alongside an action: which windows exist and what holds focus.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObservedAppState {
    pub app: String,
    /// `None` when the window list could not be read at all, which is not the same fact as an app
    /// with no windows. Collapsing the two would make every window look newly appeared the first
    /// time a read succeeds.
    pub window_titles: Option<Vec<String>>,
    pub focused: Option<ObservedElementState>,
}

/// What one dispatched action changed, as a bounded before/after read of its target element and
/// the app around it. This is the only evidence `save` has that a step did anything, and the sole
/// input to the postcondition compiler.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionObservation {
    pub tool: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    /// The action's own input strings (`value`, `text`, `key`), redacted with everything else. A
    /// derived fact may never assert one of these back.
    #[serde(default)]
    pub inputs: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_before: Option<ObservedElementState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_after: Option<ObservedElementState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_before: Option<ObservedElementState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to_before: Option<ObservedElementState>,
    /// The app's focused element before and after. The pair is how a focus move to some element
    /// other than the action's own target becomes visible — and, just as importantly, how focus
    /// that never moved is recognised as no transition at all.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_before: Option<ObservedElementState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_after: Option<ObservedElementState>,
    /// `None` on either side means the window list could not be read then, so no comparison is
    /// possible and no window may be called new.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_titles_before: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_titles_after: Option<Vec<String>>,
    /// False when the settle loop never saw two agreeing reads inside its budget, which makes the
    /// whole post-action read a snapshot of a surface still in motion.
    pub settled: bool,
    #[serde(default)]
    pub warnings: Vec<String>,
}

/// One derived transition, before the exclusions have had their say.
struct Candidate {
    kind: &'static str,
    app: String,
    locator: Option<Map<String, Value>>,
    state: Map<String, Value>,
    /// The string this candidate asserts, when it asserts one. Existence-only facts have none.
    assertion: Option<String>,
    /// Capture-time verdict: this string came out of the action's own input.
    derived_from_input: bool,
}

/// Everything one action's compilation needs.
pub struct PostconditionInput<'a> {
    pub action_id: &'a str,
    pub tool: &'a str,
    pub observation: &'a ActionObservation,
    /// Every input string the saved workflow carries, not only this action's own.
    ///
    /// Any of them may be parameterized later, and an echo often surfaces a step or two after the
    /// step that typed it — a click opens a window titled after text typed earlier. So no step may
    /// assert any input the workflow contains, whichever step supplied it.
    pub workflow_inputs: &'a [String],
}

impl PostconditionInput<'_> {
    fn excluded_inputs(&self) -> Vec<String> {
        let mut inputs = self.observation.inputs.clone();
        inputs.extend_from_slice(self.workflow_inputs);
        inputs
    }
}

/// Turns one action's observation into the postconditions that are safe to assert on replay.
pub struct DerivedPostconditionCompiler<'a> {
    taint: &'a dyn SecretTaint,
}

impl<'a> DerivedPostconditionCompiler<'a> {
    pub fn new(taint: &'a dyn SecretTaint) -> Self {
        Self { taint }
    }

    pub fn facts(&self, input: &PostconditionInput<'_>) -> Vec<Value> {
        let excluded = input.excluded_inputs();
        let mut counters: HashMap<&'static str, usize> = HashMap::new();
        Self::candidates(input.observation)
            .into_iter()
            .filter(|candidate| self.survives(candidate, &excluded))
            .map(|candidate| {
                let index = counters.entry(candidate.kind).or_insert(0);
                let id = format!("{}.{}.{}", input.action_id, candidate.kind, index);
                *index += 1;
                Self::fact(candidate, id)
            })
            .collect()
    }

    /// Every derivation is a comparison, so each one needs both sides.
    ///
    /// An attribute the pre-action read could not reach comes back the same way an attribute that
    /// does not exist does: as absent. Treating that as "it changed" would assert pre-existing
    /// state the action had nothing to do with, so every rule below requires positive before
    /// evidence. An unsettled read is refused wholesale for the same reason: a button that disables
    /// during submission and re-enables after the budget would otherwise be saved as permanently
    /// disabled.
    fn candidates(observation: &ActionObservation) -> Vec<Candidate> {
        if !observation.settled {
            return Vec::new();
        }

        let mut candidates = Vec::new();
        let before = observation.target_before.as_ref();
        let after = observation.target_after.as_ref();

        if let Some(after) = after
            && before.and_then(|state| state.focused) == Some(false)
            && after.focused == Some(true)
        {
            candidates.push(Candidate {
                kind: "focused",
                app: after.app.clone(),
                locator: after.locator.clone(),
                state: bool_state("focused", true),
                assertion: None,
                derived_from_input: false,
            });
        }

        // Focus that landed somewhere other than the acted-on element is only visible in the
        // app-level read, which is why the observation carries one. A missing before-read means
        // focus cannot be shown to have moved: nothing focused and nothing readable look alike.
        if let (Some(focus), Some(focus_before)) = (
            observation.focus_after.as_ref(),
            observation.focus_before.as_ref(),
        ) && focus.locator.is_some()
            && focus.locator != focus_before.locator
            && focus.locator != after.and_then(|state| state.locator.clone())
        {
            candidates.push(Candidate {
                kind: "focused",
                app: focus.app.clone(),
                locator: focus.locator.clone(),
                state: bool_state("focused", true),
                assertion: None,
                derived_from_input: false,
            });
        }

        if let Some(after) = after {
            if let (Some(enabled), Some(was_enabled)) =
                (after.enabled, before.and_then(|state| state.enabled))
                && was_enabled != enabled
            {
                candidates.push(Candidate {
                    kind: "enabled",
                    app: after.app.clone(),
                    locator: after.locator.clone(),
                    state: bool_state("enabled", enabled),
                    assertion: None,
                    derived_from_input: false,
                });
            }

            if let (Some(value), Some(was_value)) = (
                after.value.as_deref(),
                before.and_then(|state| state.value.as_deref()),
            ) && was_value != value
            {
                let kind = if SELECTION_ROLES.contains(&after.role.as_str()) {
                    "selected"
                } else {
                    "value"
                };
                let mut state = Map::new();
                let mut equals = Map::new();
                equals.insert("equals".into(), Value::String(value.to_owned()));
                state.insert(kind.into(), Value::Object(equals));
                candidates.push(Candidate {
                    kind,
                    app: after.app.clone(),
                    locator: after.locator.clone(),
                    state,
                    assertion: Some(value.to_owned()),
                    derived_from_input: after.value_derived_from_input,
                });
            }
        }

        if let (Some(app), Some(titles_before), Some(titles_after)) = (
            observation.app.as_deref(),
            observation.window_titles_before.as_ref(),
            observation.window_titles_after.as_ref(),
        ) {
            for title in titles_after.iter().filter(|t| !titles_before.contains(t)) {
                let mut locator = Map::new();
                locator.insert("role".into(), Value::String("AXWindow".into()));
                locator.insert("title".into(), Value::String(title.clone()));
                candidates.push(Candidate {
                    kind: "window",
                    app: app.to_owned(),
                    locator: Some(locator),
                    state: Map::new(),
                    assertion: Some(title.clone()),
                    derived_from_input: false,
                });
            }
        }

        candidates
    }

    /// The exclusions. A candidate that trips any of them is dropped silently: omission is the
    /// designed outcome, and an action with nothing safe to say stays a valid, unverified step.
    fn survives(&self, candidate: &Candidate, inputs: &[String]) -> bool {
        let Some(locator) = candidate.locator.as_ref().filter(|l| !l.is_empty()) else {
            return false;
        };
        let Some(assertion) = candidate.assertion.as_deref() else {
            return true;
        };
        if assertion.trim().is_empty() {
            return false;
        }
        if candidate.derived_from_input || echoes_input(assertion, inputs) {
            return false;
        }
        // A window fact asserts that a window resolves, not that it holds some string, so its own
        // title is not a restatement of anything.
        if !candidate.state.is_empty() && restates_locator(assertion, locator) {
            return false;
        }
        !self.taint.is_tainted(assertion)
    }

    fn fact(candidate: Candidate, id: String) -> Value {
        let mut target = Map::new();
        target.insert("app".into(), Value::String(candidate.app));
        target.insert(
            "locator".into(),
            Value::Object(candidate.locator.unwrap_or_default()),
        );

        let mut object = Map::new();
        object.insert("id".into(), Value::String(id));
        object.insert("kind".into(), Value::String(candidate.kind.into()));
        object.insert("target".into(), Value::Object(target));
        if !candidate.state.is_empty() {
            object.insert("state".into(), Value::Object(candidate.state));
        }
        Value::Object(object)
    }
}

fn bool_state(key: &str, value: bool) -> Map<String, Value> {
    let mut state = Map::new();
    state.insert(key.into(), Value::Bool(value));
    state
}
