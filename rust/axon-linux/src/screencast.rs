//! Dedicated ScreenCast/PipeWire capture actor.

use crate::portal::{LatestFrame, PipeWireFrame, PortalState, RestoreToken, TokenStore};
use axon_core::Screenshot;
use serde::Serialize;
use std::{
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

pub const INTERACTIVE_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Default)]
pub struct StopController {
    requested: AtomicBool,
    wake: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

impl StopController {
    fn request(&self) {
        self.requested.store(true, Ordering::Release);
        let wake = self.wake.lock().expect("ScreenCast stop wake poisoned");
        if let Some(wake) = wake.as_ref() {
            wake();
        }
    }

    fn clear(&self) {
        self.requested.store(false, Ordering::Release);
    }

    fn take(&self) -> bool {
        self.requested.swap(false, Ordering::AcqRel)
    }

    fn install_wake(&self, wake: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self.wake.lock().expect("ScreenCast stop wake poisoned") = wake.clone();
        if self.requested.load(Ordering::Acquire)
            && let Some(wake) = wake
        {
            wake();
        }
    }
}

type StopSignal = Arc<StopController>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CaptureError {
    AuthorizationRequired,
    TimedOut,
    Unavailable(String),
    Failed(String),
    NoFrame,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ScreenCaptureSourceType {
    Window,
}

struct Shared {
    state: PortalState,
    frame: LatestFrame,
    generation: u64,
}
struct Signal {
    shared: Mutex<Shared>,
    changed: Condvar,
}

#[derive(Clone)]
pub struct ScreenCastActor(Arc<ActorHandle>);

struct ActorHandle {
    signal: Arc<Signal>,
    command: mpsc::Sender<Command>,
    stop: StopSignal,
    shutting_down: Arc<AtomicBool>,
    request_lock: Mutex<()>,
    thread: Mutex<Option<thread::JoinHandle<()>>>,
    finished: Mutex<mpsc::Receiver<()>>,
}

enum Command {
    Capture { generation: u64, reauthorize: bool },
    Stop,
}

impl ScreenCastActor {
    pub fn spawn_production(store: TokenStore) -> Self {
        Self::spawn_with_driver(store, ProductionDriver)
    }
    pub fn spawn_with_driver<D: ScreenCastDriver>(store: TokenStore, driver: D) -> Self {
        let signal = Arc::new(Signal {
            shared: Mutex::new(Shared {
                state: PortalState::AuthorizationRequired,
                frame: LatestFrame::default(),
                generation: 0,
            }),
            changed: Condvar::new(),
        });
        let (command, commands) = mpsc::channel();
        let stop = Arc::new(StopController::default());
        let shutting_down = Arc::new(AtomicBool::new(false));
        let actor_signal = signal.clone();
        let actor_stop = stop.clone();
        let actor_shutting_down = shutting_down.clone();
        let (finished_tx, finished) = mpsc::channel();
        let thread = thread::Builder::new()
            .name("axon-screencast".into())
            .spawn(move || {
                actor_main(
                    driver,
                    store,
                    actor_signal,
                    commands,
                    actor_stop,
                    actor_shutting_down,
                );
                let _ = finished_tx.send(());
            })
            .expect("spawn ScreenCast actor");
        Self(Arc::new(ActorHandle {
            signal,
            command,
            stop,
            shutting_down,
            request_lock: Mutex::new(()),
            thread: Mutex::new(Some(thread)),
            finished: Mutex::new(finished),
        }))
    }
    pub fn state(&self) -> PortalState {
        self.0
            .signal
            .shared
            .lock()
            .expect("ScreenCast state poisoned")
            .state
            .clone()
    }
    pub fn capture(
        &self,
        reauthorize: bool,
        timeout: Duration,
    ) -> Result<ScreenCapture, CaptureError> {
        let _request = self
            .0
            .request_lock
            .lock()
            .expect("ScreenCast request lock poisoned");
        let deadline = Instant::now() + timeout.min(INTERACTIVE_TIMEOUT);
        let mut shared = self
            .0
            .signal
            .shared
            .lock()
            .expect("ScreenCast state poisoned");
        let reusable = !reauthorize
            && matches!(shared.state, PortalState::Streaming)
            && shared.frame.snapshot().is_some();
        if !reusable {
            if matches!(shared.state, PortalState::Starting | PortalState::Streaming) {
                self.0.stop.request();
            }
            shared.frame.clear();
            shared.generation = shared.generation.wrapping_add(1);
            let generation = shared.generation;
            shared.state = PortalState::Starting;
            if self
                .0
                .command
                .send(Command::Capture {
                    generation,
                    reauthorize,
                })
                .is_err()
            {
                shared.state = PortalState::Failed("ScreenCast actor stopped".into());
            }
            self.0.signal.changed.notify_all();
        }
        while matches!(shared.state, PortalState::Starting) && shared.frame.snapshot().is_none() {
            let now = Instant::now();
            if now >= deadline {
                shared.generation = shared.generation.wrapping_add(1);
                shared.state = PortalState::AuthorizationRequired;
                self.0.stop.request();
                return Err(CaptureError::AuthorizationRequired);
            }
            let (next, wait) = self
                .0
                .signal
                .changed
                .wait_timeout(shared, deadline - now)
                .expect("ScreenCast state poisoned");
            shared = next;
            if wait.timed_out() && shared.frame.snapshot().is_none() {
                shared.generation = shared.generation.wrapping_add(1);
                shared.state = PortalState::AuthorizationRequired;
                self.0.stop.request();
                return Err(CaptureError::AuthorizationRequired);
            }
        }
        if let Some(frame) = shared.frame.snapshot() {
            let source_width = frame.width;
            let source_height = frame.height;
            let image = frame
                .screenshot()
                .map_err(|e| CaptureError::Failed(format!("{e:?}")))?;
            return Ok(ScreenCapture {
                source: ScreenCaptureSource {
                    kind: "userAuthorizedScreenCast",
                    source_type: ScreenCaptureSourceType::Window,
                    width: source_width,
                    height: source_height,
                },
                image,
            });
        }
        match &shared.state {
            PortalState::AuthorizationRequired | PortalState::Starting => {
                Err(CaptureError::AuthorizationRequired)
            }
            PortalState::Unavailable(r) => Err(CaptureError::Unavailable(r.clone())),
            PortalState::Failed(r) => Err(CaptureError::Failed(r.clone())),
            PortalState::Streaming => Err(CaptureError::NoFrame),
        }
    }
}
impl Drop for ActorHandle {
    fn drop(&mut self) {
        self.shutting_down.store(true, Ordering::Release);
        self.stop.request();
        let _ = self.command.send(Command::Stop);
        let finished = self
            .finished
            .get_mut()
            .expect("ScreenCast completion lock poisoned")
            .recv_timeout(Duration::from_millis(250))
            .is_ok();
        if finished
            && let Some(thread) = self
                .thread
                .get_mut()
                .expect("ScreenCast thread lock poisoned")
                .take()
        {
            let _ = thread.join();
        }
        // A custom driver can violate the cancellation contract. Detaching after the short bound
        // keeps daemon teardown safe and responsive; production setup futures are dropped by select.
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ScreenCapture {
    pub source: ScreenCaptureSource,
    #[serde(serialize_with = "serialize_image")]
    pub image: Screenshot,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenCaptureSource {
    pub kind: &'static str,
    #[serde(rename = "type")]
    pub source_type: ScreenCaptureSourceType,
    pub width: u32,
    pub height: u32,
}

fn serialize_image<S: serde::Serializer>(
    image: &Screenshot,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    use base64::Engine;
    use serde::ser::SerializeStruct;
    let mut state = serializer.serialize_struct("ScreenCaptureImage", 4)?;
    state.serialize_field("mediaType", &image.media_type)?;
    state.serialize_field("width", &image.width)?;
    state.serialize_field("height", &image.height)?;
    state.serialize_field(
        "base64Data",
        &base64::engine::general_purpose::STANDARD.encode(&image.bytes),
    )?;
    state.end()
}
#[derive(Debug, Clone)]
pub enum DriverError {
    Cancelled,
    TimedOut,
    StaleRestore,
    Unavailable(String),
    Failed(String),
}
#[derive(Clone)]
pub struct StartedSession {
    pub restore_token: Option<RestoreToken>,
    pub source_id: Option<String>,
}

pub trait ScreenCastDriver: Send + 'static {
    fn run(
        &mut self,
        restore_token: Option<RestoreToken>,
        started: Arc<dyn Fn(StartedSession) + Send + Sync>,
        publish: Arc<dyn Fn(PipeWireFrame) + Send + Sync>,
        stopped: StopSignal,
    ) -> Result<(), DriverError>;
}

fn set_state(signal: &Signal, state: PortalState) {
    signal
        .shared
        .lock()
        .expect("ScreenCast state poisoned")
        .state = state;
    signal.changed.notify_all();
}
fn actor_main<D: ScreenCastDriver>(
    mut driver: D,
    store: TokenStore,
    signal: Arc<Signal>,
    commands: mpsc::Receiver<Command>,
    stopped: StopSignal,
    shutting_down: Arc<AtomicBool>,
) {
    while let Ok(command) = commands.recv() {
        match command {
            Command::Stop => break,
            Command::Capture {
                generation,
                reauthorize,
            } => {
                // A stop belongs only to the generation that observed it. Drain any signal left by
                // a caller whose timeout raced with driver completion before starting a retry.
                stopped.clear();
                let stored = if reauthorize {
                    None
                } else {
                    match store.load() {
                        Ok(stored) => stored.map(|(_, token)| token),
                        Err(error) => {
                            set_state(
                                &signal,
                                PortalState::Failed(format!(
                                    "could not load portal token: {error}"
                                )),
                            );
                            continue;
                        }
                    }
                };
                let run_once = |driver: &mut D, token, clear_missing: bool| {
                    let persistence_error = Arc::new(Mutex::new(None::<String>));
                    let started_error = persistence_error.clone();
                    let started_signal = signal.clone();
                    let started_generation = generation;
                    let started_store = store.clone();
                    let started = Arc::new(move |session: StartedSession| {
                        if started_signal
                            .shared
                            .lock()
                            .expect("ScreenCast state poisoned")
                            .generation
                            != started_generation
                        {
                            return;
                        }
                        let persisted = match session.restore_token {
                            Some(token) => {
                                started_store.replace(session.source_id.as_deref(), token)
                            }
                            None if clear_missing => started_store.clear(),
                            None => Ok(()),
                        };
                        if let Err(error) = persisted {
                            let message = format!("could not persist portal token: {error}");
                            *started_error
                                .lock()
                                .expect("persistence error lock poisoned") = Some(message.clone());
                            set_state(&started_signal, PortalState::Failed(message));
                        }
                    });
                    let publish_error = persistence_error.clone();
                    let publish_signal = signal.clone();
                    let publish_generation = generation;
                    let publish = Arc::new(move |new_frame: PipeWireFrame| {
                        if publish_error
                            .lock()
                            .expect("persistence error lock poisoned")
                            .is_some()
                        {
                            return;
                        }
                        let shared = publish_signal
                            .shared
                            .lock()
                            .expect("ScreenCast state poisoned");
                        if shared.generation != publish_generation {
                            return;
                        }
                        shared.frame.publish(new_frame);
                        drop(shared);
                        set_state(&publish_signal, PortalState::Streaming);
                    });
                    driver.run(token, started, publish, stopped.clone())
                };
                let first = run_once(&mut driver, stored.clone(), reauthorize);
                let result = if matches!(first, Err(DriverError::StaleRestore))
                    && stored.is_some()
                    && !shutting_down.load(Ordering::Acquire)
                {
                    run_once(&mut driver, None, true)
                } else {
                    first
                };
                if shutting_down.load(Ordering::Acquire) {
                    break;
                }
                let shared = signal.shared.lock().expect("ScreenCast state poisoned");
                if shared.generation != generation {
                    continue;
                }
                shared.frame.clear();
                drop(shared);
                match result {
                    Ok(())
                    | Err(
                        DriverError::Cancelled | DriverError::StaleRestore | DriverError::TimedOut,
                    ) => set_state(&signal, PortalState::AuthorizationRequired),
                    Err(DriverError::Unavailable(r)) => {
                        set_state(&signal, PortalState::Unavailable(r))
                    }
                    Err(DriverError::Failed(r)) => set_state(&signal, PortalState::Failed(r)),
                }
            }
        }
    }
}

fn extract_pipewire_chunk(
    bytes: &[u8],
    offset: usize,
    size: usize,
    stride: isize,
) -> Option<(Vec<u8>, isize)> {
    let end = offset.checked_add(size)?;
    (end <= bytes.len()).then(|| (bytes[offset..end].to_vec(), stride))
}

struct ProductionDriver;
impl ScreenCastDriver for ProductionDriver {
    fn run(
        &mut self,
        token: Option<RestoreToken>,
        started: Arc<dyn Fn(StartedSession) + Send + Sync>,
        publish: Arc<dyn Fn(PipeWireFrame) + Send + Sync>,
        stopped: StopSignal,
    ) -> Result<(), DriverError> {
        production::run(token, started, publish, stopped)
    }
}

mod production {
    use super::*;
    use ashpd::desktop::{
        PersistMode,
        screencast::{
            OpenPipeWireRemoteOptions, Screencast, SelectSourcesOptions, SourceType,
            StartCastOptions,
        },
    };
    use enumflags2::BitFlags;
    use pipewire as pw;
    use pw::spa::{self, pod::Pod};
    use std::os::fd::OwnedFd;

    struct Format {
        raw: spa::param::video::VideoInfoRaw,
    }

    /// How long the portal gets for the calls no human is part of.
    ///
    /// Reaching the portal, asking what it can capture, and creating a session are machine-speed
    /// operations. Giving them the interactive budget makes a portal that is simply not there look
    /// like a user who has not answered yet, and delays the refusal by the whole of that budget.
    const PORTAL_TIMEOUT: Duration = Duration::from_secs(5);

    /// How long a session is given to close before the driver stops waiting for it.
    const CLOSE_TIMEOUT: Duration = Duration::from_secs(1);

    /// What a completed negotiation hands to PipeWire.
    struct Negotiated {
        fd: OwnedFd,
        node: u32,
        restore_token: Option<String>,
        source_id: Option<String>,
    }

    pub fn run(
        token: Option<RestoreToken>,
        started: Arc<dyn Fn(StartedSession) + Send + Sync>,
        publish: Arc<dyn Fn(PipeWireFrame) + Send + Sync>,
        stopped: StopSignal,
    ) -> Result<(), DriverError> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_io()
            .enable_time()
            .build()
            .map_err(|e| DriverError::Failed(e.to_string()))?;

        // The session leaves the negotiation through an out-parameter rather than a return value,
        // which is what makes the close below reachable from every terminating path. Everything
        // that can end an authorization early -- the deadline, a stop request, a refusal -- drops
        // the future that owns the session, and `ashpd::desktop::Session` cannot close itself on
        // Drop, because closing is an async D-Bus call. An abandoned session is not merely untidy:
        // a client that leaves one open stops being shown a chooser for its later requests, so a
        // daemon that times out once can never ask for consent again.
        let mut session = None;
        let negotiated = runtime.block_on(negotiate(token.as_ref(), &mut session, &stopped));
        stopped.install_wake(None);

        let result = match negotiated {
            Err(error) => Err(error),
            Ok(stream) => {
                started(StartedSession {
                    restore_token: stream.restore_token.map(RestoreToken::new),
                    source_id: stream.source_id,
                });
                // Runs before the close deliberately: closing the session tears the stream down,
                // so the session has to outlive the capture as well as every failure.
                run_pipewire(stream.fd, stream.node, publish, stopped)
            }
        };

        if let Some(session) = session {
            let _ = runtime
                .block_on(async { tokio::time::timeout(CLOSE_TIMEOUT, session.close()).await });
        }
        result
    }

    /// Runs the portal handshake, publishing the session into `session` the moment it exists.
    ///
    /// Split by who is being waited on. Everything up to and including `create_session` is
    /// machine-speed and gets [`PORTAL_TIMEOUT`]; only the source chooser waits on a person, so
    /// only it spends the interactive budget and races the stop signal.
    async fn negotiate(
        token: Option<&RestoreToken>,
        session: &mut Option<ashpd::desktop::Session<Screencast>>,
        stopped: &StopSignal,
    ) -> Result<Negotiated, DriverError> {
        let restoring = token.is_some();
        let portal = bounded("reach the ScreenCast portal", Screencast::new(), restoring).await?;
        if !bounded(
            "list the portal's source types",
            portal.available_source_types(),
            restoring,
        )
        .await?
        .contains(SourceType::Window)
        {
            return Err(DriverError::Unavailable("WINDOW source unavailable".into()));
        }
        *session = Some(
            bounded(
                "create a ScreenCast session",
                portal.create_session(Default::default()),
                restoring,
            )
            .await?,
        );
        let live = session.as_ref().expect("the session was just created");

        let authorize = async {
            portal
                .select_sources(
                    live,
                    SelectSourcesOptions::default()
                        .set_sources(BitFlags::from_flag(SourceType::Window))
                        .set_multiple(false)
                        .set_persist_mode(PersistMode::ExplicitlyRevoked)
                        .set_restore_token(token.map(RestoreToken::expose)),
                )
                .await?
                .response()?;
            let streams = portal
                .start(live, None, StartCastOptions::default())
                .await?
                .response()?;
            let stream = streams.streams().first().ok_or_else(|| {
                ashpd::Error::Portal(ashpd::PortalError::NotFound(
                    "portal returned no stream".into(),
                ))
            })?;
            let node = stream.pipe_wire_node_id();
            let source_id = stream.id().map(str::to_owned);
            let restore_token = streams.restore_token().map(str::to_owned);
            let fd = portal
                .open_pipe_wire_remote(live, OpenPipeWireRemoteOptions::default())
                .await?;
            Ok::<_, ashpd::Error>(Negotiated {
                fd,
                node,
                restore_token,
                source_id,
            })
        };

        tokio::select! {
            result = authorize => result.map_err(|error| classify(error, restoring)),
            _ = tokio::time::sleep(INTERACTIVE_TIMEOUT) => Err(DriverError::TimedOut),
            _ = stop_requested(stopped) => Err(DriverError::Cancelled),
        }
    }

    /// Bounds one portal call that nobody is being asked to answer.
    async fn bounded<T>(
        what: &str,
        call: impl std::future::Future<Output = ashpd::Result<T>>,
        restoring: bool,
    ) -> Result<T, DriverError> {
        match tokio::time::timeout(PORTAL_TIMEOUT, call).await {
            Err(_) => Err(DriverError::Unavailable(format!(
                "the desktop portal did not answer within {}s when asked to {what}",
                PORTAL_TIMEOUT.as_secs()
            ))),
            Ok(Err(error)) => Err(classify(error, restoring)),
            Ok(Ok(value)) => Ok(value),
        }
    }

    /// Resolves when a stop is requested.
    ///
    /// The controller wakes this directly. What it replaces was a 25 ms timer asking six hundred
    /// times across a full interactive wait whether anything had happened, allocating a fresh
    /// timer each time round.
    async fn stop_requested(stopped: &StopSignal) {
        let notify = Arc::new(tokio::sync::Notify::new());
        let wake = notify.clone();
        // Installing a wake fires it immediately when a stop is already pending, so a stop that
        // arrived before this future existed is observed rather than waited through.
        stopped.install_wake(Some(Arc::new(move || wake.notify_one())));
        while !stopped.take() {
            notify.notified().await;
        }
    }

    fn run_pipewire(
        fd: OwnedFd,
        node: u32,
        publish: Arc<dyn Fn(PipeWireFrame) + Send + Sync>,
        stopped: StopSignal,
    ) -> Result<(), DriverError> {
        pw::init();
        let mainloop = pw::main_loop::MainLoopRc::new(None).map_err(fail)?;
        let context = pw::context::ContextRc::new(&mainloop, None).map_err(fail)?;
        let core = context.connect_fd_rc(fd, None).map_err(fail)?;
        let stream = pw::stream::StreamBox::new(
            &core,
            "axon-window-capture",
            pw::properties::properties! {
                *pw::keys::MEDIA_TYPE => "Video", *pw::keys::MEDIA_CATEGORY => "Capture",
                *pw::keys::MEDIA_ROLE => "Screen",
            },
        )
        .map_err(fail)?;
        let _listener = stream
            .add_local_listener_with_user_data(Format {
                raw: Default::default(),
            })
            .param_changed(|_, f, id, pod| {
                if id == spa::param::ParamType::Format.as_raw()
                    && let Some(pod) = pod
                {
                    let _ = f.raw.parse(pod);
                }
            })
            .process(move |stream, f| {
                let Some(mut buffer) = stream.dequeue_buffer() else {
                    return;
                };
                let Some(data) = buffer.datas_mut().first_mut() else {
                    return;
                };
                let size = f.raw.size();
                let format = match f.raw.format() {
                    spa::param::video::VideoFormat::BGRx => crate::portal::PackedFormat::Bgrx,
                    spa::param::video::VideoFormat::BGRA => crate::portal::PackedFormat::Bgra,
                    spa::param::video::VideoFormat::RGBx => crate::portal::PackedFormat::Rgbx,
                    spa::param::video::VideoFormat::RGBA => crate::portal::PackedFormat::Rgba,
                    _ => return,
                };
                let stride = data.chunk().stride() as isize;
                let offset = data.chunk().offset() as usize;
                let length = data.chunk().size() as usize;
                let Some(bytes) = data.data() else { return };
                if let Some((data, stride)) = extract_pipewire_chunk(bytes, offset, length, stride)
                {
                    publish(PipeWireFrame {
                        width: size.width,
                        height: size.height,
                        offset: 0,
                        stride,
                        format,
                        data,
                    });
                }
            })
            .register()
            .map_err(fail)?;
        let obj = spa::pod::object!(
            spa::utils::SpaTypes::ObjectParamFormat,
            spa::param::ParamType::EnumFormat,
            spa::pod::property!(
                spa::param::format::FormatProperties::MediaType,
                Id,
                spa::param::format::MediaType::Video
            ),
            spa::pod::property!(
                spa::param::format::FormatProperties::MediaSubtype,
                Id,
                spa::param::format::MediaSubtype::Raw
            ),
            spa::pod::property!(
                spa::param::format::FormatProperties::VideoFormat,
                Choice,
                Enum,
                Id,
                spa::param::video::VideoFormat::BGRx,
                spa::param::video::VideoFormat::BGRx,
                spa::param::video::VideoFormat::BGRA,
                spa::param::video::VideoFormat::RGBx,
                spa::param::video::VideoFormat::RGBA
            )
        );
        let values = spa::pod::serialize::PodSerializer::serialize(
            std::io::Cursor::new(Vec::new()),
            &spa::pod::Value::Object(obj),
        )
        .map_err(fail)?
        .0
        .into_inner();
        let mut params = [Pod::from_bytes(&values)
            .ok_or_else(|| DriverError::Failed("invalid format pod".into()))?];
        stream
            .connect(
                spa::utils::Direction::Input,
                Some(node),
                pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
                &mut params,
            )
            .map_err(fail)?;
        let raw_mainloop = mainloop.as_raw_ptr() as usize;
        // Keep the wake closure under StopController's mutex while it runs, so uninstalling it
        // below proves the raw main-loop pointer is no longer reachable before MainLoopRc drops.
        stopped.install_wake(Some(Arc::new(move || unsafe {
            pw::sys::pw_main_loop_quit(raw_mainloop as *mut pw::sys::pw_main_loop);
        })));
        mainloop.run();
        stopped.install_wake(None);
        stopped.clear();
        Ok(())
    }
    fn fail(e: impl ToString) -> DriverError {
        DriverError::Failed(e.to_string())
    }
    pub(super) fn classify(e: ashpd::Error, restoring: bool) -> DriverError {
        use ashpd::PortalError;

        match e {
            // ashpd keeps the portal response-code type private. A Response error is the
            // request-level cancellation/refusal boundary; transport and service failures use
            // the distinct variants handled below.
            ashpd::Error::Response(_) | ashpd::Error::Portal(PortalError::Cancelled(_)) => {
                DriverError::Cancelled
            }
            ashpd::Error::Portal(PortalError::NotFound(message))
                if message == "WINDOW source unavailable" =>
            {
                DriverError::Unavailable(message)
            }
            ashpd::Error::Portal(PortalError::InvalidArgument(_) | PortalError::NotFound(_))
                if restoring =>
            {
                DriverError::StaleRestore
            }
            error @ (ashpd::Error::PortalNotFound(_) | ashpd::Error::RequiresVersion(_, _)) => {
                DriverError::Unavailable(error.to_string())
            }
            error => DriverError::Failed(error.to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::portal::PackedFormat;
    use std::{collections::VecDeque, sync::atomic::AtomicUsize};

    enum Action {
        Fail(DriverError),
        Delay(Duration),
        LateStream(Duration),
        Stream(Option<mpsc::Receiver<()>>),
    }

    struct Mock {
        actions: VecDeque<Action>,
        calls: Arc<AtomicUsize>,
        tokens: Arc<Mutex<Vec<bool>>>,
    }

    impl ScreenCastDriver for Mock {
        fn run(
            &mut self,
            token: Option<RestoreToken>,
            started: Arc<dyn Fn(StartedSession) + Send + Sync>,
            publish: Arc<dyn Fn(PipeWireFrame) + Send + Sync>,
            stopped: StopSignal,
        ) -> Result<(), DriverError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.tokens.lock().unwrap().push(token.is_some());
            match self.actions.pop_front().expect("unexpected driver run") {
                Action::Fail(error) => Err(error),
                Action::Delay(duration) => {
                    thread::sleep(duration);
                    Err(DriverError::TimedOut)
                }
                Action::LateStream(duration) => {
                    thread::sleep(duration);
                    started(StartedSession {
                        restore_token: Some(RestoreToken::new("late")),
                        source_id: Some("late-source".into()),
                    });
                    publish(frame());
                    Ok(())
                }
                Action::Stream(ended) => {
                    started(StartedSession {
                        restore_token: Some(RestoreToken::new("next")),
                        source_id: Some("source".into()),
                    });
                    publish(frame());
                    if let Some(ended) = ended {
                        let _ = ended.recv();
                    } else {
                        while !stopped.take() {
                            thread::sleep(Duration::from_millis(1));
                        }
                    }
                    Ok(())
                }
            }
        }
    }

    fn frame() -> PipeWireFrame {
        PipeWireFrame {
            width: 1,
            height: 1,
            offset: 0,
            stride: 4,
            format: PackedFormat::Rgba,
            data: vec![1, 2, 3, 255],
        }
    }

    fn actor(actions: Vec<Action>) -> (ScreenCastActor, Arc<AtomicUsize>, Arc<Mutex<Vec<bool>>>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let tokens = Arc::new(Mutex::new(Vec::new()));
        let store = TokenStore::at(tempfile::tempdir().unwrap().keep().join("token"));
        let actor = ScreenCastActor::spawn_with_driver(
            store,
            Mock {
                actions: actions.into(),
                calls: calls.clone(),
                tokens: tokens.clone(),
            },
        );
        (actor, calls, tokens)
    }

    #[test]
    fn pipewire_chunk_extraction_honors_offset_size_and_negative_stride() {
        assert_eq!(
            extract_pipewire_chunk(&[9, 9, 1, 2, 3, 4, 8], 2, 4, -4),
            Some((vec![1, 2, 3, 4], -4))
        );
        assert_eq!(extract_pipewire_chunk(&[1, 2], 1, 2, 4), None);
    }

    #[test]
    fn spawn_and_state_are_noninteractive() {
        let (actor, calls, _) = actor(vec![Action::Fail(DriverError::Cancelled)]);
        assert_eq!(actor.state(), PortalState::AuthorizationRequired);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn first_capture_starts_one_session_and_streaming_capture_reuses_it() {
        let (actor, calls, _) = actor(vec![Action::Stream(None)]);
        let capture = actor.capture(false, Duration::from_secs(1)).unwrap();
        assert_eq!(capture.image.width, 1);
        assert_eq!(capture.source.source_type, ScreenCaptureSourceType::Window);
        assert_eq!(
            serde_json::to_value(&capture).unwrap()["source"]["type"],
            "window"
        );
        assert_eq!(
            actor
                .capture(false, Duration::from_secs(1))
                .unwrap()
                .image
                .width,
            1
        );
        assert_eq!(actor.state(), PortalState::Streaming);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn reauthorize_stops_old_stream_and_starts_a_fresh_session() {
        let (actor, calls, _) = actor(vec![Action::Stream(None), Action::Stream(None)]);
        assert_eq!(
            actor
                .capture(false, Duration::from_secs(1))
                .unwrap()
                .image
                .width,
            1
        );
        assert_eq!(
            actor
                .capture(true, Duration::from_secs(1))
                .unwrap()
                .image
                .width,
            1
        );
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn setup_timeout_is_authorization_required_not_capture_failed() {
        let (actor, _, _) = actor(vec![Action::Delay(Duration::from_millis(50))]);
        assert_eq!(
            actor.capture(false, Duration::from_millis(10)),
            Err(CaptureError::AuthorizationRequired)
        );
    }

    #[test]
    fn callbacks_after_timeout_cannot_resurrect_the_cancelled_generation() {
        let (actor, calls, _) = actor(vec![
            Action::LateStream(Duration::from_millis(50)),
            Action::Stream(None),
        ]);
        assert_eq!(
            actor.capture(false, Duration::from_millis(10)),
            Err(CaptureError::AuthorizationRequired)
        );
        thread::sleep(Duration::from_millis(75));
        assert_eq!(actor.state(), PortalState::AuthorizationRequired);
        assert_eq!(
            actor
                .capture(false, Duration::from_secs(1))
                .unwrap()
                .image
                .width,
            1
        );
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn failed_session_permits_a_later_capture_to_retry() {
        let (actor, calls, _) = actor(vec![
            Action::Fail(DriverError::Failed("session failed".into())),
            Action::Stream(None),
        ]);
        assert_eq!(
            actor.capture(false, Duration::from_secs(1)),
            Err(CaptureError::Failed("session failed".into()))
        );
        assert_eq!(
            actor
                .capture(false, Duration::from_secs(1))
                .unwrap()
                .image
                .width,
            1
        );
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn stale_restore_falls_back_to_fresh_authorization() {
        let dir = tempfile::tempdir().unwrap();
        let store = TokenStore::at(dir.path().join("token"));
        store.replace(None, RestoreToken::new("stale")).unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let tokens = Arc::new(Mutex::new(Vec::new()));
        let actor = ScreenCastActor::spawn_with_driver(
            store,
            Mock {
                actions: vec![
                    Action::Fail(DriverError::StaleRestore),
                    Action::Stream(None),
                ]
                .into(),
                calls,
                tokens: tokens.clone(),
            },
        );
        assert_eq!(
            actor
                .capture(false, Duration::from_secs(1))
                .unwrap()
                .image
                .width,
            1
        );
        assert_eq!(*tokens.lock().unwrap(), vec![true, false]);
    }

    #[test]
    fn restore_transport_failure_does_not_retry_without_token() {
        let classified = production::classify(ashpd::Error::NoResponse, true);
        assert!(matches!(classified, DriverError::Failed(_)));

        let dir = tempfile::tempdir().unwrap();
        let store = TokenStore::at(dir.path().join("token"));
        store.replace(None, RestoreToken::new("stored")).unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let tokens = Arc::new(Mutex::new(Vec::new()));
        let actor = ScreenCastActor::spawn_with_driver(
            store,
            Mock {
                actions: vec![Action::Fail(classified)].into(),
                calls: calls.clone(),
                tokens: tokens.clone(),
            },
        );

        assert!(matches!(
            actor.capture(false, Duration::from_secs(1)),
            Err(CaptureError::Failed(_))
        ));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(*tokens.lock().unwrap(), vec![true]);
    }

    #[test]
    fn session_token_is_persisted_while_stream_is_still_running() {
        let root = tempfile::tempdir().unwrap();
        let store = TokenStore::at(root.path().join("token"));
        let calls = Arc::new(AtomicUsize::new(0));
        let tokens = Arc::new(Mutex::new(Vec::new()));
        let actor = ScreenCastActor::spawn_with_driver(
            store.clone(),
            Mock {
                actions: vec![Action::Stream(None)].into(),
                calls,
                tokens,
            },
        );
        actor.capture(false, Duration::from_secs(1)).unwrap();
        assert_eq!(store.load().unwrap().unwrap().1.expose(), "next");
        assert_eq!(actor.state(), PortalState::Streaming);
    }

    #[test]
    fn stream_lifecycle_transitions_authorized_false_true_false_and_clears_frame() {
        let (end, ended) = mpsc::channel();
        let (actor, _, _) = actor(vec![Action::Stream(Some(ended))]);
        assert_eq!(actor.state(), PortalState::AuthorizationRequired);
        assert_eq!(
            actor
                .capture(false, Duration::from_secs(1))
                .unwrap()
                .image
                .width,
            1
        );
        assert_eq!(actor.state(), PortalState::Streaming);
        end.send(()).unwrap();

        let deadline = Instant::now() + Duration::from_secs(1);
        while actor.state() == PortalState::Streaming && Instant::now() < deadline {
            thread::yield_now();
        }
        assert_eq!(actor.state(), PortalState::AuthorizationRequired);
        assert!(
            actor
                .0
                .signal
                .shared
                .lock()
                .unwrap()
                .frame
                .snapshot()
                .is_none()
        );
    }
}
