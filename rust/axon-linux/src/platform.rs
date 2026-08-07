use crate::{PointerTargetVerifier, x11::X11Session};
use atspi::{
    AccessibilityConnection, CoordType, ObjectRefOwned,
    proxy::{accessible::ObjectRefExt, proxy_ext::ProxyExt},
    zbus::{fdo::DBusProxy, names::BusName},
};
use axon_core::{
    AppQuery, Application, BackendError, Capability, CapabilityInfo, KeyboardIntent, Node,
    Observation, PlatformBackend, RecordedCall, Screenshot, Snapshot, SnapshotHandle, Window,
};
use std::{
    collections::HashMap,
    future::Future,
    pin::Pin,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

const MAX_DEPTH: usize = 18;
const MAX_NODES: usize = 2_000;
const CALL_TIMEOUT: Duration = Duration::from_secs(2);

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

type Reply<T> = mpsc::Sender<Result<T, BackendError>>;
enum Command {
    Enumerate(Reply<Vec<Application>>),
    Identities(Reply<Vec<AppIdentity>>),
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
    Available(X11Session),
    Unavailable(&'static str),
}

/// Classifies the session once, at startup, along the axes that each independently withhold the
/// foreground rung.
///
/// The Wayland check is not redundant with the EWMH one. Mutter under Wayland runs XWayland and
/// does publish EWMH properties for X11 clients, and XTest still injects input globally, so this
/// backend could activate an X11 window, prove it came forward, and dispatch — while a
/// Wayland-native application held the focus it could neither see nor give back. A mechanism that
/// works while its proof quietly does not is the precise failure this contract exists to refuse.
fn input_session() -> InputSession {
    let Some(x11) = X11Session::connect() else {
        return InputSession::Unavailable(NO_X_DISPLAY);
    };
    if x11.under_wayland() {
        return InputSession::Unavailable(WAYLAND_SESSION);
    }
    if !x11.supports_ewmh() {
        return InputSession::Unavailable(NO_WINDOW_MANAGER);
    }
    InputSession::Available(x11)
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
            InputSession::Available(session) => Ok(session),
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
    connection: AccessibilityConnection,
    retained: HashMap<String, Vec<ObjectRefOwned>>,
}
impl Actor {
    async fn connect() -> Result<Self, BackendError> {
        Ok(Self {
            connection: AccessibilityConnection::new()
                .await
                .map_err(|e| operation("connect AT-SPI", e))?,
            retained: HashMap::new(),
        })
    }
    async fn run(&mut self, rx: mpsc::Receiver<Command>) {
        while let Ok(command) = rx.recv() {
            match command {
                Command::Enumerate(r) => {
                    let _ = r.send(self.enumerate().await);
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
        let registry = timeout("registry", self.connection.root_accessible_on_registry()).await?;
        timeout("enumerate applications", registry.get_children()).await
    }
    async fn enumerate(&self) -> Result<Vec<Application>, BackendError> {
        let mut out = Vec::new();
        for object in self.roots().await? {
            let proxy = timeout(
                "application proxy",
                object.as_accessible_proxy(self.connection.connection()),
            )
            .await?;
            let name = timeout("application name", proxy.name()).await?;
            out.push(Application {
                name,
                identifier: Some(object.path().to_string()),
                windows: vec![],
            });
        }
        Ok(out)
    }
    async fn select(&self, q: &AppQuery) -> Result<(ObjectRefOwned, String), BackendError> {
        let mut partial = None;
        for object in self.roots().await? {
            let proxy = timeout(
                "application proxy",
                object.as_accessible_proxy(self.connection.connection()),
            )
            .await?;
            let name = timeout("application name", proxy.name()).await?;
            let id_match = q
                .identifier
                .as_deref()
                .is_some_and(|id| id == object.path().as_str());
            let exact = q
                .name
                .as_deref()
                .is_some_and(|n| name.eq_ignore_ascii_case(n));
            if id_match || exact {
                return Ok((object, name));
            }
            if partial.is_none()
                && q.name
                    .as_deref()
                    .is_some_and(|n| name.to_lowercase().contains(&n.to_lowercase()))
            {
                partial = Some((object, name));
            }
        }
        partial.ok_or_else(|| operation("select application", "no AT-SPI application matched"))
    }
    async fn capture(&mut self, q: AppQuery) -> Result<Snapshot, BackendError> {
        let (root, name) = self.select(&q).await?;
        let identifier = Some(root.path().to_string());
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
    fn node<'a>(
        &'a self,
        object: ObjectRefOwned,
        depth: usize,
        remaining: &'a mut usize,
        refs: &'a mut Vec<ObjectRefOwned>,
    ) -> Pin<Box<dyn Future<Output = Result<Node, BackendError>> + 'a>> {
        Box::pin(async move {
            if *remaining == 0 {
                return Err(operation("capture", "node limit reached"));
            }
            *remaining -= 1;
            refs.push(object.clone());
            let proxy = timeout(
                "accessible proxy",
                object.as_accessible_proxy(self.connection.connection()),
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
            let children_refs = if depth < MAX_DEPTH && *remaining > 0 {
                timeout("children", proxy.get_children())
                    .await
                    .unwrap_or_default()
            } else {
                vec![]
            };
            let child_count = children_refs.len();
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
                identifier: Some(object.path().to_string()),
                actions,
                frame,
                editable,
                children,
                child_count: Some(child_count),
                truncation_reason: (*remaining == 0).then(|| "node limit reached".into()),
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
            object.as_accessible_proxy(self.connection.connection()),
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
            object.as_accessible_proxy(self.connection.connection()),
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
            object.as_accessible_proxy(self.connection.connection()),
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
            object.as_accessible_proxy(self.connection.connection()),
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
                matches!(super::capability(capability.clone(), reason), BackendError::Capability { capability: c, .. } if c == capability)
            );
        }
    }
}
