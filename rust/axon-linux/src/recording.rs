//! Translating the X11 core input stream into the shared recorder's vocabulary.
//!
//! Nothing in this module talks to an X server or to AT-SPI, so the hosted suite exercises all of
//! it on every platform rather than only under a display. `xrecord.rs` owns the RECORD
//! conversation and `global_input.rs` owns the two threads and the AT-SPI reads; both feed this
//! module raw events and forward what it decides they mean.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use axon_core::RecordedKeystroke;
use std::{
    collections::VecDeque,
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

/// X11 core event type codes, named here so this module needs nothing from `x11rb` and therefore
/// compiles and is tested on every host.
pub const KEY_PRESS: u8 = 2;
pub const KEY_RELEASE: u8 = 3;
pub const BUTTON_PRESS: u8 = 4;
pub const BUTTON_RELEASE: u8 = 5;
pub const MOTION_NOTIFY: u8 = 6;

/// The primary button, which is the only one a recorded click is made of.
pub const BUTTON_PRIMARY: u8 = 1;
/// X11 spells a wheel notch as a press of one of these buttons rather than as its own event.
pub const BUTTON_WHEEL_UP: u8 = 4;
pub const BUTTON_WHEEL_DOWN: u8 = 5;
pub const BUTTON_WHEEL_LEFT: u8 = 6;
pub const BUTTON_WHEEL_RIGHT: u8 = 7;

/// What XRecord handed over, before anything has been read about the interface around it.
///
/// Deliberately small and `Copy`: this is what crosses from a data connection that must keep
/// reading into the enrichment thread that can afford to wait on D-Bus.
///
/// Points are the `root_x`/`root_y` of the core event, which are screen coordinates -- the same
/// frame AT-SPI's `CoordType::Screen` answers in and the same one a dispatch is aimed with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RawInput {
    Key {
        keycode: u8,
        /// The modifier mask the server reported *before* the event.
        ///
        /// This is the reason the observer records through RECORD rather than XInput2: a core
        /// event carries the modifier state with it, where an XI2 raw event omits it by design and
        /// would leave the observer rebuilding it from the key stream the way the Windows one has
        /// to.
        state: u16,
        up: bool,
    },
    Button {
        down: bool,
        point: (i16, i16),
    },
    Motion {
        point: (i16, i16),
    },
    /// One wheel notch, already resolved to the axis and direction it turned.
    Wheel {
        point: (i16, i16),
        delta_x: f64,
        delta_y: f64,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RawEvent {
    pub input: RawInput,
    pub timestamp_ms: u64,
}

/// The bounded hand-off from the RECORD data connection to the enrichment thread.
///
/// The discipline it enforces is stated once in shared core; only the raw event differs per
/// platform. What makes it load-bearing here is that the data connection must keep reading: a
/// recording client that stops draining backs up in the server, and the server's response is to
/// stall every client's input.
pub type RawQueue = axon_core::ObservedInputQueue<RawEvent>;

/// One wheel notch in the direction an X11 wheel button means.
///
/// The magnitude is one notch rather than a pixel count, because that is all the core protocol
/// carries. Sign follows the same convention the Windows observer records: positive vertical is a
/// wheel turned away from the user, positive horizontal is a tilt to the right.
pub fn wheel_delta(button: u8) -> Option<(f64, f64)> {
    Some(match button {
        BUTTON_WHEEL_UP => (0.0, 1.0),
        BUTTON_WHEEL_DOWN => (0.0, -1.0),
        BUTTON_WHEEL_RIGHT => (1.0, 0.0),
        BUTTON_WHEEL_LEFT => (-1.0, 0.0),
        _ => return None,
    })
}

/// Which bit of a core event's `state` mask each modifier occupies on *this* server.
///
/// Read from the server's modifier mapping rather than assumed, because only `Shift`, `Lock` and
/// `Control` have fixed bits in the core protocol. Which of `Mod1`..`Mod5` carries Alt, Super, or
/// the third level is a convention a session is free to rearrange, and a keyboard that puts Super
/// on `Mod3` would otherwise have every chord recorded under the wrong name.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ModifierMasks {
    pub shift: u16,
    pub lock: u16,
    pub control: u16,
    pub alt: u16,
    pub super_key: u16,
    /// AltGr, which selects the third keysym level rather than naming a chord.
    pub level3: u16,
}

impl ModifierMasks {
    /// The core protocol's fixed bits, and the conventional placement of the rest.
    ///
    /// The fallback for a server whose modifier mapping cannot be read, never a substitute for
    /// reading it.
    pub const CONVENTIONAL: Self = Self {
        shift: 1 << 0,
        lock: 1 << 1,
        control: 1 << 2,
        alt: 1 << 3,
        super_key: 1 << 6,
        level3: 1 << 7,
    };
}

/// The modifiers held when an event was generated, read off the core event's own `state`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ModifierState {
    pub shift: bool,
    pub lock: bool,
    pub control: bool,
    pub alt: bool,
    pub super_key: bool,
    pub level3: bool,
}

impl ModifierState {
    pub fn from_mask(state: u16, masks: ModifierMasks) -> Self {
        let held = |mask: u16| mask != 0 && state & mask != 0;
        Self {
            shift: held(masks.shift),
            lock: held(masks.lock),
            control: held(masks.control),
            alt: held(masks.alt),
            super_key: held(masks.super_key),
            level3: held(masks.level3),
        }
    }

    /// Whether a modifier is held that makes this a chord rather than typing.
    ///
    /// Shift is excluded on purpose: shift+a is the character `A`, not a chord. So is the third
    /// level, for the same reason -- AltGr+e is a character the layout produces.
    pub fn chorded(&self) -> bool {
        self.control || self.alt || self.super_key
    }

    /// The modifier names a recorded chord is spelled with, in a stable order.
    ///
    /// The same order and the same words the Windows observer uses, because they are both writing
    /// into one shared vocabulary that `axon_core::parse_chord` has to read back.
    pub fn names(&self) -> Vec<&'static str> {
        [
            (self.super_key, "super"),
            (self.control, "ctrl"),
            (self.alt, "alt"),
            (self.shift, "shift"),
        ]
        .into_iter()
        .filter_map(|(held, name)| held.then_some(name))
        .collect()
    }

    /// The same state with every naming modifier released, which is how a chord's base key is
    /// named: the character `l` produces on its own, not whatever ctrl+l would have typed.
    fn unmodified(&self) -> Self {
        Self {
            lock: self.lock,
            ..Self::default()
        }
    }
}

/// The keysym level a modifier state selects, in the two-per-group shape
/// `GetKeyboardMapping` reports.
///
/// Shift and Lock choose between the pair; the third level is a second pair further along. Caps
/// lock is applied as shift, which is right for letters and wrong for symbols -- the core protocol
/// says a server may apply `Lock` as either shift or caps lock and does not say which this one
/// does, and letters are what a recording is made of.
pub fn keysym_level(modifiers: ModifierState) -> usize {
    let shifted = usize::from(modifiers.shift != modifiers.lock);
    if modifiers.level3 { 2 + shifted } else { shifted }
}

/// Whether a keysym is a modifier, which is context for the keystroke that follows rather than a
/// keystroke of its own.
pub fn is_modifier_keysym(keysym: u32) -> bool {
    matches!(
        keysym,
        // Shift_L through Hyper_R, which is the whole modifier block.
        0xFFE1..=0xFFEE
            // ISO_Level3_Shift, ISO_Level5_Shift, and the group switches beside them.
            | 0xFE01..=0xFE13
            | 0xFF7E // Mode_switch
            | 0xFF7F // Num_Lock
    )
}

/// The shared vocabulary's name for a keysym, or nothing when it is not a key this project names.
///
/// The reverse of `keys::keysym_for`, and it has to stay that way: a recorded `Key { key }` is
/// replayed by parsing it back through `axon_core::parse_chord` and synthesizing it through that
/// table, so a name this produces which that cannot read is a recording that cannot be replayed.
pub fn named_key(keysym: u32) -> Option<&'static str> {
    const FUNCTION_KEYS: [&str; 12] = [
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ];
    Some(match keysym {
        0xFF0D | 0xFF8D => "return", // Return, KP_Enter
        0xFF09 => "tab",
        0xFF1B => "escape",
        0xFF08 => "backspace",
        0xFFFF | 0xFF9F => "delete", // Delete, KP_Delete
        0xFF63 | 0xFF9E => "insert",
        0xFF50 | 0xFF95 => "home",
        0xFF57 | 0xFF9C => "end",
        0xFF55 | 0xFF9A => "pageup", // Prior
        0xFF56 | 0xFF9B => "pagedown", // Next
        0xFF52 | 0xFF97 => "up",
        0xFF54 | 0xFF99 => "down",
        0xFF51 | 0xFF96 => "left",
        0xFF53 | 0xFF98 => "right",
        0xFFBE..=0xFFC9 => FUNCTION_KEYS[(keysym - 0xFFBE) as usize],
        _ => return None,
    })
}

/// The characters a keysym stands for, or nothing when it stands for no text at all.
///
/// Three cases, and no table: Latin-1 keysyms *are* their code points, Unicode keysyms are their
/// code point plus `0x01000000`, and the keypad's own digits and operators have to be spelled out
/// because they are named keysyms that nonetheless type characters.
pub fn keysym_text(keysym: u32) -> Option<String> {
    let character = match keysym {
        0x20..=0x7E | 0xA0..=0xFF => char::from_u32(keysym)?,
        0x0100_0020..=0x0110_FFFF => char::from_u32(keysym - 0x0100_0000)?,
        0xFFB0..=0xFFB9 => char::from_u32(keysym - 0xFFB0 + u32::from(b'0'))?, // KP_0..KP_9
        0xFFAA => '*',
        0xFFAB => '+',
        0xFFAD => '-',
        0xFFAE => '.',
        0xFFAF => '/',
        0xFFAC => ',',
        0xFFBD => '=',
        _ => return None,
    };
    (!character.is_control()).then(|| character.to_string())
}

/// What one key-press amounts to in the shared vocabulary, or nothing when it is not an event a
/// recording should carry.
///
/// `keysym` resolves a modifier state against the live keyboard mapping, which is a round trip to
/// the X server and therefore injected rather than made here.
///
/// The classification is made once, at the physical event, and carried through -- the same reason
/// [`RecordedKeystroke`] exists. After the fact no backend can tell `End` the named key from `End`
/// the three characters.
pub fn classify_keystroke(
    modifiers: ModifierState,
    keysym: impl Fn(ModifierState) -> Option<u32>,
) -> Option<RecordedKeystroke> {
    let pressed = keysym(modifiers)?;
    if is_modifier_keysym(pressed) {
        return None;
    }
    let named = named_key(pressed);
    if named.is_none()
        && !modifiers.chorded()
        && let Some(text) = keysym_text(pressed)
    {
        return Some(RecordedKeystroke::Text { text });
    }
    let base = match named {
        Some(name) => name.to_owned(),
        // A chord is named by the key itself, so the base is resolved with the naming modifiers
        // released: ctrl+shift+p, not ctrl+shift+P.
        None => keysym(modifiers.unmodified())
            .and_then(keysym_text)
            .filter(|text| text.chars().count() == 1)
            .map(|text| text.to_lowercase())?,
    };
    let mut parts: Vec<&str> = modifiers.names();
    parts.push(&base);
    Some(RecordedKeystroke::Key {
        key: parts.join("+"),
    })
}

/// Whether an element holds something the recorder must never read or transcribe.
///
/// Two signals, because AT-SPI offers two and the observer sensitivity contract sets both as the
/// floor for this platform. `STATE_PROTECTED` is the general one a toolkit sets on any field whose
/// contents are concealed; `ROLE_PASSWORD_TEXT` is what GTK and Qt entries report even where the
/// state is missing. Taking either is what keeps the floor from narrowing to whichever one the
/// toolkit in front of the user happens to publish.
pub fn is_sensitive(protected: bool, role: &str) -> bool {
    protected || role.trim().eq_ignore_ascii_case("password text")
}

/// How long an unmatched expectation may suppress input before it is abandoned.
///
/// The X server generates a synthetic event as it processes the request that asked for it, so a
/// live expectation is matched within a round trip. This bound only exists for the request that
/// produced nothing -- a keycode the server has no key for, a dispatch that errored -- where a
/// permanent expectation would swallow the next matching thing the user really did.
const EXPECTATION_LIFETIME: Duration = Duration::from_secs(2);

/// A ceiling on outstanding expectations, so a stream of failed injections cannot grow this
/// without bound between drains.
const MAX_EXPECTATIONS: usize = 256;

/// One event this daemon is about to put into the server's input stream.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Expectation {
    kind: u8,
    detail: u8,
    expires: Instant,
}

/// The ledger that tells this daemon's own delivery apart from a person's hand on the keyboard.
///
/// **X11 has no per-event channel to mark delivery with.** Windows stamps `INPUT.dwExtraInfo` and
/// reads it straight back off the hook; a core X11 event has no equivalent field, and an
/// XTEST-injected event is by design indistinguishable from a real one -- that is the entire point
/// of the extension, and it is why `xdotool` output reaches `xev`. The obvious substitutes are
/// worse: nothing in a `KeyPressEvent` says where it came from, and refusing all synthetic input
/// would discard assistive technology, remote-desktop sessions, and any live probe's own helper,
/// leaving the capability with no way to be tested.
///
/// So the exclusion is made by *order* rather than by mark or by clock. Every synthetic event this
/// daemon posts goes through one function -- `X11Session::fake_input` -- which registers what it is
/// about to inject before the request is sent. The observer drops the first matching event it sees
/// while that expectation is outstanding.
///
/// **The window this leaves open, stated rather than papered over.** The registration precedes the
/// request, so an expectation is always in place before the server can generate the event; there is
/// no race in that direction. What it cannot separate is a genuine user event of the *identical*
/// kind and keycode arriving between the request and its event -- a window of one server round trip
/// -- which would be consumed as ours while our own event is recorded as the user's. The counts
/// stay right and only the attribution of two identical events swaps. A held-open time bracket has
/// the same failure across a far wider window, in both directions, which is why this is not one.
pub struct SelfDelivery {
    /// Whether anything is observing. Kept as an atomic so the dispatch path pays one relaxed load
    /// rather than a lock on every synthetic event when no recording is running.
    armed: AtomicBool,
    expectations: Mutex<VecDeque<Expectation>>,
}

impl SelfDelivery {
    const fn new() -> Self {
        Self {
            armed: AtomicBool::new(false),
            expectations: Mutex::new(VecDeque::new()),
        }
    }

    /// Begins excluding this daemon's own delivery, discarding anything an earlier session left.
    pub fn arm(&self) {
        self.expectations.lock().expect(NEVER_POISONED).clear();
        self.armed.store(true, Ordering::Release);
    }

    pub fn disarm(&self) {
        self.armed.store(false, Ordering::Release);
        self.expectations.lock().expect(NEVER_POISONED).clear();
    }

    /// Records that this daemon is about to inject one event. Called before the request is sent.
    pub fn expect(&self, kind: u8, detail: u8) {
        self.expect_at(kind, detail, Instant::now());
    }

    fn expect_at(&self, kind: u8, detail: u8, now: Instant) {
        if !self.armed.load(Ordering::Acquire) {
            return;
        }
        let mut expectations = self.expectations.lock().expect(NEVER_POISONED);
        expectations.retain(|pending| pending.expires > now);
        if expectations.len() >= MAX_EXPECTATIONS {
            expectations.pop_front();
        }
        expectations.push_back(Expectation {
            kind,
            detail,
            expires: now + EXPECTATION_LIFETIME,
        });
    }

    /// Whether this event is one this daemon just asked for, consuming the expectation if so.
    pub fn claims(&self, kind: u8, detail: u8) -> bool {
        self.claims_at(kind, detail, Instant::now())
    }

    fn claims_at(&self, kind: u8, detail: u8, now: Instant) -> bool {
        if !self.armed.load(Ordering::Acquire) {
            return false;
        }
        let mut expectations = self.expectations.lock().expect(NEVER_POISONED);
        // Motion carries no detail worth matching: `fake_input` gives it a detail of zero and the
        // position travels in the request's coordinates instead.
        let matches = |pending: &Expectation| {
            pending.expires > now
                && pending.kind == kind
                && (kind == MOTION_NOTIFY || pending.detail == detail)
        };
        let Some(index) = expectations.iter().position(matches) else {
            return false;
        };
        expectations.remove(index);
        true
    }

    pub fn outstanding(&self) -> usize {
        self.expectations.lock().expect(NEVER_POISONED).len()
    }
}

const NEVER_POISONED: &str = "the self-delivery ledger is never poisoned";

/// The one ledger this process keeps.
///
/// A process-global for the same reason the raw queue is one: the dispatch path that injects and
/// the listener that observes are on opposite sides of the backend, with no shared owner, and the
/// exclusion has to be visible from both.
pub fn self_delivery() -> &'static SelfDelivery {
    static LEDGER: OnceLock<SelfDelivery> = OnceLock::new();
    LEDGER.get_or_init(SelfDelivery::new)
}
