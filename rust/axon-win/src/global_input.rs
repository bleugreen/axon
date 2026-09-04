//! Windows global input observation for the shared recorder.
//!
//! Two threads, because one constraint dictates the whole shape: `RecordedInputEvent::MouseDown`
//! carries its evidence *inside* the event, and shared core reads that evidence as a picture of the
//! interface taken before the click landed. But `poll` is only called on `recording.status` and
//! `recording.stop`, so an event can sit in a queue for minutes. **The evidence therefore has to be
//! read at event time**, and on Windows it cannot be read where the event arrives:
//!
//! - A `WH_KEYBOARD_LL` / `WH_MOUSE_LL` callback runs on the installing thread's message pump and
//!   is removed from the hook chain without warning if it exceeds `LowLevelHooksTimeout`, 300 ms
//!   by default.
//! - A cross-process UI Automation read can take up to the 1500 ms transaction timeout this
//!   backend configures in `UiaState::new`.
//!
//! So the hook thread does nothing but stamp and queue, and an enrichment thread reads the
//! interface immediately afterwards through a clone of the command sender for the MTA actor that
//! already exists. There is one UI Automation client per process and this does not add a second.

use super::Command;
use crate::recording::{
    ModifierState, RawEvent, RawInput, RawQueue, classify_keystroke, dropped_events_warning,
    is_self_delivered, wheel_delta,
};
use axon_core::{
    BackendError, Capability, GlobalInputObserver, RecordedAppIdentity, RecordedInputEvent,
    RecordedPoint, RecordedTargetEvidence, RecordingScope,
};
use std::{
    collections::VecDeque,
    sync::{
        Arc, Condvar, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread::{self, JoinHandle},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use windows::Win32::{
    Foundation::{LPARAM, LRESULT, WPARAM},
    System::Threading::GetCurrentThreadId,
    UI::{
        Input::KeyboardAndMouse::{GetKeyboardLayout, ToUnicodeEx},
        WindowsAndMessaging::{
            CallNextHookEx, DispatchMessageW, GetForegroundWindow, GetMessageW,
            GetWindowThreadProcessId, HHOOK, KBDLLHOOKSTRUCT, MSG, MSLLHOOKSTRUCT, PM_NOREMOVE,
            PeekMessageW, PostThreadMessageW, SetWindowsHookExW, TranslateMessage,
            UnhookWindowsHookEx, WH_KEYBOARD_LL, WH_MOUSE_LL, WM_KEYUP, WM_LBUTTONDOWN,
            WM_LBUTTONUP, WM_MOUSEHWHEEL, WM_MOUSEMOVE, WM_MOUSEWHEEL, WM_QUIT, WM_SYSKEYUP,
            WM_USER,
        },
    },
};

/// How many raw events may wait for enrichment before the hook starts dropping them.
///
/// Large enough that a fast typing burst does not reach it while UI Automation answers, small
/// enough that a wedged enrichment thread cannot grow without bound. Reaching it is reported, never
/// silent — a recording that quietly lost actions is worse than one that says it did.
const RAW_CAPACITY: usize = 4_096;

/// How long the enrichment thread parks between drains. Only affects how quickly `stop` is noticed.
const DRAIN_INTERVAL: Duration = Duration::from_millis(100);

fn operation(message: impl Into<String>) -> BackendError {
    BackendError::Operation {
        operation: "observeGlobalInput".into(),
        message: message.into(),
        diagnostic: None,
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// The hand-off from the hook callbacks, which is a static because it has to be.
///
/// A low-level hook procedure is given no context pointer, so there is nowhere to hang a per-session
/// queue: the callback can only reach a process-global. That is sound here because the observer
/// permits exactly one session at a time and clears the queue when one starts.
fn raw_queue() -> &'static RawQueue {
    static RAW: OnceLock<RawQueue> = OnceLock::new();
    RAW.get_or_init(|| RawQueue::with_capacity(RAW_CAPACITY))
}

/// Whether a mouse button is currently held, so motion is queued only while it can mean a drag.
///
/// `WM_MOUSEMOVE` arrives continuously whenever the pointer moves at all. Queuing every one would
/// fill the raw queue with events shared core discards, hiding real drops behind noise. Motion only
/// carries meaning between a press and its release, which is exactly the macOS observer's event
/// mask (`leftMouseDragged`) expressed the way Windows reports the same thing.
static BUTTON_HELD: AtomicBool = AtomicBool::new(false);

unsafe extern "system" fn keyboard_hook(code: i32, message: WPARAM, data: LPARAM) -> LRESULT {
    if code >= 0 {
        let event = unsafe { &*(data.0 as *const KBDLLHOOKSTRUCT) };
        if !is_self_delivered(event.dwExtraInfo) {
            raw_queue().offer(RawEvent {
                input: RawInput::Key {
                    virtual_key: event.vkCode as u16,
                    scan_code: event.scanCode,
                    up: matches!(message.0 as u32, WM_KEYUP | WM_SYSKEYUP),
                },
                timestamp_ms: now_ms(),
            });
        }
    }
    unsafe { CallNextHookEx(None, code, message, data) }
}

unsafe extern "system" fn mouse_hook(code: i32, message: WPARAM, data: LPARAM) -> LRESULT {
    if code >= 0 {
        let event = unsafe { &*(data.0 as *const MSLLHOOKSTRUCT) };
        if !is_self_delivered(event.dwExtraInfo) {
            let point = (event.pt.x, event.pt.y);
            let input = match message.0 as u32 {
                WM_LBUTTONDOWN => {
                    BUTTON_HELD.store(true, Ordering::Relaxed);
                    Some(RawInput::Button { down: true, point })
                }
                WM_LBUTTONUP => {
                    BUTTON_HELD.store(false, Ordering::Relaxed);
                    Some(RawInput::Button { down: false, point })
                }
                WM_MOUSEMOVE => BUTTON_HELD
                    .load(Ordering::Relaxed)
                    .then_some(RawInput::Motion { point }),
                WM_MOUSEWHEEL => Some(RawInput::Wheel {
                    point,
                    mouse_data: event.mouseData,
                    horizontal: false,
                }),
                WM_MOUSEHWHEEL => Some(RawInput::Wheel {
                    point,
                    mouse_data: event.mouseData,
                    horizontal: true,
                }),
                _ => None,
            };
            if let Some(input) = input {
                raw_queue().offer(RawEvent {
                    input,
                    timestamp_ms: now_ms(),
                });
            }
        }
    }
    unsafe { CallNextHookEx(None, code, message, data) }
}

/// The installed hooks, removed on every exit path including an unwind.
struct Hooks {
    keyboard: Option<HHOOK>,
    mouse: Option<HHOOK>,
}

impl Hooks {
    fn install() -> Result<Self, BackendError> {
        let keyboard = unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), None, 0) }
            .map_err(|error| operation(format!("WH_KEYBOARD_LL installation failed: {error}")))?;
        let mouse = match unsafe { SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_hook), None, 0) } {
            Ok(mouse) => mouse,
            Err(error) => {
                unsafe {
                    let _ = UnhookWindowsHookEx(keyboard);
                }
                return Err(operation(format!(
                    "WH_MOUSE_LL installation failed: {error}"
                )));
            }
        };
        Ok(Self {
            keyboard: Some(keyboard),
            mouse: Some(mouse),
        })
    }
}

impl Drop for Hooks {
    fn drop(&mut self) {
        for hook in [self.mouse.take(), self.keyboard.take()].into_iter().flatten() {
            unsafe {
                let _ = UnhookWindowsHookEx(hook);
            }
        }
    }
}

/// Installs the hooks and pumps the messages that service them until asked to quit.
///
/// The pump is the whole reason this thread exists. A low-level hook belongs to the thread that
/// installed it and its callbacks are delivered by that thread's message loop, so the hooks cannot
/// be installed on the daemon's request thread — that thread is blocked on a socket, and a hook
/// whose owner is not pumping is dropped from the chain.
fn hook_thread(started: mpsc::SyncSender<Result<u32, BackendError>>) {
    let hooks = match Hooks::install() {
        Ok(hooks) => hooks,
        Err(error) => {
            let _ = started.send(Err(error));
            return;
        }
    };
    // Forces the thread's message queue into existence before anyone is told this thread's id,
    // because `PostThreadMessageW` fails against a thread that has not yet created one and the
    // session would then have no way to stop.
    let mut message = MSG::default();
    unsafe {
        let _ = PeekMessageW(&mut message, None, WM_USER, WM_USER, PM_NOREMOVE);
    }
    if started
        .send(Ok(unsafe { GetCurrentThreadId() }))
        .is_err()
    {
        return;
    }
    // Blocking, not polling: this thread has nothing to do between callbacks, and `GetMessageW`
    // returns 0 exactly when the posted `WM_QUIT` arrives. `Hooks` unhooks as it goes out of scope.
    while unsafe { GetMessageW(&mut message, None, 0, 0) }.0 > 0 {
        unsafe {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    drop(hooks);
}

/// What the *target's* keyboard layout would type for one key in one modifier state.
///
/// The layout is read from the foreground window's thread rather than this one. A daemon that asks
/// for its own layout transcribes a French keyboard as though it were American, which is the same
/// class of mistake as reading `GetKeyboardState` here instead of rebuilding the modifier state
/// from the hook stream.
fn layout_text(virtual_key: u16, scan_code: u32, modifiers: ModifierState) -> Option<String> {
    let window = unsafe { GetForegroundWindow() };
    let thread = unsafe { GetWindowThreadProcessId(window, None) };
    let layout = unsafe { GetKeyboardLayout(thread) };
    let state = modifiers.key_state();
    let mut buffer = [0u16; 8];
    // Bit 2 asks the layout not to disturb the kernel keyboard state. Without it, translating a
    // dead key here would consume it, and the accent the user typed would go missing from the
    // application they typed it into — an observer that changes what it observes.
    let count = unsafe {
        ToUnicodeEx(
            u32::from(virtual_key),
            scan_code,
            &state,
            &mut buffer,
            0x4,
            Some(layout),
        )
    };
    (count > 0).then(|| String::from_utf16_lossy(&buffer[..count as usize]))
}

/// The enriched events `poll` hands to shared core.
#[derive(Default)]
struct Enriched {
    events: Mutex<VecDeque<RecordedInputEvent>>,
    ready: Condvar,
}

impl Enriched {
    fn push(&self, event: RecordedInputEvent) {
        self.events
            .lock()
            .expect("enriched queue is never poisoned")
            .push_back(event);
        self.ready.notify_one();
    }

    fn drain(&self, timeout: Duration) -> Vec<RecordedInputEvent> {
        let mut events = self
            .events
            .lock()
            .expect("enriched queue is never poisoned");
        if events.is_empty() {
            events = self
                .ready
                .wait_timeout(events, timeout)
                .expect("enriched queue is never poisoned")
                .0;
        }
        events.drain(..).collect()
    }

    fn clear(&self) {
        self.events
            .lock()
            .expect("enriched queue is never poisoned")
            .clear();
    }
}

/// Asks the MTA actor one question and waits for its answer.
///
/// A failed read is not a failed recording: the caller decides what an absent answer means, which
/// is usually "record the event with less evidence" rather than "lose the event".
fn ask<T>(
    commands: &mpsc::Sender<Command>,
    make: impl FnOnce(mpsc::Sender<Result<T, BackendError>>) -> Command,
) -> Option<T> {
    let (tx, rx) = mpsc::channel();
    commands.send(make(tx)).ok()?;
    rx.recv().ok()?.ok()
}

/// What the observer knows about the application a keystroke was delivered to.
///
/// A struct rather than a bare identity because of the leak this recorder does not yet close:
/// shared core decides whether a burst was typed into a password field at *flush* time, by which
/// point focus may already have moved (axn/226). Closing it means carrying sensitivity on the
/// keystroke itself, and this is where that value would be read and attached — adding the field
/// here and on `RecordedInputEvent::KeyDown` is then the whole change, with no second reshaping of
/// the observer's vocabulary.
///
/// It is deliberately not read today: it costs a `GetFocusedElement` round trip per keystroke
/// against a 1500 ms transaction timeout, and how far enrichment can fall behind a fast burst is
/// the open measurement this design is waiting on.
struct KeyContext {
    app: RecordedAppIdentity,
}

fn key_context(commands: &mpsc::Sender<Command>) -> Option<KeyContext> {
    ask(commands, Command::ForegroundIdentity)
        .flatten()
        .map(|app| KeyContext { app })
}

/// Turns one raw event into what shared core records, reading the interface as it does so.
fn enrich(
    scope: &RecordingScope,
    commands: &mpsc::Sender<Command>,
    modifiers: &mut ModifierState,
    raw: RawEvent,
) -> Option<RecordedInputEvent> {
    let timestamp_ms = raw.timestamp_ms;
    match raw.input {
        RawInput::Key {
            virtual_key,
            scan_code,
            up,
        } => {
            // Applied for presses and releases alike, because the state a later keystroke is
            // classified against is only correct if releases are folded in too.
            modifiers.apply(virtual_key, up);
            if up {
                return None;
            }
            let keystroke = classify_keystroke(virtual_key, *modifiers, |state| {
                layout_text(virtual_key, scan_code, state)
            })?;
            let context = key_context(commands)?;
            accepts(scope, &context.app).then_some(RecordedInputEvent::KeyDown {
                app: context.app,
                keystroke,
                timestamp_ms,
            })
        }
        RawInput::Button { down, point } => {
            let evidence = point_evidence(commands, point)?;
            if !accepts(scope, &evidence.app) {
                return None;
            }
            Some(if down {
                RecordedInputEvent::MouseDown {
                    evidence,
                    timestamp_ms,
                }
            } else {
                RecordedInputEvent::MouseUp {
                    evidence,
                    timestamp_ms,
                }
            })
        }
        // Scoping a motion is shared core's job: it only reads one between a `MouseDown` it already
        // accepted and that press's `MouseUp`, so re-deriving an application here would cost a
        // hit test per pointer sample to answer a question that has already been answered.
        RawInput::Motion { point } => Some(RecordedInputEvent::MouseDragged {
            at: RecordedPoint {
                x: f64::from(point.0),
                y: f64::from(point.1),
            },
            timestamp_ms,
        }),
        RawInput::Wheel {
            point,
            mouse_data,
            horizontal,
        } => {
            let evidence = point_evidence(commands, point)?;
            if !accepts(scope, &evidence.app) {
                return None;
            }
            let (delta_x, delta_y) = wheel_delta(mouse_data, horizontal);
            Some(RecordedInputEvent::Scroll {
                evidence,
                delta_x,
                delta_y,
                timestamp_ms,
            })
        }
    }
}

fn point_evidence(
    commands: &mpsc::Sender<Command>,
    point: (i32, i32),
) -> Option<RecordedTargetEvidence> {
    ask(commands, |tx| {
        Command::PointEvidence((f64::from(point.0), f64::from(point.1)), tx)
    })
    .flatten()
}

/// Whether an event belongs to the session's scope.
fn accepts(scope: &RecordingScope, app: &RecordedAppIdentity) -> bool {
    match scope {
        RecordingScope::AllApplications => true,
        RecordingScope::Application { app: wanted } => wanted.matches_runtime(app),
    }
}

/// Drains raw events and reads the interface around each one, at event time.
fn enrichment_thread(
    scope: RecordingScope,
    commands: mpsc::Sender<Command>,
    enriched: Arc<Enriched>,
) {
    let mut modifiers = ModifierState::default();
    loop {
        let batch = raw_queue().drain(DRAIN_INTERVAL);
        if batch.dropped > 0 {
            let warning = dropped_events_warning(batch.dropped);
            // Said twice on purpose, because neither surface reaches everyone. The log is what an
            // operator watching the daemon sees, and reaches them even when the drop happened
            // before any action was recorded; the notification is what the artifact keeps, so a
            // recording read a week later still admits the gap.
            eprintln!("axon-win: {warning}");
            enriched.push(RecordedInputEvent::Notification {
                app: scope_identity(&scope),
                notification: warning,
                role: None,
                timestamp_ms: now_ms(),
            });
        }
        for raw in batch.events {
            if let Some(event) = enrich(&scope, &commands, &mut modifiers, raw) {
                enriched.push(event);
            }
        }
        if raw_queue().stopped() {
            return;
        }
    }
}

/// An identity a scoped session will accept, so an observation about the recording itself is not
/// filtered out of the recording it is about.
fn scope_identity(scope: &RecordingScope) -> RecordedAppIdentity {
    match scope {
        RecordingScope::AllApplications => RecordedAppIdentity::default(),
        RecordingScope::Application { app } => app.clone(),
    }
}

struct Session {
    hook_thread_id: u32,
    hooks: Option<JoinHandle<()>>,
    enrichment: Option<JoinHandle<()>>,
}

pub struct WindowsGlobalInputObserver {
    /// A clone of the sender for the MTA actor this backend already runs. One UI Automation client
    /// per process is the discipline; the observer borrows the existing one rather than opening a
    /// second.
    commands: mpsc::Sender<Command>,
    enriched: Arc<Enriched>,
    session: Option<Session>,
}

impl WindowsGlobalInputObserver {
    pub fn new(commands: mpsc::Sender<Command>) -> Self {
        Self {
            commands,
            enriched: Arc::new(Enriched::default()),
            session: None,
        }
    }

    /// Why this process cannot observe global input, or nothing when it can.
    ///
    /// A low-level hook is installed against a window station's desktop. In session 0, or off the
    /// interactive window station, that desktop has no user at it: the hook installs and simply
    /// never fires. UI Automation keeps answering in those sessions, which is what makes the
    /// failure quiet enough to need naming here rather than discovering at `poll`.
    pub fn unavailable(&self) -> Option<BackendError> {
        let session = crate::lifecycle::current_session();
        (!session.interactive || !session.graphical).then(|| BackendError::CapabilityReason {
            capability: Capability::ObserveGlobalInput,
            code: "session-not-interactive",
            reason: session.detail.clone().unwrap_or_else(|| {
                "this session cannot reach the interactive desktop's input devices".to_string()
            }),
            diagnostic: None,
        })
    }

    /// The deepest the raw queue has been this session.
    ///
    /// Reported by the live diagnostic rather than by the daemon: whether enrichment can fall
    /// behind a fast burst is a question about a real machine under a real UI Automation provider,
    /// and this is the number that answers it.
    pub fn raw_queue_depth(&self) -> usize {
        raw_queue().high_water()
    }
}

impl GlobalInputObserver for WindowsGlobalInputObserver {
    fn start(&mut self, scope: &RecordingScope) -> Result<(), BackendError> {
        if self.session.is_some() {
            return Err(operation(
                "a global input observer session is already active",
            ));
        }
        if let Some(error) = self.unavailable() {
            // Typed, not an operation failure: this is the same refusal `global_input_observer`
            // publishes, and a start that reaches this point must arrive on the wire as a
            // capability refusal rather than as `operation observeGlobalInput failed`.
            return Err(error);
        }
        raw_queue().reset();
        self.enriched.clear();
        BUTTON_HELD.store(false, Ordering::Relaxed);

        let (started_tx, started_rx) = mpsc::sync_channel(1);
        let hooks = thread::Builder::new()
            .name("axon-global-input".into())
            .spawn(move || hook_thread(started_tx))
            .map_err(|error| operation(format!("could not create observer thread: {error}")))?;
        let hook_thread_id = match started_rx.recv_timeout(Duration::from_secs(2)) {
            Ok(Ok(id)) => id,
            Ok(Err(error)) => {
                let _ = hooks.join();
                return Err(error);
            }
            Err(_) => {
                // The thread never reported a hook. It holds no session state and its own `Drop`
                // removes anything it did install, so it is left to finish rather than joined
                // against a pump that may not have started.
                return Err(operation("input hook installation timed out"));
            }
        };

        let scope = scope.clone();
        let commands = self.commands.clone();
        let enriched = Arc::clone(&self.enriched);
        let enrichment = thread::Builder::new()
            .name("axon-global-input-evidence".into())
            .spawn(move || enrichment_thread(scope, commands, enriched))
            .map_err(|error| {
                stop_hook_thread(hook_thread_id);
                operation(format!("could not create evidence thread: {error}"))
            })?;

        self.session = Some(Session {
            hook_thread_id,
            hooks: Some(hooks),
            enrichment: Some(enrichment),
        });
        Ok(())
    }

    fn poll(&mut self, timeout: Duration) -> Result<Vec<RecordedInputEvent>, BackendError> {
        if self.session.is_none() {
            return Err(operation("no global input observer session is active"));
        }
        Ok(self.enriched.drain(timeout))
    }

    fn stop(&mut self) -> Result<(), BackendError> {
        if let Some(mut session) = self.session.take() {
            stop_hook_thread(session.hook_thread_id);
            if let Some(hooks) = session.hooks.take() {
                let _ = hooks.join();
            }
            // Stopped after the hooks are gone, so the last events the hook queued are enriched
            // rather than abandoned: the enrichment thread drains once more before it returns.
            raw_queue().stop();
            if let Some(enrichment) = session.enrichment.take() {
                let _ = enrichment.join();
            }
        }
        self.enriched.clear();
        Ok(())
    }

    fn is_recording(&self) -> bool {
        self.session.is_some()
    }
}

/// Ends the hook thread's pump. The only way in: a low-level hook belongs to its installing thread.
fn stop_hook_thread(thread_id: u32) {
    unsafe {
        let _ = PostThreadMessageW(thread_id, WM_QUIT, WPARAM(0), LPARAM(0));
    }
}

impl Drop for WindowsGlobalInputObserver {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}
