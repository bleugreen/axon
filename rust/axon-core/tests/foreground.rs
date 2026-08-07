//! The shared foreground transaction, exercised directly against a fake session.
//!
//! The router tests in `axon-linux` and `axon-win` check what a caller sees; these check what the
//! transaction does to the user's session and in what order, which is the part every backend
//! inherits. Both matter, and neither substitutes for the other.

use axon_core::{
    AppQuery, Application, BackendError, CapabilityInfo, DeliveryRefusalReason, ForegroundTarget,
    KeyboardIntent, Node, Observation, PlatformBackend, RecordedCall, Screenshot, Snapshot,
    SnapshotHandle, dispatch_in_foreground,
};
use serde_json::Value;
use std::time::Duration;

/// One thing the transaction asked of the session, recorded in the order it was asked. Order is
/// part of the contract: the cursor goes home before the user's window comes back.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Step {
    ReadForeground,
    Activate(String),
    Dispatch,
    ReadPointer,
    MovePointer,
}

struct FakeSession {
    frontmost: Option<String>,
    /// Applications that will not come forward, so activation cannot be proved.
    refuses_activation: Vec<String>,
    /// Whether the foreground can be read at all. Distinct from nothing being frontmost.
    foreground_readable: bool,
    pointer: (f64, f64),
    /// Whether the pointer can be read at all. Distinct from having no pointer.
    pointer_readable: bool,
    /// Whether this session has a pointer to speak of, which a keyboard-only backend does not.
    has_pointer: bool,
    /// Where the dispatch leaves the cursor, when it moves it.
    dispatch_moves_pointer_to: Option<(f64, f64)>,
    refuses_pointer_move: bool,
    steps: Vec<Step>,
}

impl FakeSession {
    fn new() -> Self {
        Self {
            frontmost: Some("Prior".into()),
            refuses_activation: vec![],
            foreground_readable: true,
            pointer: (10.0, 10.0),
            pointer_readable: true,
            has_pointer: true,
            dispatch_moves_pointer_to: None,
            refuses_pointer_move: false,
            steps: vec![],
        }
    }

    /// The dispatch itself: it records that it ran, and moves the cursor if that is what it does.
    fn dispatch(&mut self) -> Result<(), BackendError> {
        self.steps.push(Step::Dispatch);
        if let Some(to) = self.dispatch_moves_pointer_to {
            self.pointer = to;
        }
        Ok(())
    }

    fn position(&self, step: &Step) -> Option<usize> {
        self.steps.iter().position(|recorded| recorded == step)
    }
}

fn unavailable(operation: &str) -> BackendError {
    BackendError::Operation {
        operation: operation.into(),
        message: "the session refused".into(),
        diagnostic: None,
    }
}

impl PlatformBackend for FakeSession {
    fn supports_foreground_transaction(&self) -> bool {
        true
    }
    fn frontmost_application(&mut self) -> Result<Option<String>, BackendError> {
        self.steps.push(Step::ReadForeground);
        if !self.foreground_readable {
            return Err(unavailable("read the foreground"));
        }
        Ok(self.frontmost.clone())
    }
    fn activate_application(&mut self, identity: &str) -> Result<bool, BackendError> {
        self.steps.push(Step::Activate(identity.into()));
        if self.refuses_activation.iter().any(|app| app == identity) {
            return Ok(false);
        }
        self.frontmost = Some(identity.into());
        Ok(true)
    }
    fn pointer_location(&mut self) -> Result<Option<(f64, f64)>, BackendError> {
        self.steps.push(Step::ReadPointer);
        if !self.pointer_readable {
            return Err(unavailable("read the pointer"));
        }
        Ok(self.has_pointer.then_some(self.pointer))
    }
    fn move_pointer(&mut self, to: (f64, f64)) -> Result<bool, BackendError> {
        self.steps.push(Step::MovePointer);
        if self.refuses_pointer_move {
            return Ok(false);
        }
        self.pointer = to;
        Ok(true)
    }

    // Nothing below participates in a foreground transaction.
    fn capabilities(&self) -> Result<Vec<CapabilityInfo>, BackendError> {
        Ok(vec![])
    }
    fn enumerate_applications(&self) -> Result<Vec<Application>, BackendError> {
        Ok(vec![])
    }
    fn capture(&mut self, _: &AppQuery) -> Result<Snapshot, BackendError> {
        unreachable!()
    }
    fn invoke(&mut self, _: &SnapshotHandle, _: &str) -> Result<(), BackendError> {
        unreachable!()
    }
    fn read_value(&self, _: &SnapshotHandle) -> Result<Option<String>, BackendError> {
        unreachable!()
    }
    fn set_value(&mut self, _: &SnapshotHandle, _: &str) -> Result<(), BackendError> {
        unreachable!()
    }
    fn focus(&mut self, _: &SnapshotHandle) -> Result<(), BackendError> {
        unreachable!()
    }
    fn scroll(&mut self, _: &SnapshotHandle, _: (f64, f64)) -> Result<(), BackendError> {
        unreachable!()
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
        unreachable!()
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
        unreachable!()
    }
    fn screenshot(&mut self, _: &AppQuery) -> Result<Screenshot, BackendError> {
        unreachable!()
    }
    fn hit_test(&mut self, _: (f64, f64)) -> Result<Option<Node>, BackendError> {
        unreachable!()
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

#[test]
fn a_click_puts_the_cursor_home_before_the_window_and_reports_it() {
    let mut session = FakeSession::new();
    session.dispatch_moves_pointer_to = Some((400.0, 300.0));

    let dispatch = dispatch_in_foreground(
        &mut session,
        ForegroundTarget::Application("Target"),
        true,
        FakeSession::dispatch,
    );

    assert!(dispatch.refusal.is_none());
    assert_eq!(dispatch.cleanup.activation_proved, true);
    assert_eq!(dispatch.cleanup.restored, true);
    assert_eq!(dispatch.cleanup.pointer_restored, Some(true));
    assert!(dispatch.cleanup.session_restored());
    assert_eq!(dispatch.cleanup.message, None);
    // The session is as the user left it, on both axes.
    assert_eq!(session.frontmost.as_deref(), Some("Prior"));
    assert_eq!(session.pointer, (10.0, 10.0));
    // The cursor goes home before the window comes back, so the user never sees their own
    // application return with Axon's cursor sitting in it.
    let dispatched = session.position(&Step::Dispatch).expect("dispatched");
    let warped = session.position(&Step::MovePointer).expect("pointer warped");
    let handed_back = session
        .position(&Step::Activate("Prior".into()))
        .expect("foreground restored");
    assert!(dispatched < warped, "{:?}", session.steps);
    assert!(warped < handed_back, "{:?}", session.steps);
}

#[test]
fn a_dispatch_that_never_moved_the_cursor_reports_nothing_to_put_back() {
    // None means "there was nothing to restore", not "we did not check". Reporting `true` here
    // would claim a restoration that never happened.
    let mut session = FakeSession::new();

    let dispatch = dispatch_in_foreground(
        &mut session,
        ForegroundTarget::Application("Target"),
        true,
        FakeSession::dispatch,
    );

    assert_eq!(dispatch.cleanup.pointer_restored, None);
    assert!(dispatch.cleanup.session_restored());
    assert!(!session.steps.contains(&Step::MovePointer));
}

#[test]
fn a_cursor_that_barely_drifted_counts_as_never_having_moved() {
    let mut session = FakeSession::new();
    session.dispatch_moves_pointer_to = Some((10.2, 9.8));

    let dispatch = dispatch_in_foreground(
        &mut session,
        ForegroundTarget::Application("Target"),
        true,
        FakeSession::dispatch,
    );

    assert_eq!(dispatch.cleanup.pointer_restored, None);
    assert!(!session.steps.contains(&Step::MovePointer));
}

#[test]
fn an_action_that_does_not_move_the_cursor_never_captures_one() {
    // Keyboard input is the case: capturing a pointer it does not touch would make an unrelated
    // cursor movement look like a restoration this transaction performed.
    let mut session = FakeSession::new();
    session.dispatch_moves_pointer_to = Some((400.0, 300.0));

    let dispatch = dispatch_in_foreground(
        &mut session,
        ForegroundTarget::Application("Target"),
        false,
        FakeSession::dispatch,
    );

    assert_eq!(dispatch.cleanup.pointer_restored, None);
    assert!(!session.steps.contains(&Step::ReadPointer));
    assert!(!session.steps.contains(&Step::MovePointer));
}

#[test]
fn a_backend_with_no_pointer_has_nothing_to_put_back() {
    let mut session = FakeSession::new();
    session.has_pointer = false;

    let dispatch = dispatch_in_foreground(
        &mut session,
        ForegroundTarget::Application("Target"),
        true,
        FakeSession::dispatch,
    );

    assert!(dispatch.refusal.is_none());
    assert_eq!(dispatch.cleanup.pointer_restored, None);
}

#[test]
fn a_cursor_that_cannot_be_put_back_fails_the_action_and_keeps_the_evidence() {
    let mut session = FakeSession::new();
    session.dispatch_moves_pointer_to = Some((400.0, 300.0));
    session.refuses_pointer_move = true;

    let dispatch = dispatch_in_foreground(
        &mut session,
        ForegroundTarget::Application("Target"),
        true,
        FakeSession::dispatch,
    );

    // The events went out and the window came back, but the cursor did not.
    assert!(dispatch.value.is_some());
    assert_eq!(dispatch.cleanup.restored, true);
    assert_eq!(dispatch.cleanup.pointer_restored, Some(false));
    assert!(!dispatch.cleanup.session_restored());
    assert!(
        dispatch
            .cleanup
            .message
            .as_deref()
            .is_some_and(|message| message.contains("pointer")),
        "{:?}",
        dispatch.cleanup.message
    );
}

#[test]
fn an_unreadable_foreground_refuses_without_activating_or_dispatching() {
    // A backend that cannot read the prior foreground cannot promise to put it back. Treating that
    // as "nothing was frontmost" would activate the target and silently leave it there.
    let mut session = FakeSession::new();
    session.foreground_readable = false;

    let dispatch = dispatch_in_foreground(
        &mut session,
        ForegroundTarget::Application("Target"),
        true,
        FakeSession::dispatch,
    );

    let refusal = dispatch.refusal.expect("an unpromisable restore refuses");
    assert_eq!(refusal.reason, DeliveryRefusalReason::ActivationNotProved);
    assert!(dispatch.value.is_none());
    assert!(!dispatch.cleanup.activation_proved);
    assert!(!session.steps.contains(&Step::Dispatch));
    assert!(
        !session
            .steps
            .iter()
            .any(|step| matches!(step, Step::Activate(_))),
        "{:?}",
        session.steps
    );
    assert_eq!(session.frontmost.as_deref(), Some("Prior"));
}

#[test]
fn an_action_aimed_at_the_frontmost_survives_an_unreadable_foreground() {
    // Nothing is activated and nothing is restored, so there is nothing the failed read would have
    // been needed for. Refusing here would withhold delivery over an irrelevant fact.
    let mut session = FakeSession::new();
    session.foreground_readable = false;

    let dispatch = dispatch_in_foreground(
        &mut session,
        ForegroundTarget::Frontmost,
        false,
        FakeSession::dispatch,
    );

    assert!(dispatch.refusal.is_none());
    assert!(dispatch.value.is_some());
    assert!(dispatch.cleanup.already_frontmost);
    assert!(dispatch.cleanup.restored);
    assert!(session.steps.contains(&Step::Dispatch));
}

#[test]
fn an_unreadable_pointer_refuses_and_hands_the_foreground_back() {
    // The target has already been brought forward at this point, so the refusal has to undo it.
    let mut session = FakeSession::new();
    session.pointer_readable = false;

    let dispatch = dispatch_in_foreground(
        &mut session,
        ForegroundTarget::Application("Target"),
        true,
        FakeSession::dispatch,
    );

    let refusal = dispatch.refusal.expect("an unrestorable cursor refuses");
    assert_eq!(refusal.reason, DeliveryRefusalReason::ActivationNotProved);
    assert!(refusal.message.contains("pointer"), "{}", refusal.message);
    assert!(dispatch.value.is_none());
    assert!(!session.steps.contains(&Step::Dispatch));
    assert!(dispatch.cleanup.restored);
    assert_eq!(session.frontmost.as_deref(), Some("Prior"));
}

#[test]
fn a_target_that_will_not_come_forward_dispatches_nothing() {
    let mut session = FakeSession::new();
    session.refuses_activation.push("Target".into());

    let dispatch = dispatch_in_foreground(
        &mut session,
        ForegroundTarget::Application("Target"),
        true,
        FakeSession::dispatch,
    );

    let refusal = dispatch.refusal.expect("unproved activation refuses");
    assert_eq!(refusal.reason, DeliveryRefusalReason::ActivationNotProved);
    assert!(!session.steps.contains(&Step::Dispatch));
    // The pointer is captured after activation is proved, so an unproved one never reads it.
    assert!(!session.steps.contains(&Step::ReadPointer));
    assert_eq!(session.frontmost.as_deref(), Some("Prior"));
}
