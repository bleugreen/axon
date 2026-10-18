//! Translating the X11 core input stream into the shared recorder's vocabulary.
//!
//! Nothing in this module talks to an X server or to AT-SPI, so the hosted suite exercises all of
//! it on every platform rather than only under a display. `xrecord.rs` owns the RECORD
//! conversation and `global_input.rs` owns the two threads and the AT-SPI reads; both feed this
//! module raw events and forward what it decides they mean.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use axon_core::{Node, RecordedElementEvidence, RecordedKeystroke};
use std::{
    collections::VecDeque,
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
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
    /// A key going down. Releases never reach this vocabulary: see [`Decoder::observe`].
    Key {
        keycode: u8,
        /// The modifier mask the server reported *before* the event.
        ///
        /// This is the reason the observer records through RECORD rather than XInput2: a core
        /// event carries the modifier state with it, where an XI2 raw event omits it by design and
        /// would leave the observer rebuilding it from the key stream the way the Windows one has
        /// to.
        state: u16,
    },
    Button {
        down: bool,
        point: (i16, i16),
    },
    Motion {
        point: (i16, i16),
    },
    /// One wheel notch, still spelled as the button X11 reported it as. Resolving the axis and
    /// direction is enrichment's job, so the queued event stays what the server actually said.
    Wheel {
        button: u8,
        point: (i16, i16),
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RawEvent {
    pub input: RawInput,
    pub timestamp_ms: u64,
}

/// One recorded X11 core input event, in the four fields that decide what it means.
///
/// The wire bytes are parsed by `x11rb` in `xrecord.rs`; what an event *is* is decided here, so
/// every rule below -- which button is a click, which are wheel notches, when motion matters, and
/// which events are this daemon's own -- is exercised by the hosted suite on every platform rather
/// than only under a display.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CoreEvent {
    pub kind: u8,
    /// The keycode of a key event or the button number of a button event.
    pub detail: u8,
    /// `root_x`/`root_y`: the position on screen, in the frame a dispatch is aimed with.
    pub point: (i16, i16),
    /// The modifier mask the server reported for the moment before the event.
    pub state: u16,
}

/// Turns the recorded event stream into the events a recording is made of.
///
/// Stateful for one reason, and it is the reason the Windows observer keeps the same state: X11
/// reports pointer motion continuously whenever the pointer moves at all, and queueing every
/// sample would fill the hand-off with events shared core discards -- hiding a real drop behind
/// noise. Motion only carries meaning between a press and its release.
#[derive(Debug, Default)]
pub struct Decoder {
    held: bool,
}

impl Decoder {
    /// What one recorded event amounts to, against this process's own delivery ledger.
    pub fn observe(&mut self, event: CoreEvent) -> Option<RawInput> {
        self.observe_against(self_delivery(), event)
    }

    /// The same decision against a ledger named explicitly.
    ///
    /// The ledger is a process-global in the running daemon, because the dispatch path that injects
    /// and the listener that observes are on opposite sides of the backend with no shared owner.
    /// Taking it as an argument here is what keeps a test from having to reach for that global and
    /// race every other test that does.
    pub fn observe_against(
        &mut self,
        self_delivery: &SelfDelivery,
        event: CoreEvent,
    ) -> Option<RawInput> {
        // Where this daemon's own delivery stops being a recordable event, and it happens here --
        // in the listener, not in enrichment -- because the ledger's deadline runs on a wall
        // clock while enrichment can be seconds behind a burst. An exclusion decided late would
        // find its own expectations already expired.
        //
        // Returning before the state below is touched is not incidental. If a stamped release
        // were allowed to clear `held` -- posted, say, while the user happens to be mid-drag --
        // every real motion sample after it would be discarded and the user's drag would be
        // recorded truncated. Excluding our own delivery has to include the state later events
        // are judged against, not only the events themselves.
        if self_delivery.claims(event.kind, event.detail) {
            return None;
        }
        match event.kind {
            KEY_PRESS => Some(RawInput::Key {
                keycode: event.detail,
                state: event.state,
            }),
            // Nothing to carry. The modifier state a later keystroke is read against travels on
            // the event that needs it, so unlike a low-level Windows hook this observer has no
            // state to fold a release into.
            KEY_RELEASE => None,
            BUTTON_PRESS | BUTTON_RELEASE => {
                let down = event.kind == BUTTON_PRESS;
                match event.detail {
                    BUTTON_PRIMARY => {
                        self.held = down;
                        Some(RawInput::Button {
                            down,
                            point: event.point,
                        })
                    }
                    // A wheel notch is a press and a release of the same button. Only the press is
                    // a notch; recording the release too would double every scroll.
                    button if down && wheel_delta(button).is_some() => Some(RawInput::Wheel {
                        button,
                        point: event.point,
                    }),
                    _ => None,
                }
            }
            MOTION_NOTIFY => self.held.then_some(RawInput::Motion { point: event.point }),
            _ => None,
        }
    }
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
    if modifiers.level3 {
        2 + shifted
    } else {
        shifted
    }
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
        0xFF55 | 0xFF9A => "pageup",   // Prior
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
/// **`STATE_PROTECTED` is not one of the signals, because AT-SPI does not have it.** It is ATK and
/// MSAA vocabulary; the AT-SPI state set has no member of that name, and the state that *is* called
/// `SENSITIVE` there means the opposite of what the word suggests -- that a widget is enabled and
/// can be interacted with. Reading either as "holds a credential" would mark almost every element
/// sensitive or none of them.
///
/// What AT-SPI does have is `ROLE_PASSWORD_TEXT`, which is what GTK entries, Qt line edits, and
/// Chromium and Firefox web content all report for a concealed field, and it is the floor. The
/// description is tested beside it for the same reason the macOS observer tests it: a provider that
/// spells the concealment in words rather than in the role is still telling us. The description and
/// not the name, because on this platform an entry's `name` is usually its *label* -- and a field
/// labelled "Password" next to the real one would otherwise be recorded as a secret.
pub fn is_sensitive(role: &str, description: Option<&str>) -> bool {
    role.trim().eq_ignore_ascii_case("password text")
        || description.is_some_and(|description| description.to_lowercase().contains("password"))
}

/// What one AT-SPI element says about itself, in the fields a capture and a recording both describe
/// it by.
///
/// One reading builds both, and agreement between them is the reason it exists. Shared core turns a
/// recorded event into a semantic target by comparing each evidence candidate field by field against
/// a fresh capture, so a field that evidence spells one way and capture another matches nothing --
/// and the failure is silent: every click still records, as a bare screen point. Two hand-written
/// mappings of the same AT-SPI properties can drift apart that way with neither noticing; one
/// mapping cannot.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ElementDescription {
    pub role: String,
    /// The AT-SPI accessible name. On this platform that is usually the element's visible label.
    pub name: Option<String>,
    pub description: Option<String>,
    /// The bus name and object path: exact, and stable for as long as the element exists.
    pub identifier: String,
    pub actions: Vec<String>,
}

impl ElementDescription {
    pub fn is_sensitive(&self) -> bool {
        is_sensitive(&self.role, self.description.as_deref())
    }

    /// The capture node, with every field a capture adds beyond this description left empty for
    /// the walk to fill in.
    ///
    /// AT-SPI publishes one name where this project has both a title and a label, and capture puts
    /// it in `label`.
    pub fn into_node(self) -> Node {
        Node {
            role: self.role,
            subrole: None,
            name: self.name.clone(),
            title: None,
            label: self.name,
            value: None,
            description: self.description,
            identifier: Some(self.identifier),
            actions: self.actions,
            frame: None,
            editable: false,
            focused: None,
            enabled: None,
            children: Vec::new(),
            child_count: None,
            truncation_reason: None,
        }
    }

    /// The evidence a recording carries for this element.
    ///
    /// Two fields are withheld from a candidate shared core will match, and each for a reason:
    ///
    /// - **`title`**, because capture leaves a node's title empty and puts the name in `label`, for
    ///   which the evidence vocabulary has no field. A candidate carrying the name as its title would
    ///   match no node at all. A sensitive candidate keeps it, because shared core never matches one
    ///   -- it refuses to build a target from a credential field -- and the field's name is the one
    ///   handle the person replaying has for the secret argument it becomes.
    /// - **`value`**, because it is read at event time while the snapshot it is compared with is
    ///   captured when the recording is next pumped, which may be after the user has typed into the
    ///   very field they clicked. The identifier already names the element exactly, so the value
    ///   could only add a way to fail. The `setValue` payload is read separately, from the focused
    ///   element at the moment its burst is flushed.
    pub fn into_evidence(self, window_title: Option<&str>) -> RecordedElementEvidence {
        let sensitive = self.is_sensitive();
        RecordedElementEvidence {
            role: self.role,
            subrole: None,
            identifier: Some(self.identifier),
            title: if sensitive { self.name } else { None },
            value: None,
            description: self.description,
            actions: self.actions,
            window_title: window_title.map(str::to_owned),
            sensitive,
        }
    }
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

/// Names one registered expectation, so the site that registered it can take it back.
///
/// An identity and not a `(kind, detail)` pair, because those are not unique: a keyboard sequence
/// registers a press and a release for the same keycode, and a retracted failure that matched by
/// shape could remove the expectation belonging to an injection that did go out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ExpectationId(u64);

/// One event this daemon is about to put into the server's input stream.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Expectation {
    id: ExpectationId,
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
    next_id: AtomicU64,
    expectations: Mutex<VecDeque<Expectation>>,
}

impl SelfDelivery {
    const fn new() -> Self {
        Self {
            armed: AtomicBool::new(false),
            next_id: AtomicU64::new(0),
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
    ///
    /// Returns the expectation's identity so a caller whose request then failed can take it back
    /// with [`Self::cancel`]. `None` means nothing was recorded, because nothing is observing.
    pub fn expect(&self, kind: u8, detail: u8) -> Option<ExpectationId> {
        self.expect_at(kind, detail, Instant::now())
    }

    fn expect_at(&self, kind: u8, detail: u8, now: Instant) -> Option<ExpectationId> {
        if !self.armed.load(Ordering::Acquire) {
            return None;
        }
        let id = ExpectationId(self.next_id.fetch_add(1, Ordering::Relaxed));
        let mut expectations = self.expectations.lock().expect(NEVER_POISONED);
        expectations.retain(|pending| pending.expires > now);
        if expectations.len() >= MAX_EXPECTATIONS {
            expectations.pop_front();
        }
        expectations.push_back(Expectation {
            id,
            kind,
            detail,
            expires: now + EXPECTATION_LIFETIME,
        });
        Some(id)
    }

    /// Takes back an expectation for an injection that never happened.
    ///
    /// The deadline above is a backstop for what cannot be known — an event the server dropped, an
    /// asynchronous X error — and it is deliberately generous. A request that failed *at the call
    /// site* is not that case: it is known immediately, and leaving its expectation to expire would
    /// let a failed dispatch discard the next genuine thing the user did with the same key or
    /// button for the whole of that interval. A partially delivered keyboard sequence makes it
    /// worse, because each failed press or release leaves its own suppressor behind.
    pub fn cancel(&self, expectation: Option<ExpectationId>) {
        let Some(id) = expectation else { return };
        let mut expectations = self.expectations.lock().expect(NEVER_POISONED);
        if let Some(index) = expectations.iter().position(|pending| pending.id == id) {
            expectations.remove(index);
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A recorded click on an element is only worth anything if shared core can find that element
    /// again in a capture. Driven through the public recorder rather than its private matching
    /// predicate, so it fails for any reason a real recording would degrade to a screen point.
    mod evidence_resolves_against_capture {
        use super::*;
        use axon_core::{
            Application, BackendError, GlobalInputObserver, OwnedUserActionRecorder,
            RecordedAppIdentity, RecordedFocusedEvidence, RecordedInputEvent, RecordedPoint,
            RecordedSettleEvidence, RecordedTargetEvidence, RecordedUserAction,
            RecordingEvidenceProvider, RecordingScope, Snapshot, Window,
        };
        use std::collections::VecDeque;

        struct Provider {
            events: VecDeque<Vec<RecordedInputEvent>>,
            focused: Option<RecordedFocusedEvidence>,
            snapshot: Snapshot,
        }

        impl GlobalInputObserver for Provider {
            fn start(&mut self, _: &RecordingScope) -> Result<(), BackendError> {
                Ok(())
            }
            fn poll(&mut self, _: Duration) -> Result<Vec<RecordedInputEvent>, BackendError> {
                Ok(self.events.pop_front().unwrap_or_default())
            }
            fn stop(&mut self) -> Result<(), BackendError> {
                Ok(())
            }
            fn is_recording(&self) -> bool {
                true
            }
        }

        impl RecordingEvidenceProvider for Provider {
            fn read_focused(&mut self) -> Result<Option<RecordedFocusedEvidence>, BackendError> {
                Ok(self.focused.clone())
            }
            fn capture_snapshot(
                &mut self,
                _: &RecordedAppIdentity,
            ) -> Result<Option<Snapshot>, BackendError> {
                Ok(Some(self.snapshot.clone()))
            }
            fn settle(
                &mut self,
                _: usize,
                _: &str,
            ) -> Result<RecordedSettleEvidence, BackendError> {
                Ok(RecordedSettleEvidence::default())
            }
        }

        fn chromium() -> RecordedAppIdentity {
            RecordedAppIdentity {
                name: "Chromium".into(),
                bundle_identifier: None,
                process_id: Some(4242),
            }
        }

        fn described(role: &str, name: &str, path: &str) -> ElementDescription {
            ElementDescription {
                role: role.into(),
                name: Some(name.into()),
                description: None,
                identifier: format!(":1.42{path}"),
                actions: vec!["click".into()],
            }
        }

        /// The window a capture of `elements` produces, with each node given the value it holds
        /// *when the snapshot is taken* -- which is later than the evidence was read.
        fn captured(elements: Vec<(ElementDescription, Option<&str>)>) -> Snapshot {
            let mut root = ElementDescription {
                role: "frame".into(),
                name: Some("Axon Recording Probe".into()),
                identifier: ":1.42/org/a11y/atspi/accessible/1".into(),
                ..Default::default()
            }
            .into_node();
            root.children = elements
                .into_iter()
                .map(|(element, value)| Node {
                    value: value.map(str::to_owned),
                    ..element.into_node()
                })
                .collect();
            Snapshot::new(Application {
                process_id: Some(4242),
                name: "Chromium".into(),
                identifier: None,
                windows: vec![Window {
                    title: root.name.clone(),
                    root,
                }],
            })
        }

        fn at(element: &ElementDescription) -> RecordedTargetEvidence {
            RecordedTargetEvidence {
                app: chromium(),
                point: RecordedPoint { x: 100.0, y: 200.0 },
                candidates: vec![element.clone().into_evidence(Some("Axon Recording Probe"))],
            }
        }

        fn record(provider: Provider) -> Vec<RecordedUserAction> {
            let mut recorder =
                OwnedUserActionRecorder::start(provider, RecordingScope::AllApplications).unwrap();
            recorder.poll(Duration::ZERO).unwrap();
            recorder
                .finish()
                .unwrap()
                .into_iter()
                .filter_map(|group| group.action)
                .collect()
        }

        fn is_semantic(target: &serde_json::Value) -> bool {
            target.get("locator").is_some() && target.get("point").is_none()
        }

        #[test]
        fn a_click_and_a_typed_burst_both_resolve_to_the_elements_they_hit() {
            let button = described("button", "Press me", "/org/a11y/atspi/accessible/7");
            let entry = described("entry", "Recording note", "/org/a11y/atspi/accessible/9");
            let click = |element: &ElementDescription| {
                [
                    RecordedInputEvent::MouseDown {
                        evidence: at(element),
                        timestamp_ms: 1,
                    },
                    RecordedInputEvent::MouseUp {
                        evidence: at(element),
                        timestamp_ms: 2,
                    },
                ]
            };
            let mut events: Vec<_> = click(&button).into_iter().chain(click(&entry)).collect();
            events.push(RecordedInputEvent::KeyDown {
                app: chromium(),
                keystroke: RecordedKeystroke::Text {
                    text: "axon recorded this".into(),
                },
                timestamp_ms: 3,
            });

            let actions = record(Provider {
                events: VecDeque::from([events]),
                focused: Some(RecordedFocusedEvidence {
                    target: at(&entry),
                    value: Some("axon recorded this".into()),
                }),
                // Captured after the burst, as a pump on `recording.stop` would: the entry already
                // holds the text that was typed after it was clicked, which no event-time read of it
                // could have known.
                snapshot: captured(vec![
                    (button, Some("Press me")),
                    (entry, Some("axon recorded this")),
                ]),
            });

            assert_eq!(actions.len(), 3, "{actions:#?}");
            for action in &actions {
                let target = match action {
                    RecordedUserAction::Click { target } => target,
                    RecordedUserAction::SetValue { target, value, .. } => {
                        assert_eq!(value, "axon recorded this");
                        target
                    }
                    other => panic!("unexpected action {other:?}"),
                };
                assert!(
                    is_semantic(target),
                    "every action resolves to an element rather than a point: {target}"
                );
            }
        }

        #[test]
        fn a_password_field_keeps_its_name_for_the_secret_and_nothing_else() {
            let field = ElementDescription {
                role: "password text".into(),
                ..described("", "Password", "/org/a11y/atspi/accessible/11")
            };
            let evidence = field.clone().into_evidence(None);
            assert!(evidence.sensitive);
            assert_eq!(evidence.value, None, "a credential is never carried");
            assert_eq!(evidence.title.as_deref(), Some("Password"));

            let ordinary = described("entry", "Password hint", "/org/a11y/atspi/accessible/12")
                .into_evidence(None);
            assert!(!ordinary.sensitive);
            assert_eq!(
                ordinary.title, None,
                "capture has no title to match an ordinary element's against"
            );
        }
    }

    /// A US layout stub standing in for `GetKeyboardMapping`: two keysyms per keycode, the
    /// unshifted one and the shifted one, in the order the protocol reports them.
    fn us_layout(pair: [u32; 2]) -> impl Fn(ModifierState) -> Option<u32> {
        move |modifiers| pair.get(keysym_level(modifiers).min(1)).copied()
    }

    #[test]
    fn a_plain_letter_is_text_and_shift_only_changes_its_case() {
        let layout = us_layout([u32::from(b'a'), u32::from(b'A')]);
        assert_eq!(
            classify_keystroke(ModifierState::default(), &layout),
            Some(RecordedKeystroke::Text { text: "a".into() })
        );
        let shifted = ModifierState {
            shift: true,
            ..Default::default()
        };
        assert_eq!(
            classify_keystroke(shifted, &layout),
            Some(RecordedKeystroke::Text { text: "A".into() }),
            "shift alone is case, not a chord"
        );
    }

    #[test]
    fn a_control_chord_is_named_by_its_unmodified_base_key() {
        let layout = us_layout([u32::from(b'l'), u32::from(b'L')]);
        let control = ModifierState {
            control: true,
            ..Default::default()
        };
        assert_eq!(
            classify_keystroke(control, &layout),
            Some(RecordedKeystroke::Key {
                key: "ctrl+l".into()
            })
        );

        let layout = us_layout([u32::from(b'p'), u32::from(b'P')]);
        let both = ModifierState {
            control: true,
            shift: true,
            ..Default::default()
        };
        assert_eq!(
            classify_keystroke(both, &layout),
            Some(RecordedKeystroke::Key {
                key: "ctrl+shift+p".into()
            }),
            "the base key is the one the layout produces unmodified, not the shifted glyph"
        );
    }

    #[test]
    fn every_recorded_chord_is_one_this_project_can_replay() {
        let layout = us_layout([u32::from(b's'), u32::from(b'S')]);
        let all = ModifierState {
            shift: true,
            control: true,
            alt: true,
            super_key: true,
            ..Default::default()
        };
        let Some(RecordedKeystroke::Key { key }) = classify_keystroke(all, &layout) else {
            panic!("a fully modified letter is a chord");
        };
        assert_eq!(key, "super+ctrl+alt+shift+s");
        let chord = axon_core::parse_chord(&key).expect("a recorded chord parses back");
        assert_eq!(chord.key, axon_core::Key::Character('s'));
        assert_eq!(chord.modifiers.len(), 4);
    }

    /// Every name this observer can produce has to survive the round trip a replay makes, because
    /// replay parses the recorded string and synthesizes it through `keys::keysym_for`.
    #[test]
    fn every_named_key_this_observer_produces_replays_through_the_same_table() {
        for keysym in (0xFF00_u32..=0xFFFF).chain([0x0100_0041]) {
            let Some(name) = named_key(keysym) else {
                continue;
            };
            let chord = axon_core::parse_chord(name)
                .unwrap_or_else(|error| panic!("{keysym:#06x} recorded as {name}: {error}"));
            let axon_core::Key::Named(key) = chord.key else {
                panic!("{name} is a named key, not a character");
            };
            assert_eq!(
                crate::keys::keysym_for(axon_core::Key::Named(key)),
                match keysym {
                    // The keypad twins resolve to their main-block keysym, which is the one this
                    // project synthesizes; that they are not identical is the point of naming both.
                    0xFF8D => 0xFF0D,
                    0xFF9F => 0xFFFF,
                    0xFF9E => 0xFF63,
                    0xFF95 => 0xFF50,
                    0xFF9C => 0xFF57,
                    0xFF9A => 0xFF55,
                    0xFF9B => 0xFF56,
                    0xFF97 => 0xFF52,
                    0xFF99 => 0xFF54,
                    0xFF96 => 0xFF51,
                    0xFF98 => 0xFF53,
                    other => other,
                },
                "{name} does not synthesize back to the keysym it was recorded from"
            );
        }
    }

    #[test]
    fn modifiers_are_context_and_an_unmapped_key_is_nothing() {
        for keysym in [0xFFE1, 0xFFE3, 0xFFE9, 0xFFEB, 0xFFE5, 0xFE03, 0xFF7F] {
            assert_eq!(
                classify_keystroke(ModifierState::default(), |_| Some(keysym)),
                None,
                "{keysym:#06x} is context, not a keystroke"
            );
        }
        assert_eq!(
            classify_keystroke(ModifierState::default(), |_| None),
            None,
            "a keycode the layout has nothing for is not recorded"
        );
        assert_eq!(
            classify_keystroke(ModifierState::default(), |_| Some(0xFF6A)),
            None,
            "a keysym that is neither named nor text is not recorded"
        );
    }

    #[test]
    fn unicode_and_keypad_keysyms_resolve_to_the_characters_they_type() {
        assert_eq!(keysym_text(0x0100_00E9).as_deref(), Some("\u{e9}"));
        assert_eq!(keysym_text(0xE9).as_deref(), Some("\u{e9}"), "Latin-1");
        assert_eq!(keysym_text(0x20).as_deref(), Some(" "));
        assert_eq!(keysym_text(0xFFB7).as_deref(), Some("7"), "KP_7");
        assert_eq!(keysym_text(0xFFAB).as_deref(), Some("+"), "KP_Add");
        assert_eq!(keysym_text(0xFF0D), None, "Return types no text");
        assert_eq!(
            keysym_text(0x0100_0009),
            None,
            "a control character is not typed text"
        );
    }

    #[test]
    fn caps_lock_selects_the_shifted_level_and_shift_takes_it_back() {
        let lock = ModifierState {
            lock: true,
            ..Default::default()
        };
        assert_eq!(keysym_level(lock), 1);
        assert_eq!(
            keysym_level(ModifierState {
                shift: true,
                ..lock
            }),
            0,
            "shift while caps lock is on types lower case"
        );
        assert_eq!(
            keysym_level(ModifierState {
                level3: true,
                ..Default::default()
            }),
            2,
            "AltGr is a second pair of levels, not a chord"
        );
        assert!(
            !ModifierState {
                level3: true,
                shift: true,
                ..Default::default()
            }
            .chorded()
        );
    }

    #[test]
    fn modifier_bits_are_read_from_the_server_rather_than_assumed() {
        // A session that puts Super on Mod3 instead of Mod4. Under the conventional masks the same
        // event reads as no modifier at all, and every chord would be recorded under a wrong name.
        let rearranged = ModifierMasks {
            super_key: 1 << 5,
            ..ModifierMasks::CONVENTIONAL
        };
        let state = ModifierState::from_mask(1 << 5, rearranged);
        assert!(state.super_key);
        assert!(
            !ModifierState::from_mask(1 << 5, ModifierMasks::CONVENTIONAL).super_key,
            "this is the reading the mapping exists to correct"
        );
        assert_eq!(state.names(), vec!["super"]);
        // A mask a server did not publish at all must never match, however the bits fall.
        let missing = ModifierMasks {
            level3: 0,
            ..ModifierMasks::CONVENTIONAL
        };
        assert!(!ModifierState::from_mask(u16::MAX, missing).level3);
    }

    #[test]
    fn wheel_notches_keep_one_sign_convention_across_platforms() {
        assert_eq!(wheel_delta(BUTTON_WHEEL_UP), Some((0.0, 1.0)));
        assert_eq!(wheel_delta(BUTTON_WHEEL_DOWN), Some((0.0, -1.0)));
        assert_eq!(wheel_delta(BUTTON_WHEEL_RIGHT), Some((1.0, 0.0)));
        assert_eq!(wheel_delta(BUTTON_WHEEL_LEFT), Some((-1.0, 0.0)));
        assert_eq!(
            wheel_delta(BUTTON_PRIMARY),
            None,
            "an ordinary button is a click, not a scroll"
        );
    }

    #[test]
    fn a_password_element_is_sensitive_and_an_ordinary_one_is_not() {
        assert!(
            is_sensitive("password text", None),
            "ROLE_PASSWORD_TEXT is the floor this platform can actually offer"
        );
        assert!(is_sensitive("Password Text", None), "however it is cased");
        assert!(is_sensitive("entry", Some("Master Password")));
        assert!(!is_sensitive("entry", None));
        assert!(!is_sensitive("text", Some("Search")));
        assert!(
            !is_sensitive("label", None),
            "the label beside a password field is not itself one"
        );
    }

    #[test]
    fn the_ledger_excludes_our_own_delivery_once_each_and_leaves_the_users_alone() {
        let ledger = SelfDelivery::new();
        assert!(
            !ledger.claims(KEY_PRESS, 38),
            "nothing is excluded while no session is observing"
        );
        ledger.expect(KEY_PRESS, 38);
        assert_eq!(ledger.outstanding(), 0, "a disarmed ledger records nothing");

        ledger.arm();
        // One click, as `X11Session::click` posts it.
        ledger.expect(MOTION_NOTIFY, 0);
        ledger.expect(BUTTON_PRESS, BUTTON_PRIMARY);
        ledger.expect(BUTTON_RELEASE, BUTTON_PRIMARY);
        assert_eq!(ledger.outstanding(), 3);

        assert!(ledger.claims(MOTION_NOTIFY, 0));
        assert!(ledger.claims(BUTTON_PRESS, BUTTON_PRIMARY));
        assert!(ledger.claims(BUTTON_RELEASE, BUTTON_PRIMARY));
        assert!(
            !ledger.claims(BUTTON_PRESS, BUTTON_PRIMARY),
            "a user click that follows ours is the user's"
        );
        assert_eq!(ledger.outstanding(), 0);

        ledger.expect(KEY_PRESS, 38);
        assert!(
            !ledger.claims(KEY_PRESS, 39),
            "a different key is not the one we injected"
        );
        assert!(
            !ledger.claims(KEY_RELEASE, 38),
            "a release is not the press we registered"
        );
        assert!(ledger.claims(KEY_PRESS, 38));

        ledger.disarm();
        ledger.expect(KEY_PRESS, 38);
        assert!(!ledger.claims(KEY_PRESS, 38));
    }

    /// A dispatch that failed at the call site must not cost the user their next keystroke.
    ///
    /// The deadline below is a backstop for what cannot be known. A refused request is known
    /// immediately, and the two must not be confused: leaving a rejected injection to expire would
    /// discard the next genuine event of the same shape for the whole of that interval.
    #[test]
    fn a_rejected_injection_cannot_suppress_the_next_thing_the_user_does() {
        let ledger = SelfDelivery::new();
        ledger.arm();

        let rejected = ledger.expect(KEY_PRESS, 38);
        ledger.cancel(rejected);
        assert_eq!(ledger.outstanding(), 0);
        assert!(
            !ledger.claims(KEY_PRESS, 38),
            "the user's next press is the user's"
        );

        // A keyboard sequence that got half way out: the press was accepted and the release was
        // refused. Cancellation is by identity precisely so the retraction cannot reach across to
        // the half that did go, which a `(kind, detail)` match could not have told apart.
        let sent = ledger.expect(BUTTON_PRESS, BUTTON_PRIMARY);
        let refused = ledger.expect(BUTTON_PRESS, BUTTON_PRIMARY);
        ledger.cancel(refused);
        assert_eq!(ledger.outstanding(), 1);
        assert!(
            ledger.claims(BUTTON_PRESS, BUTTON_PRIMARY),
            "the injection that was accepted is still ours"
        );
        assert!(
            !ledger.claims(BUTTON_PRESS, BUTTON_PRIMARY),
            "and only that one; the refused half suppresses nothing"
        );

        // Cancelling twice, or cancelling one already consumed, disturbs nothing.
        ledger.cancel(sent);
        ledger.cancel(refused);
        ledger.cancel(None);
        assert_eq!(ledger.outstanding(), 0);

        // A disarmed ledger records nothing, so there is nothing to take back and saying so is not
        // an error either.
        ledger.disarm();
        ledger.cancel(ledger.expect(KEY_PRESS, 38));
        assert_eq!(ledger.outstanding(), 0);
    }

    #[test]
    fn an_expectation_that_never_arrived_stops_suppressing_input() {
        let ledger = SelfDelivery::new();
        ledger.arm();
        let injected = Instant::now();
        // A dispatch that errored, or a keycode this server has no key for: the event the ledger is
        // waiting on will never be generated, and without a deadline it would eat the next thing
        // the user really typed.
        ledger.expect_at(KEY_PRESS, 38, injected);
        assert!(!ledger.claims_at(KEY_PRESS, 38, injected + EXPECTATION_LIFETIME));
        assert_eq!(
            ledger.outstanding(),
            1,
            "expired but not yet swept, which is why matching checks the deadline too"
        );
        ledger.expect_at(KEY_PRESS, 39, injected + EXPECTATION_LIFETIME);
        assert_eq!(
            ledger.outstanding(),
            1,
            "the sweep runs on the next injection"
        );
    }

    /// What the listener makes of a stream, in the cases a real desktop would only produce by
    /// accident and this can produce on purpose.
    #[test]
    fn a_wheel_notch_is_a_scroll_and_motion_only_counts_between_a_press_and_its_release() {
        let ledger = SelfDelivery::new();
        let mut decoder = Decoder::default();
        let mut observe = |kind, detail| {
            decoder.observe_against(
                &ledger,
                CoreEvent {
                    kind,
                    detail,
                    point: (10, 20),
                    state: 0,
                },
            )
        };

        assert_eq!(
            observe(MOTION_NOTIFY, 0),
            None,
            "a pointer crossing the screen is not an action"
        );
        assert_eq!(
            observe(BUTTON_PRESS, BUTTON_PRIMARY),
            Some(RawInput::Button {
                down: true,
                point: (10, 20)
            })
        );
        assert_eq!(
            observe(MOTION_NOTIFY, 0),
            Some(RawInput::Motion { point: (10, 20) }),
            "motion between a press and its release is a drag"
        );
        assert_eq!(
            observe(BUTTON_RELEASE, BUTTON_PRIMARY),
            Some(RawInput::Button {
                down: false,
                point: (10, 20)
            })
        );
        assert_eq!(observe(MOTION_NOTIFY, 0), None);

        // X11 spells a wheel notch as a press and a release of button 4. Only the press is a notch.
        assert_eq!(
            observe(BUTTON_PRESS, BUTTON_WHEEL_UP),
            Some(RawInput::Wheel {
                button: BUTTON_WHEEL_UP,
                point: (10, 20)
            })
        );
        assert_eq!(
            observe(BUTTON_RELEASE, BUTTON_WHEEL_UP),
            None,
            "recording the release too would double every scroll"
        );
        assert_eq!(
            observe(MOTION_NOTIFY, 0),
            None,
            "nor does a wheel notch make the observer think a button is held"
        );

        assert_eq!(
            observe(KEY_PRESS, 38),
            Some(RawInput::Key {
                keycode: 38,
                state: 0
            })
        );
        assert_eq!(
            observe(KEY_RELEASE, 38),
            None,
            "a key release carries nothing the recorder needs"
        );
    }

    /// The sequence the ledger exists for, at the level the listener sees it.
    ///
    /// Our own release must not be what decides the user is no longer dragging. If it were, every
    /// real motion sample after a click this daemon posted mid-gesture would be discarded and the
    /// user's drag would be recorded truncated.
    #[test]
    fn our_own_click_cannot_truncate_a_drag_the_user_is_making() {
        let ledger = SelfDelivery::new();
        ledger.arm();
        let mut decoder = Decoder::default();
        let mut observe = |kind, detail| {
            decoder.observe_against(
                &ledger,
                CoreEvent {
                    kind,
                    detail,
                    point: (5, 6),
                    state: 0,
                },
            )
        };

        assert!(observe(BUTTON_PRESS, BUTTON_PRIMARY).is_some());

        // The daemon posts a click of its own, mid-gesture. Both halves are registered before they
        // are sent, exactly as `X11Session::fake_input` registers them.
        ledger.expect(BUTTON_PRESS, BUTTON_PRIMARY);
        ledger.expect(BUTTON_RELEASE, BUTTON_PRIMARY);
        assert_eq!(observe(BUTTON_PRESS, BUTTON_PRIMARY), None);
        assert_eq!(observe(BUTTON_RELEASE, BUTTON_PRIMARY), None);

        assert_eq!(
            observe(MOTION_NOTIFY, 0),
            Some(RawInput::Motion { point: (5, 6) }),
            "our own release must not end the user's drag"
        );
    }

    #[test]
    fn a_flood_of_failed_injections_cannot_grow_the_ledger_without_bound() {
        let ledger = SelfDelivery::new();
        ledger.arm();
        for _ in 0..(MAX_EXPECTATIONS * 2) {
            ledger.expect(KEY_PRESS, 38);
        }
        assert_eq!(ledger.outstanding(), MAX_EXPECTATIONS);
    }
}
