//! Shared recording behaviour: what a recorded flow becomes as a v2 document, and which observed
//! transitions are safe to assert.
//!
//! Every test here is driven by hand-built evidence rather than by a live desktop, which is the
//! point of the provider seam: the rules that decide what a saved workflow claims are reachable
//! without Accessibility, a pointer, or a clock.

use axon_core::{
    ActionObservation, AxnAction, BackendError, DerivedPostconditionCompiler, GlobalInputObserver,
    ObservedElementState, PostconditionInput, RecordedAppIdentity, RecordedFocusedEvidence, RecordedInputEvent, RecordedKeystroke, RecordedPoint,
    RecordedSettleEvidence, RecordedTargetEvidence, RecordedUserAction, RecordedUserEventGroup,
    RecordingEvidenceProvider, RecordingScope, RedactionMarkerTaint, Snapshot, OwnedUserActionRecorder,
    UserRecordingTranslator,
};
use serde_json::{Value, json};
use std::{cell::RefCell, collections::VecDeque, rc::Rc, time::Duration};

#[derive(Default)]
struct FakeRecorderState {
    polls: VecDeque<Vec<RecordedInputEvent>>,
    focused: VecDeque<Option<RecordedFocusedEvidence>>,
    settle_calls: Vec<(usize, String)>,
    stop_calls: usize,
    fail_settle: bool,
    fail_stop: bool,
}

#[test]
fn application_scope_prefers_runtime_pid_over_bundle_and_name() {
    let mut wanted = app("Notes", "com.example.notes");
    wanted.process_id = Some(41);
    let mut wrong_process = wanted.clone();
    wrong_process.process_id = Some(42);
    let state = Rc::new(RefCell::new(FakeRecorderState {
        polls: VecDeque::from([vec![text(wrong_process, "outside"), text(wanted.clone(), "inside")]]),
        ..Default::default()
    }));
    let mut recorder = OwnedUserActionRecorder::start(FakeRecordingProvider(state), RecordingScope::Application { app: wanted }).unwrap();
    recorder.poll(Duration::ZERO).unwrap();
    let groups = recorder.finish().unwrap();
    assert_eq!(groups.len(), 1);
    assert!(matches!(&groups[0].action, Some(RecordedUserAction::TypeText { text, .. }) if text == "inside"));
}

#[derive(Clone)]
struct FakeRecordingProvider(Rc<RefCell<FakeRecorderState>>);

fn backend_error(operation: &str) -> BackendError {
    BackendError::Operation { operation: operation.into(), message: "fake failure".into(), diagnostic: None }
}

impl GlobalInputObserver for FakeRecordingProvider {
    fn start(&mut self, _: &RecordingScope) -> Result<(), BackendError> { Ok(()) }
    fn poll(&mut self, _: Duration) -> Result<Vec<RecordedInputEvent>, BackendError> {
        Ok(self.0.borrow_mut().polls.pop_front().unwrap_or_default())
    }
    fn stop(&mut self) -> Result<(), BackendError> {
        let mut state = self.0.borrow_mut();
        state.stop_calls += 1;
        if state.fail_stop { Err(backend_error("stop")) } else { Ok(()) }
    }
    fn is_recording(&self) -> bool { true }
}

impl RecordingEvidenceProvider for FakeRecordingProvider {
    fn read_focused(&mut self) -> Result<Option<RecordedFocusedEvidence>, BackendError> {
        Ok(self.0.borrow_mut().focused.pop_front().unwrap_or(None))
    }
    fn capture_snapshot(&mut self, _: &RecordedAppIdentity) -> Result<Option<Snapshot>, BackendError> { Ok(None) }
    fn settle(&mut self, index: usize, tool: &str) -> Result<RecordedSettleEvidence, BackendError> {
        let mut state = self.0.borrow_mut();
        state.settle_calls.push((index, tool.into()));
        if state.fail_settle { Err(backend_error("settle")) } else { Ok(RecordedSettleEvidence::default()) }
    }
}

fn app(name: &str, bundle: &str) -> RecordedAppIdentity {
    RecordedAppIdentity { name: name.into(), bundle_identifier: Some(bundle.into()), process_id: Some(42) }
}

fn point_evidence(app: RecordedAppIdentity, x: f64, y: f64) -> RecordedTargetEvidence {
    RecordedTargetEvidence { app, point: RecordedPoint { x, y }, candidates: Vec::new() }
}

fn text(app: RecordedAppIdentity, value: &str) -> RecordedInputEvent {
    RecordedInputEvent::KeyDown { app, keystroke: RecordedKeystroke::Text { text: value.into() }, timestamp_ms: 0 }
}

fn recorder_with(events: Vec<RecordedInputEvent>) -> (OwnedUserActionRecorder<FakeRecordingProvider>, Rc<RefCell<FakeRecorderState>>) {
    let state = Rc::new(RefCell::new(FakeRecorderState { polls: VecDeque::from([events]), ..Default::default() }));
    let recorder = OwnedUserActionRecorder::start(FakeRecordingProvider(state.clone()), RecordingScope::AllApplications).unwrap();
    (recorder, state)
}

fn translate(groups: &[RecordedUserEventGroup]) -> Vec<AxnAction> {
    UserRecordingTranslator::new()
        .axn_document(groups, Vec::new(), &RedactionMarkerTaint)
        .expect("authored document satisfies the replay contract")
        .actions
}

fn field_target(app: &str, name: &str, title: &str) -> Value {
    json!({"app": app, "name": name, "locator": {"role": "AXTextField", "title": title}})
}

fn button_target(app: &str, name: &str, title: &str) -> Value {
    json!({"app": app, "name": name, "locator": {"role": "AXButton", "title": title}})
}

fn scroll_group(app: &str, delta_y: f64) -> RecordedUserEventGroup {
    RecordedUserEventGroup::new(RecordedUserAction::Scroll {
        target: None,
        app: Some(app.into()),
        delta_x: 0.0,
        delta_y,
    })
}

fn expect_ids(action: &AxnAction) -> Vec<&str> {
    action.expects.iter().map(|fact| fact.id.as_str()).collect()
}

#[test]
fn actions_are_numbered_deterministically_from_one() {
    let groups = [
        RecordedUserEventGroup::new(RecordedUserAction::Click {
            target: button_target("Notes", "new-button", "New"),
        }),
        RecordedUserEventGroup::new(RecordedUserAction::TypeText {
            app: "Notes".into(),
            text: "hello".into(),
        }),
    ];

    let actions = translate(&groups);

    assert_eq!(actions.len(), 2);
    assert_eq!(actions[0].id.as_deref(), Some("a001"));
    assert_eq!(actions[0].tool, "click");
    assert_eq!(actions[1].id.as_deref(), Some("a002"));
    assert_eq!(actions[1].tool, "keyboard");
    assert_eq!(
        actions[1].params.get("text"),
        Some(&Value::String("hello".into()))
    );
}

#[test]
fn a_typed_value_guard_survives_only_when_a_later_step_depends_on_it() {
    let groups = [
        RecordedUserEventGroup::new(RecordedUserAction::SetValue {
            target: field_target("Safari", "address-field", "Address"),
            value: "axon.dev".into(),
            fact_target: None,
        }),
        RecordedUserEventGroup::new(RecordedUserAction::PressKey {
            app: "Safari".into(),
            key: "Return".into(),
        }),
    ];

    let actions = translate(&groups);

    // The guard is what makes the submit safe: do not press Return unless the field still holds
    // what was typed.
    assert_eq!(expect_ids(&actions[0]), vec!["a001.value.0"]);
    assert_eq!(actions[1].requires, vec!["a001.value.0".to_string()]);
}

#[test]
fn a_typed_value_guard_nothing_depends_on_is_pruned() {
    // Emitted on every text burst this fact would assert the input back at itself, which is the
    // input echo derived postconditions must never be.
    let groups = [
        RecordedUserEventGroup::new(RecordedUserAction::SetValue {
            target: field_target("Notes", "body-field", "Body"),
            value: "grocery list".into(),
            fact_target: None,
        }),
        RecordedUserEventGroup::new(RecordedUserAction::Click {
            target: button_target("Notes", "bold-button", "Bold"),
        }),
    ];

    let actions = translate(&groups);

    assert!(actions[0].expects.is_empty());
    assert!(actions[1].requires.is_empty());
}

#[test]
fn a_submit_looking_click_both_depends_on_the_typed_value_and_expects_the_app_to_change() {
    let groups = [
        RecordedUserEventGroup::new(RecordedUserAction::SetValue {
            target: field_target("Safari", "query-field", "Query"),
            value: "axon".into(),
            fact_target: None,
        }),
        RecordedUserEventGroup::new(RecordedUserAction::Click {
            target: button_target("Safari", "search-button", "Search"),
        }),
    ];

    let actions = translate(&groups);

    assert_eq!(actions[1].requires, vec!["a001.value.0".to_string()]);
    assert_eq!(expect_ids(&actions[1]), vec!["a002.changed.0"]);
    assert_eq!(
        actions[1].expects[0].fields.get("kind"),
        Some(&Value::String("changed".into()))
    );
}

#[test]
fn a_click_with_a_new_window_observed_expects_the_app_to_change() {
    let groups = [RecordedUserEventGroup::new(RecordedUserAction::Click {
        target: button_target("Notes", "open-button", "Open"),
    })
    .with_observed(vec![json!({"notification": "AXWindowCreated"})])];

    let actions = translate(&groups);

    assert_eq!(expect_ids(&actions[0]), vec!["a001.changed.0"]);
}

#[test]
fn a_click_with_only_incidental_evidence_expects_nothing() {
    let groups = [RecordedUserEventGroup::new(RecordedUserAction::Click {
        target: button_target("Notes", "bold-button", "Bold"),
    })
    .with_observed(vec![json!({"notification": "AXValueChanged"})])];

    let actions = translate(&groups);

    assert!(actions[0].expects.is_empty());
}

#[test]
fn a_burst_of_scrolls_in_one_app_becomes_a_single_step() {
    let groups = [
        scroll_group("Safari", -30.0),
        scroll_group("Safari", -30.0),
        scroll_group("Safari", -30.0),
    ];

    let actions = translate(&groups);

    assert_eq!(actions.len(), 1);
    assert_eq!(actions[0].tool, "scroll");
    // The physical total is 90, but replay needs a delta large enough to actually move a surface.
    assert_eq!(actions[0].params.get("deltaY"), Some(&json!(-120.0)));
    assert_eq!(actions[0].params.get("deltaX"), Some(&json!(0.0)));
}

#[test]
fn scroll_bursts_in_different_apps_stay_separate_steps() {
    let groups = [scroll_group("Safari", -30.0), scroll_group("Notes", -30.0)];

    let actions = translate(&groups);

    assert_eq!(actions.len(), 2);
    assert_eq!(actions[0].params.get("app"), Some(&json!("Safari")));
    assert_eq!(actions[1].params.get("app"), Some(&json!("Notes")));
}

#[test]
fn a_scroll_that_only_reveals_the_next_target_becomes_that_step_s_resolve_hint() {
    let groups = [
        scroll_group("Safari", -30.0),
        RecordedUserEventGroup::new(RecordedUserAction::Click {
            target: button_target("Safari", "accept-button", "Accept"),
        }),
    ];

    let actions = translate(&groups);

    // The scroll is not a step of its own; it is how replay finds the button again.
    assert_eq!(actions.len(), 1);
    assert_eq!(actions[0].tool, "click");
    assert_eq!(
        actions[0].params.get("resolve"),
        Some(&json!({"reveal": {"direction": "down", "deltaY": -120.0, "app": "Safari"}}))
    );
}

#[test]
fn a_recorded_flow_round_trips_through_the_shared_v2_codec() {
    let groups = [RecordedUserEventGroup::new(RecordedUserAction::Click {
        target: button_target("Notes", "new-button", "New"),
    })];

    let document = UserRecordingTranslator::new()
        .axn_document(&groups, Vec::new(), &RedactionMarkerTaint)
        .expect("authored document satisfies the replay contract");
    let yaml = axon_core::AxnCodec::to_yaml(&document).expect("authored document serializes");
    let reparsed = axon_core::AxnCodec::parse(&yaml).expect("authored document reparses");

    assert_eq!(reparsed.version, 2);
    assert_eq!(reparsed, document);
    // An action that requires nothing and expects nothing says so by omission, so a recorded file
    // stays readable by the person who has to edit it.
    assert!(
        !yaml.contains("requires"),
        "unexpected scaffolding in {yaml}"
    );
    assert!(
        !yaml.contains("expects"),
        "unexpected scaffolding in {yaml}"
    );
    assert!(!yaml.contains("null"), "unexpected scaffolding in {yaml}");
}

#[test]
fn authoring_refuses_a_target_its_own_replay_would_reject() {
    // A provider that loses durable identity must fail here, not at the moment someone tries to
    // use the recording.
    let groups = [RecordedUserEventGroup::new(RecordedUserAction::Click {
        target: json!({"app": "Notes", "name": "new-button"}),
    })];

    let error = UserRecordingTranslator::new()
        .axn_document(&groups, Vec::new(), &RedactionMarkerTaint)
        .expect_err("a target without an attached locator is not replayable");

    assert!(
        error.to_string().contains("attached locator"),
        "unhelpful refusal: {error}"
    );
}

#[test]
fn an_honest_point_fallback_still_satisfies_the_replay_contract() {
    // When semantic identity could not be captured the recorder keeps the physical point, and that
    // recording has to stay usable rather than being refused as malformed.
    let groups = [RecordedUserEventGroup::new(RecordedUserAction::Click {
        target: json!({"app": "Notes", "point": {"x": 12.0, "y": 34.0}}),
    })
    .with_warnings(vec!["recorded point fallback".into()])];

    let actions = translate(&groups);

    assert_eq!(actions[0].params["target"]["point"]["x"], json!(12.0));
    assert_eq!(
        actions[0].params["warnings"],
        json!(["recorded point fallback"])
    );
}

#[test]
fn a_redacted_value_is_carried_as_the_typed_value_but_never_asserted() {
    // Redaction happens upstream, so a credential arrives here already a marker. Carrying it is
    // what keeps a recording of a password field readable and parameterizable; asserting it back
    // is what must never happen. The submit step is the case that matters: a guard built from the
    // marker would make the field's real contents fail the check, so the recording would author
    // cleanly and then never replay.
    let groups = [
        RecordedUserEventGroup::new(RecordedUserAction::SetValue {
            target: field_target("1Password", "password-field", "Password"),
            value: "<redacted: active-credential>".into(),
            fact_target: None,
        }),
        RecordedUserEventGroup::new(RecordedUserAction::PressKey {
            app: "1Password".into(),
            key: "Return".into(),
        }),
    ];

    let yaml = UserRecordingTranslator::new()
        .yaml(&groups, Vec::new(), &RedactionMarkerTaint)
        .expect("authored document satisfies the replay contract");
    let actions = translate(&groups);

    assert!(yaml.contains("<redacted: active-credential>"), "{yaml}");
    assert!(actions[0].expects.is_empty());
    assert!(
        actions[1].requires.is_empty(),
        "submit depends on an unsatisfiable guard: {:?}",
        actions[1].requires
    );
}

#[test]
fn a_redacted_value_followed_by_a_submit_click_also_carries_no_guard() {
    let groups = [
        RecordedUserEventGroup::new(RecordedUserAction::SetValue {
            target: field_target("1Password", "password-field", "Password"),
            value: "<redacted: active-credential>".into(),
            fact_target: None,
        }),
        RecordedUserEventGroup::new(RecordedUserAction::Click {
            target: button_target("1Password", "signin-button", "Sign In"),
        }),
    ];

    let actions = translate(&groups);

    assert!(actions[0].expects.is_empty());
    assert!(actions[1].requires.is_empty());
    // The submit still expects the application to change; only the unsatisfiable guard is gone.
    assert_eq!(expect_ids(&actions[1]), vec!["a002.changed.0"]);
}

#[test]
fn a_runtime_process_id_never_reaches_a_serialized_artifact() {
    // Runtime scoping for the semantic-name registry must not be mistaken for durable identity by
    // a later session that reads it back.
    let identity = RecordedAppIdentity {
        name: "Notes".into(),
        bundle_identifier: Some("com.apple.Notes".into()),
        process_id: Some(4321),
    };

    let encoded = serde_json::to_string(&identity).expect("identity serializes");

    assert!(!encoded.contains("4321"), "pid leaked into {encoded}");
    assert!(encoded.contains("com.apple.Notes"));
    let decoded: RecordedAppIdentity = serde_json::from_str(&encoded).expect("identity reparses");
    assert_eq!(decoded.process_id, None);
    assert_eq!(decoded.name, "Notes");
}

// --- derived postconditions -------------------------------------------------------------------

fn element(app: &str, role: &str, title: &str) -> ObservedElementState {
    ObservedElementState {
        app: app.into(),
        role: role.into(),
        locator: json!({"role": role, "title": title}).as_object().cloned(),
        ..Default::default()
    }
}

fn facts(observation: &ActionObservation, workflow_inputs: &[String]) -> Vec<Value> {
    DerivedPostconditionCompiler::new(&RedactionMarkerTaint).facts(&PostconditionInput {
        action_id: "a001",
        tool: &observation.tool,
        observation,
        workflow_inputs,
    })
}

#[test]
fn a_changed_value_becomes_a_value_fact() {
    let mut before = element("Notes", "AXTextField", "Body");
    before.value = Some("old".into());
    let mut after = before.clone();
    after.value = Some("new".into());

    let observation = ActionObservation {
        tool: "click".into(),
        app: Some("Notes".into()),
        target_before: Some(before),
        target_after: Some(after),
        settled: true,
        ..Default::default()
    };

    let facts = facts(&observation, &[]);

    assert_eq!(facts.len(), 1);
    assert_eq!(facts[0]["id"], json!("a001.value.0"));
    assert_eq!(facts[0]["kind"], json!("value"));
    assert_eq!(facts[0]["state"], json!({"value": {"equals": "new"}}));
}

#[test]
fn a_changed_value_on_a_selection_role_becomes_a_selected_fact() {
    let mut before = element("Notes", "AXCheckBox", "Pinned");
    before.value = Some("0".into());
    let mut after = before.clone();
    after.value = Some("1".into());

    let observation = ActionObservation {
        tool: "click".into(),
        app: Some("Notes".into()),
        target_before: Some(before),
        target_after: Some(after),
        settled: true,
        ..Default::default()
    };

    let facts = facts(&observation, &[]);

    assert_eq!(facts[0]["kind"], json!("selected"));
    assert_eq!(facts[0]["id"], json!("a001.selected.0"));
}

#[test]
fn no_step_asserts_an_input_the_workflow_carries_even_from_another_step() {
    // An echo often surfaces a step or two after the step that typed it, and every input is a
    // parameterization candidate, so the whole workflow's inputs are excluded.
    let mut before = element("Safari", "AXStaticText", "Result");
    before.value = Some("nothing".into());
    let mut after = before.clone();
    after.value = Some("axon.dev".into());

    let observation = ActionObservation {
        tool: "click".into(),
        app: Some("Safari".into()),
        target_before: Some(before),
        target_after: Some(after),
        settled: true,
        ..Default::default()
    };

    assert!(facts(&observation, &["axon.dev".to_string()]).is_empty());
}

#[test]
fn an_unsettled_read_derives_nothing_at_all() {
    // A button that disables during submission and re-enables after the budget would otherwise be
    // saved as permanently disabled.
    let mut before = element("Safari", "AXButton", "Search");
    before.enabled = Some(true);
    let mut after = before.clone();
    after.enabled = Some(false);

    let observation = ActionObservation {
        tool: "click".into(),
        app: Some("Safari".into()),
        target_before: Some(before),
        target_after: Some(after),
        settled: false,
        ..Default::default()
    };

    assert!(facts(&observation, &[]).is_empty());
}

#[test]
fn a_missing_before_read_derives_nothing_because_nothing_can_be_shown_to_have_changed() {
    let mut after = element("Safari", "AXButton", "Search");
    after.enabled = Some(false);

    let observation = ActionObservation {
        tool: "click".into(),
        app: Some("Safari".into()),
        target_after: Some(after),
        settled: true,
        ..Default::default()
    };

    assert!(facts(&observation, &[]).is_empty());
}

#[test]
fn an_assertion_that_only_restates_the_locator_is_dropped() {
    // Clicking a button labelled Submit and asserting it still reads Submit proves nothing: the
    // locator resolving at all already proved it.
    let mut before = element("Safari", "AXButton", "Submit");
    before.value = Some("idle".into());
    let mut after = before.clone();
    after.value = Some("Submit".into());

    let observation = ActionObservation {
        tool: "click".into(),
        app: Some("Safari".into()),
        target_before: Some(before),
        target_after: Some(after),
        settled: true,
        ..Default::default()
    };

    assert!(facts(&observation, &[]).is_empty());
}

#[test]
fn a_redacted_value_never_becomes_an_assertion() {
    let mut before = element("1Password", "AXTextField", "Password");
    before.value = Some("empty".into());
    let mut after = before.clone();
    after.value = Some("<redacted:secret>".into());

    let observation = ActionObservation {
        tool: "type".into(),
        app: Some("1Password".into()),
        target_before: Some(before),
        target_after: Some(after),
        settled: true,
        ..Default::default()
    };

    assert!(facts(&observation, &[]).is_empty());
}

#[test]
fn an_element_without_a_durable_locator_is_observed_but_never_asserted() {
    let mut before = element("Notes", "AXTextField", "Body");
    before.locator = None;
    before.value = Some("old".into());
    let mut after = before.clone();
    after.value = Some("new".into());

    let observation = ActionObservation {
        tool: "type".into(),
        app: Some("Notes".into()),
        target_before: Some(before),
        target_after: Some(after),
        settled: true,
        ..Default::default()
    };

    assert!(facts(&observation, &[]).is_empty());
}

#[test]
fn a_newly_appeared_window_becomes_a_window_fact() {
    let observation = ActionObservation {
        tool: "click".into(),
        app: Some("Notes".into()),
        window_titles_before: Some(vec!["Notes".into()]),
        window_titles_after: Some(vec!["Notes".into(), "Export".into()]),
        settled: true,
        ..Default::default()
    };

    let facts = facts(&observation, &[]);

    assert_eq!(facts.len(), 1);
    assert_eq!(facts[0]["kind"], json!("window"));
    assert_eq!(facts[0]["target"]["locator"]["title"], json!("Export"));
}

#[test]
fn an_unreadable_window_list_never_calls_a_window_new() {
    // Nil on either side means no comparison is possible, which is not the same fact as an app
    // with no windows.
    let observation = ActionObservation {
        tool: "click".into(),
        app: Some("Notes".into()),
        window_titles_after: Some(vec!["Export".into()]),
        settled: true,
        ..Default::default()
    };

    assert!(facts(&observation, &[]).is_empty());
}

#[test]
fn focus_that_moved_elsewhere_is_derived_from_the_app_level_read() {
    let observation = ActionObservation {
        tool: "click".into(),
        app: Some("Notes".into()),
        focus_before: Some(element("Notes", "AXTextField", "Title")),
        focus_after: Some(element("Notes", "AXTextField", "Body")),
        settled: true,
        ..Default::default()
    };

    let facts = facts(&observation, &[]);

    assert_eq!(facts.len(), 1);
    assert_eq!(facts[0]["kind"], json!("focused"));
    assert_eq!(facts[0]["state"], json!({"focused": true}));
}

#[test]
fn focus_that_never_moved_is_no_transition_at_all() {
    let focus = element("Notes", "AXTextField", "Body");
    let observation = ActionObservation {
        tool: "click".into(),
        app: Some("Notes".into()),
        focus_before: Some(focus.clone()),
        focus_after: Some(focus),
        settled: true,
        ..Default::default()
    };

    assert!(facts(&observation, &[]).is_empty());
}


#[test]
fn recorder_groups_text_and_reads_the_complete_value_only_when_flushed() {
    let notes = app("Notes", "com.example.notes");
    let (mut recorder, state) = recorder_with(vec![text(notes.clone(), "hel"), text(notes.clone(), "lo")]);
    state.borrow_mut().focused.push_back(Some(RecordedFocusedEvidence {
        target: point_evidence(notes, 8.0, 9.0),
        value: Some("hello from field".into()),
    }));

    assert_eq!(recorder.poll(Duration::ZERO).unwrap(), 2);
    assert!(recorder.groups().is_empty(), "the burst must remain pending until a boundary");
    let groups = recorder.finish().unwrap();

    assert_eq!(groups.len(), 1);
    assert!(matches!(&groups[0].action, Some(RecordedUserAction::SetValue { value, .. }) if value == "hello from field"));
    assert_eq!(state.borrow().settle_calls, vec![(0, "type".into())]);
}

#[test]
fn recorder_warns_when_a_text_burst_falls_back_to_keyboard_input() {
    let notes = app("Notes", "com.example.notes");
    let (mut recorder, state) = recorder_with(vec![text(notes.clone(), "hello")]);
    state.borrow_mut().focused.push_back(Some(RecordedFocusedEvidence {
        target: point_evidence(notes, 1.0, 2.0), value: None,
    }));

    recorder.poll(Duration::ZERO).unwrap();
    let groups = recorder.finish().unwrap();

    assert!(matches!(&groups[0].action, Some(RecordedUserAction::TypeText { text, .. }) if text == "hello"));
    assert!(groups[0].warnings.iter().any(|warning| warning.contains("keyboard fallback")));
}

#[test]
fn recorder_appends_a_group_before_settle_can_fail() {
    let notes = app("Notes", "com.example.notes");
    let event = RecordedInputEvent::KeyDown {
        app: notes, keystroke: RecordedKeystroke::Key { key: "Return".into() }, timestamp_ms: 0,
    };
    let (mut recorder, state) = recorder_with(vec![event]);
    state.borrow_mut().fail_settle = true;

    assert!(recorder.poll(Duration::ZERO).is_err());
    assert_eq!(recorder.groups().len(), 1, "the attempted action must remain inspectable after settle failure");
    assert_eq!(state.borrow().settle_calls, vec![(0, "press".into())]);
}

#[test]
fn secure_input_clears_pending_text_and_drops_events_until_disabled() {
    let notes = app("Notes", "com.example.notes");
    let events = vec![
        text(notes.clone(), "secret-before-toggle"),
        RecordedInputEvent::SecureInputChanged { active: true, timestamp_ms: 1 },
        text(notes.clone(), "secret-during-toggle"),
        RecordedInputEvent::SecureInputChanged { active: false, timestamp_ms: 2 },
        text(notes, "safe"),
    ];
    let (mut recorder, _) = recorder_with(events);

    recorder.poll(Duration::ZERO).unwrap();
    let groups = recorder.finish().unwrap();

    assert_eq!(groups.len(), 1);
    assert!(matches!(&groups[0].action, Some(RecordedUserAction::TypeText { text, .. }) if text == "safe"));
}

#[test]
fn application_scope_filters_by_stable_bundle_identity() {
    let wanted = app("Renamed Notes", "com.example.notes");
    let other = app("Notes", "com.example.other");
    let state = Rc::new(RefCell::new(FakeRecorderState {
        polls: VecDeque::from([vec![text(other, "outside"), text(wanted.clone(), "inside")]]),
        ..Default::default()
    }));
    let mut recorder = OwnedUserActionRecorder::start(
        FakeRecordingProvider(state), RecordingScope::Application { app: app("Notes", "com.example.notes") },
    ).unwrap();

    recorder.poll(Duration::ZERO).unwrap();
    let groups = recorder.finish().unwrap();

    assert_eq!(groups.len(), 1);
    assert!(matches!(&groups[0].action, Some(RecordedUserAction::TypeText { text, .. }) if text == "inside"));
}

#[test]
fn click_and_drag_preserve_pre_delivery_origin_and_point_fallbacks() {
    let notes = app("Notes", "com.example.notes");
    let events = vec![
        RecordedInputEvent::MouseDown { evidence: point_evidence(notes.clone(), 10.0, 20.0), timestamp_ms: 100 },
        RecordedInputEvent::MouseUp { evidence: point_evidence(notes.clone(), 11.0, 21.0), timestamp_ms: 120 },
        RecordedInputEvent::MouseDown { evidence: point_evidence(notes.clone(), 30.0, 40.0), timestamp_ms: 200 },
        RecordedInputEvent::MouseDragged { at: RecordedPoint { x: 50.0, y: 60.0 }, timestamp_ms: 230 },
        RecordedInputEvent::MouseUp { evidence: point_evidence(notes, 51.0, 61.0), timestamp_ms: 260 },
    ];
    let (mut recorder, _) = recorder_with(events);

    recorder.poll(Duration::ZERO).unwrap();
    let groups = recorder.finish().unwrap();

    assert_eq!(groups.len(), 2);
    assert!(matches!(&groups[0].action, Some(RecordedUserAction::Click { target }) if target["point"] == json!({"x": 10.0, "y": 20.0})));
    assert!(matches!(&groups[1].action, Some(RecordedUserAction::Drag { from, to, duration_ms: Some(60), .. }) if from["point"] == json!({"x": 30.0, "y": 40.0}) && to["point"] == json!({"x": 50.0, "y": 60.0})));
    assert!(groups.iter().all(|group| group.warnings.iter().any(|warning| warning.contains("point fallback"))));
}

#[test]
fn finish_stops_exactly_once_and_propagates_stop_failure() {
    let (recorder, state) = recorder_with(Vec::new());
    state.borrow_mut().fail_stop = true;

    let error = recorder.finish().unwrap_err();

    assert!(error.to_string().contains("stop"));
    assert_eq!(state.borrow().stop_calls, 1);
}
