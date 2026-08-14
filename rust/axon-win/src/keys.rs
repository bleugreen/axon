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
}
