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
    /// The timestamp carried by synthetic events sent to a target window.
    ///
    /// A sent event has to carry a time, and this client cannot read the server's clock without a
    /// round trip per event. Seeded from the wall clock and advanced per event, which is exactly
    /// what the acceptance harness did: the values are far larger than any server uptime, so a
    /// toolkit that discards events older than the last one it saw sees these as current, and each
    /// event in a sequence is strictly later than the one before it. Matching the harness matters
    /// more than elegance here, because the harness is what measured that these events are acted
    /// on at all.
    event_clock: AtomicU32,
}

/// A window's position on screen and its size: the resolved geometry a pixel-rung coordinate is
/// converted through, and the reading that says whether it has moved since.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WindowGeometry {
    pub origin: (i16, i16),
    pub size: (u16, u16),
}

impl WindowGeometry {
    /// Whether a screen point falls inside this window.
    pub fn contains(&self, (x, y): (i16, i16)) -> bool {
        let right = i32::from(self.origin.0) + i32::from(self.size.0);
        let bottom = i32::from(self.origin.1) + i32::from(self.size.1);
        i32::from(x) >= i32::from(self.origin.0)
            && i32::from(y) >= i32::from(self.origin.1)
            && i32::from(x) < right
            && i32::from(y) < bottom
    }
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
            event_clock: AtomicU32::new(
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|since| since.as_millis() as u32)
                    .unwrap_or(1),
            ),
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

    /// The window EWMH reports as active, read plainly.
    ///
    /// Distinct from [`Self::active_window_pid`], which interprets an absent answer against the
    /// session type. The pixel rung only compares this reading before a dispatch with the same
    /// reading after it, and for that an empty session is as unchanged as a busy one.
    pub fn active_window(&self) -> Result<Option<Window>, BackendError> {
        Ok(self
            .property(self.root, self.atoms._NET_ACTIVE_WINDOW, AtomEnum::WINDOW)?
            .first()
            .copied()
            .filter(|window| *window != x11rb::NONE))
    }

    /// The window holding the X input focus.
    ///
    /// Read alongside the active window rather than instead of it, because they are different
    /// facts and the harness caught a toolkit moving one of them. Qt acts on a background click
    /// and asks to be activated while doing so: on a session with no window manager that moved the
    /// input focus while `_NET_ACTIVE_WINDOW` — which only a manager maintains — stayed where it
    /// was. A dispatch proved against the active window alone would have reported that as
    /// background delivery.
    pub fn input_focus(&self) -> Result<Window, BackendError> {
        Ok(self
            .connection
            .get_input_focus()
            .map_err(|error| operation("read the input focus", error))?
            .reply()
            .map_err(|error| operation("read the input focus", error))?
            .focus)
    }

    /// The process id of whatever holds the X11 foreground.
    ///
    /// `Ok(None)` means nothing is focused, which is a real state on a bare X session. Under
    /// XWayland the same reading means something else entirely — a Wayland-native application holds
    /// focus and X11 cannot see it — so it is an error there. Collapsing the two is how a backend
    /// ends up believing the session is empty and dispatching into someone's work.
    pub fn active_window_pid(&self) -> Result<Option<u32>, BackendError> {
        let Some(window) = self.active_window()? else {
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
        let Some(window) = self.windows_for_pid(pid)?.first().copied() else {
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

    /// Every managed top-level window a process owns.
    ///
    /// `_NET_CLIENT_LIST` is the window manager's own list of what it manages, so this excludes
    /// the tooltips, menus and override-redirect surfaces a process also owns. That is what makes
    /// it the right list to bind a target against: those are not windows a caller ever meant.
    pub fn windows_for_pid(&self, pid: u32) -> Result<Vec<Window>, BackendError> {
        let mut owned = Vec::new();
        for window in self.property(self.root, self.atoms._NET_CLIENT_LIST, AtomEnum::WINDOW)? {
            if self.window_pid(window)? == Some(pid) {
                owned.push(window);
            }
        }
        Ok(owned)
    }

    /// A window's origin on screen and its size.
    pub fn window_geometry(&self, window: Window) -> Result<WindowGeometry, BackendError> {
        let size = self
            .connection
            .get_geometry(window)
            .map_err(|error| operation("read a window's geometry", error))?
            .reply()
            .map_err(|error| operation("read a window's geometry", error))?;
        // A window's own x and y are relative to its parent, which under a reparenting window
        // manager is a frame rather than the root. Translating (0, 0) is what turns that into the
        // screen position a resolved coordinate has to be converted against.
        let origin = self.translate(window, self.root, (0, 0))?;
        Ok(WindowGeometry {
            origin,
            size: (size.width, size.height),
        })
    }

    /// A point in one window's coordinates expressed in another's.
    pub fn translate(
        &self,
        from: Window,
        to: Window,
        (x, y): (i16, i16),
    ) -> Result<(i16, i16), BackendError> {
        let reply = self
            .connection
            .translate_coordinates(from, to, x, y)
            .map_err(|error| operation("translate window coordinates", error))?
            .reply()
            .map_err(|error| operation("translate window coordinates", error))?;
        Ok((reply.dst_x, reply.dst_y))
    }

    /// The process's managed top-level window that owns a screen point, if one does.
    ///
    /// Both halves of this are load-bearing. Reaching the window by descending from the root is
    /// what makes it the window that *owns* the point rather than one that merely surrounds it: a
    /// target covered by another application's window at that point is not returned, which is the
    /// occlusion check this backend otherwise has no hit test for. Requiring the window the
    /// descent lands in to be one of the resolved process's own managed top-levels is the other
    /// half, and it is what keeps the target bound to the application the caller resolved instead
    /// of inferred from a bare screen point — which the contract forbids outright.
    ///
    /// The climb back up exists because a reparenting window manager wraps the client window in a
    /// frame, and toolkits put their own child windows inside it; the descent ends at a leaf, and
    /// the client window is somewhere between that leaf and the root.
    pub fn managed_window_at(
        &self,
        pid: u32,
        point: (i16, i16),
    ) -> Result<Option<Window>, BackendError> {
        let owned = self.windows_for_pid(pid)?;
        if owned.is_empty() {
            return Ok(None);
        }
        let mut window = self.window_under(point)?;
        for _ in 0..MAX_WINDOW_TREE_STEPS {
            if owned.contains(&window) {
                return Ok(Some(window));
            }
            match self.parent_of(window)? {
                Some(parent) if parent != self.root && parent != x11rb::NONE => window = parent,
                _ => return Ok(None),
            }
        }
        Ok(None)
    }

    /// The deepest window at a screen point: where a real pointer click would land.
    fn window_under(&self, point: (i16, i16)) -> Result<Window, BackendError> {
        let mut window = self.root;
        for _ in 0..MAX_WINDOW_TREE_STEPS {
            let reply = self
                .connection
                .translate_coordinates(self.root, window, point.0, point.1)
                .map_err(|error| operation("find the window under a point", error))?
                .reply()
                .map_err(|error| operation("find the window under a point", error))?;
            if reply.child == x11rb::NONE {
                return Ok(window);
            }
            window = reply.child;
        }
        Ok(window)
    }

    fn parent_of(&self, window: Window) -> Result<Option<Window>, BackendError> {
        let tree = self
            .connection
            .query_tree(window)
            .map_err(|error| operation("read the window tree", error))?
            .reply()
            .map_err(|error| operation("read the window tree", error))?;
        Ok((tree.parent != x11rb::NONE).then_some(tree.parent))
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
        for stroke in &self.strokes(intent)? {
            self.post(stroke)?;
        }
        self.flush("post keyboard input")
    }

    /// Resolves an entire intent against the live layout, before anything is posted or sent.
    fn strokes(&self, intent: KeyboardIntent<'_>) -> Result<Vec<Stroke>, BackendError> {
        let mapping = self.keyboard_mapping()?;
        match intent {
            KeyboardIntent::Text(text) => keys::text_keysyms(text)
                .into_iter()
                .map(|keysym| mapping.stroke(keysym, &[]))
                .collect(),
            KeyboardIntent::Key(spec) => {
                let chord = keys::parse_chord(spec)
                    .map_err(|error| capability(Capability::KeyboardInput, &error))?;
                Ok(vec![mapping.stroke(chord.key, &chord.modifiers)?])
            }
        }
    }

    /// A primary-button press and release delivered to one window with `XSendEvent`.
    ///
    /// This is the pixel rung's pointer mechanism, and it is a different thing from [`Self::click`]
    /// rather than a narrower one. Nothing here touches the global pointer device: the events name
    /// a window and carry the coordinates the caller resolved, the real cursor stays wherever the
    /// user left it, and the session focus is never asked to move.
    ///
    /// Every event this sends is flagged `send_event`, and a toolkit is free to drop it. The X
    /// server reports success as soon as it accepts the request, so a clean return here means the
    /// events were delivered to the target's connection and never means the target acted on them.
    /// Which toolkits do act is the measured fact in [`crate::pixel`], and this must not be called
    /// for a toolkit that table has not cleared.
    pub fn send_click(
        &self,
        window: Window,
        window_point: (i16, i16),
        screen_point: (i16, i16),
        variant: SendVariant,
    ) -> Result<(), BackendError> {
        // A release carries the button already held, exactly as the server would report it: the
        // `state` field describes the modifier and button state immediately before the event.
        for (kind, state) in [
            (BUTTON_PRESS_EVENT, KeyButMask::default()),
            (BUTTON_RELEASE_EVENT, KeyButMask::BUTTON1),
        ] {
            let event = ButtonPressEvent {
                response_type: kind,
                detail: 1,
                sequence: 0,
                time: self.tick(),
                root: self.root,
                event: window,
                child: x11rb::NONE,
                root_x: screen_point.0,
                root_y: screen_point.1,
                event_x: window_point.0,
                event_y: window_point.1,
                state,
                same_screen: true,
            };
            self.send(window, mask_for(kind, variant), event, "send a click to a window")?;
        }
        self.flush("send a click to a window")
    }

    /// Literal text or one chord delivered to one window with `XSendEvent`.
    ///
    /// Resolved against the live layout in full before anything is sent, for the same reason
    /// [`Self::keyboard`] is: an unmappable character halfway through a string would otherwise
    /// leave the first half typed into the target while the call reported a failure.
    ///
    /// The delivery is otherwise the pointer path's twin, including what it does not prove. See
    /// [`Self::send_click`].
    pub fn send_keyboard(
        &self,
        window: Window,
        intent: KeyboardIntent<'_>,
        variant: SendVariant,
    ) -> Result<(), BackendError> {
        let strokes = self.strokes(intent)?;
        let modifiers = self.modifier_mapping()?;
        for stroke in &strokes {
            self.send_stroke(window, stroke, &modifiers, variant)?;
        }
        self.flush("send keyboard input to a window")
    }

    /// Sends one keystroke as the server itself would report it: each modifier pressed, the key
    /// pressed and released, then the modifiers released in reverse.
    ///
    /// The `state` field is what makes this a keystroke rather than a bare keycode. `XSendEvent`
    /// does not change the server's own modifier state, so a toolkit has nothing but `state` to
    /// read the held modifiers from — and a chord sent without it arrives as the unmodified key,
    /// which is a different keystroke than the caller asked for rather than a failure to deliver.
    /// Capital letters run through the same path, because a shifted character is a Shift chord.
    ///
    /// X reports the state as it was immediately *before* each event, which is why a modifier's
    /// own press carries the state without it and its release carries the state with it.
    fn send_stroke(
        &self,
        window: Window,
        stroke: &Stroke,
        modifiers: &ModifierMapping,
        variant: SendVariant,
    ) -> Result<(), BackendError> {
        let mut state = 0u16;
        for code in &stroke.held {
            self.send_key(window, KEY_PRESS_EVENT, *code, state, variant)?;
            state |= modifiers.mask_of(*code);
        }
        self.send_key(window, KEY_PRESS_EVENT, stroke.key, state, variant)?;
        self.send_key(window, KEY_RELEASE_EVENT, stroke.key, state, variant)?;
        for code in stroke.held.iter().rev() {
            self.send_key(window, KEY_RELEASE_EVENT, *code, state, variant)?;
            state &= !modifiers.mask_of(*code);
        }
        Ok(())
    }

    fn send_key(
        &self,
        window: Window,
        kind: u8,
        keycode: u8,
        state: u16,
        variant: SendVariant,
    ) -> Result<(), BackendError> {
        let event = KeyPressEvent {
            response_type: kind,
            detail: keycode,
            sequence: 0,
            time: self.tick(),
            root: self.root,
            event: window,
            child: x11rb::NONE,
            // A key event's coordinates say where the pointer was, and this delivery deliberately
            // did not touch it. Zero is what the harness sent and what every accepting toolkit was
            // measured against; a real coordinate here would describe a pointer that never moved.
            root_x: 0,
            root_y: 0,
            event_x: 0,
            event_y: 0,
            state: state.into(),
            same_screen: true,
        };
        self.send(
            window,
            mask_for(kind, variant),
            event,
            "send keyboard input to a window",
        )
    }

    fn send<E>(
        &self,
        window: Window,
        mask: EventMask,
        event: E,
        what: &str,
    ) -> Result<(), BackendError>
    where
        E: Into<[u8; 32]>,
    {
        // `propagate` false, always: an event the target's own window does not want must not climb
        // its ancestry looking for someone who does. The rung is bound to one window or it is not
        // bound at all.
        self.connection
            .send_event(false, window, mask, event)
            .map_err(|error| operation(what, error))?;
        Ok(())
    }

    /// Which modifier bit each keycode carries, as the server currently reports it.
    fn modifier_mapping(&self) -> Result<ModifierMapping, BackendError> {
        let reply = self
            .connection
            .get_modifier_mapping()
            .map_err(|error| operation("read the modifier mapping", error))?
            .reply()
            .map_err(|error| operation("read the modifier mapping", error))?;
        Ok(ModifierMapping {
            per_modifier: reply.keycodes_per_modifier().into(),
            keycodes: reply.keycodes,
        })
    }

    /// The next timestamp for a sent event, strictly later than the last one.
    fn tick(&self) -> u32 {
        self.event_clock.fetch_add(10, Ordering::Relaxed) + 10
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

/// The event mask one sent event travels under, which is the whole of the delivery variant.
///
/// `Targeted` names the mask matching the event, so the server routes it to whichever clients
/// selected for that event on the destination window. `Owner` sends an empty mask, which the
/// server routes to the client that created the window regardless of what it selected. Which one a
/// toolkit honours is measured, not chosen: GTK 3 acts only on the second, Qt and Chromium only on
/// the first, and sending the wrong one arrives as silence.
fn mask_for(kind: u8, variant: SendVariant) -> EventMask {
    if variant == SendVariant::Owner {
        return EventMask::NO_EVENT;
    }
    match kind {
        BUTTON_PRESS_EVENT => EventMask::BUTTON_PRESS,
        BUTTON_RELEASE_EVENT => EventMask::BUTTON_RELEASE,
        KEY_PRESS_EVENT => EventMask::KEY_PRESS,
        _ => EventMask::KEY_RELEASE,
    }
}

/// Which of the eight modifier bits each keycode carries, as the server currently reports it.
///
/// Read from the server rather than assumed: only Shift, Lock and Control have fixed positions,
/// and which of `Mod1`..`Mod5` carries Alt, Meta or Super is a property of the running layout.
struct ModifierMapping {
    per_modifier: usize,
    keycodes: Vec<u8>,
}

impl ModifierMapping {
    /// The mask bit a keycode sets while it is held, or zero for a key that is not a modifier.
    fn mask_of(&self, keycode: u8) -> u16 {
        if self.per_modifier == 0 {
            return 0;
        }
        self.keycodes
            .chunks(self.per_modifier)
            .position(|codes| codes.contains(&keycode))
            .map_or(0, |modifier| 1u16 << modifier)
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
