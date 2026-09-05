//! Linux global input observation for the shared recorder.
//!
//! Two threads, because one constraint dictates the whole shape: `RecordedInputEvent::MouseDown`
//! carries its evidence *inside* the event, and shared core reads that evidence as a picture of the
//! interface taken before the click landed. But `poll` is only called on `recording.status` and
//! `recording.stop`, so an event can sit in a queue for minutes. **The evidence therefore has to be
//! read at event time**, and on Linux it cannot be read where the event arrives:
//!
//! - The RECORD data connection must keep reading. A recording client that stops draining backs the
//!   stream up in the server, and the server's answer to that is to stall input for everyone.
//! - An AT-SPI property read is a D-Bus round trip owned by the tokio actor thread, bounded at two
//!   seconds by `CALL_TIMEOUT` and routinely much slower than one input event.
//!
//! So the listener thread does nothing but decode and queue, and an enrichment thread reads the
//! interface immediately afterwards through a clone of the command sender for the AT-SPI actor that
//! already exists. One accessibility-bus connection per process is the discipline axn/174 exists to
//! protect, and this does not add a second.

use super::Command;
use crate::recording::{
    ModifierState, RawEvent, RawInput, RawQueue, classify_keystroke, keysym_level, self_delivery,
    wheel_delta,
};
use crate::x11::{Keyboard, X11Session};
use crate::xrecord::RecordSession;
use axon_core::{
    BackendError, GlobalInputObserver, RecordedAppIdentity, RecordedInputEvent, RecordedPoint,
    RecordedTargetEvidence, RecordingScope, dropped_events_warning,
};
use std::{
    sync::{Arc, mpsc},
    thread::{self, JoinHandle},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// How many raw events may wait for enrichment before the listener starts dropping them.
///
/// Large enough that a fast typing burst does not reach it while AT-SPI answers, small enough that
/// a wedged enrichment thread cannot grow without bound. Reaching it is reported, never silent -- a
/// recording that quietly lost actions is worse than one that says it did.
const RAW_CAPACITY: usize = 4_096;

/// How long the enrichment thread parks between drains. Only affects how quickly `stop` is noticed.
const DRAIN_INTERVAL: Duration = Duration::from_millis(100);

/// The enriched events `poll` hands to shared core.
///
/// The same hand-off shape as the raw queue -- produced on one thread, drained with a timeout on
/// another -- with no bound, because these are the product rather than the backlog. Dropping one
/// here would lose an action that had already been read and understood.
type Enriched = axon_core::ObservedInputQueue<RecordedInputEvent>;

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

/// Asks the AT-SPI actor one question and waits for its answer.
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

/// Which process owns what is under a screen point, or which owns the foreground.
///
/// X11 answers both and AT-SPI answers neither: the accessibility bus exposes no stacking order
/// and no foreground, so an application resolved there would be a guess. The enrichment thread
/// therefore keeps a connection of its own -- it runs on its own thread and cannot borrow the
/// backend's -- and asks the actor about a process it has already established.
fn process_at(lookup: Option<&X11Session>, point: (i16, i16)) -> Option<u32> {
    lookup?.process_at(point).ok().flatten()
}

fn frontmost_process(lookup: Option<&X11Session>) -> Option<u32> {
    lookup?.active_window_pid().ok().flatten()
}

fn point_evidence(
    commands: &mpsc::Sender<Command>,
    lookup: Option<&X11Session>,
    point: (i16, i16),
) -> Option<RecordedTargetEvidence> {
    let pid = process_at(lookup, point)?;
    ask(commands, |tx| {
        Command::PointEvidence(pid, (f64::from(point.0), f64::from(point.1)), tx)
    })
    .flatten()
}

/// What the observer knows about the application a keystroke was delivered to.
///
/// A struct rather than a bare identity because of the leak this recorder does not yet close:
/// shared core decides whether a burst was typed into a password field at *flush* time, by which
/// point focus may already have moved (axn/227). Closing it means carrying sensitivity on the
/// keystroke itself, and this is where that value would be read and attached -- adding the field
/// here and on `RecordedInputEvent::KeyDown` is then the whole change, with no second reshaping of
/// the observer's vocabulary.
///
/// It is deliberately not read today: it costs a focused-element round trip per keystroke across
/// D-Bus, and enrichment is already the slow half of this observer.
struct KeyContext {
    app: RecordedAppIdentity,
}

fn key_context(
    commands: &mpsc::Sender<Command>,
    lookup: Option<&X11Session>,
) -> Option<KeyContext> {
    let pid = frontmost_process(lookup)?;
    ask(commands, |tx| Command::RecordedIdentity(pid, tx))
        .flatten()
        .map(|app| KeyContext { app })
}

/// Turns one raw event into what shared core records, reading the interface as it does so.
fn enrich(
    scope: &RecordingScope,
    commands: &mpsc::Sender<Command>,
    lookup: Option<&X11Session>,
    keyboard: &Keyboard,
    raw: RawEvent,
) -> Option<RecordedInputEvent> {
    let timestamp_ms = raw.timestamp_ms;
    match raw.input {
        RawInput::Key { keycode, state } => {
            let modifiers = ModifierState::from_mask(state, keyboard.masks);
            let keystroke = classify_keystroke(modifiers, |level| {
                keyboard.mapping.keysym_at(keycode, keysym_level(level))
            })?;
            let context = key_context(commands, lookup)?;
            scope
                .accepts(&context.app)
                .then_some(RecordedInputEvent::KeyDown {
                    app: context.app,
                    keystroke,
                    timestamp_ms,
                })
        }
        RawInput::Button { down, point } => {
            let evidence = point_evidence(commands, lookup, point)?;
            if !scope.accepts(&evidence.app) {
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
        RawInput::Wheel { button, point } => {
            let (delta_x, delta_y) = wheel_delta(button)?;
            let evidence = point_evidence(commands, lookup, point)?;
            if !scope.accepts(&evidence.app) {
                return None;
            }
            Some(RecordedInputEvent::Scroll {
                evidence,
                delta_x,
                delta_y,
                timestamp_ms,
            })
        }
    }
}

/// Drains raw events and reads the interface around each one, at event time.
fn enrichment_thread(
    scope: RecordingScope,
    commands: mpsc::Sender<Command>,
    keyboard: Keyboard,
    raw: Arc<RawQueue>,
    enriched: Arc<Enriched>,
) {
    let lookup = X11Session::connect();
    loop {
        let batch = raw.drain(DRAIN_INTERVAL);
        if batch.dropped > 0 {
            let warning = dropped_events_warning(batch.dropped);
            // Said twice on purpose, because neither surface reaches everyone. The log is what an
            // operator watching the daemon sees, and reaches them even when the drop happened
            // before any action was recorded; the notification is what the artifact keeps, so a
            // recording read a week later still admits the gap.
            eprintln!("axon-linux: {warning}");
            enriched.offer(RecordedInputEvent::Notification {
                app: scope.identity(),
                notification: warning,
                role: None,
                timestamp_ms: now_ms(),
            });
        }
        for event in batch.events {
            if let Some(event) = enrich(&scope, &commands, lookup.as_ref(), &keyboard, event) {
                enriched.offer(event);
            }
        }
        if raw.stopped() {
            return;
        }
    }
}

struct Session {
    record: RecordSession,
    enrichment: Option<JoinHandle<()>>,
}

pub struct LinuxGlobalInputObserver {
    /// A clone of the sender for the AT-SPI actor this backend already runs. One accessibility-bus
    /// connection per process is the discipline; the observer borrows the existing one rather than
    /// opening a second.
    commands: mpsc::Sender<Command>,
    /// Owned rather than a process-global, unlike the Windows observer's. A low-level Windows hook
    /// is handed no context pointer and can only reach a static; a RECORD listener is an ordinary
    /// thread this observer spawned, so the queue can simply belong to the session that uses it.
    raw: Arc<RawQueue>,
    enriched: Arc<Enriched>,
    session: Option<Session>,
}

impl LinuxGlobalInputObserver {
    pub fn new(commands: mpsc::Sender<Command>) -> Self {
        Self {
            commands,
            raw: Arc::new(RawQueue::with_capacity(RAW_CAPACITY)),
            enriched: Arc::new(Enriched::with_capacity(usize::MAX)),
            session: None,
        }
    }

    /// Begins one owned capture session.
    ///
    /// The keyboard is read by the caller rather than here, because the backend already holds an X
    /// connection and this observer would otherwise open a third.
    pub fn start(
        &mut self,
        scope: &RecordingScope,
        keyboard: Keyboard,
    ) -> Result<(), BackendError> {
        if self.session.is_some() {
            return Err(operation(
                "a global input observer session is already active",
            ));
        }
        self.raw.reset();
        self.enriched.reset();
        // Armed before the listener exists, so no synthetic event this daemon posts can slip
        // through between observation starting and the exclusion being in place.
        self_delivery().arm();

        let record = RecordSession::start(Arc::clone(&self.raw)).inspect_err(|_| {
            self_delivery().disarm();
        })?;

        let scope = scope.clone();
        let commands = self.commands.clone();
        let raw = Arc::clone(&self.raw);
        let enriched = Arc::clone(&self.enriched);
        let enrichment = thread::Builder::new()
            .name("axon-global-input-evidence".into())
            .spawn(move || enrichment_thread(scope, commands, keyboard, raw, enriched))
            .map_err(|error| {
                self_delivery().disarm();
                operation(format!("could not create evidence thread: {error}"))
            })?;

        self.session = Some(Session {
            record,
            enrichment: Some(enrichment),
        });
        Ok(())
    }

    /// Stops observing and lets enrichment finish, leaving everything already seen pollable.
    ///
    /// Separate from `stop`, and the separation is the difference between a complete recording and
    /// one missing its own ending. Enrichment runs *behind* the listener by design, so the events a
    /// session's final moments produced do not exist yet when the last ordinary poll happens. They
    /// come into being here, once the RECORD context is disabled and the enrichment thread has
    /// drained what it left. A caller polls between this and `stop`; `stop` alone would produce
    /// them and then immediately discard them.
    pub fn quiesce(&mut self) {
        let Some(session) = self.session.as_mut() else {
            return;
        };
        // Ends the stream first, so nothing new arrives while the backlog is worked through.
        session.record.stop();
        // Stopped only once the listener is gone, so the last events it queued are enriched rather
        // than abandoned: the enrichment thread drains once more before it returns.
        self.raw.stop();
        if let Some(enrichment) = session.enrichment.take() {
            let _ = enrichment.join();
        }
        self_delivery().disarm();
    }

    /// The deepest the raw queue has been this session, which is what says whether enrichment is
    /// keeping up or merely has not fallen behind yet.
    pub fn raw_queue_depth(&self) -> usize {
        self.raw.high_water()
    }

    /// What is still waiting for enrichment. Zero at the end of a burst means it caught up.
    pub fn raw_queue_pending(&self) -> usize {
        self.raw.depth()
    }

    pub fn poll(&mut self, timeout: Duration) -> Result<Vec<RecordedInputEvent>, BackendError> {
        if self.session.is_none() {
            return Err(operation("no global input observer session is active"));
        }
        Ok(self.enriched.drain(timeout).events)
    }

    pub fn stop(&mut self) -> Result<(), BackendError> {
        self.quiesce();
        self.session = None;
        // Discarded here and not a moment sooner. `quiesce` is what makes a session's last events
        // reachable; a caller that wants them polls between the two calls.
        self.enriched.reset();
        Ok(())
    }

    pub fn is_recording(&self) -> bool {
        self.session.is_some()
    }
}

impl Drop for LinuxGlobalInputObserver {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

/// Named so the trait's own methods can be reached on the backend that delegates to this observer.
const _: fn() = || {
    fn assert_seam<T: GlobalInputObserver>() {}
    let _ = assert_seam::<super::LinuxBackend>;
};
