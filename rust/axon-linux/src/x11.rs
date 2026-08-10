//! The X11 client layer: the only part of this backend that can read or change the session's
//! foreground, move the real pointer, or post synthetic input.
//!
//! AT-SPI knows applications by bus name and EWMH knows windows by process id, so the process id is
//! the one fact the two halves agree on. Every method here therefore speaks in process ids, and the
//! translation to an AT-SPI identity happens in `platform`.
//!
//! Nothing here claims an outcome. `activate_pid` reports that a request was sent, not that a window
//! came forward; the shared foreground transaction proves that by reading the foreground back.

use crate::{
    keys::{self, Keysym},
    pixel::SendVariant,
    platform::{capability, operation},
};
use axon_core::{BackendError, Capability, KeyboardIntent};
use std::{
    sync::atomic::{AtomicU32, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};
use x11rb::{
    connection::{Connection, RequestConnection as _},
    protocol::{
        xproto::{
            Atom, AtomEnum, BUTTON_PRESS_EVENT, BUTTON_RELEASE_EVENT, ButtonPressEvent,
            ClientMessageEvent, ConnectionExt as _, EventMask, KEY_PRESS_EVENT, KEY_RELEASE_EVENT,
            KeyButMask, KeyPressEvent, MOTION_NOTIFY_EVENT, Window,
        },
        xtest::{self, ConnectionExt as _},
    },
    rust_connection::RustConnection,
    wrapper::ConnectionExt as _,
};

/// How far a descent through the window tree or a climb back up it may go.
///
/// Deeply nested window trees exist; unbounded loops over a live one do not belong in a dispatch
/// path, where the tree can be changing underneath the walk.
const MAX_WINDOW_TREE_STEPS: usize = 32;

x11rb::atom_manager! {
    Atoms: AtomsCookie {
        _NET_SUPPORTED,
        _NET_ACTIVE_WINDOW,
        _NET_CLIENT_LIST,
        _NET_WM_PID,
    }
}

/// A connection to the session's X server, and the facts about it that decide what may be offered.
pub struct X11Session {
    connection: RustConnection,
    root: Window,
    atoms: Atoms,
    /// True when a Wayland compositor is also present, which means this X server is XWayland.
    under_wayland: bool,
}

impl X11Session {
    /// Opens `DISPLAY`. `None` when there is no display or the server refuses the connection, which
    /// is an ordinary state for a daemon on a Wayland-only session or at the login greeter rather
    /// than an error to report.
    pub fn connect() -> Option<Self> {
        let (connection, screen) = x11rb::connect(None).ok()?;
        let root = connection.setup().roots.get(screen)?.root;
        let atoms = Atoms::new(&connection).ok()?.reply().ok()?;
        Some(Self {
            connection,
            root,
            atoms,
            under_wayland: std::env::var_os("WAYLAND_DISPLAY").is_some(),
        })
    }

    /// Whether this server actually provides XTEST.
    ///
    /// The extension is near-universal but not guaranteed: a server started with `-extension XTEST`
    /// or a remote X server without it will answer everything else about the session normally.
    /// Advertising synthetic input on the strength of a window manager alone would report the
    /// capability usable and only discover otherwise at the moment of dispatch.
    pub fn supports_xtest(&self) -> bool {
        self.connection
            .extension_information(xtest::X11_EXTENSION_NAME)
            .ok()
            .flatten()
            .is_some()
    }

    /// Whether a window manager is present that publishes the two properties the foreground
    /// transaction is built from.
    ///
    /// Without a manager honouring `_NET_ACTIVE_WINDOW` there is nothing to activate through, and
    /// without `_NET_WM_PID` an active window cannot be tied back to an application. Either gap
    /// means the rung must not be offered at all rather than offered and hoped for.
    pub fn supports_ewmh(&self) -> bool {
        let Ok(supported) = self.property(self.root, self.atoms._NET_SUPPORTED, AtomEnum::ATOM)
        else {
            return false;
        };
        [self.atoms._NET_ACTIVE_WINDOW, self.atoms._NET_WM_PID]
            .iter()
            .all(|required| supported.contains(required))
    }

    /// The process id of whatever holds the X11 foreground.
    ///
    /// `Ok(None)` means nothing is focused, which is a real state on a bare X session. Under
    /// XWayland the same reading means something else entirely — a Wayland-native application holds
    /// focus and X11 cannot see it — so it is an error there. Collapsing the two is how a backend
    /// ends up believing the session is empty and dispatching into someone's work.
    pub fn active_window_pid(&self) -> Result<Option<u32>, BackendError> {
        let active = self.property(self.root, self.atoms._NET_ACTIVE_WINDOW, AtomEnum::WINDOW)?;
        let window = active
            .first()
            .copied()
            .filter(|window| *window != x11rb::NONE);
        let Some(window) = window else {
            if self.under_wayland {
                return Err(operation(
                    "read the foreground window",
                    "no X11 window holds the focus, and under XWayland that means a Wayland-native \
                     application does; X11 cannot see or restore it",
                ));
            }
            return Ok(None);
        };
        self.window_pid(window)
    }

    /// Asks the window manager to bring this process's window forward.
    ///
    /// Returns whether a request was sent: `false` means the process has no managed top-level
    /// window to raise. Even `true` is not proof, which is why the caller reads the foreground back.
    pub fn activate_pid(&self, pid: u32) -> Result<bool, BackendError> {
        let Some(window) = self.window_for_pid(pid)? else {
            return Ok(false);
        };
        // Source indication 2 is "pager": an explicit request from a tool acting for the user,
        // which managers honour without the focus-stealing heuristics they apply to applications
        // raising themselves.
        let request = ClientMessageEvent::new(
            32,
            window,
            self.atoms._NET_ACTIVE_WINDOW,
            [2, x11rb::CURRENT_TIME, 0, 0, 0],
        );
        self.connection
            .send_event(
                false,
                self.root,
                EventMask::SUBSTRUCTURE_NOTIFY | EventMask::SUBSTRUCTURE_REDIRECT,
                request,
            )
            .map_err(|error| operation("request activation", error))?;
        self.flush("request activation")?;
        Ok(true)
    }

    pub fn pointer_location(&self) -> Result<(f64, f64), BackendError> {
        let pointer = self
            .connection
            .query_pointer(self.root)
            .map_err(|error| operation("read the pointer", error))?
            .reply()
            .map_err(|error| operation("read the pointer", error))?;
        Ok((pointer.root_x.into(), pointer.root_y.into()))
    }

    /// Puts the pointer back where it was. Warping rather than synthesizing motion, because this is
    /// restoration and no application should see it as the user moving the mouse.
    pub fn warp_pointer(&self, (x, y): (f64, f64)) -> Result<(), BackendError> {
        self.connection
            .warp_pointer(
                x11rb::NONE,
                self.root,
                0,
                0,
                0,
                0,
                coordinate(x),
                coordinate(y),
            )
            .map_err(|error| operation("move the pointer", error))?;
        self.flush("move the pointer")
    }

    /// A primary-button click at a screen point, through the global pointer device.
    ///
    /// This moves the real cursor, which is exactly why it is the foreground rung and why the
    /// transaction around it captures and restores the pointer.
    pub fn click(&self, (x, y): (f64, f64)) -> Result<(), BackendError> {
        self.fake_input(MOTION_NOTIFY_EVENT, 0, coordinate(x), coordinate(y))?;
        self.fake_input(BUTTON_PRESS_EVENT, 1, 0, 0)?;
        self.fake_input(BUTTON_RELEASE_EVENT, 1, 0, 0)?;
        self.flush("post a click")
    }

    /// Literal text or one chord, through the global keyboard device.
    ///
    /// The entire intent is resolved against the live layout before a single event is posted.
    /// Resolving as it goes would let an unmappable character halfway through a string leave the
    /// first half typed into the user's window while the call reports a failure, and no caller can
    /// tell that apart from nothing having happened at all.
    pub fn keyboard(&self, intent: KeyboardIntent<'_>) -> Result<(), BackendError> {
        let mapping = self.keyboard_mapping()?;
        let strokes = match intent {
            KeyboardIntent::Text(text) => keys::text_keysyms(text)
                .into_iter()
                .map(|keysym| mapping.stroke(keysym, &[]))
                .collect::<Result<Vec<_>, _>>()?,
            KeyboardIntent::Key(spec) => {
                let chord = keys::parse_chord(spec)
                    .map_err(|error| capability(Capability::KeyboardInput, &error))?;
                vec![mapping.stroke(chord.key, &chord.modifiers)?]
            }
        };
        for stroke in &strokes {
            self.post(stroke)?;
        }
        self.flush("post keyboard input")
    }

    /// Presses one key with its modifiers held, then releases everything in reverse.
    fn post(&self, stroke: &Stroke) -> Result<(), BackendError> {
        for code in &stroke.held {
            self.fake_input(KEY_PRESS_EVENT, *code, 0, 0)?;
        }
        self.fake_input(KEY_PRESS_EVENT, stroke.key, 0, 0)?;
        self.fake_input(KEY_RELEASE_EVENT, stroke.key, 0, 0)?;
        for code in stroke.held.iter().rev() {
            self.fake_input(KEY_RELEASE_EVENT, *code, 0, 0)?;
        }
        Ok(())
    }

    fn keyboard_mapping(&self) -> Result<KeyboardMapping, BackendError> {
        let setup = self.connection.setup();
        let first = setup.min_keycode;
        // Keycodes are 8-bit, and a server reporting the full range would overflow this on the
        // way to describing itself.
        let count = setup
            .max_keycode
            .saturating_sub(setup.min_keycode)
            .saturating_add(1);
        let mapping = self
            .connection
            .get_keyboard_mapping(first, count)
            .map_err(|error| operation("read the keyboard mapping", error))?
            .reply()
            .map_err(|error| operation("read the keyboard mapping", error))?;
        Ok(KeyboardMapping {
            first,
            per_keycode: mapping.keysyms_per_keycode.into(),
            keysyms: mapping.keysyms,
        })
    }

    fn fake_input(&self, kind: u8, detail: u8, x: i16, y: i16) -> Result<(), BackendError> {
        self.connection
            .xtest_fake_input(kind, detail, x11rb::CURRENT_TIME, self.root, x, y, 0)
            .map_err(|error| operation("post synthetic input", error))?;
        Ok(())
    }

    /// Sends everything queued and waits for the server to have processed it, so a caller that
    /// reads the session back immediately afterwards sees the effect rather than a race.
    fn flush(&self, what: &str) -> Result<(), BackendError> {
        self.connection
            .flush()
            .map_err(|error| operation(what, error))?;
        self.connection
            .sync()
            .map_err(|error| operation(what, error))?;
        Ok(())
    }

    fn window_pid(&self, window: Window) -> Result<Option<u32>, BackendError> {
        Ok(self
            .property(window, self.atoms._NET_WM_PID, AtomEnum::CARDINAL)?
            .first()
            .copied())
    }

    fn window_for_pid(&self, pid: u32) -> Result<Option<Window>, BackendError> {
        for window in self.property(self.root, self.atoms._NET_CLIENT_LIST, AtomEnum::WINDOW)? {
            if self.window_pid(window)? == Some(pid) {
                return Ok(Some(window));
            }
        }
        Ok(None)
    }

    fn property(
        &self,
        window: Window,
        property: Atom,
        kind: AtomEnum,
    ) -> Result<Vec<u32>, BackendError> {
        let reply = self
            .connection
            .get_property(false, window, property, kind, 0, u32::MAX)
            .map_err(|error| operation("read an X11 property", error))?
            .reply()
            .map_err(|error| operation("read an X11 property", error))?;
        Ok(reply.value32().map(Iterator::collect).unwrap_or_default())
    }
}

/// One keystroke resolved against the live layout: the key to press, and the modifier keys held
/// around it. Resolved before anything is posted, so an intent this layout cannot express is
/// refused rather than half delivered.
struct Stroke {
    key: u8,
    held: Vec<u8>,
}

/// The layout the user is actually typing on, as the server currently reports it.
struct KeyboardMapping {
    first: u8,
    per_keycode: usize,
    keysyms: Vec<u32>,
}

impl KeyboardMapping {
    /// Resolves one keystroke, or explains which key this layout does not have.
    fn stroke(&self, keysym: Keysym, modifiers: &[Keysym]) -> Result<Stroke, BackendError> {
        let missing = |keysym: Keysym| {
            capability(
                Capability::KeyboardInput,
                &format!(
                    "the active keyboard layout has no key for keysym {keysym:#x}; remapping the \
                     layout to reach it would change what every other X client types"
                ),
            )
        };
        let (key, needs_shift) = self.locate(keysym).ok_or_else(|| missing(keysym))?;
        let mut held = Vec::new();
        for modifier in modifiers {
            let (code, _) = self.locate(*modifier).ok_or_else(|| missing(*modifier))?;
            held.push(code);
        }
        // A character on the shifted level of its key needs Shift held even when the caller named
        // no modifier, which is how literal text containing capitals is typed.
        if needs_shift
            && !modifiers.contains(&keys::SHIFT_L)
            && let Some((shift, _)) = self.locate(keys::SHIFT_L)
        {
            held.push(shift);
        }
        Ok(Stroke { key, held })
    }

    /// The keycode that produces `keysym`, and whether Shift has to be held to reach it.
    ///
    /// Only the unshifted and shifted levels are consulted. Higher levels need a group or AltGr
    /// switch whose modifier assignment is layout-specific, and guessing at one would post
    /// something other than what was asked for.
    fn locate(&self, keysym: Keysym) -> Option<(u8, bool)> {
        if self.per_keycode == 0 {
            return None;
        }
        for (index, levels) in self.keysyms.chunks(self.per_keycode).enumerate() {
            let keycode = u8::try_from(index)
                .ok()
                .and_then(|index| self.first.checked_add(index))?;
            for (level, candidate) in levels.iter().enumerate().take(2) {
                if *candidate == keysym {
                    return Some((keycode, level == 1));
                }
            }
        }
        None
    }
}

/// Screen coordinates cross the wire as 16-bit signed values, so a point outside that range is
/// clamped rather than wrapped into a different part of the screen.
fn coordinate(value: f64) -> i16 {
    value.round().clamp(i16::MIN as f64, i16::MAX as f64) as i16
}
