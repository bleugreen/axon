//! The X11 half of the Linux pixel rung, against a real X server.
//!
//! `#[ignore]` by default, so it runs only where a display exists: the Xvfb lane in CI, or a
//! developer's own X11 session.
//!
//! What this can and cannot settle is worth being precise about. Whether a *toolkit* acts on a
//! background, window-targeted event is not a protocol question and cannot be asked here at all;
//! that is measured once by `scripts/linux-toolkit-acceptance/` and committed as the table in
//! `src/pixel.rs`. What is a protocol question, and what this settles against a real server, is
//! everything underneath that table: that the two delivery variants route the way the table
//! assumes, that a window is bound to the process that owns it and not to whatever sits at a
//! screen point, that coordinates convert through the window's own geometry, that a chord's
//! modifier state survives the wire, and that none of it disturbs the pointer or the focus.
//!
//! The test is its own X client rather than a toolkit, for the same reason the foreground test is
//! its own window manager: what this code touches is exactly the protocol conversation reproduced
//! here, and reproducing it needs nothing but the `Xvfb` binary.

#![cfg(target_os = "linux")]

use axon_core::KeyboardIntent;
use axon_linux::{pixel::SendVariant, x11::X11Session};
use std::{
    thread,
    time::{Duration, Instant},
};
use x11rb::{
    COPY_DEPTH_FROM_PARENT, COPY_FROM_PARENT,
    connection::Connection,
    protocol::{
        Event,
        xproto::{
            AtomEnum, ConnectionExt as _, CreateWindowAux, EventMask, KeyButMask, PropMode, Window,
            WindowClass,
        },
    },
    rust_connection::RustConnection,
    wrapper::ConnectionExt as _,
};

/// The process id the test's windows claim. Nothing resolves it against a real process: the
/// backend's X11 half only ever matches `_NET_WM_PID` values, and the AT-SPI half that turns a
/// process into an application needs the desktop session this test deliberately does without.
const TEST_PID: u32 = 525_252;

/// Where the listening window sits, and how big it is. Deliberately not at the origin, so a
/// conversion that forgot to subtract the window's own position would land somewhere visibly
/// wrong rather than accidentally right.
const LISTENING: Geometry = Geometry {
    x: 120,
    y: 90,
    width: 480,
    height: 320,
};
const SILENT: Geometry = Geometry {
    x: 700,
    y: 90,
    width: 200,
    height: 200,
};

/// Long enough for a real server on a loaded CI machine, short enough to fail rather than hang.
const OBSERVED_WITHIN: Duration = Duration::from_millis(1_500);

/// One test rather than several: these share one X server, one set of root properties, and one
/// stacking order, and Cargo runs the tests inside a binary in parallel by default.
#[test]
#[ignore = "requires an X server; run with DISPLAY set, for example under Xvfb"]
fn the_x11_session_binds_a_window_converts_into_it_and_delivers_without_disturbing_the_session() {
    let session = X11Session::connect().expect("an X server on DISPLAY");
    let client = TestClient::start();

    // -- binding ------------------------------------------------------------------------------

    let owned = session
        .windows_for_pid(TEST_PID)
        .expect("the client list reads");
    assert_eq!(
        owned,
        vec![client.listening, client.silent],
        "binding starts from the window manager's own list of what it manages, so the cover \
         window this client also owns is not a candidate"
    );
    assert!(
        session
            .windows_for_pid(TEST_PID + 1)
            .expect("the client list reads")
            .is_empty(),
        "a process with no managed window has nothing to bind"
    );

    let geometry = session
        .window_geometry(client.listening)
        .expect("the window geometry reads");
    assert_eq!(geometry.origin, (LISTENING.x, LISTENING.y));
    assert_eq!(geometry.size, (LISTENING.width, LISTENING.height));

    // The point the plan would aim at, and the conversion through that resolved geometry.
    let inside = (LISTENING.x + 40, LISTENING.y + 24);
    assert_eq!(
        session
            .managed_window_at(TEST_PID, inside)
            .expect("the window under a point reads"),
        Some(client.listening),
        "a point inside the window binds to the process's own top-level, not to whatever the \
         descent from the root happened to land in"
    );
    assert_eq!(
        session.window_point(client.listening, inside).unwrap(),
        (40, 24),
        "window-relative coordinates are the screen point converted through the window's origin"
    );

    // Occlusion, which is the only hit test this backend has. The cover window belongs to the
    // same client and is not managed, so a point under it binds to nothing rather than falling
    // through to the window it is covering.
    let covered = (SILENT.x + 20, SILENT.y + 20);
    assert_eq!(
        session
            .managed_window_at(TEST_PID, covered)
            .expect("the window under a point reads"),
        None,
        "a target covered at the point is not bound, which is what stops a delivery landing \
         somewhere the caller cannot see"
    );
    assert_eq!(
        session
            .managed_window_at(TEST_PID, (LISTENING.x - 10, LISTENING.y - 10))
            .expect("the window under a point reads"),
        None,
        "a point outside every window of the process binds to nothing"
    );

    // -- delivery -----------------------------------------------------------------------------

    let before = (
        session.pointer_location().expect("the pointer reads"),
        session.input_focus().expect("the input focus reads"),
    );

    // `targeted` reaches a client that selected the event on the destination window.
    session
        .send_click(client.listening, (40, 24), inside, SendVariant::Targeted)
        .expect("a click is sent");
    let clicks = client.collect(2);
    let [press, release] = &clicks[..] else {
        panic!("a targeted click is a press and a release, and {clicks:?} arrived")
    };
    let Event::ButtonPress(press) = press else {
        panic!("the first event of a click is a press, and {press:?} arrived")
    };
    assert!(
        matches!(release, Event::ButtonRelease(_)),
        "the second event of a click is a release, and {release:?} arrived"
    );
    assert!(
        press.response_type & 0x80 != 0,
        "every event this rung delivers carries send_event, which is the flag a toolkit is free \
         to filter on and the whole reason acceptance had to be measured"
    );
    assert_eq!(press.event, client.listening);
    assert_eq!((press.event_x, press.event_y), (40, 24));
    assert_eq!((press.root_x, press.root_y), inside);
    assert_eq!(press.detail, 1, "the primary button");

    // `targeted` reaches nobody on a window whose client selected nothing, and `owner` reaches
    // that client anyway. This is the distinction the acceptance table is keyed on: GTK 3 honours
    // only the second, and sending a toolkit the wrong one arrives as silence.
    session
        .send_click(client.silent, (10, 10), covered, SendVariant::Targeted)
        .expect("a click is sent");
    assert!(
        client.collect(1).is_empty(),
        "a targeted event on an unselected window is delivered to nobody"
    );
    session
        .send_click(client.silent, (10, 10), covered, SendVariant::Owner)
        .expect("a click is sent");
    assert_eq!(
        client.collect(2).len(),
        2,
        "an empty event mask routes to the client that created the window, whatever it selected"
    );

    // A chord's modifiers travel in the `state` field, because XSendEvent leaves the server's own
    // modifier state alone and a toolkit has nothing else to read them from. A chord sent without
    // it would arrive as the unmodified key: a different keystroke than the caller asked for,
    // rather than a failure to deliver.
    session
        .send_keyboard(
            client.listening,
            KeyboardIntent::Key("ctrl+a"),
            SendVariant::Targeted,
        )
        .expect("a chord is sent");
    let chord = client.collect(4);
    assert_eq!(
        chord.len(),
        4,
        "a chord is the modifier down, the key down and up, and the modifier up: {chord:?}"
    );
    let states: Vec<KeyButMask> = chord
        .iter()
        .map(|event| match event {
            Event::KeyPress(event) | Event::KeyRelease(event) => event.state,
            other => panic!("a chord delivers key events, and {other:?} arrived"),
        })
        .collect();
    assert!(
        !states[0].contains(KeyButMask::CONTROL),
        "X reports the state as it was immediately before each event, so the modifier's own \
         press carries the state without it"
    );
    assert!(
        states[1..]
            .iter()
            .all(|state| state.contains(KeyButMask::CONTROL)),
        "the key events between the modifier's press and its release carry it held: {states:?}"
    );

    // The invariants the contract requires of this rung, proved against a real server rather than
    // asserted. Nothing above went near the global pointer or keyboard device.
    assert_eq!(
        (
            session.pointer_location().expect("the pointer reads"),
            session.input_focus().expect("the input focus reads"),
        ),
        before,
        "window-targeted delivery leaves the real pointer and the X input focus exactly as it \
         found them"
    );

    client.stop();
}

#[derive(Clone, Copy)]
struct Geometry {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
}

/// An ordinary X client with two managed windows and one unmanaged cover, on its own connection.
///
/// A second connection is what makes the test mean anything: events sent by the backend's session
/// have to cross the server to a different client, exactly as they do to a real application.
struct TestClient {
    connection: RustConnection,
    root: Window,
    listening: Window,
    silent: Window,
    cover: Window,
    properties: Vec<u32>,
}

impl TestClient {
    fn start() -> Self {
        let (connection, screen) = x11rb::connect(None).expect("a second X connection");
        let root = connection.setup().roots[screen].root;
        let atom = |name: &str| {
            connection
                .intern_atom(false, name.as_bytes())
                .expect("an atom request")
                .reply()
                .expect("an atom")
                .atom
        };
        let supported = atom("_NET_SUPPORTED");
        let active_window = atom("_NET_ACTIVE_WINDOW");
        let client_list = atom("_NET_CLIENT_LIST");
        let window_pid = atom("_NET_WM_PID");

        let window = |geometry: Geometry, mask: EventMask| {
            let window = connection.generate_id().expect("a window id");
            connection
                .create_window(
                    COPY_DEPTH_FROM_PARENT,
                    window,
                    root,
                    geometry.x,
                    geometry.y,
                    geometry.width,
                    geometry.height,
                    0,
                    WindowClass::INPUT_OUTPUT,
                    COPY_FROM_PARENT,
                    &CreateWindowAux::new().event_mask(mask),
                )
                .expect("a window");
            connection
                .change_property32(
                    PropMode::REPLACE,
                    window,
                    window_pid,
                    AtomEnum::CARDINAL,
                    &[TEST_PID],
                )
                .expect("a pid property");
            connection.map_window(window).expect("a mapped window");
            window
        };
        let listening = window(
            LISTENING,
            EventMask::BUTTON_PRESS
                | EventMask::BUTTON_RELEASE
                | EventMask::KEY_PRESS
                | EventMask::KEY_RELEASE,
        );
        let silent = window(SILENT, EventMask::NO_EVENT);
        // Mapped last, so it is on top of `silent` without needing a stacking request. It is
        // absent from `_NET_CLIENT_LIST` on purpose: an unmanaged surface is exactly what a menu
        // or a tooltip is, and binding must refuse a point under one rather than reach past it.
        let cover = window(SILENT, EventMask::NO_EVENT);

        let publish = |property: u32, kind: AtomEnum, values: &[u32]| {
            connection
                .change_property32(PropMode::REPLACE, root, property, kind, values)
                .expect("a root property");
        };
        publish(
            supported,
            AtomEnum::ATOM,
            &[active_window, client_list, window_pid],
        );
        publish(client_list, AtomEnum::WINDOW, &[listening, silent]);
        // Sent *and* processed before the test reads any of it back over the other connection: a
        // flush alone only guarantees these requests left this client, and two clients' requests
        // carry no ordering against each other.
        connection.flush().expect("the setup flushes");
        connection.sync().expect("the server processes the setup");

        Self {
            connection,
            root,
            listening,
            silent,
            cover,
            properties: vec![supported, client_list],
        }
    }

    /// Up to `expected` events, or however many arrive before the deadline.
    ///
    /// Bounded on both sides on purpose. A case asserting that nothing arrives has to wait out the
    /// whole window to mean anything, and a case expecting events must not hang when they never
    /// come.
    fn collect(&self, expected: usize) -> Vec<Event> {
        let deadline = Instant::now() + OBSERVED_WITHIN;
        let mut events = Vec::new();
        while events.len() < expected && Instant::now() < deadline {
            match self.connection.poll_for_event() {
                Ok(Some(event)) => events.push(event),
                Ok(None) => thread::sleep(Duration::from_millis(5)),
                Err(error) => panic!("the test client's connection failed: {error}"),
            }
        }
        events
    }

    /// Leaves the server as it was found, so a second run starts from the same place.
    fn stop(self) {
        for property in self.properties {
            let _ = self.connection.delete_property(self.root, property);
        }
        for window in [self.listening, self.silent, self.cover] {
            let _ = self.connection.destroy_window(window);
        }
        let _ = self.connection.flush();
        let _ = self.connection.sync();
    }
}
