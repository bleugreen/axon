//! The X11 half of the Linux foreground transaction, against a real X server.
//!
//! `#[ignore]` by default, so it runs only where a display exists: the Xvfb lane in CI, or a
//! developer's own X11 session.
//!
//! The test is its own miniature EWMH window manager rather than depending on an installed one.
//! That is deliberate. A real desktop brings a toolkit, a compositor, and a session's worth of
//! variability, none of which this code touches; what it does touch is exactly the protocol
//! conversation reproduced here, and reproducing it needs nothing but the `Xvfb` binary. The
//! manager also removes everything it published on the way out, so the test can be run twice
//! against the same server and mean the same thing both times.

#![cfg(target_os = "linux")]

use axon_linux::x11::X11Session;
use std::{
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use x11rb::{
    COPY_DEPTH_FROM_PARENT, COPY_FROM_PARENT,
    connection::Connection,
    protocol::{
        Event,
        xproto::{
            AtomEnum, ChangeWindowAttributesAux, ConnectionExt as _, CreateWindowAux, EventMask,
            PropMode, Window, WindowClass,
        },
    },
    wrapper::ConnectionExt as _,
};

/// Process ids the managed windows claim. Nothing resolves them against real processes: the
/// backend's X11 half only ever matches `_NET_WM_PID` values, and the AT-SPI half that turns a
/// process into an application needs the desktop session this test deliberately does without.
const FIRST_PID: u32 = 424_242;
const SECOND_PID: u32 = 424_243;

/// Long enough for a cooperating manager on a loaded CI machine, short enough to fail rather than
/// hang when the conversation never happens.
const OBSERVED_WITHIN: Duration = Duration::from_secs(2);

/// One test rather than several, because a window manager is a singleton: only one X client may
/// hold `SubstructureRedirect` on the root, and Cargo runs tests in parallel by default.
#[test]
#[ignore = "requires an X server; run with DISPLAY set, for example under Xvfb"]
fn the_x11_session_reads_activates_dispatches_and_restores_the_foreground() {
    let session = X11Session::connect().expect("an X server on DISPLAY");

    // Before a manager publishes anything there is nothing to activate through, and the backend
    // must say so rather than offering a rung it cannot honour.
    assert!(
        !session.supports_ewmh(),
        "a bare X server has no window manager, so the foreground rung must stay withheld"
    );

    let manager = MiniWindowManager::start();

    assert!(
        session.supports_ewmh(),
        "a manager publishing _NET_ACTIVE_WINDOW and _NET_WM_PID makes the rung available"
    );

    // Capture the prior foreground, exactly as the transaction does first.
    let prior = session
        .active_window_pid()
        .expect("the active window reads");
    assert_eq!(prior, Some(FIRST_PID));

    // Activate the other window and prove it came forward, rather than trusting the request.
    assert!(
        session
            .activate_pid(SECOND_PID)
            .expect("activation is sent"),
        "a process with a managed window has something to raise"
    );
    assert!(
        settle(|| session.active_window_pid().ok().flatten() == Some(SECOND_PID)),
        "the manager honours _NET_ACTIVE_WINDOW and the activation is proved by reading it back"
    );

    // Dispatch, and watch the real cursor move: this is why the rung is foreground and not pixel.
    let origin = session.pointer_location().expect("the pointer reads");
    let target = (origin.0 + 37.0, origin.1 + 23.0);
    session.click(target).expect("a click is posted");
    let after_click = settle_value(|| {
        let now = session.pointer_location().ok()?;
        (near(now, target)).then_some(now)
    });
    assert!(
        after_click.is_some(),
        "XTest motion moves the real pointer, which is what the transaction has to undo"
    );

    // Hand the session back: the cursor first, then the window.
    session.warp_pointer(origin).expect("the pointer warps");
    assert!(
        settle(|| session
            .pointer_location()
            .is_ok_and(|now| near(now, origin))),
        "the pointer returns to where the dispatch found it"
    );

    assert!(session.activate_pid(FIRST_PID).expect("activation is sent"));
    assert!(
        settle(|| session.active_window_pid().ok().flatten() == prior),
        "the window that held the foreground before comes back"
    );

    // A process with no managed window cannot be raised, and the backend reports that rather than
    // claiming a request it never sent.
    assert!(
        !session
            .activate_pid(SECOND_PID + 1000)
            .expect("the client list reads"),
        "there is nothing to activate for a process with no window"
    );

    manager.stop();

    // The manager took its properties with it, so the next run starts from the same place.
    assert!(
        !session.supports_ewmh(),
        "the manager removed what it published"
    );
}

fn near(observed: (f64, f64), expected: (f64, f64)) -> bool {
    (observed.0 - expected.0).abs() < 0.5 && (observed.1 - expected.1).abs() < 0.5
}

fn settle(mut observed: impl FnMut() -> bool) -> bool {
    settle_value(|| observed().then_some(())).is_some()
}

fn settle_value<T>(mut observed: impl FnMut() -> Option<T>) -> Option<T> {
    let deadline = Instant::now() + OBSERVED_WITHIN;
    loop {
        if let Some(value) = observed() {
            return Some(value);
        }
        if Instant::now() >= deadline {
            return None;
        }
        thread::sleep(Duration::from_millis(10));
    }
}

/// A miniature EWMH window manager: enough of one for the conversation the backend actually has.
///
/// It publishes `_NET_SUPPORTED`, owns two windows carrying `_NET_WM_PID`, keeps
/// `_NET_CLIENT_LIST` and `_NET_ACTIVE_WINDOW`, and honours an `_NET_ACTIVE_WINDOW` client message
/// by moving the active window. That is the whole protocol surface this backend depends on.
struct MiniWindowManager {
    stop: mpsc::Sender<()>,
    thread: thread::JoinHandle<()>,
}

impl MiniWindowManager {
    fn start() -> Self {
        let (stop, stopped) = mpsc::channel();
        let (ready, is_ready) = mpsc::channel();
        let thread = thread::spawn(move || run_manager(&ready, &stopped));
        is_ready
            .recv_timeout(OBSERVED_WITHIN)
            .expect("the window manager starts")
            .expect("the window manager claims the root");
        Self { stop, thread }
    }

    fn stop(self) {
        let _ = self.stop.send(());
        let _ = self.thread.join();
    }
}

fn run_manager(ready: &mpsc::Sender<Result<(), String>>, stopped: &mpsc::Receiver<()>) {
    let started = start_manager();
    let (connection, root, atoms, windows) = match started {
        Ok(parts) => {
            let _ = ready.send(Ok(()));
            parts
        }
        Err(error) => {
            let _ = ready.send(Err(error));
            return;
        }
    };

    // Polled rather than blocked on `wait_for_event`, so a stop request is always noticed. Waking
    // a blocked manager would need an event of its own, and an event that turns out not to be
    // generated leaves the test hanging until CI kills it.
    while stopped.try_recv().is_err() {
        let event = match connection.poll_for_event() {
            Ok(Some(event)) => event,
            Ok(None) => {
                thread::sleep(Duration::from_millis(5));
                continue;
            }
            Err(_) => break,
        };
        // The one request a manager owes this backend: bring the named window forward.
        if let Event::ClientMessage(message) = event
            && message.type_ == atoms.active_window
        {
            let _ = connection.change_property32(
                PropMode::REPLACE,
                root,
                atoms.active_window,
                AtomEnum::WINDOW,
                &[message.window],
            );
            let _ = connection.flush();
        }
    }

    // Leave the server as it was found, so a second run of this test starts from the same place.
    for property in [atoms.supported, atoms.active_window, atoms.client_list] {
        let _ = connection.delete_property(root, property);
    }
    for window in windows {
        let _ = connection.destroy_window(window);
    }
    // `flush` only guarantees the teardown reached the socket, not that the server applied it. The
    // test reads the root back over a *different* connection as soon as `stop` returns, and two
    // clients' requests carry no ordering against each other, so the manager has to wait for the
    // server to have processed its own teardown before the thread ends. This is the same round
    // trip `X11Session::flush` makes for the same reason.
    let _ = connection.flush();
    let _ = connection.sync();
}

struct ManagerAtoms {
    supported: u32,
    active_window: u32,
    client_list: u32,
    window_pid: u32,
}

type Manager = (
    x11rb::rust_connection::RustConnection,
    Window,
    ManagerAtoms,
    Vec<Window>,
);

fn start_manager() -> Result<Manager, String> {
    let (connection, screen) = x11rb::connect(None).map_err(|error| error.to_string())?;
    let root = connection.setup().roots[screen].root;

    let atom = |name: &str| -> Result<u32, String> {
        connection
            .intern_atom(false, name.as_bytes())
            .map_err(|error| error.to_string())?
            .reply()
            .map(|reply| reply.atom)
            .map_err(|error| error.to_string())
    };
    let atoms = ManagerAtoms {
        supported: atom("_NET_SUPPORTED")?,
        active_window: atom("_NET_ACTIVE_WINDOW")?,
        client_list: atom("_NET_CLIENT_LIST")?,
        window_pid: atom("_NET_WM_PID")?,
    };

    // Only one client may hold this, which is what makes a window manager a singleton. Failing
    // here means something else is already managing the display.
    connection
        .change_window_attributes(
            root,
            &ChangeWindowAttributesAux::new()
                .event_mask(EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY),
        )
        .map_err(|error| error.to_string())?
        .check()
        .map_err(|_| "another window manager already owns this display".to_string())?;

    let mut windows = Vec::new();
    for pid in [FIRST_PID, SECOND_PID] {
        let window = connection
            .generate_id()
            .map_err(|error| error.to_string())?;
        connection
            .create_window(
                COPY_DEPTH_FROM_PARENT,
                window,
                root,
                0,
                0,
                200,
                200,
                0,
                WindowClass::INPUT_OUTPUT,
                COPY_FROM_PARENT,
                &CreateWindowAux::new(),
            )
            .map_err(|error| error.to_string())?;
        connection
            .change_property32(
                PropMode::REPLACE,
                window,
                atoms.window_pid,
                AtomEnum::CARDINAL,
                &[pid],
            )
            .map_err(|error| error.to_string())?;
        connection
            .map_window(window)
            .map_err(|error| error.to_string())?;
        windows.push(window);
    }

    let publish = |property: u32, kind: AtomEnum, values: &[u32]| -> Result<(), String> {
        connection
            .change_property32(PropMode::REPLACE, root, property, kind, values)
            .map_err(|error| error.to_string())?;
        Ok(())
    };
    publish(
        atoms.supported,
        AtomEnum::ATOM,
        &[atoms.active_window, atoms.client_list, atoms.window_pid],
    )?;
    publish(atoms.client_list, AtomEnum::WINDOW, &windows)?;
    publish(atoms.active_window, AtomEnum::WINDOW, &windows[..1])?;
    connection.flush().map_err(|error| error.to_string())?;

    Ok((connection, root, atoms, windows))
}
