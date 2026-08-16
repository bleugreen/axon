//! The observations and dispatches the coordinator asks for, one subcommand
//! each, answering with a single JSON object on stdout.
//!
//! Nothing here decides whether a result is good. Each command records what
//! macOS reported, including the readings that would invalidate a trial — the
//! frontmost application and the real pointer either side of every dispatch —
//! so the coordinator derives a verdict from evidence it did not have to ask
//! for separately.

use std::ffi::c_void;
use std::thread::sleep;
use std::time::Duration;

use crate::args::Args;
use crate::json::J;
use crate::sys::*;

/// How long to let an application react before reading back. A target that is
/// going to act on a posted event acts on it in milliseconds; this bound is for
/// a loaded machine, not for an application taking its time to decide.
const SETTLE: Duration = Duration::from_millis(400);

pub fn run(command: &str, args: &Args) -> Result<J, String> {
    match command {
        "env" => Ok(env()),
        "frontmost" => Ok(frontmost()),
        "pointer" => Ok(point_json(pointer_location())),
        "park" => park(args),
        "app" => app(args),
        "find-app" => find_app(args),
        "windows" => windows(args),
        "owner-at" => owner_at(args),
        "post-click" => post_click(args),
        "post-key" => post_key(args),
        "foreground-click" => foreground_click(args),
        "foreground-key" => foreground_key(args),
        "activate" => activate_command(args),
        "ax-read" => ax_read(args),
        other => Err(format!("unknown command: {other}")),
    }
}

// -- observations --------------------------------------------------------------------------

fn env() -> J {
    let display = unsafe { CGMainDisplayID() };
    let (width, height) = unsafe {
        (
            CGDisplayPixelsWide(display) as i64,
            CGDisplayPixelsHigh(display) as i64,
        )
    };
    let version = send(class("NSProcessInfo"), "processInfo");
    let version_string = nsstring_to_string(send(version, "operatingSystemVersionString"));
    J::obj(vec![
        (
            "accessibilityTrusted",
            J::Bool(unsafe { AXIsProcessTrusted() } != 0),
        ),
        (
            "operatingSystem",
            version_string.map(J::Str).unwrap_or(J::Null),
        ),
        (
            "mainDisplay",
            J::obj(vec![
                ("id", J::Int(display as i64)),
                ("width", J::Int(width)),
                ("height", J::Int(height)),
            ]),
        ),
        ("probePid", J::Int(std::process::id() as i64)),
    ])
}

fn frontmost() -> J {
    match frontmost_application() {
        Some(identity) => identity_json(&identity),
        None => J::Null,
    }
}

fn point_json(point: CGPoint) -> J {
    J::obj(vec![("x", J::Num(point.x)), ("y", J::Num(point.y))])
}

fn identity_json(identity: &AppIdentity) -> J {
    J::obj(vec![
        ("pid", J::Int(identity.pid as i64)),
        (
            "bundleId",
            identity.bundle_id.clone().map(J::Str).unwrap_or(J::Null),
        ),
        ("name", identity.name.clone().map(J::Str).unwrap_or(J::Null)),
        (
            "bundlePath",
            identity.bundle_path.clone().map(J::Str).unwrap_or(J::Null),
        ),
        ("active", J::Bool(identity.active)),
        ("terminated", J::Bool(identity.terminated)),
    ])
}

fn park(args: &Args) -> Result<J, String> {
    let point = CGPoint {
        x: args.f64("x")?,
        y: args.f64("y")?,
    };
    warp_pointer(point);
    sleep(Duration::from_millis(80));
    Ok(J::obj(vec![
        ("requested", point_json(point)),
        ("pointer", point_json(pointer_location())),
    ]))
}

fn app(args: &Args) -> Result<J, String> {
    let pid = args.i32("pid")?;
    match identity_of(running_application(pid)) {
        Some(identity) => Ok(identity_json(&identity)),
        None => Ok(J::obj(vec![
            ("pid", J::Int(pid as i64)),
            ("found", J::Bool(false)),
        ])),
    }
}

fn find_app(args: &Args) -> Result<J, String> {
    let wanted = args.string("bundle-id")?;
    let workspace = send(class("NSWorkspace"), "sharedWorkspace");
    let applications = send(workspace, "runningApplications");
    let count = send_ret_u64(applications, "count");
    let mut found = Vec::new();
    for index in 0..count {
        let application = send_u64_arg(applications, "objectAtIndex:", index);
        let Some(identity) = identity_of(application) else {
            continue;
        };
        if identity.bundle_id.as_deref() == Some(wanted.as_str()) {
            found.push(identity_json(&identity));
        }
    }
    Ok(J::obj(vec![
        ("bundleId", J::str(wanted)),
        ("found", J::Bool(!found.is_empty())),
        ("applications", J::Arr(found)),
    ]))
}

#[derive(Clone, Debug)]
struct Window {
    id: i64,
    owner_pid: i64,
    owner_name: Option<String>,
    name: Option<String>,
    layer: i64,
    on_screen: bool,
    alpha: f64,
    bounds: CGRect,
}

impl Window {
    fn to_json(&self) -> J {
        J::obj(vec![
            ("windowId", J::Int(self.id)),
            ("ownerPid", J::Int(self.owner_pid)),
            (
                "ownerName",
                self.owner_name.clone().map(J::Str).unwrap_or(J::Null),
            ),
            ("name", self.name.clone().map(J::Str).unwrap_or(J::Null)),
            ("layer", J::Int(self.layer)),
            ("onScreen", J::Bool(self.on_screen)),
            ("alpha", J::Num(self.alpha)),
            (
                "bounds",
                J::obj(vec![
                    ("x", J::Num(self.bounds.origin.x)),
                    ("y", J::Num(self.bounds.origin.y)),
                    ("width", J::Num(self.bounds.size.width)),
                    ("height", J::Num(self.bounds.size.height)),
                ]),
            ),
        ])
    }

    fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.bounds.origin.x
            && y >= self.bounds.origin.y
            && x < self.bounds.origin.x + self.bounds.size.width
            && y < self.bounds.origin.y + self.bounds.size.height
    }
}

/// The on-screen window stack, front to back, which is the order
/// `CGWindowListCopyWindowInfo` returns for an on-screen query.
fn window_stack() -> Vec<Window> {
    let mut windows = Vec::new();
    unsafe {
        let list = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID,
        );
        if list.is_null() {
            return windows;
        }
        for index in 0..CFArrayGetCount(list) {
            let entry = CFArrayGetValueAtIndex(list, index);
            if entry.is_null() {
                continue;
            }
            let bounds_dictionary = dictionary_value(entry, "kCGWindowBounds");
            let bounds = if bounds_dictionary.is_null() {
                CGRect::default()
            } else {
                CGRect {
                    origin: CGPoint {
                        x: cf_number_f64(dictionary_value(bounds_dictionary, "X")).unwrap_or(0.0),
                        y: cf_number_f64(dictionary_value(bounds_dictionary, "Y")).unwrap_or(0.0),
                    },
                    size: CGSize {
                        width: cf_number_f64(dictionary_value(bounds_dictionary, "Width"))
                            .unwrap_or(0.0),
                        height: cf_number_f64(dictionary_value(bounds_dictionary, "Height"))
                            .unwrap_or(0.0),
                    },
                }
            };
            windows.push(Window {
                id: cf_number_i64(dictionary_value(entry, "kCGWindowNumber")).unwrap_or(-1),
                owner_pid: cf_number_i64(dictionary_value(entry, "kCGWindowOwnerPID"))
                    .unwrap_or(-1),
                owner_name: cf_string_to_string(dictionary_value(entry, "kCGWindowOwnerName")),
                name: cf_string_to_string(dictionary_value(entry, "kCGWindowName")),
                layer: cf_number_i64(dictionary_value(entry, "kCGWindowLayer")).unwrap_or(0),
                on_screen: !dictionary_value(entry, "kCGWindowIsOnscreen").is_null(),
                alpha: cf_number_f64(dictionary_value(entry, "kCGWindowAlpha")).unwrap_or(1.0),
                bounds,
            });
        }
        CFRelease(list);
    }
    windows
}

fn windows(args: &Args) -> Result<J, String> {
    let pid = args.optional_i32("pid");
    let stack = window_stack();
    let selected: Vec<J> = stack
        .iter()
        .filter(|window| pid.is_none_or(|pid| window.owner_pid == pid as i64))
        .map(Window::to_json)
        .collect();
    Ok(J::obj(vec![("windows", J::Arr(selected))]))
}

/// The window stack at one point, front to back.
///
/// This is the ownership proof the campaign takes immediately before every
/// dispatch. A caller asserts that the frontmost entry belongs to the target:
/// if the decoy or anything else covers the coordinate, the trial is measuring
/// the wrong window and has to be invalidated rather than recorded.
fn owner_at(args: &Args) -> Result<J, String> {
    let x = args.f64("x")?;
    let y = args.f64("y")?;
    let stack: Vec<J> = window_stack()
        .iter()
        .filter(|window| window.on_screen && window.alpha > 0.0 && window.contains(x, y))
        .map(Window::to_json)
        .collect();
    Ok(J::obj(vec![
        ("point", point_json(CGPoint { x, y })),
        ("stack", J::Arr(stack)),
    ]))
}

// -- dispatch ------------------------------------------------------------------------------

fn state() -> J {
    J::obj(vec![
        ("frontmost", frontmost()),
        ("pointer", point_json(pointer_location())),
    ])
}

/// Posts a left click down and up to one process.
///
/// This is the mechanism the campaign exists to measure, built the way the
/// product builds it: a mouse event with no event source, posted with
/// `CGEventPostToPid`. The call returns no status — that is the whole problem —
/// so what is recorded is that the events were created and the post returned,
/// which is dispatch evidence and nothing more.
fn post_click(args: &Args) -> Result<J, String> {
    let pid = args.i32("pid")?;
    let point = CGPoint {
        x: args.f64("x")?,
        y: args.f64("y")?,
    };
    let source_kind = source_of(args)?;
    // How long the button is held. The product posts down and up back to back,
    // so zero is the variant a row must be measured with; a non-zero gap is
    // measured alongside it so a silent target cannot be explained away as an
    // application that wanted a slower click.
    let gap = args.optional_f64("gap-ms").unwrap_or(0.0);
    let before = state();
    let source = source_kind.create();
    let mut created = true;
    for kind in [kCGEventLeftMouseDown, kCGEventLeftMouseUp] {
        unsafe {
            let event = CGEventCreateMouseEvent(source, kind, point, kCGMouseButtonLeft);
            if event.is_null() {
                created = false;
                continue;
            }
            CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
            CGEventPostToPid(pid, event);
            CFRelease(event);
        }
        if kind == kCGEventLeftMouseDown && gap > 0.0 {
            sleep(Duration::from_secs_f64(gap / 1000.0));
        }
    }
    release_source(source);
    sleep(SETTLE);
    Ok(J::obj(vec![
        ("mechanism", J::str("CGEventPostToPid")),
        (
            "variant",
            J::str(format!(
                "leftMouseDown+leftMouseUp/source={}/gapMs={gap}",
                source_kind.key()
            )),
        ),
        ("targetPid", J::Int(pid as i64)),
        ("point", point_json(point)),
        ("eventsCreated", J::Bool(created)),
        (
            "accessibilityTrusted",
            J::Bool(unsafe { AXIsProcessTrusted() } != 0),
        ),
        ("before", before),
        ("after", state()),
    ]))
}

fn post_key(args: &Args) -> Result<J, String> {
    let pid = args.i32("pid")?;
    let text = args.string("text")?;
    let source_kind = source_of(args)?;
    let before = state();
    let source = source_kind.create();
    let mut created = true;
    for character in text.chars() {
        let code = key_code_for(character);
        let utf16: Vec<u16> = character.to_string().encode_utf16().collect();
        for down in [true, false] {
            unsafe {
                let event = CGEventCreateKeyboardEvent(source, code, down);
                if event.is_null() {
                    created = false;
                    continue;
                }
                CGEventKeyboardSetUnicodeString(event, utf16.len() as CFIndex, utf16.as_ptr());
                CGEventPostToPid(pid, event);
                CFRelease(event);
            }
        }
        sleep(Duration::from_millis(20));
    }
    release_source(source);
    sleep(SETTLE);
    Ok(J::obj(vec![
        ("mechanism", J::str("CGEventPostToPid")),
        (
            "variant",
            J::str(format!("keyDown+keyUp/source={}", source_kind.key())),
        ),
        ("targetPid", J::Int(pid as i64)),
        ("text", J::str(text)),
        ("eventsCreated", J::Bool(created)),
        (
            "accessibilityTrusted",
            J::Bool(unsafe { AXIsProcessTrusted() } != 0),
        ),
        ("before", before),
        ("after", state()),
    ]))
}

/// The control: activate the target, drive the real cursor to the same
/// coordinate, click through the HID tap, then put the cursor and the prior
/// frontmost application back.
///
/// A control that does not act invalidates the trial it was proving. Without
/// it, a silent target is ambiguous between "macOS refused the delivery" and
/// "the campaign aimed at nothing".
fn foreground_click(args: &Args) -> Result<J, String> {
    let point = CGPoint {
        x: args.f64("x")?,
        y: args.f64("y")?,
    };
    let pid = args.optional_i32("pid");
    let before = state();
    let prior_pointer = pointer_location();
    let prior_frontmost = frontmost_application().map(|identity| identity.pid);
    let activated = pid.map(activate);
    if activated.is_some() {
        sleep(Duration::from_millis(600));
    }
    warp_pointer(point);
    sleep(Duration::from_millis(120));
    // The control is meant to look like a person clicking, so the button is
    // held for a human interval by default. A control that failed because it
    // clicked faster than any hand could would invalidate every trial it was
    // supposed to be proving.
    let gap = args.optional_f64("gap-ms").unwrap_or(80.0);
    let source = Source::Null.create();
    for kind in [kCGEventLeftMouseDown, kCGEventLeftMouseUp] {
        unsafe {
            let event = CGEventCreateMouseEvent(source, kind, point, kCGMouseButtonLeft);
            if event.is_null() {
                continue;
            }
            CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        }
        if kind == kCGEventLeftMouseDown && gap > 0.0 {
            sleep(Duration::from_secs_f64(gap / 1000.0));
        }
    }
    release_source(source);
    sleep(SETTLE);
    let observed = state();
    if args.flag("restore") {
        if let Some(prior) = prior_frontmost {
            activate(prior);
            sleep(Duration::from_millis(400));
        }
        warp_pointer(prior_pointer);
    }
    Ok(J::obj(vec![
        ("mechanism", J::str("CGEventPost(kCGHIDEventTap)")),
        ("point", point_json(point)),
        (
            "activated",
            activated.map(J::Bool).unwrap_or(J::Null),
        ),
        ("restored", J::Bool(args.flag("restore"))),
        ("before", before),
        ("after", observed),
        ("final", state()),
    ]))
}

fn foreground_key(args: &Args) -> Result<J, String> {
    let text = args.string("text")?;
    let pid = args.optional_i32("pid");
    let before = state();
    let prior_frontmost = frontmost_application().map(|identity| identity.pid);
    let activated = pid.map(activate);
    if activated.is_some() {
        sleep(Duration::from_millis(600));
    }
    let source = Source::Null.create();
    for character in text.chars() {
        let code = key_code_for(character);
        let utf16: Vec<u16> = character.to_string().encode_utf16().collect();
        for down in [true, false] {
            unsafe {
                let event = CGEventCreateKeyboardEvent(source, code, down);
                if event.is_null() {
                    continue;
                }
                CGEventKeyboardSetUnicodeString(event, utf16.len() as CFIndex, utf16.as_ptr());
                CGEventPost(kCGHIDEventTap, event);
                CFRelease(event);
            }
        }
        sleep(Duration::from_millis(20));
    }
    release_source(source);
    sleep(SETTLE);
    let observed = state();
    if args.flag("restore") {
        if let Some(prior) = prior_frontmost {
            activate(prior);
            sleep(Duration::from_millis(400));
        }
    }
    Ok(J::obj(vec![
        ("mechanism", J::str("CGEventPost(kCGHIDEventTap)")),
        ("text", J::str(text)),
        (
            "activated",
            activated.map(J::Bool).unwrap_or(J::Null),
        ),
        ("before", before),
        ("after", observed),
    ]))
}

fn activate_command(args: &Args) -> Result<J, String> {
    let pid = args.i32("pid")?;
    let activated = activate(pid);
    sleep(Duration::from_millis(600));
    Ok(J::obj(vec![
        ("pid", J::Int(pid as i64)),
        ("activated", J::Bool(activated)),
        ("frontmost", frontmost()),
    ]))
}

/// Accessibility readback of the target's focused window.
///
/// `AXDocument` is what a browser publishes as the address of what it is
/// showing, which is how a navigation is verified without Automation
/// permission. A denied Accessibility permission is reported as such rather
/// than as an absent document, because those mean opposite things.
fn ax_read(args: &Args) -> Result<J, String> {
    let pid = args.i32("pid")?;
    let trusted = unsafe { AXIsProcessTrusted() } != 0;
    if !trusted {
        return Ok(J::obj(vec![
            ("pid", J::Int(pid as i64)),
            ("accessibilityTrusted", J::Bool(false)),
            ("document", J::Null),
            ("title", J::Null),
            (
                "error",
                J::str("the probe does not hold Accessibility permission"),
            ),
        ]));
    }
    unsafe {
        let application = AXUIElementCreateApplication(pid);
        if application.is_null() {
            return Err(format!("no accessibility element for pid {pid}"));
        }
        let (window, window_error) = copy_attribute(application, "AXFocusedWindow");
        let mut document = J::Null;
        let mut title = J::Null;
        if !window.is_null() {
            let (value, _) = copy_attribute(window, "AXDocument");
            if let Some(text) = cf_describe(value) {
                document = J::Str(text);
            }
            if !value.is_null() {
                CFRelease(value);
            }
            let (value, _) = copy_attribute(window, "AXTitle");
            if let Some(text) = cf_describe(value) {
                title = J::Str(text);
            }
            if !value.is_null() {
                CFRelease(value);
            }
            CFRelease(window);
        }
        CFRelease(application);
        Ok(J::obj(vec![
            ("pid", J::Int(pid as i64)),
            ("accessibilityTrusted", J::Bool(true)),
            ("focusedWindowError", J::Int(window_error as i64)),
            ("document", document),
            ("title", title),
        ]))
    }
}

fn copy_attribute(element: CFTypeRef, attribute: &str) -> (CFTypeRef, i32) {
    let name = CFString::new(attribute);
    let mut value: CFTypeRef = std::ptr::null();
    let status = unsafe {
        AXUIElementCopyAttributeValue(element, name.0, &mut value as *mut CFTypeRef)
    };
    if status != 0 {
        return (std::ptr::null(), status);
    }
    (value, status)
}

fn source_of(args: &Args) -> Result<Source, String> {
    let requested = args.optional_string("source").unwrap_or_else(|| "null".into());
    Source::parse(&requested)
        .ok_or_else(|| format!("unknown event source: {requested} (null|hid|combined|private)"))
}

fn release_source(source: CGEventSourceRef) {
    if !source.is_null() {
        unsafe { CFRelease(source as *const c_void) };
    }
}
