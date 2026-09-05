//! Listen-only observation of the X11 core input stream, through the RECORD extension.
//!
//! RECORD rather than XInput2, and the reason is the modifier state. A core `KeyPressEvent` carries
//! the modifiers held when it was generated; an XI2 raw event omits them by design, which would
//! leave the observer rebuilding that state from the key stream the way the Windows one has to. The
//! whole point of choosing the mechanism that reports it is not to have to.
//!
//! Two connections, because the protocol says so: "the typical communication model for a recording
//! client is to open two connections to the server and use one for RC control and the other for
//! reading protocol data." The control connection creates the context and is the only way to stop
//! it; the data connection blocks in `RecordEnableContext` on a thread of its own and must keep
//! reading, because a recording client that stops draining backs the stream up in the server.
//!
//! Nothing here reads the interface. The listener decodes bytes into
//! [`crate::recording::RawEvent`] and queues them; the accessibility reads happen behind it, on the
//! enrichment thread, at event time.

use crate::recording::{
    BUTTON_PRESS, BUTTON_RELEASE, CoreEvent, Decoder, KEY_PRESS, KEY_RELEASE, MOTION_NOTIFY,
    RawEvent, RawQueue,
};
use axon_core::BackendError;
use std::{
    sync::{Arc, mpsc},
    thread::{self, JoinHandle},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use x11rb::{
    connection::{Connection, RequestConnection as _},
    protocol::{
        record::{self, ConnectionExt as _},
        xproto,
    },
    rust_connection::RustConnection,
    wrapper::ConnectionExt as _,
    x11_utils::TryParse,
};

/// The RECORD reply category for protocol the server generated, which is where device events
/// arrive. The generated bindings do not name these, so they are named here.
const FROM_SERVER: u8 = 0;

/// Every core event is 32 bytes on the wire, which is what makes a malformed element recoverable:
/// the stream can be advanced by exactly one event rather than abandoned.
const EVENT_BYTES: usize = 32;

/// How long `stop` waits for the listener to notice the context was disabled before letting it go.
///
/// Disabling the context is the protocol's own way to end the stream and it ends promptly, but this
/// runs inside a daemon answering a request: a listener that somehow did not notice must not be
/// able to wedge `recording.stop`. Its queue is already stopped by then, so a detached listener has
/// nowhere to put anything.
const LISTENER_SHUTDOWN: Duration = Duration::from_secs(2);

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

/// Whether this server provides RECORD at all.
///
/// Not a formality: `Xvfb` and a stripped-down remote server can both be built or started without
/// it, and a session missing it answers everything else about itself normally. Advertising
/// observation on such a server would report the capability usable and discover otherwise only
/// after a caller had started recording.
pub fn supported(connection: &RustConnection) -> bool {
    connection
        .extension_information(record::X11_EXTENSION_NAME)
        .ok()
        .flatten()
        .is_some()
}

/// A live recording context and the thread draining it.
pub struct RecordSession {
    control: RustConnection,
    context: record::Context,
    listener: Option<JoinHandle<()>>,
    finished: mpsc::Receiver<()>,
}

impl RecordSession {
    /// Opens both connections, creates the context, and starts draining it into `queue`.
    ///
    /// Leaves nothing behind on any failure path: a context that was created but could not be
    /// enabled is freed before the error is returned.
    pub fn start(queue: Arc<RawQueue>) -> Result<Self, BackendError> {
        let (control, _) = x11rb::connect(None)
            .map_err(|error| operation(format!("could not open a control connection: {error}")))?;
        if !supported(&control) {
            return Err(operation(
                "this X server does not provide the RECORD extension",
            ));
        }
        control
            .record_query_version(
                record::X11_XML_VERSION.0 as u16,
                record::X11_XML_VERSION.1 as u16,
            )
            .map_err(|error| operation(format!("could not negotiate RECORD: {error}")))?
            .reply()
            .map_err(|error| operation(format!("could not negotiate RECORD: {error}")))?;

        let context = control
            .generate_id()
            .map_err(|error| operation(format!("could not allocate a RECORD context: {error}")))?;
        let empty = record::Range8 { first: 0, last: 0 };
        let empty_ext = record::ExtRange {
            major: empty,
            minor: record::Range16 { first: 0, last: 0 },
        };
        let range = record::Range {
            core_requests: empty,
            core_replies: empty,
            ext_requests: empty_ext,
            ext_replies: empty_ext,
            // Deliberately empty. `delivered_events` records what the server hands to clients,
            // which would include every `XSendEvent` the pixel rung dispatches -- input this
            // daemon posted to one window, which was never the user acting. `device_events` is the
            // physical input stream, which is what a recording is about.
            delivered_events: empty,
            device_events: record::Range8 {
                first: xproto::KEY_PRESS_EVENT,
                last: xproto::MOTION_NOTIFY_EVENT,
            },
            errors: empty,
            client_started: false,
            client_died: false,
        };
        control
            .record_create_context(context, 0, &[record::CS::ALL_CLIENTS.into()], &[range])
            .map_err(|error| operation(format!("could not create a RECORD context: {error}")))?
            .check()
            .map_err(|error| operation(format!("could not create a RECORD context: {error}")))?;

        let free = |control: &RustConnection| {
            if let Ok(cookie) = control.record_free_context(context) {
                let _ = cookie.check();
            }
        };
        let (data, _) = match x11rb::connect(None) {
            Ok(connection) => connection,
            Err(error) => {
                free(&control);
                return Err(operation(format!(
                    "could not open a data connection: {error}"
                )));
            }
        };
        let (finished_tx, finished) = mpsc::channel();
        let listener = thread::Builder::new()
            .name("axon-global-input".into())
            .spawn(move || {
                listen(&data, context, &queue);
                let _ = finished_tx.send(());
            });
        let listener = match listener {
            Ok(listener) => listener,
            Err(error) => {
                free(&control);
                return Err(operation(format!(
                    "could not create observer thread: {error}"
                )));
            }
        };
        Ok(Self {
            control,
            context,
            listener: Some(listener),
            finished,
        })
    }

    /// Ends the stream and releases the context. Idempotent.
    ///
    /// Disabling the context is the only way in: the listener is blocked reading its own
    /// connection, and the protocol's answer to that is for the controlling client to disable the
    /// context, at which point the server closes the stream and the read returns.
    pub fn stop(&mut self) {
        let Some(listener) = self.listener.take() else {
            return;
        };
        if let Ok(cookie) = self.control.record_disable_context(self.context) {
            let _ = cookie.check();
        }
        let _ = self.control.sync();
        match self.finished.recv_timeout(LISTENER_SHUTDOWN) {
            Ok(()) => {
                let _ = listener.join();
            }
            // Detached rather than joined, so a listener that somehow missed the end of its stream
            // cannot wedge the request that asked observation to stop. Its queue is stopped by the
            // time this runs, so it has nowhere left to put anything.
            Err(_) => drop(listener),
        }
        if let Ok(cookie) = self.control.record_free_context(self.context) {
            let _ = cookie.check();
        }
    }
}

impl Drop for RecordSession {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Blocks on the data connection, decoding recorded elements until the stream ends.
fn listen(data: &RustConnection, context: record::Context, queue: &RawQueue) {
    let Ok(stream) = data.record_enable_context(context) else {
        return;
    };
    let mut decoder = Decoder::default();
    for reply in stream {
        let Ok(reply) = reply else { return };
        // A byte-swapped client's recorded data would need every field reversed before it meant
        // anything. Rather than decode it wrongly, this observer records nothing from one -- an
        // opposite-endian X client on a modern desktop does not occur, and a wrong reading of one
        // would be worse than an absent one.
        if reply.client_swapped || reply.category != FROM_SERVER {
            continue;
        }
        decode(&mut decoder, &reply.data, queue);
    }
}

/// Reads one recorded element's bytes into core events and queues what they amount to.
///
/// Only the parsing lives here. What an event *means* -- which button is a click, when motion
/// matters, which events are this daemon's own -- is [`Decoder::observe`], in the half of this
/// backend that compiles everywhere and is therefore tested everywhere.
pub fn decode(decoder: &mut Decoder, mut data: &[u8], queue: &RawQueue) {
    while data.len() >= EVENT_BYTES {
        // The high bit marks an event the server produced on a client's behalf through
        // `XSendEvent`. It is never set on a device event, and masking it off is what keeps a
        // stray one from being read as an event type nobody sent.
        let kind = data[0] & 0x7F;
        let event = match kind {
            KEY_PRESS | KEY_RELEASE => {
                xproto::KeyPressEvent::try_parse(data)
                    .ok()
                    .map(|(event, _)| CoreEvent {
                        kind,
                        detail: event.detail,
                        point: (event.root_x, event.root_y),
                        state: event.state.into(),
                    })
            }
            BUTTON_PRESS | BUTTON_RELEASE => {
                xproto::ButtonPressEvent::try_parse(data)
                    .ok()
                    .map(|(event, _)| CoreEvent {
                        kind,
                        detail: event.detail,
                        point: (event.root_x, event.root_y),
                        state: event.state.into(),
                    })
            }
            MOTION_NOTIFY => xproto::MotionNotifyEvent::try_parse(data)
                .ok()
                .map(|(event, _)| CoreEvent {
                    kind,
                    // `Normal` or `Hint` rather than a keycode, and the ledger ignores it for
                    // exactly that reason: there is nothing here to match an injection against.
                    detail: event.detail.into(),
                    point: (event.root_x, event.root_y),
                    state: event.state.into(),
                }),
            _ => None,
        };
        if let Some(input) = event.and_then(|event| decoder.observe(event)) {
            queue.offer(RawEvent {
                input,
                timestamp_ms: now_ms(),
            });
        }
        data = &data[EVENT_BYTES..];
    }
}
