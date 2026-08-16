//! Raw bindings to the macOS surfaces the campaign measures against.
//!
//! Everything here is a system framework: Core Foundation for the window-list
//! dictionaries, Core Graphics for event creation and posting, HIServices for
//! the Accessibility readback, and the Objective-C runtime for the two AppKit
//! things no C API exposes — which application is frontmost, and a window of
//! our own to hold the foreground.
//!
//! The whole file is compiled only on macOS. `main.rs` refuses to run anywhere
//! else before this module is reached, so a Linux `cargo check` never sees a
//! Core Graphics symbol.
#![allow(non_snake_case, non_upper_case_globals)]

use std::ffi::{CStr, CString, c_char, c_void};

pub type CFTypeRef = *const c_void;
pub type CFStringRef = *const c_void;
pub type CFArrayRef = *const c_void;
pub type CFDictionaryRef = *const c_void;
pub type CFIndex = isize;
pub type CFTypeID = usize;
pub type Boolean = u8;
pub type CGEventRef = *const c_void;
pub type CGEventSourceRef = *const c_void;
pub type Id = *mut c_void;
pub type Sel = *const c_void;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CGPoint {
    pub x: f64,
    pub y: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CGSize {
    pub width: f64,
    pub height: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CGRect {
    pub origin: CGPoint,
    pub size: CGSize,
}

pub const kCFStringEncodingUTF8: u32 = 0x0800_0100;
pub const kCFNumberSInt64Type: CFIndex = 4;
pub const kCFNumberFloat64Type: CFIndex = 6;

/// On-screen windows only, with the desktop picture and its icons excluded, so
/// the list is the window stack a click would actually land in.
pub const kCGWindowListOptionOnScreenOnly: u32 = 1 << 0;
pub const kCGWindowListExcludeDesktopElements: u32 = 1 << 4;
pub const kCGNullWindowID: u32 = 0;

pub const kCGEventLeftMouseDown: u32 = 1;
pub const kCGEventLeftMouseUp: u32 = 2;
pub const kCGMouseButtonLeft: u32 = 0;
pub const kCGMouseEventClickState: u32 = 1;
pub const kCGHIDEventTap: u32 = 0;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    pub fn CFRelease(cf: CFTypeRef);
    pub fn CFGetTypeID(cf: CFTypeRef) -> CFTypeID;
    pub fn CFStringGetTypeID() -> CFTypeID;
    pub fn CFNumberGetTypeID() -> CFTypeID;
    pub fn CFArrayGetCount(array: CFArrayRef) -> CFIndex;
    pub fn CFArrayGetValueAtIndex(array: CFArrayRef, index: CFIndex) -> CFTypeRef;
    pub fn CFDictionaryGetValue(dictionary: CFDictionaryRef, key: CFTypeRef) -> CFTypeRef;
    pub fn CFStringCreateWithCString(
        allocator: CFTypeRef,
        cstr: *const c_char,
        encoding: u32,
    ) -> CFStringRef;
    pub fn CFStringGetCString(
        string: CFStringRef,
        buffer: *mut c_char,
        size: CFIndex,
        encoding: u32,
    ) -> Boolean;
    pub fn CFNumberGetValue(number: CFTypeRef, kind: CFIndex, out: *mut c_void) -> Boolean;
    pub fn CFCopyDescription(cf: CFTypeRef) -> CFStringRef;
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    pub fn CGWindowListCopyWindowInfo(option: u32, relativeToWindow: u32) -> CFArrayRef;
    pub fn CGEventCreate(source: CGEventSourceRef) -> CGEventRef;
    pub fn CGEventGetLocation(event: CGEventRef) -> CGPoint;
    pub fn CGEventCreateMouseEvent(
        source: CGEventSourceRef,
        mouseType: u32,
        mouseCursorPosition: CGPoint,
        mouseButton: u32,
    ) -> CGEventRef;
    pub fn CGEventCreateKeyboardEvent(
        source: CGEventSourceRef,
        virtualKey: u16,
        keyDown: bool,
    ) -> CGEventRef;
    pub fn CGEventKeyboardSetUnicodeString(event: CGEventRef, length: CFIndex, string: *const u16);
    pub fn CGEventSetIntegerValueField(event: CGEventRef, field: u32, value: i64);
    pub fn CGEventPostToPid(pid: i32, event: CGEventRef);
    pub fn CGEventPost(tap: u32, event: CGEventRef);
    pub fn CGEventSourceCreate(stateID: i32) -> CGEventSourceRef;
    pub fn CGWarpMouseCursorPosition(newCursorPosition: CGPoint) -> i32;
    pub fn CGMainDisplayID() -> u32;
    pub fn CGDisplayPixelsWide(display: u32) -> usize;
    pub fn CGDisplayPixelsHigh(display: u32) -> usize;
}

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    pub fn AXIsProcessTrusted() -> Boolean;
    pub fn AXUIElementCreateApplication(pid: i32) -> CFTypeRef;
    pub fn AXUIElementCopyAttributeValue(
        element: CFTypeRef,
        attribute: CFStringRef,
        value: *mut CFTypeRef,
    ) -> i32;
}

#[link(name = "objc")]
unsafe extern "C" {
    pub fn objc_getClass(name: *const c_char) -> Id;
    pub fn sel_registerName(name: *const c_char) -> Sel;
    pub fn objc_msgSend();
}

// AppKit is linked for its classes rather than for any symbol named here: the
// Objective-C runtime finds `NSApplication` and friends only if the framework
// is in the image.
#[link(name = "AppKit", kind = "framework")]
#[link(name = "Foundation", kind = "framework")]
unsafe extern "C" {}

// -- Core Foundation helpers ---------------------------------------------------------------

/// A Core Foundation string that releases itself, so key lookups in the window
/// list do not leak one per window per phase.
pub struct CFString(pub CFStringRef);

impl CFString {
    pub fn new(value: &str) -> CFString {
        let owned = CString::new(value).unwrap_or_default();
        CFString(unsafe {
            CFStringCreateWithCString(std::ptr::null(), owned.as_ptr(), kCFStringEncodingUTF8)
        })
    }
}

impl Drop for CFString {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CFRelease(self.0) };
        }
    }
}

pub fn cf_string_to_string(value: CFTypeRef) -> Option<String> {
    if value.is_null() {
        return None;
    }
    unsafe {
        if CFGetTypeID(value) != CFStringGetTypeID() {
            return None;
        }
        let mut buffer = vec![0_i8; 4096];
        let copied = CFStringGetCString(
            value,
            buffer.as_mut_ptr() as *mut c_char,
            buffer.len() as CFIndex,
            kCFStringEncodingUTF8,
        );
        if copied == 0 {
            return None;
        }
        Some(
            CStr::from_ptr(buffer.as_ptr() as *const c_char)
                .to_string_lossy()
                .into_owned(),
        )
    }
}

/// Renders any Core Foundation value as text. Used where an attribute's type is
/// not guaranteed — `AXDocument` answers with a string on some applications and
/// a URL on others, and a campaign that dropped the URL case would report a
/// readback failure that never happened.
pub fn cf_describe(value: CFTypeRef) -> Option<String> {
    if value.is_null() {
        return None;
    }
    if let Some(text) = cf_string_to_string(value) {
        return Some(text);
    }
    unsafe {
        let description = CFCopyDescription(value);
        let text = cf_string_to_string(description);
        if !description.is_null() {
            CFRelease(description);
        }
        text
    }
}

pub fn cf_number_i64(value: CFTypeRef) -> Option<i64> {
    if value.is_null() {
        return None;
    }
    unsafe {
        if CFGetTypeID(value) != CFNumberGetTypeID() {
            return None;
        }
        let mut out: i64 = 0;
        if CFNumberGetValue(value, kCFNumberSInt64Type, &mut out as *mut i64 as *mut c_void) == 0 {
            return None;
        }
        Some(out)
    }
}

pub fn cf_number_f64(value: CFTypeRef) -> Option<f64> {
    if value.is_null() {
        return None;
    }
    unsafe {
        if CFGetTypeID(value) != CFNumberGetTypeID() {
            return None;
        }
        let mut out: f64 = 0.0;
        if CFNumberGetValue(value, kCFNumberFloat64Type, &mut out as *mut f64 as *mut c_void) == 0 {
            return None;
        }
        Some(out)
    }
}

pub fn dictionary_value(dictionary: CFDictionaryRef, key: &str) -> CFTypeRef {
    let key = CFString::new(key);
    unsafe { CFDictionaryGetValue(dictionary, key.0) }
}

// -- Objective-C helpers -------------------------------------------------------------------

pub fn class(name: &str) -> Id {
    let owned = CString::new(name).unwrap_or_default();
    unsafe { objc_getClass(owned.as_ptr()) }
}

pub fn sel(name: &str) -> Sel {
    let owned = CString::new(name).unwrap_or_default();
    unsafe { sel_registerName(owned.as_ptr()) }
}

/// `objc_msgSend` is variadic in its declaration and exact in its ABI: the
/// correct way to call it is to transmute it to the signature of the method
/// being sent. Each helper below is one such signature, named for its shape.
macro_rules! msg {
    ($name:ident, ($($arg:ident : $argty:ty),*) -> $ret:ty) => {
        pub fn $name(receiver: Id, selector: &str $(, $arg: $argty)*) -> $ret {
            let target: extern "C" fn(Id, Sel $(, $argty)*) -> $ret =
                unsafe { std::mem::transmute(objc_msgSend as *const c_void) };
            target(receiver, sel(selector) $(, $arg)*)
        }
    };
}

msg!(send, () -> Id);
msg!(send_id, (a: Id) -> Id);
msg!(send_bool_arg, (a: bool) -> Id);
msg!(send_u64_arg, (a: u64) -> Id);
msg!(send_f64_arg, (a: f64) -> Id);
msg!(send_ret_i64, () -> i64);
msg!(send_ret_u64, () -> u64);
msg!(send_ret_f64, () -> f64);
msg!(send_ret_bool, () -> bool);
msg!(send_ret_ptr, () -> *const c_char);
msg!(send_ret_rect, () -> CGRect);
msg!(send_ret_point, () -> CGPoint);
msg!(send_rect_arg, (a: CGRect) -> Id);
msg!(send_ret_rect_with_rect, (a: CGRect) -> CGRect);
msg!(send_ret_rect_with_rect_view, (a: CGRect, b: Id) -> CGRect);
msg!(send_sel_arg, (a: Sel) -> bool);
msg!(send_i64_arg, (a: i64) -> Id);
msg!(send_i32_arg, (a: i32) -> Id);
msg!(send_rect_mask_backing_defer, (a: CGRect, b: u64, c: u64, d: bool) -> Id);
msg!(send_next_event, (a: u64, b: Id, c: Id, d: bool) -> Id);

pub fn nsstring(value: &str) -> Id {
    let owned = CString::new(value).unwrap_or_default();
    let target: extern "C" fn(Id, Sel, *const c_char) -> Id =
        unsafe { std::mem::transmute(objc_msgSend as *const c_void) };
    target(
        class("NSString"),
        sel("stringWithUTF8String:"),
        owned.as_ptr(),
    )
}

pub fn nsstring_to_string(value: Id) -> Option<String> {
    if value.is_null() {
        return None;
    }
    let pointer = send_ret_ptr(value, "UTF8String");
    if pointer.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(pointer) }.to_string_lossy().into_owned())
}

pub fn responds_to(receiver: Id, selector: &str) -> bool {
    if receiver.is_null() {
        return false;
    }
    send_sel_arg(receiver, "respondsToSelector:", sel(selector))
}

// -- The two AppKit facts with no C equivalent ----------------------------------------------

#[derive(Clone, Debug, Default)]
pub struct AppIdentity {
    pub pid: i32,
    pub bundle_id: Option<String>,
    pub name: Option<String>,
    pub bundle_path: Option<String>,
    pub active: bool,
    pub terminated: bool,
}

pub fn running_application(pid: i32) -> Id {
    send_i32_arg(
        class("NSRunningApplication"),
        "runningApplicationWithProcessIdentifier:",
        pid,
    )
}

pub fn identity_of(application: Id) -> Option<AppIdentity> {
    if application.is_null() {
        return None;
    }
    let bundle_url = send(application, "bundleURL");
    Some(AppIdentity {
        pid: send_ret_i64(application, "processIdentifier") as i32,
        bundle_id: nsstring_to_string(send(application, "bundleIdentifier")),
        name: nsstring_to_string(send(application, "localizedName")),
        bundle_path: if bundle_url.is_null() {
            None
        } else {
            nsstring_to_string(send(bundle_url, "path"))
        },
        active: send_ret_bool(application, "isActive"),
        terminated: send_ret_bool(application, "isTerminated"),
    })
}

pub fn frontmost_application() -> Option<AppIdentity> {
    let workspace = send(class("NSWorkspace"), "sharedWorkspace");
    identity_of(send(workspace, "frontmostApplication"))
}

/// Brings one process to the front. `activate` is the modern spelling and
/// `activateWithOptions:` the one it replaced; both are tried because the
/// campaign has to run on whatever macOS the bench is on, and a control that
/// silently failed to activate would invalidate the trial it was proving.
pub fn activate(pid: i32) -> bool {
    let application = running_application(pid);
    if application.is_null() {
        return false;
    }
    if responds_to(application, "activate") {
        return send_ret_bool(application, "activate");
    }
    // NSApplicationActivateIgnoringOtherApps
    !send_u64_arg(application, "activateWithOptions:", 2).is_null()
}

// -- Core Graphics helpers -----------------------------------------------------------------

pub fn pointer_location() -> CGPoint {
    unsafe {
        let event = CGEventCreate(std::ptr::null());
        if event.is_null() {
            return CGPoint::default();
        }
        let point = CGEventGetLocation(event);
        CFRelease(event);
        point
    }
}

pub fn warp_pointer(point: CGPoint) {
    unsafe { CGWarpMouseCursorPosition(point) };
}

/// Which event source the posted events are built from.
///
/// The daemon builds its pixel-rung clicks with `CGEvent(mouseEventSource:
/// nil, ...)`, so `Null` is the variant the product would actually dispatch and
/// the one a row must be measured with. The others exist so a refusal can be
/// checked against a second variant rather than being generalized from one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Null,
    HidSystemState,
    CombinedSessionState,
    Private,
}

impl Source {
    pub fn parse(value: &str) -> Option<Source> {
        match value {
            "null" => Some(Source::Null),
            "hid" => Some(Source::HidSystemState),
            "combined" => Some(Source::CombinedSessionState),
            "private" => Some(Source::Private),
            _ => None,
        }
    }

    pub fn key(self) -> &'static str {
        match self {
            Source::Null => "null",
            Source::HidSystemState => "hid",
            Source::CombinedSessionState => "combined",
            Source::Private => "private",
        }
    }

    pub fn create(self) -> CGEventSourceRef {
        match self {
            Source::Null => std::ptr::null(),
            Source::HidSystemState => unsafe { CGEventSourceCreate(1) },
            Source::CombinedSessionState => unsafe { CGEventSourceCreate(0) },
            Source::Private => unsafe { CGEventSourceCreate(-1) },
        }
    }
}

/// The virtual key codes for the ASCII the campaign types. The unicode string
/// is what actually carries the character; the key code is set alongside it
/// because an application that reads `kCGKeyboardEventKeycode` rather than the
/// unicode payload would otherwise see every keystroke as `a`.
pub fn key_code_for(character: char) -> u16 {
    match character.to_ascii_lowercase() {
        'a' => 0,
        'b' => 11,
        'c' => 8,
        'd' => 2,
        'e' => 14,
        'f' => 3,
        'g' => 5,
        'h' => 4,
        'i' => 34,
        'j' => 38,
        'k' => 40,
        'l' => 37,
        'm' => 46,
        'n' => 45,
        'o' => 31,
        'p' => 35,
        'q' => 12,
        'r' => 15,
        's' => 1,
        't' => 17,
        'u' => 32,
        'v' => 9,
        'w' => 13,
        'x' => 7,
        'y' => 16,
        'z' => 6,
        '0' => 29,
        '1' => 18,
        '2' => 19,
        '3' => 20,
        '4' => 21,
        '5' => 23,
        '6' => 22,
        '7' => 26,
        '8' => 28,
        '9' => 25,
        ' ' => 49,
        _ => 0,
    }
}
