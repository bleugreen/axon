//! Keyboard intent translated into X keysyms.
//!
//! Deliberately free of `cfg(target_os = "linux")` and of any X connection, for the same reason
//! `lifecycle` is: parsing a chord and naming a keysym are pure functions of their inputs, so they
//! compile and are tested on every host rather than only on the one machine that could run them.
//! Only mapping a keysym onto the layout the user is actually typing on needs an X server, and that
//! lives in `x11`.

/// An X11 keysym. These are protocol constants from `keysymdef.h` and do not depend on the layout;
/// which physical key produces one is exactly what the live keyboard mapping answers.
pub type Keysym = u32;

pub const SHIFT_L: Keysym = 0xFFE1;
pub const CONTROL_L: Keysym = 0xFFE3;
pub const ALT_L: Keysym = 0xFFE9;
pub const SUPER_L: Keysym = 0xFFEB;

const RETURN: Keysym = 0xFF0D;
const TAB: Keysym = 0xFF09;

/// One keystroke: the key itself and the modifiers held down around it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chord {
    /// In the order they are pressed. Released in reverse.
    pub modifiers: Vec<Keysym>,
    pub key: Keysym,
}

/// Modifier names this backend accepts.
///
/// `cmd` is deliberately absent. The Command key has no Linux equivalent: mapping it to Super is
/// literal but useless, and mapping it to Control is a guess about what the caller meant. Refusing
/// says so, which is the answer a caller can act on.
const MODIFIERS: &[(&str, Keysym)] = &[
    ("shift", SHIFT_L),
    ("ctrl", CONTROL_L),
    ("control", CONTROL_L),
    ("alt", ALT_L),
    ("option", ALT_L),
    ("super", SUPER_L),
    ("win", SUPER_L),
];

/// Keys with names rather than characters.
const NAMED_KEYS: &[(&str, Keysym)] = &[
    ("return", RETURN),
    ("enter", RETURN),
    ("tab", TAB),
    ("escape", 0xFF1B),
    ("esc", 0xFF1B),
    ("backspace", 0xFF08),
    ("delete", 0xFFFF),
    ("insert", 0xFF63),
    ("space", 0x0020),
    ("home", 0xFF50),
    ("end", 0xFF57),
    ("pageup", 0xFF55),
    ("page_up", 0xFF55),
    ("pagedown", 0xFF56),
    ("page_down", 0xFF56),
    ("up", 0xFF52),
    ("down", 0xFF54),
    ("left", 0xFF51),
    ("right", 0xFF53),
    ("f1", 0xFFBE),
    ("f2", 0xFFBF),
    ("f3", 0xFFC0),
    ("f4", 0xFFC1),
    ("f5", 0xFFC2),
    ("f6", 0xFFC3),
    ("f7", 0xFFC4),
    ("f8", 0xFFC5),
    ("f9", 0xFFC6),
    ("f10", 0xFFC7),
    ("f11", 0xFFC8),
    ("f12", 0xFFC9),
];

/// The keysym for one literal character.
///
/// Latin-1 characters are their own codepoint; everything else uses the X protocol's Unicode
/// convention. A newline and a tab are the keys a caller means by them rather than control
/// characters no layout carries.
pub fn keysym_for_character(character: char) -> Keysym {
    match character {
        '\n' | '\r' => RETURN,
        '\t' => TAB,
        character if (0x20..=0xFF).contains(&(character as u32)) => character as u32,
        character => 0x0100_0000 + character as u32,
    }
}

/// The keysyms a literal text intent has to produce, in order.
pub fn text_keysyms(text: &str) -> Vec<Keysym> {
    text.chars().map(keysym_for_character).collect()
}

/// Parses a `key` intent such as `End`, `Return`, or `ctrl+shift+p`.
///
/// An unrecognized name is refused rather than typed. Entering the literal characters `cmd+shift+p`
/// into whatever the user has open, because a modifier was not recognized, would be far worse than
/// declining to act.
pub fn parse_chord(spec: &str) -> Result<Chord, String> {
    let spec = spec.trim();
    if spec.is_empty() {
        return Err("a key intent cannot be empty".into());
    }
    // `+` is both the separator and a key a caller can ask for, so the key is taken from the end
    // first: `+` alone and `ctrl++` both name that key rather than leaving an empty final token.
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
        let keysym = MODIFIERS
            .iter()
            .find(|(candidate, _)| *candidate == lowered)
            .map(|(_, keysym)| *keysym)
            .ok_or_else(|| {
                format!(
                    "{name} is not a modifier this backend recognizes; it accepts {}",
                    modifier_names()
                )
            })?;
        if !modifiers.contains(&keysym) {
            modifiers.push(keysym);
        }
    }

    Ok(Chord {
        modifiers,
        key: key_keysym(key_spec)?,
    })
}

fn key_keysym(spec: &str) -> Result<Keysym, String> {
    let lowered = spec.to_lowercase();
    if let Some((_, keysym)) = NAMED_KEYS.iter().find(|(name, _)| *name == lowered) {
        return Ok(*keysym);
    }
    let mut characters = spec.chars();
    match (characters.next(), characters.next()) {
        (Some(character), None) => Ok(keysym_for_character(character)),
        _ => Err(format!(
            "{spec} is not a key this backend recognizes; it accepts a single character or one of \
             {}",
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
    fn a_named_key_carries_no_modifiers() {
        assert_eq!(
            parse_chord("End").unwrap(),
            Chord {
                modifiers: vec![],
                key: 0xFF57
            }
        );
        // Names are matched case-insensitively, because callers write them as they read them.
        assert_eq!(parse_chord("RETURN").unwrap().key, RETURN);
        assert_eq!(parse_chord("enter").unwrap().key, RETURN);
    }

    #[test]
    fn a_chord_keeps_its_modifiers_in_pressing_order() {
        assert_eq!(
            parse_chord("ctrl+shift+p").unwrap(),
            Chord {
                modifiers: vec![CONTROL_L, SHIFT_L],
                key: 'p' as u32
            }
        );
        assert_eq!(
            parse_chord("Control+Alt+Delete").unwrap(),
            Chord {
                modifiers: vec![CONTROL_L, ALT_L],
                key: 0xFFFF
            }
        );
    }

    #[test]
    fn a_repeated_modifier_is_held_once() {
        // Pressing Control twice and releasing it twice leaves the session in a state the user did
        // not ask for on any server that tracks press depth.
        assert_eq!(
            parse_chord("ctrl+control+c").unwrap().modifiers,
            vec![CONTROL_L]
        );
    }

    #[test]
    fn plus_is_a_key_as_well_as_the_separator() {
        assert_eq!(parse_chord("+").unwrap().key, '+' as u32);
        assert_eq!(
            parse_chord("ctrl++").unwrap(),
            Chord {
                modifiers: vec![CONTROL_L],
                key: '+' as u32
            }
        );
    }

    #[test]
    fn an_unrecognized_name_is_refused_rather_than_typed() {
        // The alternative is entering the literal characters `cmd+shift+p` into whatever the user
        // has open, which is worse than declining.
        let error = parse_chord("cmd+shift+p").unwrap_err();
        assert!(error.contains("cmd"), "{error}");
        assert!(error.contains("super"), "{error}");

        let unknown = parse_chord("Speling").unwrap_err();
        assert!(unknown.contains("Speling"), "{unknown}");

        assert!(parse_chord("").is_err());
        assert!(parse_chord("   ").is_err());
    }

    #[test]
    fn characters_become_the_keysyms_the_protocol_defines() {
        // Latin-1 is its own codepoint.
        assert_eq!(keysym_for_character('a'), 0x61);
        assert_eq!(keysym_for_character('A'), 0x41);
        assert_eq!(keysym_for_character(' '), 0x20);
        assert_eq!(keysym_for_character('\u{e9}'), 0xE9);
        // Everything above Latin-1 uses the Unicode convention.
        assert_eq!(keysym_for_character('\u{2192}'), 0x0100_2192);
        // A newline in text means the key a caller would press to enter it.
        assert_eq!(keysym_for_character('\n'), RETURN);
        assert_eq!(keysym_for_character('\t'), TAB);
    }

    #[test]
    fn text_becomes_one_keysym_per_character() {
        assert_eq!(
            text_keysyms("hi!"),
            vec!['h' as u32, 'i' as u32, '!' as u32]
        );
        assert!(text_keysyms("").is_empty());
    }
}
