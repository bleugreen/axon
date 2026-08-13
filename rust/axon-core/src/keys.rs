//! Platform-neutral keyboard vocabulary and chord parsing.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Modifier {
    Shift,
    Control,
    Alt,
    Super,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NamedKey {
    Return,
    Tab,
    Escape,
    Backspace,
    Delete,
    Insert,
    Space,
    Home,
    End,
    PageUp,
    PageDown,
    Up,
    Down,
    Left,
    Right,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Named(NamedKey),
    Character(char),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chord {
    /// In pressing order; release these in reverse.
    pub modifiers: Vec<Modifier>,
    pub key: Key,
}

const MODIFIERS: &[(&str, Modifier)] = &[
    ("shift", Modifier::Shift),
    ("ctrl", Modifier::Control),
    ("control", Modifier::Control),
    ("alt", Modifier::Alt),
    ("option", Modifier::Alt),
    ("super", Modifier::Super),
    ("win", Modifier::Super),
];
const NAMED_KEYS: &[(&str, NamedKey)] = &[
    ("return", NamedKey::Return),
    ("enter", NamedKey::Return),
    ("tab", NamedKey::Tab),
    ("escape", NamedKey::Escape),
    ("esc", NamedKey::Escape),
    ("backspace", NamedKey::Backspace),
    ("delete", NamedKey::Delete),
    ("insert", NamedKey::Insert),
    ("space", NamedKey::Space),
    ("home", NamedKey::Home),
    ("end", NamedKey::End),
    ("pageup", NamedKey::PageUp),
    ("page_up", NamedKey::PageUp),
    ("pagedown", NamedKey::PageDown),
    ("page_down", NamedKey::PageDown),
    ("up", NamedKey::Up),
    ("down", NamedKey::Down),
    ("left", NamedKey::Left),
    ("right", NamedKey::Right),
    ("f1", NamedKey::F1),
    ("f2", NamedKey::F2),
    ("f3", NamedKey::F3),
    ("f4", NamedKey::F4),
    ("f5", NamedKey::F5),
    ("f6", NamedKey::F6),
    ("f7", NamedKey::F7),
    ("f8", NamedKey::F8),
    ("f9", NamedKey::F9),
    ("f10", NamedKey::F10),
    ("f11", NamedKey::F11),
    ("f12", NamedKey::F12),
];

pub fn parse_chord(spec: &str) -> Result<Chord, String> {
    let spec = spec.trim();
    if spec.is_empty() {
        return Err("a key intent cannot be empty".into());
    }
    let (modifier_spec, key_spec) = match spec.rsplit_once('+') {
        Some((head, "")) => (head.trim_end_matches('+'), "+"),
        Some((head, key)) => (head, key),
        None => ("", spec),
    };
    let mut modifiers = Vec::new();
    for name in modifier_spec
        .split('+')
        .filter(|name| !name.trim().is_empty())
    {
        let lowered = name.trim().to_lowercase();
        if lowered == "cmd" || lowered == "command" {
            return Err("the Command key exists only on macOS; use ctrl or super".into());
        }
        let modifier = MODIFIERS
            .iter()
            .find(|(candidate, _)| *candidate == lowered)
            .map(|(_, modifier)| *modifier)
            .ok_or_else(|| {
                format!(
                    "{name} is not a modifier this backend recognizes; it accepts {}",
                    modifier_names()
                )
            })?;
        if !modifiers.contains(&modifier) {
            modifiers.push(modifier);
        }
    }
    Ok(Chord {
        modifiers,
        key: parse_key(key_spec)?,
    })
}

fn parse_key(spec: &str) -> Result<Key, String> {
    let lowered = spec.to_lowercase();
    if let Some((_, key)) = NAMED_KEYS.iter().find(|(name, _)| *name == lowered) {
        return Ok(Key::Named(*key));
    }
    let mut chars = spec.chars();
    match (chars.next(), chars.next()) {
        (Some(character), None) => Ok(Key::Character(character)),
        _ => Err(format!(
            "{spec} is not a key this backend recognizes; it accepts a single character or one of {}",
            named_key_names()
        )),
    }
}
fn modifier_names() -> String {
    MODIFIERS
        .iter()
        .map(|(name, _)| *name)
        .collect::<Vec<_>>()
        .join(", ")
}
fn named_key_names() -> String {
    NAMED_KEYS
        .iter()
        .map(|(name, _)| *name)
        .collect::<Vec<_>>()
        .join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_named_keys_and_chords() {
        assert_eq!(parse_chord("End").unwrap().key, Key::Named(NamedKey::End));
        assert_eq!(
            parse_chord("ctrl+shift+p").unwrap(),
            Chord {
                modifiers: vec![Modifier::Control, Modifier::Shift],
                key: Key::Character('p')
            }
        );
    }
    #[test]
    fn plus_is_a_key() {
        assert_eq!(parse_chord("+").unwrap().key, Key::Character('+'));
        assert_eq!(parse_chord("ctrl++").unwrap().key, Key::Character('+'));
    }
    #[test]
    fn unknown_names_and_command_are_refused() {
        assert!(parse_chord("Speling").unwrap_err().contains("Speling"));
        assert_eq!(
            parse_chord("cmd+shift+p").unwrap_err(),
            "the Command key exists only on macOS; use ctrl or super"
        );
    }
}
