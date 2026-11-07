//! Core Graphics input synthesis: what a keystroke, a click, and a wheel burst are made of, and
//! the calls that post them.
//!
//! The tables and arithmetic are pure and compile everywhere, so the router's tests exercise the
//! same key resolution the daemon dispatches with. Only [`native`] touches Core Graphics.
//!
//! Key codes come from a static US-ANSI table and never from the active keyboard layout. That is
//! deliberate: layout translation (`TISCopyCurrentKeyboardLayoutInputSource`, `UCKeyTranslate`) must
//! run on the main queue, and calling it from a daemon worker is the crash axn/215 recorded. It is
//! also the variant the acceptance campaign measured (`probe key_code_for`): a null event source,
//! keyDown then keyUp, the ANSI key code, and the Unicode payload on both events. Native controls
//! read the payload, so text in any script still arrives; only consumers that read raw key codes
//! under a non-ANSI layout see the ANSI position instead. A shortcut is the exception: a stroke that
//! holds Command, Control, or Option carries no payload, because AppKit does not match a menu key
//! equivalent against one (see [`keyboard_events`]).
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use axon_core::{Key, Modifier, NamedKey};

pub const FLAG_SHIFT: u64 = 1 << 17;
pub const FLAG_CONTROL: u64 = 1 << 18;
pub const FLAG_OPTION: u64 = 1 << 19;
pub const FLAG_COMMAND: u64 = 1 << 20;

/// The pause between characters of a text burst, as measured.
pub const CHARACTER_INTERVAL_MS: u64 = 20;

/// One key press: a virtual key code and the modifier flags held across it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stroke {
    pub code: u16,
    pub flags: u64,
    /// The character a character key types. An unmodified or Shift-only stroke carries it as the
    /// key events' Unicode payload; a shortcut carries none ([`keyboard_events`]), and a consumer
    /// that reads its characters (the recorder among them) recovers the key from its code.
    pub character: Option<char>,
}

/// The US-ANSI virtual key code that produces `character`, ignoring case.
///
/// `None` for characters with no key on that layout; a text burst still posts them with key code
/// 0 and the character as the Unicode payload, which is all that ever carried them.
pub fn ansi_key_code(character: char) -> Option<u16> {
    Some(match character.to_ascii_lowercase() {
        'a' => 0,
        's' => 1,
        'd' => 2,
        'f' => 3,
        'h' => 4,
        'g' => 5,
        'z' => 6,
        'x' => 7,
        'c' => 8,
        'v' => 9,
        'b' => 11,
        'q' => 12,
        'w' => 13,
        'e' => 14,
        'r' => 15,
        'y' => 16,
        't' => 17,
        '1' => 18,
        '2' => 19,
        '3' => 20,
        '4' => 21,
        '6' => 22,
        '5' => 23,
        '=' => 24,
        '9' => 25,
        '7' => 26,
        '-' => 27,
        '8' => 28,
        '0' => 29,
        ']' => 30,
        'o' => 31,
        'u' => 32,
        '[' => 33,
        'i' => 34,
        'p' => 35,
        '\n' | '\r' => 36,
        'l' => 37,
        'j' => 38,
        '\'' => 39,
        'k' => 40,
        ';' => 41,
        '\\' => 42,
        ',' => 43,
        '/' => 44,
        'n' => 45,
        'm' => 46,
        '.' => 47,
        '\t' => 48,
        ' ' => 49,
        '`' => 50,
        _ => return None,
    })
}

/// The character a US-ANSI key code types, unshifted: [`ansi_key_code`] run backwards, for a
/// keystroke that arrives without a Unicode payload.
pub fn ansi_character(code: u16) -> Option<char> {
    "abcdefghijklmnopqrstuvwxyz0123456789=-][';\\,./`"
        .chars()
        .find(|character| ansi_key_code(*character) == Some(code))
}

/// The virtual key code of a named key.
///
/// `Delete` is forward delete (117), which is what it means on Windows and Linux and what the
/// recorder writes for that key; `Backspace` is 51. The Swift daemon (until 0.4.0) aliased `delete`
/// to 51, so a `delete` in a Swift-made recording replays here as forward delete.
pub fn named_key_code(key: NamedKey) -> Result<u16, String> {
    Ok(match key {
        NamedKey::Return => 36,
        NamedKey::Tab => 48,
        NamedKey::Space => 49,
        NamedKey::Backspace => 51,
        NamedKey::Escape => 53,
        NamedKey::Delete => 117,
        NamedKey::Home => 115,
        NamedKey::PageUp => 116,
        NamedKey::End => 119,
        NamedKey::PageDown => 121,
        NamedKey::Left => 123,
        NamedKey::Right => 124,
        NamedKey::Down => 125,
        NamedKey::Up => 126,
        NamedKey::F1 => 122,
        NamedKey::F2 => 120,
        NamedKey::F3 => 99,
        NamedKey::F4 => 118,
        NamedKey::F5 => 96,
        NamedKey::F6 => 97,
        NamedKey::F7 => 98,
        NamedKey::F8 => 100,
        NamedKey::F9 => 101,
        NamedKey::F10 => 109,
        NamedKey::F11 => 103,
        NamedKey::F12 => 111,
        NamedKey::Insert => {
            return Err("Insert has no key on a Mac keyboard".into());
        }
    })
}

/// The Core Graphics flag a modifier holds. Super and Command are the same key on a Mac, as they
/// were in the Swift daemon.
pub fn modifier_flag(modifier: Modifier) -> u64 {
    match modifier {
        Modifier::Shift => FLAG_SHIFT,
        Modifier::Control => FLAG_CONTROL,
        Modifier::Alt => FLAG_OPTION,
        Modifier::Super | Modifier::Command => FLAG_COMMAND,
    }
}

/// Resolves a `key` intent, with or without modifiers, to the one stroke it posts.
///
/// A character with no ANSI key is refused here rather than posted as key code 0: under a held
/// modifier the key code is what the application reads, and code 0 is `a`.
pub fn stroke(spec: &str) -> Result<Stroke, String> {
    let chord = axon_core::parse_chord(spec)?;
    let (code, character) = match chord.key {
        Key::Named(key) => (named_key_code(key)?, None),
        Key::Character(character) => (
            ansi_key_code(character).ok_or_else(|| {
                format!("{character} has no key on the US-ANSI layout this backend posts with")
            })?,
            Some(character.to_ascii_lowercase()),
        ),
    };
    Ok(Stroke {
        code,
        character,
        flags: chord
            .modifiers
            .into_iter()
            .fold(0, |flags, modifier| flags | modifier_flag(modifier)),
    })
}

/// The modifier keys a chord presses, in the order they go down, with the flag each holds. Released
/// in reverse.
const MODIFIER_KEYS: [(u64, u16); 4] = [
    (FLAG_COMMAND, 55),
    (FLAG_SHIFT, 56),
    (FLAG_OPTION, 58),
    (FLAG_CONTROL, 59),
];

/// One keyboard event a stroke posts: a key code, whether it goes down, and the flags it carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeyEvent {
    pub code: u16,
    pub down: bool,
    pub flags: u64,
}

/// Every event one stroke posts, in order.
///
/// Each modifier is pressed and released as a key of its own, and the last release carries no
/// flags. Setting a modifier's flag on the key's events alone is not a chord the window server can
/// close: it records the flag into the session's modifier state and nothing ever clears it, so
/// Command stays logically held and every later keystroke on the machine, the user's included,
/// arrives as a Command shortcut. That was measured on bgsrv-mac (axn/230), after a chord built that
/// way.
pub fn stroke_events(stroke: Stroke) -> Vec<KeyEvent> {
    let held: Vec<(u64, u16)> = MODIFIER_KEYS
        .into_iter()
        .filter(|(flag, _)| stroke.flags & flag != 0)
        .collect();
    let mut events = Vec::with_capacity(held.len() * 2 + 2);
    let mut flags = 0;
    for &(flag, code) in &held {
        flags |= flag;
        events.push(KeyEvent {
            code,
            down: true,
            flags,
        });
    }
    events.push(KeyEvent {
        code: stroke.code,
        down: true,
        flags,
    });
    events.push(KeyEvent {
        code: stroke.code,
        down: false,
        flags,
    });
    for &(flag, code) in held.iter().rev() {
        flags &= !flag;
        events.push(KeyEvent {
            code,
            down: false,
            flags,
        });
    }
    events
}

/// The modifiers that make a stroke a shortcut rather than a character. Shift is not among them:
/// it chooses which character a key types.
const SHORTCUT_FLAGS: u64 = FLAG_COMMAND | FLAG_CONTROL | FLAG_OPTION;

/// The one stroke that types `character` as text: no modifiers, the ANSI key code where there is
/// one and code 0 where there is not, and the character itself, case kept, as the payload.
pub fn text_stroke(character: char) -> Stroke {
    Stroke {
        code: ansi_key_code(character).unwrap_or(0),
        flags: 0,
        character: Some(character),
    }
}

/// Every event one stroke posts ([`stroke_events`]), each beside the character it carries as its
/// Unicode payload.
///
/// Only the key's own events carry a character; a modifier key types nothing. A shortcut's key
/// events carry none either. On bgsrv-mac (macOS 26.6, axn/268), `cmd+n` posted to TextEdit with
/// the payload `n` on its key events opened no window, while the identical sequence without the
/// payload did, whether posted to the HID tap, the session tap, or the process, and with or
/// without gaps between events: AppKit matches menu key equivalents against characters it derives
/// from the key code, and an explicitly set string defeats that match. The key code alone then
/// says which key was pressed, as it does for a real keyboard's shortcut.
pub fn keyboard_events(stroke: Stroke) -> Vec<(KeyEvent, Option<char>)> {
    let payload = stroke
        .character
        .filter(|_| stroke.flags & SHORTCUT_FLAGS == 0);
    stroke_events(stroke)
        .into_iter()
        .map(|event| (event, payload.filter(|_| event.code == stroke.code)))
        .collect()
}

/// Whether a `key` intent holds any modifier. Text never does: every text event carries no flags,
/// which is the variant the campaign measured (it ran with no modifier held).
pub fn has_modifiers(spec: &str) -> Result<bool, String> {
    Ok(!axon_core::parse_chord(spec)?.modifiers.is_empty())
}

/// One classic wheel notch, the largest single step a burst carries.
const MAX_STEP: f64 = 120.0;
const MAX_STEPS: usize = 16;

/// The pause between wheel steps.
pub const WHEEL_STEP_INTERVAL_MS: u64 = 4;

/// Splits a pixel delta into the integer wheel steps a burst posts, as `(x, y)`.
///
/// A single large wheel event is clamped or ignored by some views, and a real wheel never arrives
/// as one jump. Each step is at most one notch, there are at most sixteen, and the running total is
/// what gets rounded, so the steps sum to exactly the rounded request instead of drifting by a unit
/// per step. A step that rounds to nothing on both axes is dropped rather than posted.
pub fn wheel_steps(delta_x: f64, delta_y: f64) -> Vec<(i32, i32)> {
    // `f64::max` ignores NaN, so finiteness is checked on each axis rather than on the magnitude.
    if !(delta_x.is_finite() && delta_y.is_finite()) {
        return Vec::new();
    }
    let magnitude = delta_x.abs().max(delta_y.abs());
    if magnitude == 0.0 {
        return Vec::new();
    }
    let count = ((magnitude / MAX_STEP).ceil() as usize).clamp(1, MAX_STEPS);
    let clamp = |value: f64| value.round().clamp(i32::MIN as f64, i32::MAX as f64) as i32;
    let mut steps = Vec::with_capacity(count);
    let (mut posted_x, mut posted_y) = (0i32, 0i32);
    for index in 1..=count {
        let share = index as f64 / count as f64;
        let x = clamp(delta_x * share) - posted_x;
        let y = clamp(delta_y * share) - posted_y;
        if x == 0 && y == 0 {
            continue;
        }
        posted_x += x;
        posted_y += y;
        steps.push((x, y));
    }
    steps
}

#[cfg(target_os = "macos")]
pub mod native {
    use super::{
        CHARACTER_INTERVAL_MS, KeyEvent, Stroke, WHEEL_STEP_INTERVAL_MS, keyboard_events,
        text_stroke,
    };
    use axon_core::{BackendError, Capability};
    use std::{ffi::c_void, thread::sleep, time::Duration};

    type CGEventRef = *const c_void;
    type CGEventSourceRef = *const c_void;

    #[repr(C)]
    #[derive(Clone, Copy, Debug, Default)]
    struct CGPoint {
        x: f64,
        y: f64,
    }

    const HID_EVENT_TAP: u32 = 0;
    const LEFT_MOUSE_DOWN: u32 = 1;
    const LEFT_MOUSE_UP: u32 = 2;
    const MOUSE_BUTTON_LEFT: u32 = 0;
    const MOUSE_EVENT_CLICK_STATE: u32 = 1;
    const SCROLL_UNIT_PIXEL: u32 = 0;

    #[link(name = "ApplicationServices", kind = "framework")]
    unsafe extern "C" {
        fn CGEventCreate(source: CGEventSourceRef) -> CGEventRef;
        fn CGEventGetLocation(event: CGEventRef) -> CGPoint;
        fn CGEventCreateKeyboardEvent(source: CGEventSourceRef, key: u16, down: bool)
        -> CGEventRef;
        fn CGEventKeyboardSetUnicodeString(event: CGEventRef, length: usize, string: *const u16);
        fn CGEventSetFlags(event: CGEventRef, flags: u64);
        fn CGEventCreateMouseEvent(
            source: CGEventSourceRef,
            kind: u32,
            position: CGPoint,
            button: u32,
        ) -> CGEventRef;
        fn CGEventSetIntegerValueField(event: CGEventRef, field: u32, value: i64);
        fn CGEventCreateScrollWheelEvent2(
            source: CGEventSourceRef,
            units: u32,
            wheel_count: u32,
            wheel1: i32,
            wheel2: i32,
            wheel3: i32,
        ) -> CGEventRef;
        fn CGEventSetLocation(event: CGEventRef, location: CGPoint);
        fn CGEventPost(tap: u32, event: CGEventRef);
        fn CGEventPostToPid(pid: i32, event: CGEventRef);
        fn CGWarpMouseCursorPosition(position: CGPoint) -> i32;
        fn CGEventSourceFlagsState(state: i32) -> u64;
    }

    const COMBINED_SESSION_STATE: i32 = 0;
    const HID_SYSTEM_STATE: i32 = 1;

    /// The modifier flags the window server holds, as `(combined session, HID system)`: the state a
    /// later null-source event inherits from.
    pub fn modifier_flags() -> (u64, u64) {
        unsafe {
            (
                CGEventSourceFlagsState(COMBINED_SESSION_STATE),
                CGEventSourceFlagsState(HID_SYSTEM_STATE),
            )
        }
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(value: *const c_void);
    }

    /// Where a posted event goes.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum Destination {
        /// The HID event tap: global input, routed by the window server like a real device.
        HidTap,
        /// One process, bypassing the window server. The application routes key events to its
        /// own key window; mouse events arrive with window number 0 and reach nothing.
        Process(i32),
    }

    fn created(
        event: CGEventRef,
        what: &str,
        capability: Capability,
    ) -> Result<CGEventRef, BackendError> {
        if event.is_null() {
            return Err(BackendError::Capability {
                capability,
                reason: format!("Core Graphics could not create the {what} event"),
                diagnostic: None,
            });
        }
        Ok(event)
    }

    /// Posts and releases one event.
    fn post(destination: Destination, event: CGEventRef) {
        unsafe {
            match destination {
                Destination::HidTap => CGEventPost(HID_EVENT_TAP, event),
                Destination::Process(pid) => CGEventPostToPid(pid, event),
            }
            CFRelease(event);
        }
    }

    /// Builds every event of a sequence before posting any, so a creation failure posts nothing
    /// rather than leaving a key held.
    ///
    /// Every event's flags are set explicitly. A null-source event otherwise inherits the session's
    /// current modifier state, so a modifier the user happens to be holding would turn background
    /// text into shortcuts in an application they are not looking at.
    fn build(events: &[(KeyEvent, Option<char>)]) -> Result<Vec<CGEventRef>, BackendError> {
        let mut built = Vec::with_capacity(events.len());
        for (event, character) in events {
            let payload = character.map(|character| character.encode_utf16(&mut [0; 2]).to_vec());
            match created(
                unsafe { CGEventCreateKeyboardEvent(std::ptr::null(), event.code, event.down) },
                "keyboard",
                Capability::KeyboardInput,
            ) {
                Ok(created) => {
                    unsafe {
                        CGEventSetFlags(created, event.flags);
                        if let Some(payload) = &payload {
                            CGEventKeyboardSetUnicodeString(
                                created,
                                payload.len(),
                                payload.as_ptr(),
                            );
                        }
                    }
                    built.push(created);
                }
                Err(error) => {
                    for event in built {
                        unsafe { CFRelease(event) };
                    }
                    return Err(error);
                }
            }
        }
        Ok(built)
    }

    /// Types `text` one character at a time, with no modifier flags.
    pub fn post_text(destination: Destination, text: &str) -> Result<(), BackendError> {
        for (index, character) in text.chars().enumerate() {
            if index > 0 {
                sleep(Duration::from_millis(CHARACTER_INTERVAL_MS));
            }
            for event in build(&keyboard_events(text_stroke(character)))? {
                post(destination, event);
            }
        }
        Ok(())
    }

    /// Presses one key, with each of its modifiers pressed around it as a key of its own.
    pub fn post_stroke(destination: Destination, stroke: Stroke) -> Result<(), BackendError> {
        // Only the key's own events carry its character, and a shortcut's carry none: AppKit
        // ignores a menu key equivalent whose event has an explicit string (axn/268, measured).
        for event in build(&keyboard_events(stroke))? {
            post(destination, event);
        }
        Ok(())
    }

    pub fn pointer_location() -> Option<(f64, f64)> {
        let event = unsafe { CGEventCreate(std::ptr::null()) };
        if event.is_null() {
            return None;
        }
        let point = unsafe { CGEventGetLocation(event) };
        unsafe { CFRelease(event) };
        Some((point.x, point.y))
    }

    /// Moves the real cursor without posting a mouse-moved event. Returns whether Core Graphics
    /// accepted the request.
    pub fn warp(to: (f64, f64)) -> bool {
        unsafe { CGWarpMouseCursorPosition(CGPoint { x: to.0, y: to.1 }) == 0 }
    }

    /// One left click at `point` through the HID tap: the construction the campaign's foreground
    /// control proved on every target. The cursor is warped there first and the button held for a
    /// human interval, because a view that tracks hover or debounces presses acts on neither a
    /// teleported press nor one shorter than any hand could make.
    pub fn click(point: (f64, f64)) -> Result<(), BackendError> {
        let position = CGPoint {
            x: point.0,
            y: point.1,
        };
        let mut events = Vec::with_capacity(2);
        for kind in [LEFT_MOUSE_DOWN, LEFT_MOUSE_UP] {
            match created(
                unsafe {
                    CGEventCreateMouseEvent(std::ptr::null(), kind, position, MOUSE_BUTTON_LEFT)
                },
                "mouse",
                Capability::PointerInput,
            ) {
                Ok(event) => events.push(event),
                Err(error) => {
                    for event in events {
                        unsafe { CFRelease(event) };
                    }
                    return Err(error);
                }
            }
        }
        warp(point);
        sleep(Duration::from_millis(120));
        let [down, up] = [events[0], events[1]];
        unsafe {
            CGEventSetIntegerValueField(down, MOUSE_EVENT_CLICK_STATE, 1);
            CGEventSetIntegerValueField(up, MOUSE_EVENT_CLICK_STATE, 1);
        }
        post(Destination::HidTap, down);
        sleep(Duration::from_millis(80));
        post(Destination::HidTap, up);
        Ok(())
    }

    /// Posts a pixel-unit wheel burst at `point` through the HID tap, returning the steps that were
    /// posted. A wheel event has no window of its own: the window server routes it by the event's
    /// location, so setting that location is what aims it.
    pub fn scroll(
        point: (f64, f64),
        steps: &[(i32, i32)],
    ) -> Result<Vec<(i32, i32)>, BackendError> {
        let position = CGPoint {
            x: point.0,
            y: point.1,
        };
        let mut posted = Vec::with_capacity(steps.len());
        for (index, &(x, y)) in steps.iter().enumerate() {
            let event = created(
                unsafe {
                    CGEventCreateScrollWheelEvent2(std::ptr::null(), SCROLL_UNIT_PIXEL, 2, y, x, 0)
                },
                "scroll-wheel",
                Capability::PointerInput,
            )?;
            unsafe { CGEventSetLocation(event, position) };
            post(Destination::HidTap, event);
            posted.push((x, y));
            if index + 1 < steps.len() {
                sleep(Duration::from_millis(WHEEL_STEP_INTERVAL_MS));
            }
        }
        Ok(posted)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Ported from `ScrollEventPathTests`: a request travels as notch-sized steps that sum to it.
    #[test]
    fn wheel_steps_sum_exactly_to_the_request() {
        for (x, y) in [
            (0.0, -400.0),
            (0.0, 400.0),
            (35.0, -120.0),
            (0.0, -121.0),
            (250.5, 0.0),
            (0.0, -5000.0),
            (7.0, 3.0),
        ] {
            let steps = wheel_steps(x, y);
            let (sum_x, sum_y) = steps
                .iter()
                .fold((0, 0), |(sx, sy), (dx, dy)| (sx + dx, sy + dy));
            assert_eq!(
                (sum_x, sum_y),
                (x.round() as i32, y.round() as i32),
                "({x}, {y})"
            );
            assert!(steps.len() <= 16, "({x}, {y}) took {} steps", steps.len());
            assert!(steps.iter().all(|&(dx, dy)| dx != 0 || dy != 0));
        }
    }

    #[test]
    fn wheel_steps_are_at_most_one_notch_until_the_step_cap_binds() {
        let steps = wheel_steps(0.0, -400.0);
        assert_eq!(steps.len(), 4);
        assert!(steps.iter().all(|&(_, dy)| dy.abs() <= 120));
        // Past sixteen notches the cap binds and each step carries more.
        assert_eq!(wheel_steps(0.0, -5000.0).len(), 16);
    }

    #[test]
    fn a_zero_or_non_finite_delta_posts_nothing() {
        assert!(wheel_steps(0.0, 0.0).is_empty());
        assert!(wheel_steps(f64::NAN, 10.0).is_empty());
        assert!(wheel_steps(0.4, 0.0).is_empty());
    }

    #[test]
    fn the_key_table_matches_the_measured_variant() {
        assert_eq!(ansi_key_code('a'), Some(0));
        assert_eq!(ansi_key_code('A'), Some(0));
        assert_eq!(ansi_key_code('p'), Some(35));
        assert_eq!(ansi_key_code(' '), Some(49));
        assert_eq!(ansi_key_code('0'), Some(29));
        assert_eq!(ansi_key_code('é'), None);
        assert_eq!(named_key_code(NamedKey::Delete), Ok(117));
        assert_eq!(named_key_code(NamedKey::Backspace), Ok(51));
        assert_eq!(named_key_code(NamedKey::F1), Ok(122));
        assert!(
            named_key_code(NamedKey::Insert)
                .unwrap_err()
                .contains("Insert")
        );
    }

    /// The sequence a chord posts presses its modifiers as keys and ends with nothing held: the
    /// last event carries no flags, so the window server's modifier state is closed.
    #[test]
    fn a_chord_presses_and_releases_its_modifiers_and_ends_with_nothing_held() {
        let event = |code, down, flags| KeyEvent { code, down, flags };
        assert_eq!(
            stroke_events(stroke("cmd+s").unwrap()),
            vec![
                event(55, true, FLAG_COMMAND),
                event(1, true, FLAG_COMMAND),
                event(1, false, FLAG_COMMAND),
                event(55, false, 0),
            ]
        );
        let all = FLAG_COMMAND | FLAG_SHIFT | FLAG_OPTION | FLAG_CONTROL;
        let events = stroke_events(stroke("ctrl+option+shift+cmd+Tab").unwrap());
        assert_eq!(events.len(), 10);
        assert_eq!(events[4], event(48, true, all));
        assert_eq!(events.last().unwrap().flags, 0);
        // Every modifier that went down comes back up, in reverse.
        let downs: Vec<u16> = events
            .iter()
            .filter(|e| e.down && e.code != 48)
            .map(|e| e.code)
            .collect();
        let mut ups: Vec<u16> = events
            .iter()
            .filter(|e| !e.down && e.code != 48)
            .map(|e| e.code)
            .collect();
        ups.reverse();
        assert_eq!(downs, ups);
        // An unmodified key, and every text character, is exactly one down and one up with no flags.
        assert_eq!(
            stroke_events(stroke("Return").unwrap()),
            vec![event(36, true, 0), event(36, false, 0)]
        );
    }

    /// A shortcut's key events carry no payload, so AppKit can match its key equivalent; an
    /// unmodified key, a Shift-only stroke, and text keep the character on the key's own events.
    #[test]
    fn a_shortcut_carries_no_payload_while_a_character_and_text_do() {
        let payloads = |stroke: Stroke| -> Vec<Option<char>> {
            keyboard_events(stroke)
                .into_iter()
                .map(|(_, payload)| payload)
                .collect()
        };
        assert_eq!(payloads(stroke("cmd+n").unwrap()), vec![None; 4]);
        assert_eq!(payloads(stroke("ctrl+a").unwrap()), vec![None; 4]);
        assert_eq!(payloads(stroke("option+e").unwrap()), vec![None; 4]);
        assert_eq!(payloads(stroke("cmd+shift+s").unwrap()), vec![None; 6]);
        assert_eq!(payloads(stroke("n").unwrap()), vec![Some('n'); 2]);
        assert_eq!(
            payloads(stroke("shift+a").unwrap()),
            vec![None, Some('a'), Some('a'), None]
        );
        assert_eq!(payloads(stroke("Return").unwrap()), vec![None; 2]);
        assert_eq!(payloads(text_stroke('N')), vec![Some('N'); 2]);
        assert_eq!(payloads(text_stroke('é')), vec![Some('é'); 2]);
        // The events themselves are exactly the stroke's, whatever they carry.
        let chord = stroke("cmd+n").unwrap();
        let events: Vec<KeyEvent> = keyboard_events(chord).into_iter().map(|(e, _)| e).collect();
        assert_eq!(events, stroke_events(chord));
        assert_eq!(
            stroke_events(text_stroke('é')),
            vec![
                KeyEvent { code: 0, down: true, flags: 0 },
                KeyEvent { code: 0, down: false, flags: 0 },
            ]
        );
    }

    #[test]
    fn every_ansi_key_code_reads_back_to_the_character_that_produces_it() {
        for character in "abcdefghijklmnopqrstuvwxyz0123456789=-][';\\,./`".chars() {
            let code = ansi_key_code(character).unwrap();
            assert_eq!(ansi_character(code), Some(character), "{character}");
        }
        assert_eq!(
            ansi_character(36),
            None,
            "Return is a named key, not a character"
        );
    }

    #[test]
    fn chords_map_to_flags_with_super_and_command_as_one_key() {
        assert_eq!(
            stroke("cmd+s").unwrap(),
            Stroke {
                code: 1,
                flags: FLAG_COMMAND,
                character: Some('s'),
            }
        );
        assert_eq!(stroke("super+s").unwrap(), stroke("command+s").unwrap());
        assert_eq!(
            stroke("ctrl+option+shift+Tab").unwrap(),
            Stroke {
                code: 48,
                flags: FLAG_CONTROL | FLAG_OPTION | FLAG_SHIFT,
                character: None,
            }
        );
        assert_eq!(
            stroke("Return").unwrap(),
            Stroke {
                code: 36,
                flags: 0,
                character: None
            }
        );
        assert!(stroke("cmd+é").unwrap_err().contains("US-ANSI"));
        assert!(stroke("Insert").is_err());
        assert!(has_modifiers("cmd+a").unwrap());
        assert!(!has_modifiers("Return").unwrap());
    }
}
