//! The AppKit facts with no C equivalent: what a running application is called, whether it is
//! still running, and the call that brings it forward. Reached through the Objective-C runtime so
//! the daemon needs no AppKit bindings.

use std::ffi::{CStr, c_char, c_void};

#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {}
#[link(name = "objc")]
unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> *mut c_void;
    fn sel_registerName(name: *const c_char) -> *mut c_void;
    fn objc_msgSend();
}

/// `objc_msgSend` is variadic in its declaration and exact in its ABI, so each call transmutes it
/// to the signature of the method being sent. BOOL is read as `i8`, which is its width on both
/// architectures.
unsafe fn send_id(receiver: *mut c_void, selector: &CStr) -> *mut c_void {
    let send: unsafe extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
        unsafe { std::mem::transmute(objc_msgSend as *const ()) };
    unsafe { send(receiver, sel_registerName(selector.as_ptr())) }
}
unsafe fn send_bool(receiver: *mut c_void, selector: &CStr) -> bool {
    let send: unsafe extern "C" fn(*mut c_void, *mut c_void) -> i8 =
        unsafe { std::mem::transmute(objc_msgSend as *const ()) };
    unsafe { send(receiver, sel_registerName(selector.as_ptr())) != 0 }
}
unsafe fn send_i32(receiver: *mut c_void, selector: &CStr) -> i32 {
    let send: unsafe extern "C" fn(*mut c_void, *mut c_void) -> i32 =
        unsafe { std::mem::transmute(objc_msgSend as *const ()) };
    unsafe { send(receiver, sel_registerName(selector.as_ptr())) }
}

unsafe fn string_property(object: *mut c_void, selector: &CStr) -> Option<String> {
    let value = unsafe { send_id(object, selector) };
    if value.is_null() {
        return None;
    }
    let utf8: unsafe extern "C" fn(*mut c_void, *mut c_void) -> *const c_char =
        unsafe { std::mem::transmute(objc_msgSend as *const ()) };
    let bytes = unsafe { utf8(value, sel_registerName(c"UTF8String".as_ptr())) };
    (!bytes.is_null()).then(|| {
        unsafe { CStr::from_ptr(bytes) }
            .to_string_lossy()
            .into_owned()
    })
}

fn running_application(pid: i32) -> *mut c_void {
    unsafe {
        let class = objc_getClass(c"NSRunningApplication".as_ptr());
        if class.is_null() {
            return std::ptr::null_mut();
        }
        let lookup: unsafe extern "C" fn(*mut c_void, *mut c_void, i32) -> *mut c_void =
            std::mem::transmute(objc_msgSend as *const ());
        lookup(
            class,
            sel_registerName(c"runningApplicationWithProcessIdentifier:".as_ptr()),
            pid,
        )
    }
}

/// The localized name and bundle identifier `NSRunningApplication` reports for a process.
pub fn running_application_identity(pid: i32) -> (Option<String>, Option<String>) {
    let app = running_application(pid);
    if app.is_null() {
        return (None, None);
    }
    unsafe {
        (
            string_property(app, c"localizedName"),
            string_property(app, c"bundleIdentifier"),
        )
    }
}

/// How this backend names one running application: the display name a person would call it, and
/// its bundle identifier.
///
/// Enumeration, capture, and the recorder all come through here, so a recorded artifact calls an
/// application what `look` calls it. The localized name is what `AppResolver` in `Sources/AxonCore`
/// both reports and resolves applications by; AXTitle names windows and elements there, never an
/// application. `accessibility_name` is the `AXTitle` already read from the application element,
/// used only as a fallback when `NSRunningApplication` has no localized name.
pub fn application_identity(pid: i32, accessibility_name: String) -> (String, Option<String>) {
    let (native_name, bundle_identifier) = running_application_identity(pid);
    (
        native_name
            .filter(|value| !value.is_empty())
            .unwrap_or(accessibility_name),
        bundle_identifier,
    )
}

/// The identity foreground delivery compares and activates: the bundle identifier, or `pid:<n>`
/// for a process with none.
pub fn identity_of(pid: i32, bundle_identifier: Option<String>) -> String {
    bundle_identifier.unwrap_or_else(|| format!("pid:{pid}"))
}

/// The processes running the application with this bundle identifier.
pub fn processes_with_bundle(bundle_identifier: &str) -> Vec<i32> {
    let Ok(bundle) = std::ffi::CString::new(bundle_identifier) else {
        return Vec::new();
    };
    unsafe {
        let class = objc_getClass(c"NSRunningApplication".as_ptr());
        let string_class = objc_getClass(c"NSString".as_ptr());
        if class.is_null() || string_class.is_null() {
            return Vec::new();
        }
        let with_utf8: unsafe extern "C" fn(
            *mut c_void,
            *mut c_void,
            *const c_char,
        ) -> *mut c_void = std::mem::transmute(objc_msgSend as *const ());
        let identifier = with_utf8(
            string_class,
            sel_registerName(c"stringWithUTF8String:".as_ptr()),
            bundle.as_ptr(),
        );
        if identifier.is_null() {
            return Vec::new();
        }
        let lookup: unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void) -> *mut c_void =
            std::mem::transmute(objc_msgSend as *const ());
        let apps = lookup(
            class,
            sel_registerName(c"runningApplicationsWithBundleIdentifier:".as_ptr()),
            identifier,
        );
        if apps.is_null() {
            return Vec::new();
        }
        let count: unsafe extern "C" fn(*mut c_void, *mut c_void) -> usize =
            std::mem::transmute(objc_msgSend as *const ());
        let at: unsafe extern "C" fn(*mut c_void, *mut c_void, usize) -> *mut c_void =
            std::mem::transmute(objc_msgSend as *const ());
        (0..count(apps, sel_registerName(c"count".as_ptr())))
            .map(|index| at(apps, sel_registerName(c"objectAtIndex:".as_ptr()), index))
            .filter(|app| !app.is_null() && !send_bool(*app, c"isTerminated"))
            .map(|app| send_i32(app, c"processIdentifier"))
            .collect()
    }
}

/// Whether `pid` is a running application that has not terminated.
pub fn is_running(pid: i32) -> bool {
    let app = running_application(pid);
    !app.is_null() && !unsafe { send_bool(app, c"isTerminated") }
}

/// The process `NSWorkspace` believes is frontmost.
///
/// Only a fallback. `NSWorkspace` refreshes this from notifications delivered on the main run loop,
/// which this daemon never spins, so it can lag the window server; the Accessibility system-wide
/// element is read first.
pub fn workspace_frontmost_process() -> Option<i32> {
    unsafe {
        let class = objc_getClass(c"NSWorkspace".as_ptr());
        if class.is_null() {
            return None;
        }
        let workspace = send_id(class, c"sharedWorkspace");
        if workspace.is_null() {
            return None;
        }
        let app = send_id(workspace, c"frontmostApplication");
        (!app.is_null()).then(|| send_i32(app, c"processIdentifier"))
    }
}

/// Asks AppKit to bring `pid` forward, returning the primitive used and what it answered.
///
/// `activate` is the modern spelling and `activateWithOptions:` the one it replaced; both are tried
/// because the daemon has to run on whatever macOS the machine is on. The answer is an
/// acknowledgement only: the caller proves activation by reading the foreground back.
pub fn activate(pid: i32) -> Option<(&'static str, bool)> {
    let app = running_application(pid);
    if app.is_null() {
        return None;
    }
    unsafe {
        if send_bool_arg(
            app,
            c"respondsToSelector:",
            sel_registerName(c"activate".as_ptr()),
        ) {
            return Some(("NSRunningApplication.activate", send_bool(app, c"activate")));
        }
        let activate_with: unsafe extern "C" fn(*mut c_void, *mut c_void, u64) -> i8 =
            std::mem::transmute(objc_msgSend as *const ());
        // NSApplicationActivateIgnoringOtherApps
        let accepted =
            activate_with(app, sel_registerName(c"activateWithOptions:".as_ptr()), 2) != 0;
        Some(("NSRunningApplication.activateWithOptions:", accepted))
    }
}

unsafe fn send_bool_arg(receiver: *mut c_void, selector: &CStr, argument: *mut c_void) -> bool {
    let send: unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void) -> i8 =
        unsafe { std::mem::transmute(objc_msgSend as *const ()) };
    unsafe { send(receiver, sel_registerName(selector.as_ptr()), argument) != 0 }
}
