use crate::{PointerTargetVerifier, x11::X11Session};
use atspi::{
    CoordType, ObjectRefOwned,
    proxy::{
        accessible::{AccessibleProxy, ObjectRefExt},
        bus::BusProxy,
        proxy_ext::ProxyExt,
    },
    zbus::{
        self,
        fdo::{DBusProxy, PropertiesProxy},
        names::{BusName, InterfaceName},
        proxy::CacheProperties,
    },
};
use axon_core::{
    AppQuery, Application, BackendError, Capability, CapabilityInfo, KeyboardIntent, Node,
    Observation, PlatformBackend, RecordedCall, Screenshot, Snapshot, SnapshotHandle, Window,
};
use std::{
    collections::{HashMap, HashSet},
    future::Future,
    pin::Pin,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

/// The well-known name of the AT-SPI registry, the one object whose location is known in advance.
/// Every other object is reached from it, addressed by the bus name it reports.
const REGISTRY: &str = "org.a11y.atspi.Registry";

const MAX_DEPTH: usize = 18;
const MAX_NODES: usize = 2_000;
const CALL_TIMEOUT: Duration = Duration::from_secs(2);

/// How long a provider is given to publish a tree it has claimed, and how often that is checked.
///
/// Chromium builds the tree in its renderer and pushes it to the browser process, so the answer is
/// neither immediate nor slow: the 2026-08-08 probe recorded in `docs/cross-platform.md` measured
/// 0.09s for Electron 33 and 1.12s for Chrome 151. The ceiling is generous against a loaded machine
/// and a heavy page. Only an application that is actually withholding waits at all, and only on the
/// first capture of it, so a provider that never publishes cannot tax every later `look`.
const ACTIVATION_TIMEOUT: Duration = Duration::from_secs(3);
const ACTIVATION_POLL: Duration = Duration::from_millis(50);

const NODE_LIMIT_REACHED: &str = "node limit reached";

/// Said of a node the walk never asked about, because it sits at [`MAX_DEPTH`]. Reporting it as a
/// childless leaf would be the same lie as reporting a withheld subtree as an empty one.
const DEPTH_LIMIT_REACHED: &str = "depth limit reached";

/// Said of a node whose provider answered with AT-SPI's null reference in place of a child.
///
/// States what was observed and diagnoses nothing. `Null` is AT-SPI's general sentinel for "no
/// object": a provider that has not built a subtree emits it, and so does one with an ordinary
/// hole in its child range — a cell not yet instantiated, a child destroyed mid-enumeration.
/// Those are different situations, but they leave the caller holding fewer children than the
/// provider claimed, and that is true of both and worth saying either way. A window that published
/// a menu bar and withheld everything else must not read as a window that contains only a menu
/// bar. Which answers are worth *waiting* on is a stricter question, and it is answered in
/// [`Actor::withholding`] rather than here.
const CHILD_NOT_PUBLISHED: &str = "the provider returned a null reference in place of a child";

/// The session fact that most often explains an application a caller cannot find.
///
/// Chromium and its embedders read `org.a11y.Status.IsEnabled` once at process start and never join
/// the accessibility bus while it is false. On such a session those applications are not thin —
/// they are absent, which is indistinguishable from a misspelled name unless the caller is told.
const ACCESSIBILITY_DISABLED: &str = "this session reports accessibility disabled \
     (org.a11y.Status.IsEnabled is false), so applications that read it at startup — Chromium, \
     Electron, and Chromium-backed webviews — are not on the bus at all";
const NO_APPLICATION_MATCHED: &str = "no AT-SPI application matched";
const NOTHING_ON_THE_BUS: &str = "no applications are on the accessibility bus";

/// How long the application-to-process map is trusted before it is read again.
///
/// Long enough that one foreground transaction reads it once rather than four times, and short
/// enough that a process id the kernel reused after an application exited cannot be believed for
/// long. A miss also forces a fresh read, so a newly launched application is found immediately.
const IDENTITY_FRESHNESS: Duration = Duration::from_secs(2);

const NO_X_DISPLAY: &str = "no X display is reachable from this session, so there is no synthetic \
     input device to deliver through";
const WAYLAND_SESSION: &str = "this is a Wayland session: the compositor does not permit \
     unrestricted synthetic input, and X11 cannot read or set the Wayland foreground even where \
     XWayland is running alongside";
const NO_WINDOW_MANAGER: &str = "this X11 session has no EWMH-capable window manager, so the \
     foreground application can be neither read nor activated";
const NO_XTEST: &str = "this X server does not provide the XTEST extension, so there is no way to \
     post synthetic input to it";

type Reply<T> = mpsc::Sender<Result<T, BackendError>>;
enum Command {
    Enumerate(Reply<Vec<Application>>),
    Identities(Reply<Vec<AppIdentity>>),
    Identity(AppQuery, Reply<Option<String>>),
    Capture(AppQuery, Reply<Snapshot>),
    Invoke(SnapshotHandle, String, Reply<()>),
    Read(SnapshotHandle, Reply<Option<String>>),
    Set(SnapshotHandle, String, Reply<()>),
    Focus(SnapshotHandle, Reply<()>),
}

/// An AT-SPI application paired with the process that owns it.
///
/// The process id is the bridge between this backend's two halves: AT-SPI knows applications by bus
/// name, EWMH knows windows by `_NET_WM_PID`, and the process is the only fact both agree on.
#[derive(Clone, Debug)]
struct AppIdentity {
    identity: String,
    process_id: u32,
}

/// Whether this session has a path to global input, and if not, the reason a caller is owed.
enum InputSession {
    /// A live X11 connection to an EWMH-capable window manager: the foreground rung exists here.
    Available(Box<X11Session>),
    Unavailable(&'static str),
}

/// What this session can be observed to provide. Every one of these is required, and each is
/// missing for its own reason, so a caller is told which.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SessionFacts {
    wayland: bool,
    x_display: bool,
    window_manager: bool,
    xtest: bool,
}

/// Why global input cannot be delivered in this session, or `None` when it can.
///
/// Pure, and separated from the probing above it, so the decision is tested on every host rather
/// than only where each of these conditions can be arranged — an X server without XTEST especially,
/// which no ordinary desktop and no CI lane will produce by accident.
///
/// Wayland outranks the rest, and is not redundant with them. Mutter under Wayland runs XWayland,
/// publishes EWMH for X11 clients, and injects XTest globally, so every other fact here can be true
/// while a Wayland-native application holds a focus X11 can neither see nor give back. A mechanism
/// that works while its proof quietly does not is the precise failure this contract exists to
/// refuse.
fn input_restriction(facts: SessionFacts) -> Option<&'static str> {
    if facts.wayland {
        return Some(WAYLAND_SESSION);
    }
    if !facts.x_display {
        return Some(NO_X_DISPLAY);
    }
    if !facts.window_manager {
        return Some(NO_WINDOW_MANAGER);
    }
    if !facts.xtest {
        return Some(NO_XTEST);
    }
    None
}

/// Observes the session once, at startup, and classifies it.
fn input_session() -> InputSession {
    // Asked before an X connection is attempted, because a Wayland session is one whether or not
    // XWayland happens to answer, and what XWayland could answer is about X11 clients alone.
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
    let x11 = (!wayland).then(X11Session::connect).flatten();
    let facts = SessionFacts {
        wayland,
        x_display: x11.is_some(),
        window_manager: x11.as_ref().is_some_and(X11Session::supports_ewmh),
        xtest: x11.as_ref().is_some_and(X11Session::supports_xtest),
    };
    match (input_restriction(facts), x11) {
        (None, Some(session)) => InputSession::Available(Box::new(session)),
        (Some(reason), _) => InputSession::Unavailable(reason),
        // Unreachable: no session is exactly what NO_X_DISPLAY reports.
        (None, None) => InputSession::Unavailable(NO_X_DISPLAY),
    }
}

pub struct LinuxBackend {
    tx: mpsc::Sender<Command>,
    input: InputSession,
    /// AT-SPI identity to process id, read on demand and refreshed when stale or missed.
    identities: Vec<AppIdentity>,
    identities_read: Option<Instant>,
}

impl LinuxBackend {
    pub fn start() -> Result<Self, BackendError> {
        let (tx, rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        thread::Builder::new()
            .name("axon-atspi".into())
            .spawn(move || {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build();
                match runtime {
                    Ok(rt) => rt.block_on(async move {
                        match Actor::connect().await {
                            Ok(mut actor) => {
                                let _ = ready_tx.send(Ok(()));
                                actor.run(rx).await;
                            }
                            Err(e) => {
                                let _ = ready_tx.send(Err(e));
                            }
                        }
                    }),
                    Err(e) => {
                        let _ = ready_tx.send(Err(operation("runtime", e)));
                    }
                }
            })
            .map_err(|e| operation("start AT-SPI actor", e))?;
        ready_rx
            .recv()
            .map_err(|_| operation("start AT-SPI actor", "actor exited"))??;
        // A missing or unusable X11 session is an ordinary state, not a startup failure: capture
        // and the semantic rung run on AT-SPI alone, and only global input is withheld.
        Ok(Self {
            tx,
            input: input_session(),
            identities: Vec::new(),
            identities_read: None,
        })
    }
    fn ask<T>(&self, make: impl FnOnce(Reply<T>) -> Command) -> Result<T, BackendError> {
        let (tx, rx) = mpsc::channel();
        self.tx
            .send(make(tx))
            .map_err(|_| operation("AT-SPI request", "actor exited"))?;
        rx.recv()
            .map_err(|_| operation("AT-SPI request", "actor exited"))?
    }

    /// The X11 session, or the reason this one cannot deliver global input.
    fn x11(&self, capability_needed: Capability) -> Result<&X11Session, BackendError> {
        match &self.input {
            InputSession::Available(session) => Ok(session.as_ref()),
            InputSession::Unavailable(reason) => Err(capability(capability_needed, reason)),
        }
    }

    fn input_restriction(&self) -> Option<&'static str> {
        match &self.input {
            InputSession::Available(_) => None,
            InputSession::Unavailable(reason) => Some(reason),
        }
    }

    fn read_identities(&mut self) -> Result<(), BackendError> {
        self.identities = self.ask(Command::Identities)?;
        self.identities_read = Some(Instant::now());
        Ok(())
    }

    /// Searches the application-to-process map, reading it again if it is stale or if the first
    /// look misses. A miss against a cached map may only mean the map is older than the
    /// application, and concluding "no such application" from that would be wrong.
    fn lookup<T>(
        &mut self,
        find: impl Fn(&AppIdentity) -> Option<T>,
    ) -> Result<Option<T>, BackendError> {
        let stale = self
            .identities_read
            .is_none_or(|read| read.elapsed() >= IDENTITY_FRESHNESS);
        if stale {
            self.read_identities()?;
        }
        if let Some(found) = self.identities.iter().find_map(&find) {
            return Ok(Some(found));
        }
        if stale {
            return Ok(None);
        }
        self.read_identities()?;
        Ok(self.identities.iter().find_map(&find))
    }
}

impl PlatformBackend for LinuxBackend {
    fn capabilities(&self) -> Result<Vec<CapabilityInfo>, BackendError> {
        let usable = [
            Capability::Enumerate,
            Capability::Capture,
            Capability::RetainedHandles,
            Capability::Invoke,
            Capability::ReadValue,
            Capability::SetValue,
            Capability::Focus,
        ];
        let unavailable = [
            (
                Capability::ObserveChanges,
                "AT-SPI event observation is not implemented",
            ),
            (
                Capability::Scroll,
                "AT-SPI has no portable delta-scroll operation",
            ),
            (
                Capability::Screenshot,
                "a desktop portal authorization flow is required",
            ),
            (
                Capability::HitTest,
                "AT-SPI point lookup is not implemented",
            ),
            (
                Capability::SerializeHistory,
                "live history serialization is not implemented",
            ),
            (
                Capability::ObserveGlobalInput,
                "global input observation is not implemented",
            ),
        ];
        // Synthetic input is the one pair whose availability is a fact about the running session
        // rather than about this build, and the same answer decides both the health document and
        // the dispatch ladder.
        let restriction = self.input_restriction();
        let input = [Capability::PointerInput, Capability::KeyboardInput].map(|capability| {
            CapabilityInfo {
                capability,
                usable: restriction.is_none(),
                restriction: restriction.map(str::to_string),
            }
        });
        Ok(usable
            .into_iter()
            .map(|capability| CapabilityInfo {
                capability,
                usable: true,
                restriction: None,
            })
            .chain(
                unavailable
                    .into_iter()
                    .map(|(capability, reason)| CapabilityInfo {
                        capability,
                        usable: false,
                        restriction: Some(reason.into()),
                    }),
            )
            .chain(input)
            .collect())
    }
    fn enumerate_applications(&self) -> Result<Vec<Application>, BackendError> {
        self.ask(Command::Enumerate)
    }
    fn capture(&mut self, app: &AppQuery) -> Result<Snapshot, BackendError> {
        self.ask(|r| Command::Capture(app.clone(), r))
    }
    fn invoke(&mut self, target: &SnapshotHandle, action: &str) -> Result<(), BackendError> {
        self.ask(|r| Command::Invoke(target.clone(), action.into(), r))
    }
    fn read_value(&self, target: &SnapshotHandle) -> Result<Option<String>, BackendError> {
        self.ask(|r| Command::Read(target.clone(), r))
    }
    fn set_value(&mut self, target: &SnapshotHandle, value: &str) -> Result<(), BackendError> {
        self.ask(|r| Command::Set(target.clone(), value.into(), r))
    }
    fn focus(&mut self, target: &SnapshotHandle) -> Result<(), BackendError> {
        self.ask(|r| Command::Focus(target.clone(), r))
    }
    fn scroll(&mut self, _: &SnapshotHandle, _: (f64, f64)) -> Result<(), BackendError> {
        Err(capability(
            Capability::Scroll,
            "AT-SPI has no portable delta-scroll operation",
        ))
    }
    fn observe(&mut self, _: &AppQuery, _: Duration) -> Result<Observation, BackendError> {
        Err(capability(Capability::ObserveChanges, "not implemented"))
    }
    fn wait_for_value(
        &mut self,
        _: &SnapshotHandle,
        _: &serde_json::Value,
        _: Duration,
    ) -> Result<Observation, BackendError> {
        Err(capability(
            Capability::ObserveChanges,
            "wait_for_value is not implemented",
        ))
    }
    fn pointer_click(&mut self, point: (f64, f64)) -> Result<(), BackendError> {
        self.x11(Capability::PointerInput)?.click(point)
    }
    fn pointer_drag(
        &mut self,
        _: (f64, f64),
        _: (f64, f64),
        _: Duration,
    ) -> Result<(), BackendError> {
        // A drag holds a button down across the whole gesture, so an interrupted one leaves the
        // session in a state no restoration here can describe. It needs its own capability and its
        // own story about a press held across a failure, and has neither yet.
        Err(capability(
            Capability::PointerInput,
            "pointer drag is not implemented on this backend",
        ))
    }
    /// The application is not named here: the transaction has already brought it forward and proved
    /// it, and XTest posts to whatever holds the focus regardless of what this call was told.
    fn keyboard(&mut self, _: &AppQuery, intent: KeyboardIntent<'_>) -> Result<(), BackendError> {
        self.x11(Capability::KeyboardInput)?.keyboard(intent)
    }
    fn screenshot(&mut self, _: &AppQuery) -> Result<Screenshot, BackendError> {
        Err(capability(
            Capability::Screenshot,
            "requires desktop portal authorization",
        ))
    }
    fn hit_test(&mut self, _: (f64, f64)) -> Result<Option<Node>, BackendError> {
        Err(capability(Capability::HitTest, "not implemented"))
    }
    fn recorded_calls(&self) -> Result<Vec<RecordedCall>, BackendError> {
        Err(capability(Capability::SerializeHistory, "not implemented"))
    }
    fn set_recording(&mut self, _: bool) -> Result<(), BackendError> {
        Err(capability(Capability::SerializeHistory, "not implemented"))
    }
    fn observe_global_input(&mut self, _: Duration) -> Result<Vec<RecordedCall>, BackendError> {
        Err(capability(
            Capability::ObserveGlobalInput,
            "global input observation is not implemented",
        ))
    }

    fn supports_foreground_transaction(&self) -> bool {
        matches!(self.input, InputSession::Available(_))
    }

    fn frontmost_application(&mut self) -> Result<Option<String>, BackendError> {
        let Some(process_id) = self.x11(Capability::Focus)?.active_window_pid()? else {
            return Ok(None);
        };
        match self.lookup(|app| (app.process_id == process_id).then(|| app.identity.clone()))? {
            Some(identity) => Ok(Some(identity)),
            // A window whose process has no AT-SPI application is a real foreground this backend
            // cannot name, and so cannot promise to give back. Answering `None` would tell the
            // transaction there was nothing to restore and leave the user's session where Axon
            // put it.
            None => Err(operation(
                "read the foreground application",
                format!(
                    "the foreground window belongs to process {process_id}, which exposes no \
                     AT-SPI application to name or restore"
                ),
            )),
        }
    }

    fn resolve_application(&mut self, app: &AppQuery) -> Result<Option<String>, BackendError> {
        self.ask(|r| Command::Identity(app.clone(), r))
    }

    fn activate_application(&mut self, identity: &str) -> Result<bool, BackendError> {
        let found = self.lookup(|app| (app.identity == identity).then_some(app.process_id))?;
        let Some(process_id) = found else {
            return Ok(false);
        };
        self.x11(Capability::Focus)?.activate_pid(process_id)
    }

    fn pointer_location(&mut self) -> Result<Option<(f64, f64)>, BackendError> {
        self.x11(Capability::PointerInput)?
            .pointer_location()
            .map(Some)
    }

    fn move_pointer(&mut self, to: (f64, f64)) -> Result<bool, BackendError> {
        self.x11(Capability::PointerInput)?.warp_pointer(to)?;
        Ok(true)
    }
}
impl PointerTargetVerifier for LinuxBackend {
    fn verify_pointer_target(
        &mut self,
        _: &SnapshotHandle,
        _: (f64, f64),
    ) -> Result<bool, BackendError> {
        Err(capability(Capability::HitTest, "not implemented"))
    }
}

struct Actor {
    connection: zbus::Connection,
    /// The session bus, kept past bus discovery because `org.a11y.Status` lives there and is what
    /// explains an application that is missing rather than thin.
    session: zbus::Connection,
    /// Applications this daemon has already asked to publish their tree.
    ///
    /// Activation is a one-way switch inside the application, so asking twice buys nothing, and
    /// an application that ignores the ask must not make every later `look` at it pay the wait.
    /// Keyed by AT-SPI identity, which carries the unique bus name: a restarted application owns a
    /// different one, so a stale entry can never suppress activation for the process that replaced
    /// it, and the set grows by one short string per application this daemon has ever captured.
    activated: HashSet<String>,
    retained: HashMap<String, Vec<ObjectRefOwned>>,
}
impl Actor {
    /// Opens the one accessibility-bus connection this backend uses, by asking the session bus
    /// where that bus lives.
    ///
    /// Deliberately hand-built rather than taken from `atspi`'s `AccessibilityConnection`. That
    /// constructor also stands up a peer-to-peer subsystem: it asks every registered application
    /// for a private socket address, opens a second D-Bus connection to each one that answers, and
    /// leaves a task repeating that on every name-owner change. This backend never reads a peer.
    /// It addresses every proxy by explicit destination over this single connection, which is the
    /// mechanism AXN-41 established as the one that actually crosses embedded-application
    /// boundaries. The peer subsystem was therefore cost without benefit, and it failed loudly
    /// against any participant that answers with an empty address — a running screen reader among
    /// them.
    async fn connect() -> Result<Self, BackendError> {
        let session = zbus::Connection::session()
            .await
            .map_err(|e| operation("connect session bus", e))?;
        let address = BusProxy::new(&session)
            .await
            .map_err(|e| operation("locate accessibility bus", e))?
            .get_address()
            .await
            .map_err(|e| operation("locate accessibility bus", e))?;
        let connection = zbus::connection::Builder::address(address.as_str())
            .map_err(|e| operation("connect AT-SPI", e))?
            .build()
            .await
            .map_err(|e| operation("connect AT-SPI", e))?;
        Ok(Self {
            connection,
            session,
            activated: HashSet::new(),
            retained: HashMap::new(),
        })
    }
    /// The registry's root accessible.
    ///
    /// Property caching is off because the registry implements the D-Bus properties interface
    /// incompletely, so a caching proxy fails to build against it.
    async fn registry(&self) -> Result<AccessibleProxy<'_>, zbus::Error> {
        AccessibleProxy::builder(&self.connection)
            .destination(REGISTRY)?
            .cache_properties(CacheProperties::No)
            .build()
            .await
    }
    async fn run(&mut self, rx: mpsc::Receiver<Command>) {
        while let Ok(command) = rx.recv() {
            match command {
                Command::Enumerate(r) => {
                    let _ = r.send(self.enumerate().await);
                }
                Command::Identities(r) => {
                    let _ = r.send(self.identities().await);
                }
                Command::Identity(q, r) => {
                    let _ = r.send(self.identity_of(&q).await);
                }
                Command::Capture(q, r) => {
                    let _ = r.send(self.capture(q).await);
                }
                Command::Invoke(h, a, r) => {
                    let _ = r.send(self.invoke(&h, &a).await);
                }
                Command::Read(h, r) => {
                    let _ = r.send(self.read(&h).await);
                }
                Command::Set(h, v, r) => {
                    let _ = r.send(self.set(&h, &v).await);
                }
                Command::Focus(h, r) => {
                    let _ = r.send(self.focus(&h).await);
                }
            }
        }
    }
    async fn roots(&self) -> Result<Vec<ObjectRefOwned>, BackendError> {
        let registry = timeout("registry", self.registry()).await?;
        let answered = timeout("enumerate applications", registry.get_children()).await?;
        Ok(published(answered).0)
    }
    /// The children a provider actually has, and whether it withheld any.
    async fn children(&self, object: &ObjectRefOwned) -> Result<Vec<ObjectRefOwned>, BackendError> {
        let proxy = timeout(
            "accessible proxy",
            object.as_accessible_proxy(&self.connection),
        )
        .await?;
        timeout("children", proxy.get_children()).await
    }
    /// Every application on the bus — or, when there are none and the session explains why, that
    /// explanation. A caller wondering where their applications went reaches this before capture.
    async fn enumerate(&self) -> Result<Vec<Application>, BackendError> {
        let mut out = Vec::new();
        for object in self.roots().await? {
            let proxy = timeout(
                "application proxy",
                object.as_accessible_proxy(&self.connection),
            )
            .await?;
            let name = timeout("application name", proxy.name()).await?;
            out.push(Application {
                name,
                identifier: Some(identity(&object)),
                windows: vec![],
            });
        }
        if out.is_empty()
            && let Some(explained) = nothing_on_the_bus(self.accessibility_enabled().await)
        {
            return Err(explained);
        }
        Ok(out)
    }
    /// Every AT-SPI application paired with the process that owns it.
    ///
    /// An application that cannot be asked for its process id is skipped rather than failing the
    /// whole read: one application exiting mid-enumeration must not blind the backend to the rest
    /// of the session.
    async fn identities(&self) -> Result<Vec<AppIdentity>, BackendError> {
        let dbus = timeout("D-Bus proxy", DBusProxy::new(&self.connection)).await?;
        let mut out = Vec::new();
        for object in self.roots().await? {
            let Some(bus) = object.name().cloned() else {
                continue;
            };
            let process_id = timeout(
                "application process id",
                dbus.get_connection_unix_process_id(BusName::Unique(bus)),
            )
            .await;
            if let Ok(process_id) = process_id {
                out.push(AppIdentity {
                    identity: identity(&object),
                    process_id,
                });
            }
        }
        Ok(out)
    }
    /// The canonical identity of the application a query names, matched by exactly the rules
    /// capture uses, so one request names one application across every tool.
    async fn identity_of(&self, q: &AppQuery) -> Result<Option<String>, BackendError> {
        Ok(self.select(q).await?.map(|(object, _)| identity(&object)))
    }
    /// `Ok(None)` is "nothing matched", which is a different answer from a failure to look.
    async fn select(&self, q: &AppQuery) -> Result<Option<(ObjectRefOwned, String)>, BackendError> {
        let mut partial = None;
        for object in self.roots().await? {
            let proxy = timeout(
                "application proxy",
                object.as_accessible_proxy(&self.connection),
            )
            .await?;
            let name = timeout("application name", proxy.name()).await?;
            let id_match = q
                .identifier
                .as_deref()
                .is_some_and(|id| id == identity(&object));
            let exact = q
                .name
                .as_deref()
                .is_some_and(|n| name.eq_ignore_ascii_case(n));
            if id_match || exact {
                return Ok(Some((object, name)));
            }
            if partial.is_none()
                && q.name
                    .as_deref()
                    .is_some_and(|n| name.to_lowercase().contains(&n.to_lowercase()))
            {
                partial = Some((object, name));
            }
        }
        Ok(partial)
    }
    async fn capture(&mut self, q: AppQuery) -> Result<Snapshot, BackendError> {
        let Some((root, name)) = self.select(&q).await? else {
            return Err(no_application_matched(self.accessibility_enabled().await));
        };
        let identifier = identity(&root);
        if !self.activated.contains(&identifier) && self.wake_provider(&root).await {
            self.activated.insert(identifier.clone());
        }
        let identifier = Some(identifier);
        let mut refs = Vec::new();
        let mut remaining = MAX_NODES;
        let node = self.node(root, 0, &mut remaining, &mut refs).await?;
        let snapshot = Snapshot::new(Application {
            name,
            identifier,
            windows: vec![Window {
                title: node.name.clone(),
                root: node,
            }],
        });
        self.retained.clear();
        self.retained.insert(snapshot.id.0.clone(), refs);
        Ok(snapshot)
    }
    /// Asks a provider that is withholding its tree to publish it, then waits boundedly for that.
    ///
    /// Chromium and everything embedding it — Electron, and Chromium-backed webviews — publish an
    /// application root and a window whose only child is AT-SPI's null reference until an assistive
    /// technology asks a node for its attributes or its relations. Either call reaches
    /// `AXPlatform::OnExtendedPropertiesUsedInWebContent` in Chromium, which is what turns the
    /// web-content accessibility mode on; the tree is then built in the renderer and pushed across,
    /// so the touch has to be followed by a wait rather than trusted to have already taken effect.
    ///
    /// Registering an AT-SPI event listener is not what does this, whatever the folklore says: the
    /// 2026-08-08 probe in `docs/cross-platform.md` found registration changes nothing observable
    /// about these applications. Nor can activation live on the readiness path, because the trigger
    /// is a call into one application's own tree. It belongs to the capture of that application,
    /// exactly like the MSAA touch the Windows backend performs before capturing a WebView2 target.
    ///
    /// A provider that never publishes costs its first capture the timeout and is then reported as
    /// it answers, carrying [`CHILD_NOT_PUBLISHED`] rather than passing for a complete empty tree.
    /// Later captures of it skip this entirely, because the caller remembers having asked.
    ///
    /// Returns whether the ask reached the application, which is what the caller may remember. A
    /// reply, an error reply, and a timeout on this side all count: the call was delivered, and
    /// the switch inside the application has been thrown or declined on its own terms. Only
    /// failing to build the proxy means nothing was sent, and remembering that as an ask would
    /// suppress activation for that application for the rest of the daemon's life.
    async fn wake_provider(&self, root: &ObjectRefOwned) -> bool {
        let Ok(proxy) = timeout(
            "accessible proxy",
            root.as_accessible_proxy(&self.connection),
        )
        .await
        else {
            return false;
        };
        // The reply is discarded because the call itself is the signal, and a provider that does
        // not implement attributes is not one that needed waking.
        let _ = timeout("attributes", proxy.get_attributes()).await;
        let deadline = Instant::now() + ACTIVATION_TIMEOUT;
        while self.withholding(root).await && Instant::now() < deadline {
            tokio::time::sleep(ACTIVATION_POLL).await;
        }
        true
    }
    /// Whether this application is still claiming a tree it has not published.
    ///
    /// Two levels deep, which is the shape the probe measured: the application root holds windows,
    /// and a window claims a child and answers with nothing but the null reference. It is the wait
    /// condition and nothing more — a provider that parks the null reference deeper than this ends
    /// the wait early rather than being missed, because the walk that follows carries
    /// [`CHILD_NOT_PUBLISHED`] on whichever node withheld, wherever it sits.
    ///
    /// Costs one round trip per window per poll, so a many-windowed application spends a few
    /// hundred D-Bus calls across a full wait. That is the price of the case it exists for, and it
    /// is paid once per application.
    async fn withholding(&self, root: &ObjectRefOwned) -> bool {
        let Ok(answered) = self.children(root).await else {
            return false;
        };
        let (windows, dropped) = published(answered);
        if published_nothing(&windows, dropped) {
            return true;
        }
        for window in &windows {
            if self.children(window).await.is_ok_and(|answered| {
                let (kids, dropped) = published(answered);
                published_nothing(&kids, dropped)
            }) {
                return true;
            }
        }
        false
    }
    /// Whether this session has accessibility switched on, or `None` when the bus will not say.
    async fn accessibility_enabled(&self) -> Option<bool> {
        let properties = PropertiesProxy::builder(&self.session)
            .destination("org.a11y.Bus")
            .ok()?
            .path("/org/a11y/bus")
            .ok()?
            .build()
            .await
            .ok()?;
        let status = InterfaceName::try_from("org.a11y.Status").ok()?;
        let value = timeout("accessibility status", properties.get(status, "IsEnabled"))
            .await
            .ok()?;
        bool::try_from(value).ok()
    }
    fn node<'a>(
        &'a self,
        object: ObjectRefOwned,
        depth: usize,
        remaining: &'a mut usize,
        refs: &'a mut Vec<ObjectRefOwned>,
    ) -> Pin<Box<dyn Future<Output = Result<Node, BackendError>> + 'a>> {
        Box::pin(async move {
            if *remaining == 0 {
                return Err(operation("capture", NODE_LIMIT_REACHED));
            }
            *remaining -= 1;
            refs.push(object.clone());
            let proxy = timeout(
                "accessible proxy",
                object.as_accessible_proxy(&self.connection),
            )
            .await?;
            let role = timeout("role", proxy.get_role_name()).await?;
            let name = timeout("name", proxy.name())
                .await
                .ok()
                .filter(|s| !s.is_empty());
            let description = timeout("description", proxy.description())
                .await
                .ok()
                .filter(|s| !s.is_empty());
            let proxies = timeout("interfaces", proxy.proxies()).await.ok();
            let actions = if let Some(p) = &proxies {
                match timeout("action interface", p.action()).await {
                    Ok(a) => timeout("actions", a.get_actions())
                        .await
                        .map(|v| v.into_iter().map(|x| x.name).collect())
                        .unwrap_or_default(),
                    Err(_) => vec![],
                }
            } else {
                vec![]
            };
            let value = if let Some(p) = &proxies {
                match timeout("text interface", p.text()).await {
                    Ok(t) => timeout("text", t.get_text(0, -1)).await.ok(),
                    Err(_) => None,
                }
            } else {
                None
            };
            let frame = if let Some(p) = &proxies {
                match timeout("component interface", p.component()).await {
                    Ok(c) => timeout("extents", c.get_extents(CoordType::Screen))
                        .await
                        .ok()
                        .and_then(|(x, y, w, h)| {
                            (w > 0 && h > 0).then_some(axon_core::Rect {
                                x: x.into(),
                                y: y.into(),
                                width: w.into(),
                                height: h.into(),
                            })
                        }),
                    Err(_) => None,
                }
            } else {
                None
            };
            let editable = if let Some(p) = &proxies {
                timeout("editable text interface", p.editable_text())
                    .await
                    .is_ok()
            } else {
                false
            };
            let depth_limit_reached = depth >= MAX_DEPTH;
            let asked = !depth_limit_reached && *remaining > 0;
            let answered = if asked {
                timeout("children", proxy.get_children())
                    .await
                    .unwrap_or_default()
            } else {
                vec![]
            };
            let (children_refs, dropped) = published(answered);
            // A node nobody asked about has no child count, rather than a count of zero. Saying it
            // is childless is the same lie as reporting a withheld subtree as an empty one.
            let child_count = asked.then_some(children_refs.len());
            let mut children = Vec::new();
            for child in children_refs {
                if *remaining == 0 {
                    break;
                }
                children.push(self.node(child, depth + 1, remaining, refs).await?);
            }
            Ok(Node {
                role,
                subrole: None,
                name: name.clone(),
                title: None,
                label: name,
                value,
                description,
                identifier: Some(identity(&object)),
                actions,
                frame,
                editable,
                children,
                child_count,
                truncation_reason: incompleteness(
                    *remaining == 0,
                    depth_limit_reached,
                    dropped > 0,
                ),
            })
        })
    }
    fn object(&self, handle: &SnapshotHandle) -> Result<&ObjectRefOwned, BackendError> {
        let (snapshot, index) = handle
            .0
            .split_once(':')
            .ok_or_else(|| operation("resolve handle", "malformed handle"))?;
        let index: usize = index
            .parse()
            .map_err(|_| operation("resolve handle", "malformed handle"))?;
        self.retained
            .get(snapshot)
            .and_then(|r| r.get(index))
            .ok_or_else(|| operation("resolve handle", "stale or evicted AT-SPI reference"))
    }
    async fn invoke(&self, h: &SnapshotHandle, requested: &str) -> Result<(), BackendError> {
        let object = self.object(h)?.clone();
        let proxy = timeout(
            "accessible proxy",
            object.as_accessible_proxy(&self.connection),
        )
        .await?;
        let action = timeout(
            "action interface",
            timeout("interfaces", proxy.proxies()).await?.action(),
        )
        .await?;
        let actions = timeout("actions", action.get_actions()).await?;
        let index = actions
            .iter()
            .position(|a| a.name.eq_ignore_ascii_case(requested))
            .ok_or_else(|| {
                capability(
                    Capability::Invoke,
                    "target does not expose the requested action",
                )
            })?;
        if timeout("invoke", action.do_action(index as i32)).await? {
            Ok(())
        } else {
            Err(operation("invoke", "provider rejected action"))
        }
    }
    async fn read(&self, h: &SnapshotHandle) -> Result<Option<String>, BackendError> {
        let object = self.object(h)?.clone();
        let proxy = timeout(
            "accessible proxy",
            object.as_accessible_proxy(&self.connection),
        )
        .await?;
        let p = timeout("interfaces", proxy.proxies()).await?;
        if let Ok(text) = timeout("text interface", p.text()).await {
            return timeout("read text", text.get_text(0, -1)).await.map(Some);
        }
        if let Ok(value) = timeout("value interface", p.value()).await {
            return timeout("read value", value.current_value())
                .await
                .map(|v| Some(v.to_string()));
        }
        Ok(None)
    }
    async fn set(&self, h: &SnapshotHandle, content: &str) -> Result<(), BackendError> {
        let object = self.object(h)?.clone();
        let proxy = timeout(
            "accessible proxy",
            object.as_accessible_proxy(&self.connection),
        )
        .await?;
        let p = timeout("interfaces", proxy.proxies()).await?;
        let editable = timeout("editable text interface", p.editable_text())
            .await
            .map_err(|_| capability(Capability::SetValue, "target is not editable"))?;
        if timeout("set text", editable.set_text_contents(content)).await? {
            Ok(())
        } else {
            Err(operation("set text", "provider rejected edit"))
        }
    }
    async fn focus(&self, h: &SnapshotHandle) -> Result<(), BackendError> {
        let object = self.object(h)?.clone();
        let proxy = timeout(
            "accessible proxy",
            object.as_accessible_proxy(&self.connection),
        )
        .await?;
        let p = timeout("interfaces", proxy.proxies()).await?;
        let component = timeout("component interface", p.component()).await?;
        if timeout("focus", component.grab_focus()).await? {
            Ok(())
        } else {
            Err(operation("focus", "provider rejected focus"))
        }
    }
}
async fn timeout<T, E>(
    name: &str,
    future: impl Future<Output = Result<T, E>>,
) -> Result<T, BackendError>
where
    E: std::fmt::Display,
{
    tokio::time::timeout(CALL_TIMEOUT, future)
        .await
        .map_err(|_| operation(name, "timed out"))?
        .map_err(|e| operation(name, e))
}
/// Splits what a provider answered into the children that exist and the number of references it
/// returned in place of one.
///
/// AT-SPI's null reference means "no object", and it must never become a node: it implements no
/// interfaces, so asking it for a role answers `UnknownMethod` and fails the whole capture rather
/// than yielding an empty branch. Dropping it is therefore unconditional, and how many were
/// dropped is reported rather than discarded so that neither caller has to re-derive it.
fn published(children: Vec<ObjectRefOwned>) -> (Vec<ObjectRefOwned>, usize) {
    let claimed = children.len();
    let children: Vec<ObjectRefOwned> = children.into_iter().filter(|c| !c.is_null()).collect();
    let dropped = claimed - children.len();
    (children, dropped)
}

/// Whether a provider answered with nothing but null references: it claimed a subtree and
/// published none of it.
///
/// The strict reading, and the only one worth waiting on. A partial answer — real children
/// alongside a null — is reported through [`CHILD_NOT_PUBLISHED`] but never waited on, because a
/// hole in a child range will not fill in however long anyone stands there, and the wait costs
/// [`ACTIVATION_TIMEOUT`].
fn published_nothing(published: &[ObjectRefOwned], dropped: usize) -> bool {
    dropped > 0 && published.is_empty()
}

/// What a caller is owed about a subtree that is not complete.
///
/// Ordered by how total the statement is. A walk that stopped counting has nothing to say about
/// depth or about the provider; a walk that stopped descending never asked the provider anything,
/// so it cannot report withholding either.
fn incompleteness(
    node_limit_reached: bool,
    depth_limit_reached: bool,
    child_not_published: bool,
) -> Option<String> {
    match (node_limit_reached, depth_limit_reached, child_not_published) {
        (true, _, _) => Some(NODE_LIMIT_REACHED.into()),
        (false, true, _) => Some(DEPTH_LIMIT_REACHED.into()),
        (false, false, true) => Some(CHILD_NOT_PUBLISHED.into()),
        (false, false, false) => None,
    }
}

/// Why nothing matched, said with the session fact that most often explains it.
fn no_application_matched(accessibility_enabled: Option<bool>) -> BackendError {
    match accessibility_enabled {
        Some(false) => operation(
            "select application",
            format!("{NO_APPLICATION_MATCHED}; {ACCESSIBILITY_DISABLED}"),
        ),
        _ => operation("select application", NO_APPLICATION_MATCHED),
    }
}

/// Why an enumeration came back empty, when the session explains it.
///
/// An empty desktop is an ordinary answer and stays one. An empty desktop on a session with
/// accessibility switched off is a broken session, and saying so here reaches the caller before
/// they have guessed at an application name.
fn nothing_on_the_bus(accessibility_enabled: Option<bool>) -> Option<BackendError> {
    (accessibility_enabled == Some(false)).then(|| {
        operation(
            "enumerate applications",
            format!("{NOTHING_ON_THE_BUS}; {ACCESSIBILITY_DISABLED}"),
        )
    })
}

/// The identity string Axon uses for an AT-SPI object.
///
/// AT-SPI names an object by a `(bus name, object path)` pair, and the path alone is not unique.
/// Every application's root object sits at the same path, so an identity that dropped the bus name
/// would make every application look like every other one — and the foreground transaction decides
/// what to activate and what to give back by comparing exactly these strings. The same holds inside
/// one snapshot: an application's WebKit content lives on a different bus name with its own path
/// space, so paths alone can collide within a single captured tree.
fn identity(object: &ObjectRefOwned) -> String {
    match object.name_as_str() {
        Some(bus) => format!("{bus}{}", object.path_as_str()),
        None => object.path_as_str().to_string(),
    }
}

pub(crate) fn operation(name: &str, error: impl std::fmt::Display) -> BackendError {
    BackendError::Operation {
        operation: name.into(),
        message: error.to_string(),
        diagnostic: None,
    }
}
pub(crate) fn capability(capability: Capability, reason: &str) -> BackendError {
    BackendError::Capability {
        capability,
        reason: reason.into(),
        diagnostic: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use atspi::ObjectRef;

    fn real(path: &'static str) -> ObjectRefOwned {
        ObjectRefOwned::from_static_str_unchecked(":1.7", path)
    }

    fn null() -> ObjectRefOwned {
        ObjectRefOwned::new(ObjectRef::Null)
    }

    #[test]
    fn the_null_reference_is_never_a_child() {
        // Walking it is what fails a Chromium capture outright: it implements no interfaces, so
        // the role call that opens every node answers UnknownMethod.
        let (children, _) = published(vec![
            real("/org/a11y/atspi/accessible/1"),
            null(),
            real("/org/a11y/atspi/accessible/2"),
        ]);
        assert_eq!(children.len(), 2);
        assert!(children.iter().all(|c| !c.is_null()));
    }

    #[test]
    fn every_dropped_reference_is_reported_and_only_a_total_one_is_worth_waiting_on() {
        // The shape Chromium presents: children claimed, none published. Reported, and waited on.
        let (children, dropped) = published(vec![null()]);
        assert!(dropped > 0 && published_nothing(&children, dropped));

        // A partial answer is reported and never waited on. Saying nothing would let a window that
        // published a menu bar and withheld everything else pass for a window containing a menu
        // bar; waiting on it would spend the activation timeout on a hole that will not fill in.
        let (children, dropped) = published(vec![real("/org/a11y/atspi/accessible/1"), null()]);
        assert_eq!(children.len(), 1);
        assert!(dropped > 0);
        assert!(!published_nothing(&children, dropped));

        // A genuinely childless node is a different fact again, and stays silent.
        let (children, dropped) = published(vec![]);
        assert!(children.is_empty() && dropped == 0);
        assert!(!published_nothing(&children, dropped));
    }

    #[test]
    fn incompleteness_is_ordered_by_how_total_the_statement_is() {
        assert_eq!(incompleteness(false, false, false), None);
        assert_eq!(
            incompleteness(false, false, true).as_deref(),
            Some(CHILD_NOT_PUBLISHED)
        );
        // A node at the depth limit was never asked about its children, so it is neither empty nor
        // able to report anything about the provider — the failure this change exists to stop.
        assert_eq!(
            incompleteness(false, true, false).as_deref(),
            Some(DEPTH_LIMIT_REACHED)
        );
        assert_eq!(
            incompleteness(true, true, true).as_deref(),
            Some(NODE_LIMIT_REACHED),
            "a walk that stopped counting cannot also speak for depth or for the provider"
        );
    }

    #[test]
    fn a_session_with_accessibility_off_says_so_instead_of_blaming_the_name() {
        // Chromium and its embedders read org.a11y.Status.IsEnabled once at startup, so on such a
        // session they are absent rather than thin, and the bare refusals below would send the
        // caller looking for a typo.
        for (enabled, bare) in [
            (Some(false), false),
            (Some(true), true),
            (None::<bool>, true),
        ] {
            let BackendError::Operation { message, .. } = no_application_matched(enabled) else {
                panic!("a miss is an operation failure");
            };
            assert!(message.starts_with(NO_APPLICATION_MATCHED));
            assert_eq!(message.contains(ACCESSIBILITY_DISABLED), !bare);
        }
    }

    #[test]
    fn an_empty_bus_is_explained_only_when_the_session_explains_it() {
        // An empty desktop is an ordinary answer; an empty desktop with accessibility off is a
        // broken session, and enumerate is where someone looks before guessing at a name.
        let explained = nothing_on_the_bus(Some(false)).expect("a disabled session is explained");
        assert!(matches!(
            explained,
            BackendError::Operation { ref message, .. }
                if message.starts_with(NOTHING_ON_THE_BUS) && message.contains(ACCESSIBILITY_DISABLED)
        ));
        assert!(nothing_on_the_bus(Some(true)).is_none());
        assert!(nothing_on_the_bus(None).is_none());
    }

    const USABLE: SessionFacts = SessionFacts {
        wayland: false,
        x_display: true,
        window_manager: true,
        xtest: true,
    };

    #[test]
    fn global_input_needs_a_display_a_window_manager_and_xtest() {
        assert_eq!(input_restriction(USABLE), None);
        assert_eq!(
            input_restriction(SessionFacts {
                x_display: false,
                ..USABLE
            }),
            Some(NO_X_DISPLAY)
        );
        assert_eq!(
            input_restriction(SessionFacts {
                window_manager: false,
                ..USABLE
            }),
            Some(NO_WINDOW_MANAGER)
        );
        // An X server can answer everything else and still refuse to synthesize input. Nothing on
        // an ordinary desktop, and nothing in the Xvfb lane, produces this by accident, so the
        // decision is checked here rather than left to a runtime nobody runs.
        assert_eq!(
            input_restriction(SessionFacts {
                xtest: false,
                ..USABLE
            }),
            Some(NO_XTEST)
        );
    }

    #[test]
    fn wayland_withholds_global_input_however_complete_the_x11_session_looks() {
        // XWayland satisfies every X11 fact here and still cannot see the focus that matters.
        assert_eq!(
            input_restriction(SessionFacts {
                wayland: true,
                ..USABLE
            }),
            Some(WAYLAND_SESSION)
        );
    }

    #[test]
    fn reports_wayland_restrictions_explicitly() {
        let unavailable = [
            (
                Capability::Scroll,
                "AT-SPI has no portable delta-scroll operation",
            ),
            (
                Capability::PointerInput,
                "requires compositor authorization",
            ),
        ];
        for (capability, reason) in unavailable {
            assert!(
                matches!(super::capability(capability, reason), BackendError::Capability { capability: c, .. } if c == capability)
            );
        }
    }
}
