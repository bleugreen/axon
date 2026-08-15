//! Dedicated ScreenCast/PipeWire capture actor.

use crate::portal::{
    AppAuthorizationKey, LatestFrame, PipeWireFrame, PortalState, RestoreToken, TokenStore,
};
use axon_core::{AppQuery, Screenshot};
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
type StopSignal = Arc<Mutex<mpsc::Receiver<()>>>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CaptureError {
    AuthorizationRequired,
    TimedOut,
    Unavailable(String),
    Failed(String),
    NoFrame,
}

struct Shared {
    state: PortalState,
    frame: LatestFrame,
    requested: Option<AppAuthorizationKey>,
}
struct Signal {
    shared: Mutex<Shared>,
    changed: Condvar,
}

pub struct ScreenCastActor {
    signal: Arc<Signal>,
    command: mpsc::Sender<Command>,
    stop: mpsc::Sender<()>,
    shutting_down: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}

enum Command {
    Capture(Option<AppAuthorizationKey>),
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
                requested: None,
            }),
            changed: Condvar::new(),
        });
        let (command, commands) = mpsc::channel();
        let (stop, stopped) = mpsc::channel();
        let shutting_down = Arc::new(AtomicBool::new(false));
        let actor_signal = signal.clone();
        let actor_shutting_down = shutting_down.clone();
        let thread = thread::Builder::new()
            .name("axon-screencast".into())
            .spawn(move || {
                actor_main(
                    driver,
                    store,
                    actor_signal,
                    commands,
                    Arc::new(Mutex::new(stopped)),
                    actor_shutting_down,
                )
            })
            .expect("spawn ScreenCast actor");
        Self {
            signal,
            command,
            stop,
            shutting_down,
            thread: Some(thread),
        }
    }
    pub fn state(&self) -> PortalState {
        self.signal
            .shared
            .lock()
            .expect("ScreenCast state poisoned")
            .state
            .clone()
    }
    pub fn capture(&self, app: &AppQuery, timeout: Duration) -> Result<Screenshot, CaptureError> {
        let deadline = Instant::now() + timeout.min(INTERACTIVE_TIMEOUT);
        let requested = AppAuthorizationKey::from_query(app);
        let mut shared = self
            .signal
            .shared
            .lock()
            .expect("ScreenCast state poisoned");
        let reusable = requested.is_some()
            && shared.requested == requested
            && matches!(shared.state, PortalState::Starting | PortalState::Streaming);
        if !reusable {
            if matches!(shared.state, PortalState::Starting | PortalState::Streaming) {
                let _ = self.stop.send(());
            }
            shared.frame.clear();
            shared.requested = requested.clone();
            shared.state = PortalState::Starting;
            if self.command.send(Command::Capture(requested)).is_err() {
                shared.state = PortalState::Failed("ScreenCast actor stopped".into());
            }
            self.signal.changed.notify_all();
        }
        while matches!(shared.state, PortalState::Starting) && shared.frame.snapshot().is_none() {
            let now = Instant::now();
            if now >= deadline {
                shared.state = PortalState::AuthorizationRequired;
                let _ = self.stop.send(());
                return Err(CaptureError::AuthorizationRequired);
            }
            let (next, wait) = self
                .signal
                .changed
                .wait_timeout(shared, deadline - now)
                .expect("ScreenCast state poisoned");
            shared = next;
            if wait.timed_out() && shared.frame.snapshot().is_none() {
                shared.state = PortalState::AuthorizationRequired;
                let _ = self.stop.send(());
                return Err(CaptureError::AuthorizationRequired);
            }
        }
        if let Some(frame) = shared.frame.snapshot() {
            return frame
                .screenshot()
                .map_err(|e| CaptureError::Failed(format!("{e:?}")));
        }
        match &shared.state {
            PortalState::AuthorizationRequired => Err(CaptureError::AuthorizationRequired),
            PortalState::Unavailable(r) => Err(CaptureError::Unavailable(r.clone())),
            PortalState::Failed(r) => Err(CaptureError::Failed(r.clone())),
            PortalState::Starting => Err(CaptureError::AuthorizationRequired),
            PortalState::Streaming => Err(CaptureError::NoFrame),
        }
    }
}
impl Drop for ScreenCastActor {
    fn drop(&mut self) {
        self.shutting_down.store(true, Ordering::Release);
        let _ = self.stop.send(());
        let _ = self.command.send(Command::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
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
            Command::Capture(key) => {
                let stored = key
                    .as_ref()
                    .and_then(|key| store.load(key).ok().flatten())
                    .map(|(_, token)| token);
                let run_once = |driver: &mut D, token, key: Option<AppAuthorizationKey>| {
                    let started_signal = signal.clone();
                    let started_store = store.clone();
                    let started_key = key.clone();
                    let started = Arc::new(move |session: StartedSession| {
                        if let (Some(app), Some(token)) =
                            (started_key.clone(), session.restore_token)
                        {
                            if let Err(error) =
                                started_store.replace(app, session.source_id.as_deref(), token)
                            {
                                set_state(
                                    &started_signal,
                                    PortalState::Failed(format!(
                                        "could not persist portal token: {error}"
                                    )),
                                );
                            }
                        }
                    });
                    let publish_signal = signal.clone();
                    let publish_key = key.clone();
                    let publish = Arc::new(move |new_frame: PipeWireFrame| {
                        let shared = publish_signal
                            .shared
                            .lock()
                            .expect("ScreenCast state poisoned");
                        if shared.requested != publish_key {
                            return;
                        }
                        shared.frame.publish(new_frame);
                        drop(shared);
                        set_state(&publish_signal, PortalState::Streaming);
                    });
                    driver.run(token, started, publish, stopped.clone())
                };
                let first = run_once(&mut driver, stored.clone(), key.clone());
                let result = if matches!(first, Err(DriverError::StaleRestore))
                    && stored.is_some()
                    && !shutting_down.load(Ordering::Acquire)
                {
                    run_once(&mut driver, None, key.clone())
                } else {
                    first
                };
                if shutting_down.load(Ordering::Acquire) {
                    break;
                }
                let shared = signal.shared.lock().expect("ScreenCast state poisoned");
                if shared.requested != key {
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
    use pipewire as pw;
    use pw::spa::{self, pod::Pod};
    use std::os::fd::OwnedFd;

    struct Format {
        raw: spa::param::video::VideoInfoRaw,
    }

    pub fn run(
        token: Option<RestoreToken>,
        started: Arc<dyn Fn(StartedSession) + Send + Sync>,
        publish: Arc<dyn Fn(PipeWireFrame) + Send + Sync>,
        stopped: StopSignal,
    ) -> Result<(), DriverError> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .map_err(|e| DriverError::Failed(e.to_string()))?;
        let setup = runtime.block_on(async {
            tokio::time::timeout(INTERACTIVE_TIMEOUT, setup(token.as_ref())).await
        });
        let (session, fd, node, next_token, source_id) = match setup {
            Err(_) => return Err(DriverError::TimedOut),
            Ok(Err(e)) => return Err(classify(e, token.is_some())),
            Ok(Ok(v)) => v,
        };
        started(StartedSession {
            restore_token: next_token.map(RestoreToken::new),
            source_id,
        });
        let result = run_pipewire(fd, node, publish, stopped);
        let _ = runtime.block_on(session.close());
        result
    }

    async fn setup(
        token: Option<&RestoreToken>,
    ) -> ashpd::Result<(
        ashpd::desktop::Session<Screencast>,
        OwnedFd,
        u32,
        Option<String>,
        Option<String>,
    )> {
        let portal = Screencast::new().await?;
        if !portal
            .available_source_types()
            .await?
            .contains(SourceType::Window)
        {
            return Err(ashpd::Error::Portal(ashpd::PortalError::NotFound(
                "WINDOW source unavailable".into(),
            )));
        }
        let session = portal.create_session(Default::default()).await?;
        portal
            .select_sources(
                &session,
                SelectSourcesOptions::default()
                    .set_sources(SourceType::Window | SourceType::Window)
                    .set_multiple(false)
                    .set_persist_mode(PersistMode::ExplicitlyRevoked)
                    .set_restore_token(token.map(RestoreToken::expose)),
            )
            .await?
            .response()?;
        let streams = portal
            .start(&session, None, StartCastOptions::default())
            .await?
            .response()?;
        let stream = streams.streams().first().ok_or_else(|| {
            ashpd::Error::Portal(ashpd::PortalError::NotFound(
                "portal returned no stream".into(),
            ))
        })?;
        let node = stream.pipe_wire_node_id();
        let source_id = stream.id().map(str::to_owned);
        let next_token = streams.restore_token().map(str::to_owned);
        let fd = portal
            .open_pipe_wire_remote(&session, OpenPipeWireRemoteOptions::default())
            .await?;
        Ok((session, fd, node, next_token, source_id))
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
                if id == spa::param::ParamType::Format.as_raw() {
                    if let Some(pod) = pod {
                        let _ = f.raw.parse(pod);
                    }
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
                if offset
                    .checked_add(length)
                    .is_some_and(|end| end <= bytes.len())
                {
                    publish(PipeWireFrame {
                        width: size.width,
                        height: size.height,
                        offset: 0,
                        stride,
                        format,
                        data: bytes[offset..offset + length].to_vec(),
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
        let quit = mainloop.clone();
        let timer = mainloop.loop_().add_timer(move |_| {
            if stopped
                .lock()
                .expect("stop signal poisoned")
                .try_recv()
                .is_ok()
            {
                quit.quit();
            }
        });
        timer
            .update_timer(
                Some(Duration::from_millis(50)),
                Some(Duration::from_millis(50)),
            )
            .into_result()
            .map_err(fail)?;
        mainloop.run();
        Ok(())
    }
    fn fail(e: impl ToString) -> DriverError {
        DriverError::Failed(e.to_string())
    }
    fn classify(e: ashpd::Error, restoring: bool) -> DriverError {
        let text = e.to_string();
        if text.contains("cancel") || text.contains("denied") {
            DriverError::Cancelled
        } else if text.contains("WINDOW source unavailable") {
            DriverError::Unavailable(text)
        } else if restoring {
            DriverError::StaleRestore
        } else {
            DriverError::Failed(text)
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
                Action::Stream(ended) => {
                    started(StartedSession {
                        restore_token: Some(RestoreToken::new("next")),
                        source_id: Some("source".into()),
                    });
                    publish(frame());
                    if let Some(ended) = ended {
                        let _ = ended.recv();
                    } else {
                        let _ = stopped.lock().unwrap().recv();
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

    fn app(name: &str) -> AppQuery {
        AppQuery {
            process_id: None,
            name: Some(name.into()),
            identifier: None,
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
    fn spawn_and_state_are_noninteractive() {
        let (actor, calls, _) = actor(vec![Action::Fail(DriverError::Cancelled)]);
        assert_eq!(actor.state(), PortalState::AuthorizationRequired);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn first_capture_starts_one_session_and_streaming_capture_reuses_it() {
        let (actor, calls, _) = actor(vec![Action::Stream(None)]);
        assert_eq!(
            actor
                .capture(&app("A"), Duration::from_secs(1))
                .unwrap()
                .width,
            1
        );
        assert_eq!(
            actor
                .capture(&app("A"), Duration::from_secs(1))
                .unwrap()
                .width,
            1
        );
        assert_eq!(actor.state(), PortalState::Streaming);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn changing_apps_stops_old_stream_and_starts_a_fresh_session() {
        let (actor, calls, _) = actor(vec![Action::Stream(None), Action::Stream(None)]);
        assert_eq!(
            actor
                .capture(&app("A"), Duration::from_secs(1))
                .unwrap()
                .width,
            1
        );
        assert_eq!(
            actor
                .capture(&app("B"), Duration::from_secs(1))
                .unwrap()
                .width,
            1
        );
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn setup_timeout_is_authorization_required_not_capture_failed() {
        let (actor, _, _) = actor(vec![Action::Delay(Duration::from_millis(50))]);
        assert_eq!(
            actor.capture(&app("A"), Duration::from_millis(10)),
            Err(CaptureError::AuthorizationRequired)
        );
    }

    #[test]
    fn failed_session_permits_a_later_capture_to_retry() {
        let (actor, calls, _) = actor(vec![
            Action::Fail(DriverError::Failed("session failed".into())),
            Action::Stream(None),
        ]);
        assert_eq!(
            actor.capture(&app("A"), Duration::from_secs(1)),
            Err(CaptureError::Failed("session failed".into()))
        );
        assert_eq!(
            actor
                .capture(&app("A"), Duration::from_secs(1))
                .unwrap()
                .width,
            1
        );
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn stale_restore_falls_back_to_fresh_authorization() {
        let dir = tempfile::tempdir().unwrap();
        let store = TokenStore::at(dir.path().join("token"));
        store
            .replace(
                AppAuthorizationKey::Name("A".into()),
                None,
                RestoreToken::new("stale"),
            )
            .unwrap();
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
                .capture(&app("A"), Duration::from_secs(1))
                .unwrap()
                .width,
            1
        );
        assert_eq!(*tokens.lock().unwrap(), vec![true, false]);
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
        actor.capture(&app("A"), Duration::from_secs(1)).unwrap();
        assert_eq!(
            store
                .load(&AppAuthorizationKey::Name("A".into()))
                .unwrap()
                .unwrap()
                .1
                .expose(),
            "next"
        );
        assert_eq!(actor.state(), PortalState::Streaming);
    }

    #[test]
    fn stream_lifecycle_transitions_authorized_false_true_false_and_clears_frame() {
        let (end, ended) = mpsc::channel();
        let (actor, _, _) = actor(vec![Action::Stream(Some(ended))]);
        assert_eq!(actor.state(), PortalState::AuthorizationRequired);
        assert_eq!(
            actor
                .capture(&app("A"), Duration::from_secs(1))
                .unwrap()
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
