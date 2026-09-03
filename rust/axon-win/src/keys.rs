//! Pure Windows virtual-key mapping over Axon's shared vocabulary.
#![cfg_attr(not(windows), allow(dead_code))]
use axon_core::{Modifier, NamedKey};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VirtualKey {
    pub code: u16,
    pub extended: bool,
}
const fn vk(code: u16, extended: bool) -> VirtualKey {
    VirtualKey { code, extended }
}
pub fn modifier_key(modifier: Modifier) -> VirtualKey {
    match modifier {
        Modifier::Shift => vk(0x10, false),
        Modifier::Control => vk(0x11, false),
        Modifier::Alt => vk(0x12, false),
        Modifier::Super => vk(0x5B, true),
    }
}
/// The shared vocabulary's name for a Windows virtual key, or nothing when the key has no name in
/// it and can only be described by the character it produces.
///
/// This is [`named_key`] run backwards, and the recorder is why it exists: a low-level hook hands
/// over a virtual key, and a recorded `PressKey` has to spell that key the way `parse_chord` reads
/// it back, or the artifact this daemon writes is one its own replay refuses.
pub fn key_name(code: u16) -> Option<&'static str> {
    const FUNCTION_KEYS: [&str; 12] = [
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ];
    Some(match code {
        0x0D => "return",
        0x09 => "tab",
        0x1B => "escape",
        0x08 => "backspace",
        0x2E => "delete",
        0x2D => "insert",
        0x20 => "space",
        0x24 => "home",
        0x23 => "end",
        0x21 => "pageup",
        0x22 => "pagedown",
        0x26 => "up",
        0x28 => "down",
        0x25 => "left",
        0x27 => "right",
        0x70..=0x7B => FUNCTION_KEYS[(code - 0x70) as usize],
        _ => return None,
    })
}

/// Which modifier a virtual key is, counting the left/right pairs Windows reports from a hook.
///
/// A low-level hook reports `VK_LSHIFT`/`VK_RSHIFT` where `SendInput` is given the neutral
/// `VK_SHIFT`, so the observer's side of the mapping has to accept all three spellings.
pub fn modifier_name(code: u16) -> Option<&'static str> {
    Some(match code {
        0x10 | 0xA0 | 0xA1 => "shift",
        0x11 | 0xA2 | 0xA3 => "ctrl",
        0x12 | 0xA4 | 0xA5 => "alt",
        0x5B | 0x5C => "super",
        _ => return None,
    })
}

pub fn named_key(key: NamedKey) -> VirtualKey {
    match key {
        NamedKey::Return => vk(0x0D, false),
        NamedKey::Tab => vk(0x09, false),
        NamedKey::Escape => vk(0x1B, false),
        NamedKey::Backspace => vk(0x08, false),
        NamedKey::Delete => vk(0x2E, true),
        NamedKey::Insert => vk(0x2D, true),
        NamedKey::Space => vk(0x20, false),
        NamedKey::Home => vk(0x24, true),
        NamedKey::End => vk(0x23, true),
        NamedKey::PageUp => vk(0x21, true),
        NamedKey::PageDown => vk(0x22, true),
        NamedKey::Up => vk(0x26, true),
        NamedKey::Down => vk(0x28, true),
        NamedKey::Left => vk(0x25, true),
        NamedKey::Right => vk(0x27, true),
        NamedKey::F1 => vk(0x70, false),
        NamedKey::F2 => vk(0x71, false),
        NamedKey::F3 => vk(0x72, false),
        NamedKey::F4 => vk(0x73, false),
        NamedKey::F5 => vk(0x74, false),
        NamedKey::F6 => vk(0x75, false),
        NamedKey::F7 => vk(0x76, false),
        NamedKey::F8 => vk(0x77, false),
        NamedKey::F9 => vk(0x78, false),
        NamedKey::F10 => vk(0x79, false),
        NamedKey::F11 => vk(0x7A, false),
        NamedKey::F12 => vk(0x7B, false),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn navigation_keys_are_extended() {
        for key in [
            NamedKey::Left,
            NamedKey::Right,
            NamedKey::Up,
            NamedKey::Down,
            NamedKey::Home,
            NamedKey::End,
            NamedKey::PageUp,
            NamedKey::PageDown,
            NamedKey::Insert,
            NamedKey::Delete,
        ] {
            assert!(named_key(key).extended, "{key:?}");
        }
        assert!(!named_key(NamedKey::Return).extended);
        assert_eq!(modifier_key(Modifier::Control).code, 0x11);
    }

    /// The reverse table only earns its place if a recorded name is one this project can replay,
    /// so every name it produces is parsed back and required to land on the key it came from.
    #[test]
    fn every_recorded_key_name_parses_back_to_the_same_virtual_key() {
        for code in 0u16..=0xFF {
            let Some(name) = key_name(code) else { continue };
            let chord = axon_core::parse_chord(name)
                .unwrap_or_else(|error| panic!("{name} (vk {code:#04x}): {error}"));
            assert!(chord.modifiers.is_empty(), "{name} is not a bare key");
            let axon_core::Key::Named(named) = chord.key else {
                panic!("{name} did not parse as a named key");
            };
            assert_eq!(named_key(named).code, code, "{name} round trip");
        }
    }

    #[test]
    fn modifier_names_cover_the_sided_keys_a_hook_reports() {
        for (code, expected) in [
            (0x10, "shift"),
            (0xA0, "shift"),
            (0xA1, "shift"),
            (0x11, "ctrl"),
            (0xA3, "ctrl"),
            (0x12, "alt"),
            (0xA5, "alt"),
            (0x5B, "super"),
            (0x5C, "super"),
        ] {
            assert_eq!(modifier_name(code), Some(expected), "{code:#04x}");
        }
        assert_eq!(modifier_name(0x41), None);
        assert_eq!(key_name(0x41), None, "a letter is described by its text");
    }
}
