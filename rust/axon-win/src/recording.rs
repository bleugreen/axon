//! Translating the Windows low-level input stream into the shared recorder's vocabulary.
//!
//! Nothing in this module calls Win32, so the hosted suite exercises all of it on every platform
//! rather than only on the bench. `global_input.rs` owns the hooks, the two threads, and the UI
//! Automation reads; it feeds this module raw events and forwards what it decides they mean.
#![cfg_attr(not(windows), allow(dead_code))]

use axon_core::RecordedKeystroke;
use std::sync::OnceLock;

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
const DELIVERY_MARKER: usize = 0x4158_4F4E;

/// The stamp for one process's delivery.
///
/// Derived from the process id, not a constant, and that is the whole difference between a working
/// exclusion and a broken one. What must be excluded is *this* process's posts; a constant would
/// make every `axon-win.exe` on the machine indistinguishable from this one. The live acceptance
/// depends on exactly that distinction — the input it records is posted by a second Axon process
/// precisely because the daemon must not be recording itself — and under a constant that helper's
/// input would be silently dropped and the capability would look broken while working.
pub fn delivery_tag_for(process_id: u32) -> usize {
    DELIVERY_MARKER ^ (process_id as usize).rotate_left(usize::BITS / 2)
}

/// This process's stamp, computed once.
pub fn self_delivery_tag() -> usize {
    static TAG: OnceLock<usize> = OnceLock::new();
    *TAG.get_or_init(|| delivery_tag_for(std::process::id()))
}

/// Whether an input record carries this process's own delivery stamp.
pub fn is_self_delivered(extra_info: usize) -> bool {
    extra_info == self_delivery_tag()
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
    Button {
        down: bool,
        point: (i32, i32),
    },
    Motion {
        point: (i32, i32),
    },
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
    /// The `dwExtraInfo` the hook was handed, carried rather than acted on in the callback.
    ///
    /// The self-delivery test could be made here and save a queue slot, but the callback is not
    /// where a question should be answered that a diagnostic needs to see the inputs to. Carrying
    /// it means the raw stream is what the hook actually saw, which is the thing the live
    /// measurement has to be able to look at.
    pub extra_info: usize,
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
const VK_PACKET: u16 = 0xE7;

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
    scan_code: u32,
    modifiers: ModifierState,
    text: impl Fn(ModifierState) -> Option<String>,
) -> Option<RecordedKeystroke> {
    // Text delivered through `KEYEVENTF_UNICODE` arrives as `VK_PACKET` carrying the character
    // itself in the scan code, because there is no key on any layout that would produce it. It has
    // to be read here or not at all: no keyboard layout can translate `VK_PACKET`, so every such
    // keystroke would otherwise be dropped -- and this is how assistive technology, remote desktop
    // sessions, IME relays, and any other process typing text it did not get from a keyboard all
    // reach an application. A recorder blind to them is blind to a whole class of real input.
    if virtual_key == VK_PACKET {
        return char::from_u32(scan_code)
            .filter(|character| !character.is_control())
            .map(|character| RecordedKeystroke::Text {
                text: character.to_string(),
            });
    }
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

/// The bounded hand-off from the hook callback to the enrichment thread.
///
/// The discipline it enforces -- a producer that never waits, a drop count that is always reported,
/// and a queue that survives one session because a low-level hook callback is handed no context
/// pointer and can reach only a static -- is the same on every platform, so it is stated once in
/// shared core. Only the raw event differs.
pub type RawQueue = axon_core::ObservedInputQueue<RawEvent>;

/// Whether a button transition should change what the observer believes about the user's hand.
///
/// `None` for this process's own clicks, and that is the whole point. Pointer motion only carries
/// meaning between a press and its release, so the observer tracks whether a button is held and
/// discards motion outside that. If a stamped mouse-up were allowed to clear that state -- posted,
/// say, while the user happens to be mid-drag -- every real motion sample after it would be thrown
/// away and the user's drag would be recorded truncated. Excluding our own delivery per event has
/// to include the state later events are judged against, not only the events carrying the stamp.
pub fn button_state_change(down: bool, self_delivered: bool) -> Option<bool> {
    (!self_delivered).then_some(down)
}

/// Whether an element holds something the recorder must never read or transcribe.
///
/// One property, and deliberately only one: `UIA_IsPasswordPropertyId` is the floor the observer
/// sensitivity contract sets for this platform, and Windows offers no second signal to widen it
/// with — no secure-input mode, no protected-state bit. It is a function rather than an inlined
/// field read so the floor has somewhere to be stated and tested, and so widening it later is a
/// change to one place that already has a test pointed at it.
pub fn is_sensitive(is_password: bool) -> bool {
    is_password
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
            classify_keystroke(b'A'.into(), 0x1E, modifiers, us_layout(b'A'.into())),
            Some(RecordedKeystroke::Text { text: "a".into() })
        );
        modifiers.apply(0xA0, false);
        assert_eq!(
            classify_keystroke(b'A'.into(), 0x1E, modifiers, us_layout(b'A'.into())),
            Some(RecordedKeystroke::Text { text: "A".into() }),
            "shift alone is case, not a chord"
        );
    }

    #[test]
    fn a_control_chord_is_named_by_its_unmodified_base_key() {
        let mut modifiers = ModifierState::default();
        modifiers.apply(0xA2, false);
        assert_eq!(
            classify_keystroke(b'L'.into(), 0x26, modifiers, us_layout(b'L'.into())),
            Some(RecordedKeystroke::Key {
                key: "ctrl+l".into()
            })
        );
        modifiers.apply(0xA1, false);
        assert_eq!(
            classify_keystroke(b'P'.into(), 0x19, modifiers, us_layout(b'P'.into())),
            Some(RecordedKeystroke::Key {
                key: "ctrl+shift+p".into()
            })
        );
    }

    #[test]
    fn a_named_key_stays_named_with_and_without_modifiers() {
        let unmodified = ModifierState::default();
        assert_eq!(
            classify_keystroke(0x0D, 0x1C, unmodified, |_| None),
            Some(RecordedKeystroke::Key {
                key: "return".into()
            }),
            "Return is one keystroke, never the three characters `End` would spell"
        );
        let mut shifted = ModifierState::default();
        shifted.apply(0x10, false);
        assert_eq!(
            classify_keystroke(0x09, 0x0F, shifted, |_| None),
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
            classify_keystroke(b'S'.into(), 0x1F, modifiers, us_layout(b'S'.into()))
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
                classify_keystroke(virtual_key, 0, modifiers, us_layout(b'A'.into())),
                None,
                "{virtual_key:#04x} is context, not a keystroke"
            );
        }
        assert_eq!(
            classify_keystroke(0xFF, 0, modifiers, |_| None),
            None,
            "a key with neither a name nor a character is not recorded"
        );
        assert_eq!(
            classify_keystroke(0xFF, 0, modifiers, |_| Some("\u{1b}".into())),
            None,
            "a control character is not typed text"
        );
    }

    /// Unicode-injected text has no key behind it, so the layout can say nothing about it and the
    /// character has to be read straight out of the scan code. Every process that types text it did
    /// not get from a keyboard reaches an application this way.
    #[test]
    fn unicode_injected_text_is_read_from_the_packet_rather_than_the_layout() {
        let modifiers = ModifierState::default();
        assert_eq!(
            classify_keystroke(0xE7, u32::from('\u{e9}'), modifiers, |_| None),
            Some(RecordedKeystroke::Text { text: "é".into() }),
            "a layout that knows nothing about this key must not be consulted"
        );
        assert_eq!(
            classify_keystroke(0xE7, u32::from(' '), modifiers, |_| None),
            Some(RecordedKeystroke::Text { text: " ".into() })
        );
        assert_eq!(
            classify_keystroke(0xE7, u32::from('\u{1b}'), modifiers, |_| None),
            None,
            "a control character is not typed text however it arrived"
        );
        // A chord cannot be spelled over a packet: there is no key to name, and the modifier state
        // belongs to whatever the injecting process was doing rather than to this character.
        let mut chorded = ModifierState::default();
        chorded.apply(0xA2, false);
        assert_eq!(
            classify_keystroke(0xE7, u32::from('a'), chorded, |_| None),
            Some(RecordedKeystroke::Text { text: "a".into() })
        );
    }

    #[test]
    fn caps_lock_latches_on_the_press_and_survives_its_release() {
        let mut modifiers = ModifierState::default();
        modifiers.apply(VK_CAPITAL, false);
        modifiers.apply(VK_CAPITAL, true);
        assert_eq!(
            classify_keystroke(b'A'.into(), 0x1E, modifiers, us_layout(b'A'.into())),
            Some(RecordedKeystroke::Text { text: "A".into() })
        );
        assert_eq!(modifiers.key_state()[VK_CAPITAL as usize] & 0x01, 0x01);
        modifiers.apply(VK_CAPITAL, false);
        assert_eq!(
            classify_keystroke(b'A'.into(), 0x1E, modifiers, us_layout(b'A'.into())),
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
    fn a_password_field_is_sensitive() {
        assert!(is_sensitive(true), "UIA_IsPasswordPropertyId is the floor");
        assert!(!is_sensitive(false));
    }

    #[test]
    fn our_own_click_cannot_truncate_a_drag_the_user_is_making() {
        // The sequence that matters: the user presses and starts dragging, this daemon posts a
        // click of its own mid-gesture, and the user keeps dragging. Every motion in between is
        // still the user's, and the stamped up must not be what decides otherwise.
        let mut held = false;
        for (down, self_delivered) in [(true, false), (true, true), (false, true)] {
            if let Some(state) = button_state_change(down, self_delivered) {
                held = state;
            }
        }
        assert!(held, "a stamped release must not end the user's drag");

        assert_eq!(button_state_change(false, false), Some(false));
        assert_eq!(button_state_change(true, false), Some(true));
        assert_eq!(button_state_change(true, true), None);
    }

    #[test]
    fn only_this_process_own_stamp_is_treated_as_self_delivery() {
        assert!(is_self_delivered(self_delivery_tag()));
        assert!(!is_self_delivered(0), "ordinary hardware input");
        assert!(
            !is_self_delivered(0xDEAD_BEEF),
            "another process's injection is still the user's input as far as we are concerned"
        );

        // The live acceptance stands on this: its input helper is another `axon-win.exe`, and if
        // its stamp matched this one's the recording would drop every event it posted.
        let ours = std::process::id();
        let helper = ours.wrapping_add(1);
        assert_ne!(delivery_tag_for(ours), delivery_tag_for(helper));
        assert!(!is_self_delivered(delivery_tag_for(helper)));
        assert_eq!(delivery_tag_for(ours), self_delivery_tag());
    }

}
