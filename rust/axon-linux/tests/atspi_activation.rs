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
//! One test rather than several, because `DBUS_SESSION_BUS_ADDRESS` is process-wide and is handed
//! to this process at spawn rather than set from inside it. Every fake application shares the one
//! bus, and the scenarios run in order against one backend, which is also what shows the
//! per-application activation memo not leaking between applications.

#![cfg(target_os = "linux")]

use atspi::{ObjectRef, ObjectRefOwned};
use axon_core::{AppQuery, Node, PlatformBackend, Snapshot};
use axon_linux::{ACTIVATION_TIMEOUT, CHILD_NOT_PUBLISHED, LinuxBackend};
use std::{
    collections::HashMap,
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
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

/// Set on the child this binary re-executes, and the only thing distinguishing the two runs.
const INNER_RUN: &str = "AXON_ATSPI_HERMETIC_BUS";

/// The one test, named twice: once by `#[test]` and once for the filter the inner run is launched
/// with. A mismatch is loud rather than silent, because a filter that matches nothing exits zero
/// and the outer run would pass having tested nothing.
const TEST: &str = "a_withholding_provider_is_woken_at_its_root_waited_for_and_asked_once";

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
        return supervise_an_inner_run();
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
}

/// Starts the private bus and runs this same binary against it, with the address in its environment
/// from the moment it starts.
///
/// Its output is inherited rather than captured, so a failing assertion inside the inner run reads
/// as an ordinary test failure rather than as a child process that exited non-zero.
fn supervise_an_inner_run() {
    let bus = SessionBus::start();
    let status = Command::new(std::env::current_exe().expect("this test binary's own path"))
        .args([TEST, "--exact", "--ignored", "--nocapture"])
        .env(INNER_RUN, "1")
        .env("DBUS_SESSION_BUS_ADDRESS", &bus.address)
        .status()
        .expect("this test binary re-executes");
    assert!(
        status.success(),
        "the run against the private bus failed; its output is above"
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

/// The first of Chromium's two gates, answered the way a session with accessibility switched on
/// answers it. The backend reads this only to explain an application it could not find.
struct A11yStatus;

#[interface(name = "org.a11y.Status")]
impl A11yStatus {
    #[zbus(property)]
    fn is_enabled(&self) -> bool {
        true
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
            connections.push(registry(&address, applications).await);
            (providers, connections)
        });

        Self {
            providers,
            connections,
            runtime,
        }
    }

    fn provider(&self, application: &str) -> &Provider {
        self.providers[application].as_ref()
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
async fn registry(address: &str, applications: Vec<ObjectRefOwned>) -> zbus::Connection {
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
        .serve_at("/org/a11y/bus", A11yStatus)
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
        // start at all.
        let directory = PathBuf::from("/tmp").join(format!("axon-atspi-{}", std::process::id()));
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
