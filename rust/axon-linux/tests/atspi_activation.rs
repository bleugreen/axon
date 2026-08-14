//! Chromium-family activation over AT-SPI, against a provider built to withhold like one.
//!
//! `#[ignore]` by default, so it runs only where `dbus-daemon` exists: the Linux lane in CI, or a
//! developer's own machine.
//!
//! The test brings its own accessibility desktop rather than depending on an installed one, in the
//! shape of `x11_foreground.rs`. A private session bus, an object answering `org.a11y.Bus` that
//! points back at that same bus, a registry, and three applications whose only interesting
//! properties are where they park AT-SPI's null reference and whether they ever replace it. That is
//! Chromium's behaviour reduced to its essentials, and it is the only way to hold still the three
//! things the unit tests in `platform.rs` cannot reach, because each of them crosses the wire: that
//! the attributes call is issued against the application root, that the bounded wait ends when the
//! provider publishes, and that a provider which never publishes is reported as withholding rather
//! than as empty — while being asked exactly once, however many times it is captured.
//!
//! The second test is about the session rather than about one application. Chromium's first gate,
//! `org.a11y.Status.IsEnabled`, decides whether those applications are on the bus at all, and the
//! daemon publishes it in health-v1. Only a bus can show what matters about that reading: that it
//! is taken when it is asked for, so a session which switches accessibility off under a running
//! daemon is described as it is now rather than as it was at startup.
//!
//! Each test owns a private bus and an inner run of its own, because `DBUS_SESSION_BUS_ADDRESS` is
//! process-wide and is handed to a process at spawn rather than set from inside it. Within a test
//! every fake application shares the one bus and the scenarios run in order against one backend,
//! which is also what shows the per-application activation memo not leaking between applications.

#![cfg(target_os = "linux")]

use atspi::{ObjectRef, ObjectRefOwned};
use axon_core::{
    AppQuery, JsonRpcId, JsonRpcRequest, JsonRpcResponse, Node, PlatformBackend, Snapshot, reason,
};
use axon_linux::lifecycle::{SessionEnvironment, daemon_report};
use axon_linux::{ACTIVATION_TIMEOUT, CHILD_NOT_PUBLISHED, LinuxBackend, Router};
use std::{
    collections::HashMap,
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};
use x11rb::{
    COPY_DEPTH_FROM_PARENT, COPY_FROM_PARENT,
    connection::Connection,
    protocol::{
        Event,
        xproto::{
            AtomEnum, ChangeWindowAttributesAux, ConnectionExt as _, CreateGCAux, CreateWindowAux,
            EventMask, PropMode, WindowClass,
        },
    },
    wrapper::ConnectionExt as _,
};
use zbus::{connection, interface, names::UniqueName, zvariant::ObjectPath};

/// How long the publishing provider takes to answer with the tree it was asked for.
///
/// Nonzero on purpose. Chromium builds the tree in its renderer and pushes it to the browser
/// process, so publication trails the ask; a provider that flipped the moment it was asked would
/// let the backend pass this test without ever waiting, which is the half the probe measured at
/// 0.09s for Electron 33 and 1.12s for Chrome 151.
const PUBLISH_DELAY: Duration = Duration::from_millis(300);

/// Long enough that a loaded machine does not fail the test, short enough that spending the
/// activation bound cannot be mistaken for not spending it.
const PROMPTLY: Duration = Duration::from_secs(1);

/// The three applications on the fake desktop, named so that no name contains another: the
/// backend's application selection falls back to a substring match, and this test is not about
/// that rule.
const WAKES: &str = "Publishes When Asked";
const DEEP: &str = "Withholds Below The Window";
const SILENT: &str = "Never Publishes";

/// Object paths inside one application. Real providers number their objects below a fixed root;
/// these are the same shape, and every application uses them, which is exactly why an identity has
/// to carry the bus name as well as the path.
const ROOT: &str = "/org/a11y/atspi/accessible/root";
const WINDOW: &str = "/org/a11y/atspi/accessible/1";
const INNER: &str = "/org/a11y/atspi/accessible/2";
const CONTENT: &str = "/org/a11y/atspi/accessible/3";

/// Set on the child this binary re-executes: the only thing distinguishing the two runs, and the
/// path the inner run touches on its way out to prove it ran.
const INNER_RUN: &str = "AXON_ATSPI_HERMETIC_BUS";

/// The tests, each named twice: once by `#[test]` and once as the filter its inner run is launched
/// with. The two are checked against each other at runtime rather than trusted, because a filter
/// matching nothing is a passing libtest run.
const ACTIVATION: &str = "a_withholding_provider_is_woken_at_its_root_waited_for_and_asked_once";
const ACCESSIBILITY: &str = "a_session_that_switches_accessibility_off_reports_it_in_health";
const OCR: &str = "look_ocr_coordinates_and_screenshot_text_click_cross_the_real_linux_route";
const NO_OCR: &str = "missing_tesseract_preserves_semantics_and_reports_remediation";

const WINDOW_NAME: &str = "Withholding Window";
const INNER_NAME: &str = "Tool Bar";
const CONTENT_NAME: &str = "Published Content";

#[test]
#[ignore = "requires dbus-daemon; run with `cargo test -p axon-linux -- --ignored`"]
fn a_withholding_provider_is_woken_at_its_root_waited_for_and_asked_once() {
    // Two runs of this one function. The outer run owns the private bus and re-executes this binary
    // against it; the inner run is the test.
    //
    // The split is what keeps the arrangement sound. `DBUS_SESSION_BUS_ADDRESS` has to be in the
    // environment before anything in the process connects to a bus, and a process cannot safely put
    // it there for itself: `std::env::set_var` is unsound while any other thread might touch the
    // environment, and libtest runs this body on a worker thread with its own harness thread alive
    // beside it. Handing the variable to a child at spawn time is the same arrangement without the
    // unsafety, and it leaves the backend discovering the bus exactly the way it does in production
    // rather than through a seam that exists only for a test.
    if std::env::var_os(INNER_RUN).is_none() {
        return supervise_an_inner_run(ACTIVATION);
    }

    let desktop = Desktop::start();
    let mut backend =
        LinuxBackend::start().expect("the backend reaches the fake accessibility bus");

    // The shape the 2026-08-08 probe measured: a window claiming a child it has not built, which
    // arrives shortly after the application root is asked for its attributes.
    let (published, took) = timed(|| capture(&mut backend, WAKES));
    assert_eq!(
        desktop.provider(WAKES).attributes_asked(),
        vec![ROOT],
        "activation is one call, and it is made against the application root"
    );
    assert!(
        took >= PUBLISH_DELAY,
        "the capture has to outlast the provider's own publication delay, or it never waited; \
         took {took:?}"
    );
    assert!(
        took < ACTIVATION_TIMEOUT,
        "the wait ends when the provider publishes, not when the bound expires; took {took:?}"
    );
    let window = only_child(&published, "the woken application root");
    assert_eq!(window.name.as_deref(), Some(WINDOW_NAME));
    assert_eq!(
        window.truncation_reason, None,
        "a window that published what it claimed is complete"
    );
    let content = only_child(window, "the window that published on being asked");
    assert_eq!(
        content.name.as_deref(),
        Some(CONTENT_NAME),
        "the subtree that arrived after the ask is in the captured tree"
    );

    // A provider withholding one level below where the wait condition looks. The walk still reports
    // it, wherever it sits, and the capture must not spend the bound standing over it.
    let (deep, took) = timed(|| capture(&mut backend, DEEP));
    assert!(
        took < PROMPTLY,
        "a null reference deeper than the wait condition ends the wait early rather than being \
         waited on for the full bound; took {took:?}"
    );
    let window = only_child(&deep, "the application root of a deeper withholder");
    assert_eq!(
        window.truncation_reason, None,
        "the window published everything it claimed; the withholding is below it"
    );
    let inner = only_child(window, "the window of a deeper withholder");
    assert_eq!(inner.name.as_deref(), Some(INNER_NAME));
    assert_eq!(
        inner.truncation_reason.as_deref(),
        Some(CHILD_NOT_PUBLISHED),
        "the node that answered with the null reference is the node that carries the marker"
    );
    assert!(inner.children.is_empty());
    assert_eq!(
        inner.child_count,
        Some(0),
        "the walk asked, so it reports what it got rather than declining to count"
    );

    // A provider that never publishes. No real application can be made to do this on demand, and
    // it is the case the per-application activation memo exists for.
    let (first, took) = timed(|| capture(&mut backend, SILENT));
    assert!(
        took >= ACTIVATION_TIMEOUT,
        "a provider still withholding at the bound is given the whole bound; took {took:?}"
    );
    let window = only_child(&first, "the application root of a silent provider");
    assert!(
        window.children.is_empty() && window.child_count == Some(0),
        "nothing was published, so nothing is reported as a child"
    );
    assert_eq!(
        window.truncation_reason.as_deref(),
        Some(CHILD_NOT_PUBLISHED),
        "a subtree that was withheld is marked withheld rather than passing for an empty one"
    );

    let (again, took) = timed(|| capture(&mut backend, SILENT));
    assert_eq!(
        desktop.provider(SILENT).attributes_asked(),
        vec![ROOT],
        "the ask is remembered per application, so a provider that ignored it is not asked twice"
    );
    assert!(
        took < PROMPTLY,
        "an application that never publishes must not tax every later look with the bound; \
         took {took:?}"
    );
    let window = only_child(
        &again,
        "the application root of a silent provider, captured again",
    );
    assert_eq!(
        window.truncation_reason.as_deref(),
        Some(CHILD_NOT_PUBLISHED),
        "skipping the ask does not turn a withheld subtree into an empty one"
    );

    // Waking one application says nothing about another, and the memo is keyed to say so.
    assert_eq!(desktop.provider(DEEP).attributes_asked(), vec![ROOT]);

    leave_proof_of_the_inner_run();
}

/// A deterministic X11 top-level which is simultaneously the OCR image, the EWMH process bridge,
/// and the observable recipient of the foreground click.
struct OcrWindow {
    clicked: mpsc::Receiver<(i16, i16)>,
    stop: mpsc::Sender<()>,
    thread: Option<thread::JoinHandle<()>>,
}

impl OcrWindow {
    const X: i16 = 211;
    const Y: i16 = 173;
    const WIDTH: i16 = 520;
    const HEIGHT: i16 = 240;

    fn start() -> Self {
        let (stop, stopped) = mpsc::channel();
        let (click, clicked) = mpsc::channel();
        let (ready, waiting) = mpsc::channel();
        let thread = thread::spawn(move || run_ocr_window(stopped, click, ready));
        waiting
            .recv_timeout(PROMPTLY)
            .expect("the X11 window starts")
            .expect("the X11 fixture initializes");
        Self {
            clicked,
            stop,
            thread: Some(thread),
        }
    }
}

impl Drop for OcrWindow {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn run_ocr_window(
    stopped: mpsc::Receiver<()>,
    clicked: mpsc::Sender<(i16, i16)>,
    ready: mpsc::Sender<Result<(), String>>,
) {
    let started = (|| -> Result<_, String> {
        let (connection, screen) = x11rb::connect(None).map_err(|error| error.to_string())?;
        let setup = &connection.setup().roots[screen];
        let root = setup.root;
        let atom = |name: &str| {
            connection
                .intern_atom(false, name.as_bytes())
                .map_err(|error| error.to_string())?
                .reply()
                .map(|reply| reply.atom)
                .map_err(|error| error.to_string())
        };
        let supported = atom("_NET_SUPPORTED")?;
        let active = atom("_NET_ACTIVE_WINDOW")?;
        let clients = atom("_NET_CLIENT_LIST")?;
        let pid = atom("_NET_WM_PID")?;
        connection
            .change_window_attributes(
                root,
                &ChangeWindowAttributesAux::new()
                    .event_mask(EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY),
            )
            .map_err(|error| error.to_string())?
            .check()
            .map_err(|_| "another window manager already owns this X server".to_string())?;
        let window = connection
            .generate_id()
            .map_err(|error| error.to_string())?;
        connection
            .create_window(
                COPY_DEPTH_FROM_PARENT,
                window,
                root,
                OcrWindow::X,
                OcrWindow::Y,
                OcrWindow::WIDTH as u16,
                OcrWindow::HEIGHT as u16,
                0,
                WindowClass::INPUT_OUTPUT,
                COPY_FROM_PARENT,
                &CreateWindowAux::new()
                    .background_pixel(setup.white_pixel)
                    .event_mask(EventMask::BUTTON_PRESS | EventMask::BUTTON_RELEASE),
            )
            .map_err(|error| error.to_string())?;
        connection
            .change_property32(
                PropMode::REPLACE,
                window,
                pid,
                AtomEnum::CARDINAL,
                &[std::process::id()],
            )
            .map_err(|error| error.to_string())?;
        let publish = |property, kind, values: &[u32]| -> Result<(), String> {
            connection
                .change_property32(PropMode::REPLACE, root, property, kind, values)
                .map_err(|error| error.to_string())?;
            Ok(())
        };
        publish(supported, AtomEnum::ATOM, &[active, clients, pid])?;
        publish(clients, AtomEnum::WINDOW, &[window])?;
        publish(active, AtomEnum::WINDOW, &[window])?;
        connection
            .map_window(window)
            .map_err(|error| error.to_string())?;

        let font = connection
            .generate_id()
            .map_err(|error| error.to_string())?;
        connection
            .open_font(font, b"10x20")
            .map_err(|error| error.to_string())?;
        let gc = connection
            .generate_id()
            .map_err(|error| error.to_string())?;
        connection
            .create_gc(
                gc,
                window,
                &CreateGCAux::new()
                    .foreground(setup.black_pixel)
                    .background(setup.white_pixel)
                    .font(font),
            )
            .map_err(|error| error.to_string())?;
        connection
            .image_text8(window, gc, 70, 120, b"AXON CLICK")
            .map_err(|error| error.to_string())?;
        connection.flush().map_err(|error| error.to_string())?;
        connection.sync().map_err(|error| error.to_string())?;
        Ok((connection, root, window, [supported, active, clients]))
    })();
    let Ok((connection, root, window, properties)) = started else {
        let _ = ready.send(started.map(|_| ()));
        return;
    };
    let _ = ready.send(Ok(()));
    while stopped.try_recv().is_err() {
        match connection.poll_for_event() {
            Ok(Some(Event::ClientMessage(message))) if message.type_ == properties[1] => {
                let _ = connection.change_property32(
                    PropMode::REPLACE,
                    root,
                    properties[1],
                    AtomEnum::WINDOW,
                    &[message.window],
                );
                let _ = connection.flush();
            }
            Ok(Some(Event::ButtonPress(event))) => {
                let _ = clicked.send((event.root_x, event.root_y));
            }
            Ok(Some(_)) | Ok(None) => thread::sleep(Duration::from_millis(5)),
            Err(_) => break,
        }
    }
    for property in properties {
        let _ = connection.delete_property(root, property);
    }
    let _ = connection.destroy_window(window);
    let _ = connection.flush();
    let _ = connection.sync();
}

#[test]
#[ignore = "requires dbus-daemon, Xvfb, and Tesseract; run in the hermetic Linux lane"]
fn look_ocr_coordinates_and_screenshot_text_click_cross_the_real_linux_route() {
    if std::env::var_os(INNER_RUN).is_none() {
        return supervise_an_inner_run(OCR);
    }

    let _desktop = Desktop::start();
    let window = OcrWindow::start();
    let mut router = Router::new(
        LinuxBackend::start().expect("the backend reaches both halves of the fake desktop"),
    );
    let looked = success(router.request(JsonRpcRequest::new(
        Some(JsonRpcId::Integer(1)),
        "look",
        Some(serde_json::json!({
            "app": WAKES,
            "screenText": true,
            "screenshot": false,
            "frames": true
        })),
    )));
    assert!(
        looked.get("screenshot").is_none(),
        "OCR-only look must not return PNG bytes"
    );
    let recognized = looked["screenText"]
        .as_array()
        .expect("screenText is the shared array")
        .iter()
        .find(|item| {
            item["text"]
                .as_str()
                .is_some_and(|text| text.contains("AXON CLICK"))
        })
        .unwrap_or_else(|| panic!("Tesseract recognizes the deterministic label: {looked:#}"));
    let frame = &recognized["frame"];
    let (x, y, width, height) = (
        frame["x"].as_f64().unwrap(),
        frame["y"].as_f64().unwrap(),
        frame["width"].as_f64().unwrap(),
        frame["height"].as_f64().unwrap(),
    );
    assert!(
        x >= f64::from(OcrWindow::X) && y >= f64::from(OcrWindow::Y),
        "OCR coordinates are absolute screen coordinates, not window-relative: {frame}"
    );
    assert!(
        x + width <= f64::from(OcrWindow::X + OcrWindow::WIDTH)
            && y + height <= f64::from(OcrWindow::Y + OcrWindow::HEIGHT),
        "the absolute frame remains inside the captured top-level window: {frame}"
    );

    let clicked = success(router.request(JsonRpcRequest::new(
        Some(JsonRpcId::Integer(2)),
        "click",
        Some(serde_json::json!({
            "target": {"location": {"app": WAKES, "text": "AXON CLICK", "source": "screenshot"}},
            "deliveryPolicy": "foregroundPermitted"
        })),
    )));
    assert_eq!(clicked["resolution"]["best"]["source"], "screenshot");
    let event = window
        .clicked
        .recv_timeout(PROMPTLY)
        .expect("the existing Linux foreground XTest path delivers the OCR click");
    let expected = (
        (x + width / 2.0).round() as i16,
        (y + height / 2.0).round() as i16,
    );
    assert_eq!(
        event, expected,
        "the click effect lands at the center of the absolute frame returned by look"
    );
    leave_proof_of_the_inner_run();
}

#[test]
#[ignore = "requires dbus-daemon and Xvfb; run in the hermetic Linux lane"]
fn missing_tesseract_preserves_semantics_and_reports_remediation() {
    if std::env::var_os(INNER_RUN).is_none() {
        return supervise_an_inner_run(NO_OCR);
    }
    let _desktop = Desktop::start();
    let _window = OcrWindow::start();
    let mut router =
        Router::new(LinuxBackend::start().expect("the semantic daemon remains healthy"));
    let looked = success(router.request(JsonRpcRequest::new(
        Some(JsonRpcId::Integer(1)),
        "look",
        Some(serde_json::json!({
            "app": WAKES,
            "screenText": true,
            "screenshot": false,
            "frames": true
        })),
    )));
    assert!(
        looked.to_string().contains(WINDOW_NAME),
        "the semantic observation survives an unavailable OCR engine: {looked:#}"
    );
    assert!(looked.get("screenText").is_none());
    let unavailable = &looked["screenTextUnavailable"];
    assert_eq!(unavailable["code"], "capture-failed");
    let explanation = unavailable.to_string();
    assert!(
        explanation.contains("tesseract") && explanation.contains("install Tesseract OCR"),
        "the explicit remediation names the missing executable and how to restore OCR: {unavailable}"
    );
    leave_proof_of_the_inner_run();
}

fn success(response: Option<JsonRpcResponse>) -> serde_json::Value {
    let JsonRpcResponse::Success(success) = response.expect("the router answers") else {
        panic!("the request succeeds")
    };
    success.result
}

/// The session gate, from the bus it lives on to the document that publishes it.
///
/// `org.a11y.Status.IsEnabled` is a property of the running session, not a fact about this build,
/// and a daemon that answered from a value it read once at startup would describe a desktop that
/// no longer exists. The other half is what the document makes of it: a session answering false is
/// interactive, graphical, and degraded all at once, and reporting only the two booleans would
/// publish it as healthy while every Chromium-family application on it is missing from the bus.
#[test]
#[ignore = "requires dbus-daemon; run with `cargo test -p axon-linux -- --ignored`"]
fn a_session_that_switches_accessibility_off_reports_it_in_health() {
    if std::env::var_os(INNER_RUN).is_none() {
        return supervise_an_inner_run(ACCESSIBILITY);
    }

    let desktop = Desktop::start();
    let backend = LinuxBackend::start().expect("the backend reaches the fake accessibility bus");

    assert_eq!(
        backend.accessibility_enabled(),
        Some(true),
        "a session with accessibility switched on is read as such from its own bus"
    );

    desktop.switch_accessibility_off();

    assert_eq!(
        backend.accessibility_enabled(),
        Some(false),
        "the switch is read at the moment it is asked for rather than remembered from startup"
    );

    let report = daemon_report(
        "/run/user/1000/axon-v1.sock".into(),
        std::process::id(),
        &[],
        &wayland_session(),
        true,
        backend.accessibility_enabled(),
    );

    assert!(
        report.session.interactive && report.session.graphical,
        "the desktop is up and the bus answers; what is missing is every application that reads \
         the switch"
    );
    assert_eq!(report.session.accessibility_enabled, Some(false));
    assert_eq!(
        report.session.reason.as_deref(),
        Some(reason::ACCESSIBILITY_DISABLED),
        "a consumer branching on the reason sees the degradation the booleans cannot carry"
    );
    let detail = report
        .session
        .detail
        .expect("a disabled session explains itself to a person as well");
    assert!(
        detail.contains("org.a11y.Status.IsEnabled") && detail.contains("Chromium"),
        "the detail names the property and what it hides: {detail}"
    );

    leave_proof_of_the_inner_run();
}

/// The session environment a graphical Wayland desktop presents, with this test's own private bus
/// as the session bus. Built rather than read from the environment, so that whatever desktop state
/// the host running this test happens to have cannot decide what the health document says.
fn wayland_session() -> SessionEnvironment {
    SessionEnvironment {
        runtime_dir: Some("/run/user/1000".into()),
        session_type: Some("wayland".into()),
        wayland_display: Some("wayland-0".into()),
        x11_display: None,
        session_bus: std::env::var("DBUS_SESSION_BUS_ADDRESS").ok(),
    }
}

/// Records that an inner run reached the end of its body, which is what its supervisor checks: a
/// libtest filter that matches nothing exits successfully having run nothing.
fn leave_proof_of_the_inner_run() {
    let proof = std::env::var_os(INNER_RUN).expect("the inner run was told where to leave proof");
    std::fs::write(proof, "").expect("the proof that this body ran writes");
}

/// Starts the private bus and runs this same binary against it, with the address in its environment
/// from the moment it starts.
///
/// Its output is inherited rather than captured, so a failing assertion inside the inner run reads
/// as an ordinary test failure rather than as a child process that exited non-zero.
fn supervise_an_inner_run(test: &str) {
    let bus = SessionBus::start();
    let ran = bus.directory.join("inner-run-completed");
    let mut command = Command::new(std::env::current_exe().expect("this test binary's own path"));
    command
        .args([test, "--exact", "--ignored", "--nocapture"])
        .env(INNER_RUN, &ran)
        .env("DBUS_SESSION_BUS_ADDRESS", &bus.address);
    if test == NO_OCR {
        command.env("PATH", bus.directory.join("no-executables"));
    }
    let status = command.status().expect("this test binary re-executes");
    assert!(
        status.success(),
        "the run against the private bus failed; its output is above"
    );
    assert!(
        ran.exists(),
        "the inner run exited successfully without reaching the end of the test body -- a libtest \
         filter that matches nothing is a pass, so {test:?} has drifted from the name of the test \
         function and this test has been proving nothing"
    );
}

/// The application root of a captured snapshot: AT-SPI's application object, whose children are the
/// application's windows.
fn only_child<'a>(of: impl Captured<'a>, described: &str) -> &'a Node {
    let node = of.node();
    assert_eq!(
        node.children.len(),
        1,
        "{described} should have exactly one child, and published {:?}",
        node.children
            .iter()
            .map(|child| child.name.as_deref().unwrap_or("<unnamed>"))
            .collect::<Vec<_>>()
    );
    &node.children[0]
}

/// Lets `only_child` read a snapshot and a node the same way, so the assertions above stay about
/// the tree rather than about how to reach into one.
trait Captured<'a> {
    fn node(self) -> &'a Node;
}
impl<'a> Captured<'a> for &'a Snapshot {
    fn node(self) -> &'a Node {
        &self.app.windows[0].root
    }
}
impl<'a> Captured<'a> for &'a Node {
    fn node(self) -> &'a Node {
        self
    }
}

fn capture(backend: &mut LinuxBackend, application: &str) -> Snapshot {
    backend
        .capture(&AppQuery {
            process_id: None,
            name: Some(application.to_owned()),
            identifier: None,
        })
        .unwrap_or_else(|error| panic!("{application} captures: {error:?}"))
}

fn timed<T>(work: impl FnOnce() -> T) -> (T, Duration) {
    let started = Instant::now();
    let value = work();
    (value, started.elapsed())
}

/// What a fake provider does when an assistive technology asks its application root for attributes.
#[derive(Clone, Copy)]
enum OnAttributes {
    /// Chromium's behaviour: the withheld subtree arrives, a little later.
    PublishAfter(Duration),
    /// The behaviour no real application performs on demand, and the one the activation memo and
    /// the withheld marker both exist for.
    NeverPublish,
}

/// Where in its tree a provider parks AT-SPI's null reference.
#[derive(Clone, Copy)]
enum Withholds {
    /// The shape the probe measured: an application root holding one window whose only child is the
    /// null reference. This is what the backend's wait condition looks for.
    AtWindow,
    /// One level below where the wait condition looks. The walk must still report it, and the
    /// capture must not wait for it.
    BelowWindow,
}

/// One fake application's state, shared by every object it serves.
struct Provider {
    on_attributes: OnAttributes,
    /// When the withheld subtree becomes visible. `None` until the application root is asked for
    /// its attributes, and forever for a provider that does not publish.
    publishes_at: Mutex<Option<Instant>>,
    /// Every object path `GetAttributes` was called on, in order.
    attribute_calls: Mutex<Vec<&'static str>>,
}

impl Provider {
    fn new(on_attributes: OnAttributes) -> Self {
        Self {
            on_attributes,
            publishes_at: Mutex::new(None),
            attribute_calls: Mutex::new(Vec::new()),
        }
    }

    fn published(&self) -> bool {
        self.publishes_at
            .lock()
            .unwrap()
            .is_some_and(|at| Instant::now() >= at)
    }

    fn asked_for_attributes(&self, path: &'static str) {
        self.attribute_calls.lock().unwrap().push(path);
        if let OnAttributes::PublishAfter(delay) = self.on_attributes {
            // Only the first ask starts the clock, so a second one could not shorten the wait.
            self.publishes_at
                .lock()
                .unwrap()
                .get_or_insert_with(|| Instant::now() + delay);
        }
    }

    fn attributes_asked(&self) -> Vec<&'static str> {
        self.attribute_calls.lock().unwrap().clone()
    }
}

/// What an object answers `GetChildren` with.
enum Children {
    /// These, always.
    Always(Vec<ObjectRefOwned>),
    /// AT-SPI's null reference until the provider publishes, and these afterwards.
    Withheld(Vec<ObjectRefOwned>),
}

/// One object in a fake provider's tree: the whole of `org.a11y.atspi.Accessible` that a capture
/// touches, and nothing else.
struct Accessible {
    provider: Arc<Provider>,
    path: &'static str,
    role: &'static str,
    name: String,
    children: Children,
}

#[interface(name = "org.a11y.atspi.Accessible")]
impl Accessible {
    fn get_children(&self) -> Vec<ObjectRefOwned> {
        match &self.children {
            Children::Always(children) => children.clone(),
            Children::Withheld(children) if self.provider.published() => children.clone(),
            Children::Withheld(_) => vec![ObjectRefOwned::new(ObjectRef::Null)],
        }
    }

    /// The switch. Chromium reaches `OnExtendedPropertiesUsedInWebContent` from here and starts
    /// building the tree; the attributes themselves are beside the point, and are empty.
    fn get_attributes(&self) -> HashMap<String, String> {
        self.provider.asked_for_attributes(self.path);
        HashMap::new()
    }

    fn get_role_name(&self) -> String {
        self.role.to_owned()
    }

    /// Only `Accessible`, so the walk's optional interfaces are all absent and every node in this
    /// desktop is exactly what the tree says it is.
    fn get_interfaces(&self) -> Vec<String> {
        vec!["org.a11y.atspi.Accessible".to_owned()]
    }

    #[zbus(property)]
    fn name(&self) -> String {
        self.name.clone()
    }

    #[zbus(property)]
    fn description(&self) -> String {
        String::new()
    }
}

/// The object a client asks where the accessibility bus lives. Here it is the session bus itself:
/// the backend needs a bus that says where it is, not a second one.
struct A11yBus {
    address: String,
}

#[interface(name = "org.a11y.Bus")]
impl A11yBus {
    fn get_address(&self) -> String {
        self.address.clone()
    }
}

/// The first of Chromium's two gates, and a live property rather than a constant: a real session
/// switches accessibility on when an assistive technology starts and leaves it off otherwise, and
/// what the daemon owes a caller is the session's answer now.
struct A11yStatus {
    enabled: Arc<AtomicBool>,
}

#[interface(name = "org.a11y.Status")]
impl A11yStatus {
    #[zbus(property)]
    fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    #[zbus(property)]
    fn screen_reader_enabled(&self) -> bool {
        false
    }
}

/// The whole fake accessibility desktop, alive for as long as it is held: every application on the
/// bus this process was handed, and nothing else.
struct Desktop {
    providers: HashMap<&'static str, Arc<Provider>>,
    /// The session's accessibility switch, shared with the object serving `org.a11y.Status`.
    accessibility: Arc<AtomicBool>,
    /// Held open for the life of the test: dropping a connection takes its objects off the bus.
    connections: Vec<zbus::Connection>,
    /// Every connection above serves from this runtime's threads, so it outlives them.
    runtime: tokio::runtime::Runtime,
}

impl Desktop {
    fn start() -> Self {
        let address = std::env::var("DBUS_SESSION_BUS_ADDRESS")
            .expect("the outer run handed this process the address of its private bus");

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("a runtime for the fake providers");

        // On at the start, the way a session with a screen reader running answers.
        let accessibility = Arc::new(AtomicBool::new(true));
        let switch = accessibility.clone();
        let (providers, connections) = runtime.block_on(async move {
            let mut providers = HashMap::new();
            let mut connections = Vec::new();
            let mut applications = Vec::new();
            for (name, on_attributes, withholds) in [
                (
                    WAKES,
                    OnAttributes::PublishAfter(PUBLISH_DELAY),
                    Withholds::AtWindow,
                ),
                (DEEP, OnAttributes::NeverPublish, Withholds::BelowWindow),
                (SILENT, OnAttributes::NeverPublish, Withholds::AtWindow),
            ] {
                let (connection, provider, root) =
                    application(&address, name, on_attributes, withholds).await;
                providers.insert(name, provider);
                connections.push(connection);
                applications.push(root);
            }
            connections.push(registry(&address, applications, switch).await);
            (providers, connections)
        });

        Self {
            providers,
            accessibility,
            connections,
            runtime,
        }
    }

    fn provider(&self, application: &str) -> &Provider {
        self.providers[application].as_ref()
    }

    /// Switches the session's accessibility off under a daemon that is already running, which is
    /// the state a stock desktop with no assistive technology on it is in from the start.
    fn switch_accessibility_off(&self) {
        self.accessibility.store(false, Ordering::Relaxed);
    }
}

impl Drop for Desktop {
    fn drop(&mut self) {
        // Closing a connection cancels the tasks serving it, which has to happen inside the runtime
        // that spawned them rather than after the fields have started dropping in order.
        let _runtime = self.runtime.enter();
        self.connections.clear();
    }
}

/// One fake application: its own bus connection, so that its objects are addressed by their own
/// unique name exactly as a real application's are.
async fn application(
    address: &str,
    name: &'static str,
    on_attributes: OnAttributes,
    withholds: Withholds,
) -> (zbus::Connection, Arc<Provider>, ObjectRefOwned) {
    let connection = connection::Builder::address(address)
        .expect("the bus address parses")
        .build()
        .await
        .expect("an application connects to the fake bus");
    let bus: UniqueName<'static> = connection
        .unique_name()
        .expect("the bus gave the application a unique name")
        .clone()
        .into();
    let reference = |path: &'static str| {
        ObjectRef::new_owned(bus.clone(), ObjectPath::from_static_str_unchecked(path))
    };

    let provider = Arc::new(Provider::new(on_attributes));
    let tree = match withholds {
        Withholds::AtWindow => vec![
            (
                ROOT,
                "application",
                name,
                Children::Always(vec![reference(WINDOW)]),
            ),
            (
                WINDOW,
                "frame",
                WINDOW_NAME,
                Children::Withheld(vec![reference(CONTENT)]),
            ),
            (
                CONTENT,
                "document web",
                CONTENT_NAME,
                Children::Always(vec![]),
            ),
        ],
        Withholds::BelowWindow => vec![
            (
                ROOT,
                "application",
                name,
                Children::Always(vec![reference(WINDOW)]),
            ),
            (
                WINDOW,
                "frame",
                WINDOW_NAME,
                Children::Always(vec![reference(INNER)]),
            ),
            (
                INNER,
                "tool bar",
                INNER_NAME,
                Children::Withheld(vec![reference(CONTENT)]),
            ),
            (
                CONTENT,
                "document web",
                CONTENT_NAME,
                Children::Always(vec![]),
            ),
        ],
    };
    for (path, role, name, children) in tree {
        connection
            .object_server()
            .at(
                path,
                Accessible {
                    provider: provider.clone(),
                    path,
                    role,
                    name: name.to_owned(),
                    children,
                },
            )
            .await
            .expect("the object registers");
    }

    let root = reference(ROOT);
    (connection, provider, root)
}

/// The one object whose location is known in advance, and the `org.a11y.Bus` answer that leads a
/// client to it. Both live on one connection because the fake desktop has one bus.
async fn registry(
    address: &str,
    applications: Vec<ObjectRefOwned>,
    accessibility: Arc<AtomicBool>,
) -> zbus::Connection {
    connection::Builder::address(address)
        .expect("the bus address parses")
        .name("org.a11y.atspi.Registry")
        .expect("the registry name is well-known")
        .name("org.a11y.Bus")
        .expect("the accessibility bus name is well-known")
        .serve_at(
            ROOT,
            Accessible {
                // The registry publishes every application unconditionally, so its provider state
                // is never consulted.
                provider: Arc::new(Provider::new(OnAttributes::NeverPublish)),
                path: ROOT,
                role: "desktop frame",
                name: "main".to_owned(),
                children: Children::Always(applications),
            },
        )
        .expect("the registry root registers")
        .serve_at(
            "/org/a11y/bus",
            A11yBus {
                address: address.to_owned(),
            },
        )
        .expect("the bus locator registers")
        .serve_at(
            "/org/a11y/bus",
            A11yStatus {
                enabled: accessibility,
            },
        )
        .expect("the accessibility status registers")
        .build()
        .await
        .expect("the registry connects to the fake bus")
}

/// A private session bus with nothing on it but what this test puts there. Owned by the outer run,
/// which starts it before the process that uses it exists.
///
/// Its own configuration rather than the host's `session.conf`, so that no service activation
/// directory, and nothing the desktop happens to have installed, can join the conversation.
struct SessionBus {
    daemon: Child,
    directory: PathBuf,
    address: String,
}

impl SessionBus {
    fn start() -> Self {
        // `/tmp` rather than `std::env::temp_dir()`, because the address here becomes a Unix socket
        // path and those are capped near 108 bytes by `sockaddr_un`. A test runner's `TMPDIR` is
        // routinely deeper than that leaves room for, and `dbus-daemon` answers by refusing to
        // start at all. The counter keeps the tests in this binary off each other's socket
        // directory while staying short enough to spend on the same cap.
        static BUSES: AtomicUsize = AtomicUsize::new(0);
        let directory = PathBuf::from("/tmp").join(format!(
            "axon-atspi-{}-{}",
            std::process::id(),
            BUSES.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).expect("a directory for the bus socket");
        let config = directory.join("bus.conf");
        std::fs::write(&config, configuration(&directory)).expect("the bus configuration writes");

        let mut daemon = Command::new("dbus-daemon")
            .arg("--nofork")
            .arg("--print-address")
            .arg(format!("--config-file={}", config.display()))
            .stdout(Stdio::piped())
            .spawn()
            .expect("dbus-daemon is installed");
        let mut address = String::new();
        BufReader::new(daemon.stdout.take().expect("the daemon's stdout is piped"))
            .read_line(&mut address)
            .expect("the daemon prints the address it listens on");
        let address = address.trim().to_owned();
        assert!(
            !address.is_empty(),
            "dbus-daemon started but printed no address"
        );

        Self {
            daemon,
            directory,
            address,
        }
    }
}

impl Drop for SessionBus {
    fn drop(&mut self) {
        let _ = self.daemon.kill();
        let _ = self.daemon.wait();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn configuration(directory: &Path) -> String {
    format!(
        r#"<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:dir={directory}</listen>
  <policy context="default">
    <allow send_destination="*"/>
    <!-- A bus denies receiving by default, method replies and the driver's own name signals
         included, and a client whose reply is dropped simply waits. -->
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
"#,
        directory = directory.display()
    )
}
