//! Global input observation against a real X server: the measurement, and then the regression
//! guard it becomes.
//!
//! `#[ignore]` by default, so it runs only where a display exists: the Xvfb lane in CI, or a
//! developer's own X11 session.
//!
//! **This test began as two questions the design could not answer by reading.** Does an X server
//! actually advertise RECORD -- `Xvfb` in particular, which is a build where it is worth checking
//! rather than assuming? And are XTEST-injected events visible to a RECORD client at all, given
//! that the whole observation half of this backend depends on it? Both are answered here rather
//! than asserted somewhere else, because a lane that runs on every pull request is a better place
//! to keep an answer than a comment is.
//!
//! What this can and cannot settle is worth being precise about. Everything from the X server to
//! the raw event queue is a protocol conversation and is reproduced here in full. What an event
//! then *means* -- which button is a click, when motion matters, whether our own delivery is
//! excluded -- is decided in `axon_linux::recording`, which needs no server and is unit-tested on
//! every host. And the accessibility half, where a point becomes an element with a role and a name,
//! needs a real desktop with applications on the bus: no `Xvfb` can stand in for that, and it is
//! the live lane's to prove.
//!
//! The test is its own X client rather than a toolkit, for the same reason `x11_pixel.rs` is: what
//! this code touches is exactly the protocol conversation reproduced here, and reproducing it needs
//! nothing but the `Xvfb` binary.

#![cfg(target_os = "linux")]

use axon_linux::recording::{
    self, BUTTON_PRESS, BUTTON_PRIMARY, BUTTON_RELEASE, KEY_PRESS, ModifierState, RawInput,
    RawQueue, classify_keystroke, keysym_level, self_delivery,
};
use axon_linux::x11::X11Session;
use axon_linux::xrecord::RecordSession;
use std::{
    sync::Arc,
    thread,
    time::{Duration, Instant},
};
use x11rb::{
    connection::Connection,
    protocol::{
        xproto::{ConnectionExt as _, KEY_PRESS_EVENT, KEY_RELEASE_EVENT, MOTION_NOTIFY_EVENT},
        xtest::ConnectionExt as _,
    },
    wrapper::ConnectionExt as _,
};

/// Long enough for a real server on a loaded CI machine, short enough to fail rather than hang.
const OBSERVED_WITHIN: Duration = Duration::from_secs(3);

/// Where the synthetic click lands. Deliberately not the origin, so a decode that lost the
/// coordinates entirely would land somewhere visibly wrong rather than accidentally right.
const CLICK_AT: (i16, i16) = (321, 214);

/// One test rather than several: these share one X server, one recording context, and one
/// process-global self-delivery ledger, and Cargo runs the tests inside a binary in parallel.
#[test]
#[ignore = "requires an X server; run with DISPLAY set, for example under Xvfb"]
fn xtest_input_is_observed_through_record_and_our_own_delivery_is_not() {
    let session = X11Session::connect().expect("an X server on DISPLAY");

    // -- measurement one: does this server advertise RECORD? -------------------------------------

    assert!(
        session.supports_record(),
        "this X server does not provide the RECORD extension, so there is nothing to observe \
         input with. Under Xvfb, add `+extension RECORD` to the invocation."
    );

    let keyboard = session
        .keyboard_layout()
        .expect("the server reports its keyboard mapping");

    // A separate connection, standing in for a person's hand on the keyboard or for any other
    // process. It deliberately does NOT go through `X11Session`, because that is the one path that
    // registers with the self-delivery ledger -- the whole distinction this test is about.
    let (elsewhere, _) = x11rb::connect(None).expect("a second connection to the same display");

    let keycode = letter_keycode(&keyboard).expect("a layout with a letter on it");

    // -- measurement two: are XTEST events visible to a RECORD client? ---------------------------

    let queue = Arc::new(RawQueue::with_capacity(256));
    let mut record = RecordSession::start(Arc::clone(&queue)).expect("a RECORD context");
    // The context is created on the control connection and the data connection has to have reached
    // `RecordEnableContext` before anything is posted, or the first events are simply not recorded.
    thread::sleep(Duration::from_millis(200));

    fake_input(&elsewhere, MOTION_NOTIFY_EVENT, 0, CLICK_AT);
    fake_input(&elsewhere, BUTTON_PRESS, BUTTON_PRIMARY, (0, 0));
    fake_input(&elsewhere, BUTTON_RELEASE, BUTTON_PRIMARY, (0, 0));
    fake_input(&elsewhere, KEY_PRESS_EVENT, keycode, (0, 0));
    fake_input(&elsewhere, KEY_RELEASE_EVENT, keycode, (0, 0));

    let observed = drain(&queue, 3);

    let buttons: Vec<&RawInput> = observed
        .iter()
        .filter(|input| matches!(input, RawInput::Button { .. }))
        .collect();
    assert_eq!(
        buttons,
        vec![
            &RawInput::Button {
                down: true,
                point: CLICK_AT
            },
            &RawInput::Button {
                down: false,
                point: CLICK_AT
            },
        ],
        "XTEST input reaches a RECORD client, carrying the screen point it was posted at"
    );

    // A key release carries nothing this observer needs -- the modifier state travels on the event
    // that needs it -- so exactly one key event survives the decode, not two.
    let keys: Vec<&RawInput> = observed
        .iter()
        .filter(|input| matches!(input, RawInput::Key { .. }))
        .collect();
    assert_eq!(
        keys,
        vec![&RawInput::Key { keycode, state: 0 }],
        "a press is recorded with the modifier state the server reported, and a release is not"
    );

    // The state the core event carries is the reason this backend records through RECORD rather
    // than XInput2, so it is asserted as a fact about the event and then used the way the observer
    // uses it: resolved against the live layout into what the user typed.
    let RawInput::Key { keycode, state } = keys[0] else {
        unreachable!()
    };
    let modifiers = ModifierState::from_mask(*state, keyboard.masks);
    assert_eq!(
        classify_keystroke(modifiers, |level| keyboard
            .mapping
            .keysym_at(*keycode, keysym_level(level))),
        Some(axon_core::RecordedKeystroke::Text { text: "a".into() }),
        "the recorded keycode resolves through this server's own layout"
    );

    // -- what follows from measurement two: our own delivery has to be excluded ------------------

    // The answer above is that an XTEST event is indistinguishable from a real one once the server
    // has it, which is exactly what the extension is for. So the exclusion cannot be a property of
    // the event; it is the ledger every synthetic event this daemon posts registers with. Here that
    // path is exercised for real: `X11Session::click` is what the daemon's own pointer rung calls.
    self_delivery().arm();
    session.click((CLICK_AT.0 as f64, CLICK_AT.1 as f64)).expect("a click posts");
    thread::sleep(Duration::from_millis(300));
    assert_eq!(
        queue.drain(Duration::ZERO).events.len(),
        0,
        "the daemon recorded its own click as the user's"
    );

    // And the exclusion is exact rather than a window: input from elsewhere arriving straight after
    // ours is still the user's.
    fake_input(&elsewhere, BUTTON_PRESS, BUTTON_PRIMARY, (0, 0));
    fake_input(&elsewhere, BUTTON_RELEASE, BUTTON_PRIMARY, (0, 0));
    let after = drain(&queue, 2);
    assert_eq!(
        after.len(),
        2,
        "a real click following the daemon's own must still be recorded"
    );
    self_delivery().disarm();

    record.stop();
    // Idempotent, and the observer's `stop` calls it after `quiesce` already has.
    record.stop();
}

/// Posts one synthetic event without going through `X11Session`, so the self-delivery ledger knows
/// nothing about it. This is the test's stand-in for input the daemon did not send.
fn fake_input(connection: &impl Connection, kind: u8, detail: u8, (x, y): (i16, i16)) {
    let root = connection.setup().roots[0].root;
    connection
        .xtest_fake_input(kind, detail, x11rb::CURRENT_TIME, root, x, y, 0)
        .expect("XTEST accepts the request");
    connection.sync().expect("the server processes it");
}

fn drain(queue: &RawQueue, at_least: usize) -> Vec<RawInput> {
    let deadline = Instant::now() + OBSERVED_WITHIN;
    let mut observed = Vec::new();
    while Instant::now() < deadline && observed.len() < at_least {
        observed.extend(
            queue
                .drain(Duration::from_millis(100))
                .events
                .into_iter()
                .map(|event| event.input),
        );
    }
    observed
}

/// A keycode this server's layout puts the letter `a` on, so the keystroke assertion is about the
/// decode rather than about which layout the lane happens to have loaded.
fn letter_keycode(keyboard: &axon_linux::x11::Keyboard) -> Option<u8> {
    (8..=255).find(|keycode| {
        keyboard
            .mapping
            .keysym_at(*keycode, keysym_level(ModifierState::default()))
            == Some(u32::from(b'a'))
    })
}

/// The decode is a pure function of bytes and needs no server, so the cases a real desktop would
/// only produce by accident are pinned here where they can be produced on purpose.
#[test]
fn a_wheel_notch_is_a_scroll_and_motion_only_counts_between_a_press_and_its_release() {
    let mut decoder = recording::Decoder::default();
    let event = |kind, detail| recording::CoreEvent {
        kind,
        detail,
        point: (10, 20),
        state: 0,
    };

    assert_eq!(
        decoder.observe(event(MOTION_NOTIFY_EVENT, 0)),
        None,
        "a pointer crossing the screen is not an action"
    );
    assert_eq!(
        decoder.observe(event(BUTTON_PRESS, BUTTON_PRIMARY)),
        Some(RawInput::Button {
            down: true,
            point: (10, 20)
        })
    );
    assert_eq!(
        decoder.observe(event(MOTION_NOTIFY_EVENT, 0)),
        Some(RawInput::Motion { point: (10, 20) }),
        "motion between a press and its release is a drag"
    );
    assert_eq!(
        decoder.observe(event(BUTTON_RELEASE, BUTTON_PRIMARY)),
        Some(RawInput::Button {
            down: false,
            point: (10, 20)
        })
    );
    assert_eq!(decoder.observe(event(MOTION_NOTIFY_EVENT, 0)), None);

    // X11 spells a wheel notch as a press and a release of button 4. Only the press is a notch.
    assert_eq!(
        decoder.observe(event(BUTTON_PRESS, 4)),
        Some(RawInput::Wheel {
            button: 4,
            point: (10, 20)
        })
    );
    assert_eq!(
        decoder.observe(event(BUTTON_RELEASE, 4)),
        None,
        "recording the release too would double every scroll"
    );
    // Nor does a wheel notch make the observer think a button is being held.
    assert_eq!(decoder.observe(event(MOTION_NOTIFY_EVENT, 0)), None);

    assert_eq!(
        decoder.observe(event(KEY_PRESS, 38)),
        Some(RawInput::Key {
            keycode: 38,
            state: 0
        })
    );
    assert_eq!(
        decoder.observe(event(2 + 1, 38)),
        None,
        "a key release carries nothing the recorder needs"
    );
}

/// The sequence the ledger exists for, at the level the listener sees it.
///
/// Our own release must not be what decides the user is no longer dragging: if it were, every real
/// motion sample after a click the daemon posted mid-gesture would be discarded, and the user's
/// drag would be recorded truncated.
#[test]
fn our_own_click_cannot_truncate_a_drag_the_user_is_making() {
    let mut decoder = recording::Decoder::default();
    let event = |kind, detail| recording::CoreEvent {
        kind,
        detail,
        point: (5, 6),
        state: 0,
    };

    self_delivery().arm();
    assert!(decoder.observe(event(BUTTON_PRESS, BUTTON_PRIMARY)).is_some());

    // The daemon posts a click of its own, mid-gesture. Both halves are registered before they are
    // sent, exactly as `X11Session::fake_input` registers them.
    self_delivery().expect(BUTTON_PRESS, BUTTON_PRIMARY);
    self_delivery().expect(BUTTON_RELEASE, BUTTON_PRIMARY);
    assert_eq!(decoder.observe(event(BUTTON_PRESS, BUTTON_PRIMARY)), None);
    assert_eq!(decoder.observe(event(BUTTON_RELEASE, BUTTON_PRIMARY)), None);

    assert_eq!(
        decoder.observe(event(MOTION_NOTIFY_EVENT, 0)),
        Some(RawInput::Motion { point: (5, 6) }),
        "a stamped release must not end the user's drag"
    );
    self_delivery().disarm();
}
