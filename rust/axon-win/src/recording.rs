//! Translating the Windows low-level input stream into the shared recorder's vocabulary.
//!
//! Nothing in this module calls Win32, so the hosted suite exercises all of it on every platform
//! rather than only on the bench. `global_input.rs` owns the hooks, the two threads, and the UI
//! Automation reads; it feeds this module raw events and forwards what it decides they mean.
#![cfg_attr(not(windows), allow(dead_code))]

use axon_core::RecordedKeystroke;
use std::{
    collections::VecDeque,
    sync::{
        Condvar, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};

/// The sentinel this daemon writes into `dwExtraInfo` on every input record it posts, and the only
/// thing that tells its own delivery apart from a person's hand on the keyboard.
///
/// The obvious test — `LLKHF_INJECTED` — is the wrong one, and wrong in a way that would hide
/// itself: every `SendInput` from every process sets it, so filtering on it would also discard
/// assistive technology, remote-desktop sessions, and the live probe's own helper, leaving the
/// capability with no way to be tested at all. What has to be excluded is *this process's* posts,
/// not injected input in general.
///
/// `SendInput` carries `INPUT.dwExtraInfo` through to the hook verbatim as
/// `KBDLLHOOKSTRUCT.dwExtraInfo` / `MSLLHOOKSTRUCT.dwExtraInfo`, so each record is marked
/// individually. That is why this is a stamp rather than a guard held open across the posting
/// call: the hook runs on the observer's thread, not the posting thread, so an interval-based
/// bracket either releases while events are still in flight or stays open long enough to swallow
/// input the user really did type.
///
/// One gap, stated rather than papered over: `pixel::set_cursor` moves the pointer with
/// `SetCursorPos`, which has no `dwExtraInfo` to stamp and does reach the hook as an injected
/// move. It is harmless here because a bare motion never becomes an action — shared core reads
/// `MouseDragged` only between a `MouseDown` and its `MouseUp` — but it is the one delivery this
/// tag cannot mark.
pub const SELF_DELIVERY_TAG: usize = 0x4158_4F4E;

/// Whether an input record carries this daemon's own delivery stamp.
pub fn is_self_delivered(extra_info: usize) -> bool {
    extra_info == SELF_DELIVERY_TAG
}

/// What a low-level hook saw, before anything has been read about the interface around it.
///
/// Deliberately small and `Copy`: this is what crosses from a hook callback that must never block
/// into the enrichment thread that can afford to wait on UI Automation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RawInput {
    Key {
        virtual_key: u16,
        /// Carried because `ToUnicodeEx` wants it: the layout translates the physical key, and a
        /// zero scan code makes some layouts answer for a key that was never pressed.
        scan_code: u32,
        up: bool,
    },
    Button { down: bool, point: (i32, i32) },
    Motion { point: (i32, i32) },
    Wheel {
        point: (i32, i32),
        mouse_data: u32,
        horizontal: bool,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RawEvent {
    pub input: RawInput,
    pub timestamp_ms: u64,
}

/// Modifier state rebuilt from the hook stream itself.
///
/// `GetKeyboardState` is not an option here. It answers with the *calling* thread's queue state,
/// and the observer's hook thread has no input queue of its own to speak of, so it would report a
/// shift that is being held in the foreground application as released. The only trustworthy source
/// for "what was held when this key went down" is the sequence of key events the hook has already
/// been handed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ModifierState {
    shift: bool,
    control: bool,
    alt: bool,
    windows: bool,
    caps_lock: bool,
}

const VK_CAPITAL: u16 = 0x14;

impl ModifierState {
    /// Folds one key transition into the state. Toggles latch on the press, like the OS does.
    pub fn apply(&mut self, virtual_key: u16, up: bool) {
        let held = !up;
        match virtual_key {
            0x10 | 0xA0 | 0xA1 => self.shift = held,
            0x11 | 0xA2 | 0xA3 => self.control = held,
            0x12 | 0xA4 | 0xA5 => self.alt = held,
            0x5B | 0x5C => self.windows = held,
            VK_CAPITAL if held => self.caps_lock = !self.caps_lock,
            _ => {}
        }
    }

    /// Whether a modifier is held that makes this a chord rather than typing.
    ///
    /// Shift is excluded on purpose: shift+a is the character `A`, not a chord.
    pub fn chorded(&self) -> bool {
        self.control || self.alt || self.windows
    }

    /// The key-state array `ToUnicodeEx` reads, in the layout that call expects.
    pub fn key_state(&self) -> [u8; 256] {
        let mut state = [0u8; 256];
        for (held, keys) in [
            (self.shift, [0x10usize, 0xA0]),
            (self.control, [0x11, 0xA2]),
            (self.alt, [0x12, 0xA4]),
            (self.windows, [0x5B, 0x5B]),
        ] {
            if held {
                for key in keys {
                    state[key] = 0x80;
                }
            }
        }
        if self.caps_lock {
            state[VK_CAPITAL as usize] |= 0x01;
        }
        state
    }

    /// The modifier names a recorded chord is spelled with, in a stable order.
    pub fn names(&self) -> Vec<&'static str> {
        [
            (self.windows, "super"),
            (self.control, "ctrl"),
            (self.alt, "alt"),
            (self.shift, "shift"),
        ]
        .into_iter()
        .filter_map(|(held, name)| held.then_some(name))
        .collect()
    }

    /// The same state with every modifier released, which is how a chord's base key is named: the
    /// character `l` produces on its own, not whatever ctrl+l would have typed.
    fn unmodified(&self) -> Self {
        Self {
            caps_lock: self.caps_lock,
            ..Self::default()
        }
    }
}

/// What one key-down amounts to in the shared vocabulary, or nothing when it is not an event a
/// recording should carry.
///
/// `text` resolves what the *target's* keyboard layout would have produced for a given modifier
/// state; on Windows that is `ToUnicodeEx`, which is a Win32 call and therefore injected rather
/// than made here.
///
/// The classification is made once, at the physical event, and carried through — the same reason
/// [`RecordedKeystroke`] exists. After the fact no backend can tell `End` the named key from `End`
/// the three characters.
pub fn classify_keystroke(
    virtual_key: u16,
    modifiers: ModifierState,
    text: impl Fn(ModifierState) -> Option<String>,
) -> Option<RecordedKeystroke> {
    // A modifier press is not itself a keystroke; it is context for the one that follows.
    if crate::keys::modifier_name(virtual_key).is_some() || virtual_key == VK_CAPITAL {
        return None;
    }
    let named = crate::keys::key_name(virtual_key);
    if named.is_none()
        && !modifiers.chorded()
        && let Some(text) = text(modifiers).filter(|text| is_printable(text))
    {
        return Some(RecordedKeystroke::Text { text });
    }
    let base = match named {
        Some(name) => name.to_owned(),
        None => text(modifiers.unmodified())
            .filter(|text| is_printable(text) && text.chars().count() == 1)
            .map(|text| text.to_lowercase())?,
    };
    let mut parts: Vec<&str> = modifiers.names();
    parts.push(&base);
    Some(RecordedKeystroke::Key {
        key: parts.join("+"),
    })
}

fn is_printable(text: &str) -> bool {
    !text.is_empty() && !text.chars().any(char::is_control)
}

/// The scroll delta one wheel event carries, in the units the rest of this backend already uses.
///
/// `mouse_data`'s high word is a signed notch count in `WHEEL_DELTA` (120) units, and
/// `scroll_steps` in `platform.rs` divides by exactly that, so the recorded number is left in the
/// unit the replay path reads rather than normalized here into a second one.
///
/// Sign is the Windows convention on both axes: positive vertical is a wheel turned away from the
/// user, positive horizontal is a tilt to the right.
pub fn wheel_delta(mouse_data: u32, horizontal: bool) -> (f64, f64) {
    let notches = f64::from((mouse_data >> 16) as u16 as i16);
    if horizontal {
        (notches, 0.0)
    } else {
        (0.0, notches)
    }
}

/// What one drain of the raw queue found, including what it had to throw away to keep up.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RawBatch {
    pub events: Vec<RawEvent>,
    /// Events the hook could not hand over since the previous drain. Never silently zero: a
    /// recording that lost actions has to say so.
    pub dropped: usize,
    /// The deepest the queue has been this session, which is what says whether the enrichment
    /// thread is keeping up or merely has not fallen behind yet.
    pub high_water: usize,
}

/// A bounded hand-off from the hook callback to the enrichment thread.
///
/// Bounded and non-blocking on the producer side, both for the same reason: a low-level hook
/// callback that takes longer than `LowLevelHooksTimeout` (300 ms by default) is removed from the
/// chain by Windows without asking. So the callback offers an event and gives up immediately if it
/// cannot have the lock or the queue is full, counting what it dropped rather than waiting.
pub struct RawQueue {
    events: Mutex<VecDeque<RawEvent>>,
    ready: Condvar,
    capacity: usize,
    dropped: AtomicUsize,
    high_water: AtomicUsize,
    stopped: AtomicBool,
}

impl RawQueue {
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            events: Mutex::new(VecDeque::with_capacity(capacity.min(1024))),
            ready: Condvar::new(),
            capacity,
            dropped: AtomicUsize::new(0),
            high_water: AtomicUsize::new(0),
            stopped: AtomicBool::new(false),
        }
    }

    /// Hands one event over if that can be done without waiting. Returns whether it was taken.
    pub fn offer(&self, event: RawEvent) -> bool {
        let Ok(mut events) = self.events.try_lock() else {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return false;
        };
        if events.len() >= self.capacity {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return false;
        }
        events.push_back(event);
        let depth = events.len();
        drop(events);
        self.high_water.fetch_max(depth, Ordering::Relaxed);
        self.ready.notify_one();
        true
    }

    /// Takes everything queued, waiting up to `timeout` for the first event.
    pub fn drain(&self, timeout: Duration) -> RawBatch {
        let mut events = self.events.lock().expect("raw input queue is never poisoned");
        if events.is_empty() && !self.stopped.load(Ordering::Acquire) {
            events = self
                .ready
                .wait_timeout(events, timeout)
                .expect("raw input queue is never poisoned")
                .0;
        }
        RawBatch {
            events: events.drain(..).collect(),
            dropped: self.dropped.swap(0, Ordering::Relaxed),
            high_water: self.high_water.load(Ordering::Relaxed),
        }
    }

    /// Wakes a waiting drain and stops future ones from waiting at all.
    pub fn stop(&self) {
        self.stopped.store(true, Ordering::Release);
        self.ready.notify_all();
    }

    pub fn stopped(&self) -> bool {
        self.stopped.load(Ordering::Acquire)
    }

    /// Returns the queue to the state a fresh session expects.
    ///
    /// The queue outlives any one session because a low-level hook callback is handed no context
    /// pointer and can only reach a static, so starting a second recording has to clear what the
    /// first one left rather than construct a new queue.
    pub fn reset(&self) {
        self.events
            .lock()
            .expect("raw input queue is never poisoned")
            .clear();
        self.dropped.store(0, Ordering::Relaxed);
        self.high_water.store(0, Ordering::Relaxed);
        self.stopped.store(false, Ordering::Release);
    }

    pub fn high_water(&self) -> usize {
        self.high_water.load(Ordering::Relaxed)
    }
}

/// The warning a drop is reported as, in the one channel a provider has to annotate a recording.
pub fn dropped_events_warning(dropped: usize) -> String {
    format!(
        "the global input observer dropped {dropped} raw event(s) before this point; actions may be \
         missing from this recording"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A layout stub standing in for `ToUnicodeEx`: unshifted letters lower case, shifted upper.
    fn us_layout(virtual_key: u16) -> impl Fn(ModifierState) -> Option<String> {
        move |modifiers| {
            let character = char::from(u8::try_from(virtual_key).ok()?);
            if !character.is_ascii_alphanumeric() {
                return None;
            }
            Some(if modifiers.shift != modifiers.caps_lock {
                character.to_ascii_uppercase().to_string()
            } else {
                character.to_ascii_lowercase().to_string()
            })
        }
    }

    #[test]
    fn a_plain_letter_is_text_and_shift_only_changes_its_case() {
        let mut modifiers = ModifierState::default();
        assert_eq!(
            classify_keystroke(b'A'.into(), modifiers, us_layout(b'A'.into())),
            Some(RecordedKeystroke::Text { text: "a".into() })
        );
        modifiers.apply(0xA0, false);
        assert_eq!(
            classify_keystroke(b'A'.into(), modifiers, us_layout(b'A'.into())),
            Some(RecordedKeystroke::Text { text: "A".into() }),
            "shift alone is case, not a chord"
        );
    }

    #[test]
    fn a_control_chord_is_named_by_its_unmodified_base_key() {
        let mut modifiers = ModifierState::default();
        modifiers.apply(0xA2, false);
        assert_eq!(
            classify_keystroke(b'L'.into(), modifiers, us_layout(b'L'.into())),
            Some(RecordedKeystroke::Key {
                key: "ctrl+l".into()
            })
        );
        modifiers.apply(0xA1, false);
        assert_eq!(
            classify_keystroke(b'P'.into(), modifiers, us_layout(b'P'.into())),
            Some(RecordedKeystroke::Key {
                key: "ctrl+shift+p".into()
            })
        );
    }

    #[test]
    fn a_named_key_stays_named_with_and_without_modifiers() {
        let unmodified = ModifierState::default();
        assert_eq!(
            classify_keystroke(0x0D, unmodified, |_| None),
            Some(RecordedKeystroke::Key {
                key: "return".into()
            }),
            "Return is one keystroke, never the three characters `End` would spell"
        );
        let mut shifted = ModifierState::default();
        shifted.apply(0x10, false);
        assert_eq!(
            classify_keystroke(0x09, shifted, |_| None),
            Some(RecordedKeystroke::Key {
                key: "shift+tab".into()
            })
        );
    }

    #[test]
    fn every_recorded_chord_is_one_this_project_can_replay() {
        let mut modifiers = ModifierState::default();
        for modifier in [0xA2u16, 0xA4, 0xA0, 0x5B] {
            modifiers.apply(modifier, false);
        }
        let Some(RecordedKeystroke::Key { key }) =
            classify_keystroke(b'S'.into(), modifiers, us_layout(b'S'.into()))
        else {
            panic!("a fully modified letter is a chord");
        };
        assert_eq!(key, "super+ctrl+alt+shift+s");
        let chord = axon_core::parse_chord(&key).expect("a recorded chord parses back");
        assert_eq!(chord.key, axon_core::Key::Character('s'));
        assert_eq!(chord.modifiers.len(), 4);
    }

    #[test]
    fn modifier_presses_and_dead_translations_are_not_keystrokes() {
        let modifiers = ModifierState::default();
        for virtual_key in [0x10u16, 0xA2, 0x5B, VK_CAPITAL] {
            assert_eq!(
                classify_keystroke(virtual_key, modifiers, us_layout(b'A'.into())),
                None,
                "{virtual_key:#04x} is context, not a keystroke"
            );
        }
        assert_eq!(
            classify_keystroke(0xFF, modifiers, |_| None),
            None,
            "a key with neither a name nor a character is not recorded"
        );
        assert_eq!(
            classify_keystroke(0xFF, modifiers, |_| Some("\u{1b}".into())),
            None,
            "a control character is not typed text"
        );
    }

    #[test]
    fn caps_lock_latches_on_the_press_and_survives_its_release() {
        let mut modifiers = ModifierState::default();
        modifiers.apply(VK_CAPITAL, false);
        modifiers.apply(VK_CAPITAL, true);
        assert_eq!(
            classify_keystroke(b'A'.into(), modifiers, us_layout(b'A'.into())),
            Some(RecordedKeystroke::Text { text: "A".into() })
        );
        assert_eq!(modifiers.key_state()[VK_CAPITAL as usize] & 0x01, 0x01);
        modifiers.apply(VK_CAPITAL, false);
        assert_eq!(
            classify_keystroke(b'A'.into(), modifiers, us_layout(b'A'.into())),
            Some(RecordedKeystroke::Text { text: "a".into() })
        );
    }

    #[test]
    fn key_state_marks_the_neutral_and_sided_virtual_keys_toolkits_read() {
        let mut modifiers = ModifierState::default();
        modifiers.apply(0xA3, false);
        let state = modifiers.key_state();
        assert_eq!(state[0x11], 0x80, "VK_CONTROL");
        assert_eq!(state[0xA2], 0x80, "VK_LCONTROL");
        assert_eq!(state[0x10], 0, "shift was never pressed");
    }

    #[test]
    fn wheel_notches_keep_their_windows_sign_and_unit() {
        assert_eq!(wheel_delta(120 << 16, false), (0.0, 120.0));
        assert_eq!(
            wheel_delta(u32::from(-240i16 as u16) << 16, false),
            (0.0, -240.0),
            "a wheel turned toward the user is negative"
        );
        assert_eq!(wheel_delta(120 << 16, true), (120.0, 0.0));
    }

    #[test]
    fn only_this_daemons_own_stamp_is_treated_as_self_delivery() {
        assert!(is_self_delivered(SELF_DELIVERY_TAG));
        assert!(!is_self_delivered(0), "ordinary hardware input");
        assert!(
            !is_self_delivered(0xDEAD_BEEF),
            "another process's injection is still the user's input as far as we are concerned"
        );
    }

    #[test]
    fn a_full_queue_drops_and_counts_rather_than_waiting() {
        let queue = RawQueue::with_capacity(2);
        let event = |timestamp_ms| RawEvent {
            input: RawInput::Key {
                virtual_key: 0x41,
                scan_code: 0x1E,
                up: false,
            },
            timestamp_ms,
        };
        assert!(queue.offer(event(1)));
        assert!(queue.offer(event(2)));
        assert!(!queue.offer(event(3)), "the third has nowhere to go");

        let batch = queue.drain(Duration::ZERO);
        assert_eq!(batch.events.len(), 2);
        assert_eq!(batch.dropped, 1);
        assert_eq!(batch.high_water, 2);

        assert_eq!(
            queue.drain(Duration::ZERO).dropped,
            0,
            "a drop is reported once, against the actions that followed it"
        );
        assert!(
            dropped_events_warning(1).contains("missing"),
            "the warning says what was lost"
        );

        queue.reset();
        assert_eq!(queue.high_water(), 0, "a second session starts clean");
        assert!(queue.offer(event(4)));
    }

    #[test]
    fn a_stopped_queue_stops_waiting() {
        let queue = RawQueue::with_capacity(8);
        queue.stop();
        let started = std::time::Instant::now();
        assert!(queue.drain(Duration::from_secs(30)).events.is_empty());
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "stop releases the enrichment thread instead of leaving it parked"
        );
        assert!(queue.stopped());
    }
}
