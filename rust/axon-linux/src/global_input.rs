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
    KnownApplications, ModifierState, RawEvent, RawInput, RawQueue, classify_keystroke,
    keysym_level, self_delivery, wheel_delta,
};
use crate::x11::{Keyboard, X11Session};
use crate::xrecord::RecordSession;
use axon_core::{
    BackendError, RecordedAppIdentity, RecordedInputEvent, RecordedPoint, RecordedTargetEvidence,
    RecordingScope, dropped_events_warning,
};
use std::{
    sync::{Arc, mpsc},
    thread::{self, JoinHandle},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
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

/// Asks the AT-SPI actor one question and waits for its answer, keeping the reason it failed.
///
/// A failed read is not a failed recording: the caller decides what it costs, which is "record the
/// event with less evidence" wherever that is possible. The reason is kept because it is the only
/// account anyone gets of why a recorded step is thinner than it should be.
fn ask<T>(
    commands: &mpsc::Sender<Command>,
    make: impl FnOnce(mpsc::Sender<Result<T, BackendError>>) -> Command,
) -> Result<T, String> {
    const ACTOR_GONE: &str = "the accessibility actor is no longer answering";
    let (tx, rx) = mpsc::channel();
    commands.send(make(tx)).map_err(|_| ACTOR_GONE.to_owned())?;
    rx.recv()
        .map_err(|_| ACTOR_GONE.to_owned())?
        .map_err(|error| error.to_string())
}

/// Which process owns what is under a screen point, or which owns the foreground.
///
/// X11 answers both and AT-SPI answers neither: the accessibility bus exposes no stacking order
/// and no foreground, so an application resolved there would be a guess. The enrichment thread
/// therefore keeps a connection of its own -- it runs on its own thread and cannot borrow the
/// backend's -- and asks the actor about a process it has already established.
fn process_at(lookup: Option<&X11Session>, point: (i16, i16)) -> Result<u32, String> {
    let lookup = lookup.ok_or(NO_LOOKUP)?;
    match lookup.process_at(point) {
        Ok(Some(pid)) => Ok(pid),
        Ok(None) => Err(format!(
            "no window under ({}, {}) names the process that owns it",
            point.0, point.1
        )),
        Err(error) => Err(format!(
            "reading the window under ({}, {}) failed: {error}",
            point.0, point.1
        )),
    }
}

fn frontmost_process(lookup: Option<&X11Session>) -> Result<u32, String> {
    match lookup.ok_or(NO_LOOKUP)?.active_window_pid() {
        Ok(Some(pid)) => Ok(pid),
        Ok(None) => Err("the active window names no process".into()),
        Err(error) => Err(format!("reading the active window failed: {error}")),
    }
}

const NO_LOOKUP: &str = "the evidence thread has no connection to the X server";

/// One event's evidence, or the reason it could not be read.
enum Evidence {
    Read(RecordedTargetEvidence),
    /// The application is known but the interface around the point could not be read, so the
    /// event authors as a point target in that application.
    PointOnly(RecordedTargetEvidence, String),
}

fn point_evidence(
    commands: &mpsc::Sender<Command>,
    lookup: Option<&X11Session>,
    scope: &RecordingScope,
    known: &mut KnownApplications,
    point: (i16, i16),
) -> Result<Evidence, String> {
    let pid = process_at(lookup, point)?;
    let at = (f64::from(point.0), f64::from(point.1));
    let reason = match ask(commands, |tx| Command::PointEvidence(pid, at, tx)) {
        Ok(Some(evidence)) => {
            known.remember(&evidence.app);
            return Ok(Evidence::Read(evidence));
        }
        Ok(None) => format!("no application on the accessibility bus belongs to process {pid}"),
        Err(error) => format!(
            "reading the interface at ({}, {}) failed: {error}",
            point.0, point.1
        ),
    };
    let app = known
        .recall(pid, scope)
        .ok_or_else(|| format!("{reason}, and this session has not named that process before"))?;
    Ok(Evidence::PointOnly(
        RecordedTargetEvidence {
            app,
            point: RecordedPoint { x: at.0, y: at.1 },
            candidates: Vec::new(),
        },
        reason,
    ))
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
/// Sensitivity is deliberately not read today: it costs a focused-element search across D-Bus per
/// keystroke, and on this platform that search is a tree walk rather than a single query.
struct KeyContext {
    app: RecordedAppIdentity,
}

/// How long the application behind one process id is trusted before it is asked for again.
///
/// The same bound the backend gives its own application-to-process map, and it exists here for a
/// sharper reason. Naming an application costs the actor a bus enumeration -- every application
/// root, a process id for each, and a name read -- which is affordable once per click and ruinous
/// once per keystroke. A typing burst goes into one application, so its identity is read at the
/// start of the burst and reused through it, while a pid change or the timeout re-reads it.
const KEY_IDENTITY_FRESHNESS: Duration = Duration::from_secs(2);

/// The application a keystroke belongs to, read at most once per burst.
#[derive(Default)]
struct KeyIdentity {
    current: Option<(u32, RecordedAppIdentity, Instant)>,
}

impl KeyIdentity {
    /// The typing application, and why it is less certain than it should be when it is.
    fn of(
        &mut self,
        commands: &mpsc::Sender<Command>,
        lookup: Option<&X11Session>,
        scope: &RecordingScope,
        known: &mut KnownApplications,
    ) -> Result<(KeyContext, Option<String>), String> {
        let pid = frontmost_process(lookup)?;
        if let Some((current, app, read)) = &self.current
            && *current == pid
            && read.elapsed() < KEY_IDENTITY_FRESHNESS
        {
            return Ok((KeyContext { app: app.clone() }, None));
        }
        let reason = match ask(commands, |tx| Command::RecordedIdentity(pid, tx)) {
            Ok(Some(app)) => {
                known.remember(&app);
                self.current = Some((pid, app.clone(), Instant::now()));
                return Ok((KeyContext { app }, None));
            }
            Ok(None) => format!("no application on the accessibility bus belongs to process {pid}"),
            Err(error) => format!("naming the application of process {pid} failed: {error}"),
        };
        // Not cached: the next keystroke asks again, so one slow answer does not decide a burst.
        let app = known.recall(pid, scope).ok_or_else(|| {
            format!("{reason}, and this session has not named that process before")
        })?;
        Ok((KeyContext { app }, Some(reason)))
    }
}

/// What became of one raw event.
enum Enrichment {
    Recorded(RecordedInputEvent),
    /// Recorded with less evidence than it should have had, for this reason.
    Degraded(RecordedInputEvent, String),
    /// Not something a recording carries: a modifier on its own, or an event outside the scope.
    Ignored,
    /// Something the user did that this observer could not record, for this reason.
    Lost(String),
}

impl Enrichment {
    fn scoped(
        scope: &RecordingScope,
        event: RecordedInputEvent,
        app: &RecordedAppIdentity,
        degraded: Option<String>,
    ) -> Self {
        match (scope.accepts(app), degraded) {
            (false, _) => Self::Ignored,
            (true, None) => Self::Recorded(event),
            (true, Some(reason)) => Self::Degraded(event, reason),
        }
    }
}

/// The context the evidence thread enriches with, held for one session.
struct Enricher<'a> {
    scope: &'a RecordingScope,
    commands: &'a mpsc::Sender<Command>,
    lookup: Option<&'a X11Session>,
    keyboard: &'a Keyboard,
    identity: KeyIdentity,
    known: KnownApplications,
}

impl Enricher<'_> {
    /// Turns one raw event into what shared core records, reading the interface as it does so.
    ///
    /// A user's event is never dropped without saying so. Where the interface could not be read it
    /// is still recorded, against an application this session already knows, as a point; and where
    /// not even the application can be named it comes back as [`Enrichment::Lost`] with the reason,
    /// which the caller logs and writes into the recording.
    fn enrich(&mut self, raw: RawEvent) -> Enrichment {
        let timestamp_ms = raw.timestamp_ms;
        match raw.input {
            RawInput::Key { keycode, state } => {
                let modifiers = ModifierState::from_mask(state, self.keyboard.masks);
                let Some(keystroke) = classify_keystroke(modifiers, |level| {
                    self.keyboard
                        .mapping
                        .keysym_at(keycode, keysym_level(level))
                }) else {
                    return Enrichment::Ignored;
                };
                match self
                    .identity
                    .of(self.commands, self.lookup, self.scope, &mut self.known)
                {
                    Ok((context, degraded)) => Enrichment::scoped(
                        self.scope,
                        RecordedInputEvent::KeyDown {
                            app: context.app.clone(),
                            keystroke,
                            timestamp_ms,
                        },
                        &context.app,
                        degraded,
                    ),
                    Err(reason) => {
                        Enrichment::Lost(format!("a keystroke was not recorded: {reason}"))
                    }
                }
            }
            RawInput::Button { down, point } => {
                let (evidence, degraded) = match self.evidence(point) {
                    Ok(found) => found,
                    Err(reason) => {
                        let what = if down { "press" } else { "release" };
                        return Enrichment::Lost(format!(
                            "a pointer {what} at ({}, {}) was not recorded: {reason}",
                            point.0, point.1
                        ));
                    }
                };
                let app = evidence.app.clone();
                let event = if down {
                    RecordedInputEvent::MouseDown {
                        evidence,
                        timestamp_ms,
                    }
                } else {
                    RecordedInputEvent::MouseUp {
                        evidence,
                        timestamp_ms,
                    }
                };
                Enrichment::scoped(self.scope, event, &app, degraded)
            }
            // Scoping a motion is shared core's job: it only reads one between a `MouseDown` it
            // already accepted and that press's `MouseUp`, so re-deriving an application here would
            // cost a hit test per pointer sample to answer a question that has been answered.
            RawInput::Motion { point } => Enrichment::Recorded(RecordedInputEvent::MouseDragged {
                at: RecordedPoint {
                    x: f64::from(point.0),
                    y: f64::from(point.1),
                },
                timestamp_ms,
            }),
            RawInput::Wheel { button, point } => {
                let Some((delta_x, delta_y)) = wheel_delta(button) else {
                    return Enrichment::Ignored;
                };
                let (evidence, degraded) = match self.evidence(point) {
                    Ok(found) => found,
                    Err(reason) => {
                        return Enrichment::Lost(format!(
                            "a scroll at ({}, {}) was not recorded: {reason}",
                            point.0, point.1
                        ));
                    }
                };
                let app = evidence.app.clone();
                Enrichment::scoped(
                    self.scope,
                    RecordedInputEvent::Scroll {
                        evidence,
                        delta_x,
                        delta_y,
                        timestamp_ms,
                    },
                    &app,
                    degraded,
                )
            }
        }
    }

    fn evidence(
        &mut self,
        point: (i16, i16),
    ) -> Result<(RecordedTargetEvidence, Option<String>), String> {
        Ok(
            match point_evidence(
                self.commands,
                self.lookup,
                self.scope,
                &mut self.known,
                point,
            )? {
                Evidence::Read(evidence) => (evidence, None),
                Evidence::PointOnly(evidence, reason) => (evidence, Some(reason)),
            },
        )
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
    let mut enricher = Enricher {
        scope: &scope,
        commands: &commands,
        lookup: lookup.as_ref(),
        keyboard: &keyboard,
        identity: KeyIdentity::default(),
        known: KnownApplications::default(),
    };
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
            match enricher.enrich(event) {
                Enrichment::Recorded(event) => {
                    enriched.offer(event);
                }
                // The recording already says the step fell back to a point; the log says why.
                Enrichment::Degraded(event, reason) => {
                    eprintln!("axon-linux: recorded with point evidence only: {reason}");
                    enriched.offer(event);
                }
                Enrichment::Ignored => {}
                // Said in both places for the same reason a drop is: the log reaches an operator
                // even before anything was recorded, and the notification stays with the artifact.
                Enrichment::Lost(reason) => {
                    eprintln!("axon-linux: {reason}");
                    enriched.offer(RecordedInputEvent::Notification {
                        app: scope.identity(),
                        notification: format!("{reason}; it may be missing from this recording"),
                        role: None,
                        timestamp_ms: now_ms(),
                    });
                }
            }
        }
        if raw.stopped() {
            return;
        }
    }
}

struct Session {
    record: RecordSession,
    /// This session's raw queue, and only this session's. A listener that missed the end of its
    /// stream is detached rather than joined at stop, and can go on writing; a queue shared across
    /// sessions would deliver what it wrote to the next recording, and reopen itself for it.
    raw: Arc<RawQueue>,
    enrichment: Option<JoinHandle<()>>,
}

pub struct LinuxGlobalInputObserver {
    /// A clone of the sender for the AT-SPI actor this backend already runs. One accessibility-bus
    /// connection per process is the discipline; the observer borrows the existing one rather than
    /// opening a second.
    commands: mpsc::Sender<Command>,
    enriched: Arc<Enriched>,
    session: Option<Session>,
}

impl LinuxGlobalInputObserver {
    pub fn new(commands: mpsc::Sender<Command>) -> Self {
        Self {
            commands,
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
        // Owned rather than a process-global, unlike the Windows observer's: a low-level Windows
        // hook is handed no context pointer and can only reach a static, while a RECORD listener is
        // an ordinary thread this observer spawned, so its queue can belong to its session.
        let raw = Arc::new(RawQueue::with_capacity(RAW_CAPACITY));
        self.enriched.reset();
        // Armed before the listener exists, so no synthetic event this daemon posts can slip
        // through between observation starting and the exclusion being in place.
        self_delivery().arm();

        let record = RecordSession::start(Arc::clone(&raw)).inspect_err(|_| {
            self_delivery().disarm();
        })?;

        let scope = scope.clone();
        let commands = self.commands.clone();
        let session_raw = Arc::clone(&raw);
        let enriched = Arc::clone(&self.enriched);
        let enrichment = thread::Builder::new()
            .name("axon-global-input-evidence".into())
            .spawn(move || enrichment_thread(scope, commands, keyboard, session_raw, enriched))
            .map_err(|error| {
                self_delivery().disarm();
                operation(format!("could not create evidence thread: {error}"))
            })?;

        self.session = Some(Session {
            record,
            raw,
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
        session.raw.stop();
        if let Some(enrichment) = session.enrichment.take() {
            let _ = enrichment.join();
        }
        self_delivery().disarm();
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
