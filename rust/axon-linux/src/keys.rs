//! X11 mapping over Axon's shared keyboard vocabulary.
use axon_core::{Key, Modifier, NamedKey};
pub type Keysym = u32;
pub const SHIFT_L: Keysym = 0xFFE1;
pub const CONTROL_L: Keysym = 0xFFE3;
pub const ALT_L: Keysym = 0xFFE9;
pub const SUPER_L: Keysym = 0xFFEB;
const RETURN: Keysym = 0xFF0D;
const TAB: Keysym = 0xFF09;

pub fn keysym_for_modifier(modifier: Modifier) -> Keysym {
    match modifier {
        Modifier::Shift => SHIFT_L,
        Modifier::Control => CONTROL_L,
        Modifier::Alt => ALT_L,
        Modifier::Super => SUPER_L,
    }
}
pub fn keysym_for(key: Key) -> Keysym {
    match key {
        Key::Character(character) => keysym_for_character(character),
        Key::Named(key) => match key {
            NamedKey::Return => RETURN,
            NamedKey::Tab => TAB,
            NamedKey::Escape => 0xFF1B,
            NamedKey::Backspace => 0xFF08,
            NamedKey::Delete => 0xFFFF,
            NamedKey::Insert => 0xFF63,
            NamedKey::Space => 0x20,
            NamedKey::Home => 0xFF50,
            NamedKey::End => 0xFF57,
            NamedKey::PageUp => 0xFF55,
            NamedKey::PageDown => 0xFF56,
            NamedKey::Up => 0xFF52,
            NamedKey::Down => 0xFF54,
            NamedKey::Left => 0xFF51,
            NamedKey::Right => 0xFF53,
            NamedKey::F1 => 0xFFBE,
            NamedKey::F2 => 0xFFBF,
            NamedKey::F3 => 0xFFC0,
            NamedKey::F4 => 0xFFC1,
            NamedKey::F5 => 0xFFC2,
            NamedKey::F6 => 0xFFC3,
            NamedKey::F7 => 0xFFC4,
            NamedKey::F8 => 0xFFC5,
            NamedKey::F9 => 0xFFC6,
            NamedKey::F10 => 0xFFC7,
            NamedKey::F11 => 0xFFC8,
            NamedKey::F12 => 0xFFC9,
        },
    }
}
pub fn keysym_for_character(character: char) -> Keysym {
    match character {
        '\n' | '\r' => RETURN,
        '\t' => TAB,
        c if (0x20..=0xFF).contains(&(c as u32)) => c as u32,
        c => 0x0100_0000 + c as u32,
    }
}
pub fn text_keysyms(text: &str) -> Vec<Keysym> {
    text.chars().map(keysym_for_character).collect()
}
