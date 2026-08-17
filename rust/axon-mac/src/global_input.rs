use axon_core::{
    BackendError, GlobalInputObserver, RecordedAppIdentity, RecordedElementEvidence,
    RecordedInputEvent, RecordedKeystroke, RecordedPoint, RecordedTargetEvidence, RecordingScope,
};
use std::{
    collections::VecDeque,
    ffi::{c_char, c_void},
    ptr::{null, null_mut},
    sync::{Arc, Condvar, Mutex, mpsc},
    thread::{self, JoinHandle},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

type CFTypeRef = *const c_void;
type CFStringRef = *const c_void;
type AXUIElementRef = *const c_void;
type CGEventRef = *const c_void;
type CFMachPortRef = *mut c_void;
type CFRunLoopRef = *mut c_void;

const UTF8: u32 = 0x0800_0100;
const EVENT_LEFT_DOWN: u32 = 1;
const EVENT_LEFT_UP: u32 = 2;
const EVENT_LEFT_DRAGGED: u32 = 6;
const EVENT_KEY_DOWN: u32 = 10;
const EVENT_SCROLL: u32 = 22;
const EVENT_TAP_DISABLED_TIMEOUT: u32 = 0xffff_fffe;
const EVENT_TAP_DISABLED_USER: u32 = 0xffff_ffff;
const FIELD_KEYCODE: u32 = 9;
const FIELD_SCROLL_Y: u32 = 11;
const FIELD_SCROLL_X: u32 = 12;
const FLAG_COMMAND: u64 = 1 << 20;
const FLAG_SHIFT: u64 = 1 << 17;
const FLAG_CONTROL: u64 = 1 << 18;
const FLAG_OPTION: u64 = 1 << 19;

#[repr(C)]
#[derive(Clone, Copy)]
struct CGPoint { x: f64, y: f64 }

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    fn AXUIElementCreateApplication(pid: i32) -> AXUIElementRef;
    fn AXUIElementCopyElementAtPosition(root: AXUIElementRef, x: f32, y: f32, out: *mut AXUIElementRef) -> i32;
    fn AXUIElementCopyAttributeValue(element: AXUIElementRef, attribute: CFStringRef, out: *mut CFTypeRef) -> i32;
    fn AXUIElementGetPid(element: AXUIElementRef, pid: *mut i32) -> i32;
    fn CGEventTapCreate(tap: u32, place: u32, options: u32, mask: u64, callback: unsafe extern "C" fn(*mut c_void, u32, CGEventRef, *mut c_void) -> CGEventRef, user: *mut c_void) -> CFMachPortRef;
    fn CGEventTapEnable(tap: CFMachPortRef, enable: bool);
    fn CGEventGetLocation(event: CGEventRef) -> CGPoint;
    fn CGEventGetIntegerValueField(event: CGEventRef, field: u32) -> i64;
    fn CGEventGetFlags(event: CGEventRef) -> u64;
    fn CGEventKeyboardGetUnicodeString(event: CGEventRef, max: usize, actual: *mut usize, chars: *mut u16);
}
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFMachPortCreateRunLoopSource(alloc: *const c_void, port: CFMachPortRef, order: isize) -> *mut c_void;
    fn CFRunLoopGetCurrent() -> CFRunLoopRef;
    fn CFRunLoopAddSource(run_loop: CFRunLoopRef, source: *mut c_void, mode: CFStringRef);
    fn CFRunLoopRun();
    fn CFRunLoopStop(run_loop: CFRunLoopRef);
    fn CFStringCreateWithCString(alloc: *const c_void, text: *const c_char, encoding: u32) -> CFStringRef;
    fn CFStringGetCString(value: CFStringRef, buffer: *mut c_char, size: isize, encoding: u32) -> u8;
    fn CFGetTypeID(value: CFTypeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFRelease(value: CFTypeRef);
    static kCFRunLoopCommonModes: CFStringRef;
}
#[link(name = "Carbon", kind = "framework")]
unsafe extern "C" { fn IsSecureEventInputEnabled() -> bool; }

fn operation(message: impl Into<String>) -> BackendError {
    BackendError::Operation { operation: "observeGlobalInput".into(), message: message.into(), diagnostic: None }
}

#[derive(Default)]
struct Queue { events: Mutex<VecDeque<RecordedInputEvent>>, ready: Condvar }
impl Queue {
    fn push(&self, event: RecordedInputEvent) { self.events.lock().unwrap().push_back(event); self.ready.notify_one(); }
    fn drain(&self, timeout: Duration) -> Vec<RecordedInputEvent> {
        let mut events = self.events.lock().unwrap();
        if events.is_empty() { events = self.ready.wait_timeout(events, timeout).unwrap().0; }
        events.drain(..).collect()
    }
}

trait TapRuntime: Send + Sync {
    fn trusted(&self) -> bool;
    fn spawn(&self, scope: RecordingScope, queue: Arc<Queue>) -> Result<RunningTap, BackendError>;
}

struct RunningTap { stop: Option<Box<dyn Fn() + Send + Sync>>, thread: Option<JoinHandle<()>> }
impl RunningTap {
    fn stop(&mut self) { if let Some(stop) = self.stop.take() { stop(); } if let Some(thread) = self.thread.take() { let _ = thread.join(); } }
}
impl Drop for RunningTap { fn drop(&mut self) { self.stop(); } }

#[derive(Default)]
struct NativeRuntime;
impl TapRuntime for NativeRuntime {
    fn trusted(&self) -> bool { unsafe { AXIsProcessTrusted() } }
    fn spawn(&self, scope: RecordingScope, queue: Arc<Queue>) -> Result<RunningTap, BackendError> {
        let run_loop = Arc::new(Mutex::new(0usize));
        let run_loop_for_thread = Arc::clone(&run_loop);
        let (started_tx, started_rx) = mpsc::sync_channel(1);
        let thread = thread::Builder::new().name("axon-global-input".into()).spawn(move || {
            let state = Box::new(CallbackState { scope, queue, secure: Mutex::new(false) });
            let state_ptr = Box::into_raw(state);
            let mask = [EVENT_LEFT_DOWN, EVENT_LEFT_UP, EVENT_LEFT_DRAGGED, EVENT_KEY_DOWN, EVENT_SCROLL]
                .into_iter().fold(0u64, |mask, ty| mask | (1u64 << ty));
            let tap = unsafe { CGEventTapCreate(0, 0, 1, mask, event_callback, state_ptr.cast()) };
            if tap.is_null() { unsafe { drop(Box::from_raw(state_ptr)); } let _ = started_tx.send(Err("CGEventTapCreate refused the listen-only event tap")); return; }
            let source = unsafe { CFMachPortCreateRunLoopSource(null(), tap, 0) };
            if source.is_null() { unsafe { CFRelease(tap.cast()); drop(Box::from_raw(state_ptr)); } let _ = started_tx.send(Err("could not create event-tap run-loop source")); return; }
            let current = unsafe { CFRunLoopGetCurrent() };
            *run_loop_for_thread.lock().unwrap() = current as usize;
            unsafe { CFRunLoopAddSource(current, source, kCFRunLoopCommonModes); CGEventTapEnable(tap, true); }
            let _ = started_tx.send(Ok(()));
            unsafe { CFRunLoopRun(); CGEventTapEnable(tap, false); CFRelease(source.cast()); CFRelease(tap.cast()); drop(Box::from_raw(state_ptr)); }
        }).map_err(|error| operation(format!("could not create observer thread: {error}")))?;
        match started_rx.recv_timeout(Duration::from_secs(2)) {
            Ok(Ok(())) => Ok(RunningTap { stop: Some(Box::new(move || { let value = *run_loop.lock().unwrap(); if value != 0 { unsafe { CFRunLoopStop(value as CFRunLoopRef); } } })), thread: Some(thread) }),
            Ok(Err(reason)) => { let _ = thread.join(); Err(operation(reason)) }
            Err(_) => Err(operation("event-tap initialization timed out")),
        }
    }
}

struct CallbackState { scope: RecordingScope, queue: Arc<Queue>, secure: Mutex<bool> }

unsafe extern "C" fn event_callback(tap: *mut c_void, ty: u32, event: CGEventRef, user: *mut c_void) -> CGEventRef {
    if matches!(ty, EVENT_TAP_DISABLED_TIMEOUT | EVENT_TAP_DISABLED_USER) { return event; }
    let state = unsafe { &*(user as *const CallbackState) };
    let secure = unsafe { IsSecureEventInputEnabled() };
    let mut previous = state.secure.lock().unwrap();
    if secure != *previous { state.queue.push(RecordedInputEvent::SecureInputChanged { active: secure, timestamp_ms: now_ms() }); *previous = secure; }
    drop(previous);
    if secure { return event; }
    if let Some(captured) = capture_event(state, ty, event) { state.queue.push(captured); }
    event
}

fn capture_event(state: &CallbackState, ty: u32, event: CGEventRef) -> Option<RecordedInputEvent> {
    let timestamp_ms = now_ms();
    match ty {
        EVENT_LEFT_DOWN | EVENT_LEFT_UP | EVENT_SCROLL => {
            let point = unsafe { CGEventGetLocation(event) };
            let evidence = target_evidence(point)?;
            if !scope_accepts(&state.scope, &evidence.app) { return None; }
            match ty {
                EVENT_LEFT_DOWN => Some(RecordedInputEvent::MouseDown { evidence, timestamp_ms }),
                EVENT_LEFT_UP => Some(RecordedInputEvent::MouseUp { evidence, timestamp_ms }),
                _ => Some(RecordedInputEvent::Scroll { evidence, delta_x: unsafe { CGEventGetIntegerValueField(event, FIELD_SCROLL_X) } as f64, delta_y: unsafe { CGEventGetIntegerValueField(event, FIELD_SCROLL_Y) } as f64, timestamp_ms }),
            }
        }
        EVENT_LEFT_DRAGGED => { let point = unsafe { CGEventGetLocation(event) }; Some(RecordedInputEvent::MouseDragged { at: RecordedPoint { x: point.x, y: point.y }, timestamp_ms }) }
        EVENT_KEY_DOWN => {
            let (app, _) = focused_evidence()?;
            if !scope_accepts(&state.scope, &app) { return None; }
            Some(RecordedInputEvent::KeyDown { app, keystroke: classify_key(event), timestamp_ms })
        }
        _ => None,
    }
}

fn scope_accepts(scope: &RecordingScope, app: &RecordedAppIdentity) -> bool {
    match scope { RecordingScope::AllApplications => true, RecordingScope::Application { app: wanted } => wanted.process_id.zip(app.process_id).is_some_and(|(a,b)| a == b) || (!wanted.name.is_empty() && wanted.name.eq_ignore_ascii_case(&app.name)) }
}

fn classify_key(event: CGEventRef) -> RecordedKeystroke {
    let flags = unsafe { CGEventGetFlags(event) };
    let keycode = unsafe { CGEventGetIntegerValueField(event, FIELD_KEYCODE) };
    let named = match keycode { 36 => Some("Return"), 48 => Some("Tab"), 51 => Some("Backspace"), 53 => Some("Escape"), 115 => Some("Home"), 116 => Some("PageUp"), 117 => Some("Delete"), 119 => Some("End"), 121 => Some("PageDown"), 123 => Some("Left"), 124 => Some("Right"), 125 => Some("Down"), 126 => Some("Up"), _ => None };
    let chord = flags & (FLAG_COMMAND | FLAG_CONTROL | FLAG_OPTION) != 0;
    if named.is_none() && !chord {
        let mut chars = [0u16; 16]; let mut len = 0;
        unsafe { CGEventKeyboardGetUnicodeString(event, chars.len(), &mut len, chars.as_mut_ptr()); }
        let text = String::from_utf16_lossy(&chars[..len.min(chars.len())]);
        if !text.is_empty() { return RecordedKeystroke::Text { text }; }
    }
    let base = named.map(str::to_owned).unwrap_or_else(|| { let mut chars = [0u16; 8]; let mut len = 0; unsafe { CGEventKeyboardGetUnicodeString(event, chars.len(), &mut len, chars.as_mut_ptr()); } String::from_utf16_lossy(&chars[..len.min(chars.len())]).to_lowercase() });
    let mut parts = Vec::new();
    if flags & FLAG_COMMAND != 0 { parts.push("cmd"); } if flags & FLAG_CONTROL != 0 { parts.push("ctrl"); } if flags & FLAG_OPTION != 0 { parts.push("option"); } if flags & FLAG_SHIFT != 0 { parts.push("shift"); } parts.push(&base);
    RecordedKeystroke::Key { key: parts.join("+") }
}

fn target_evidence(point: CGPoint) -> Option<RecordedTargetEvidence> {
    let root = unsafe { AXUIElementCreateSystemWide() }; if root.is_null() { return None; }
    let mut element = null(); let status = unsafe { AXUIElementCopyElementAtPosition(root, point.x as f32, point.y as f32, &mut element) }; unsafe { CFRelease(root); }
    if status != 0 || element.is_null() { return None; }
    let app = app_identity(element)?;
    let candidate = element_evidence(element); unsafe { CFRelease(element); }
    Some(RecordedTargetEvidence { app, point: RecordedPoint { x: point.x, y: point.y }, candidates: candidate.into_iter().collect() })
}

pub(crate) fn focused_evidence() -> Option<(RecordedAppIdentity, RecordedElementEvidence)> {
    let system = unsafe { AXUIElementCreateSystemWide() }; if system.is_null() { return None; }
    let app = attribute(system, "AXFocusedApplication")?; unsafe { CFRelease(system); }
    let element = attribute(app, "AXFocusedUIElement")?;
    let identity = app_identity(app)?; let evidence = element_evidence(element)?;
    unsafe { CFRelease(element); CFRelease(app); }
    Some((identity, evidence))
}

fn app_identity(element: AXUIElementRef) -> Option<RecordedAppIdentity> {
    let mut pid = 0; if unsafe { AXUIElementGetPid(element, &mut pid) } != 0 { return None; }
    let app = unsafe { AXUIElementCreateApplication(pid) }; if app.is_null() { return None; }
    let name = text_attribute(app, "AXTitle").unwrap_or_default(); unsafe { CFRelease(app); }
    Some(RecordedAppIdentity { name, bundle_identifier: None, process_id: Some(pid as u32) })
}

fn element_evidence(element: AXUIElementRef) -> Option<RecordedElementEvidence> {
    let role = text_attribute(element, "AXRole")?;
    let sensitive = role == "AXSecureTextField" || text_attribute(element, "AXDescription").is_some_and(|v| v.to_ascii_lowercase().contains("password"));
    Some(RecordedElementEvidence { role, subrole: text_attribute(element, "AXSubrole"), identifier: text_attribute(element, "AXIdentifier"), title: text_attribute(element, "AXTitle"), value: (!sensitive).then(|| text_attribute(element, "AXValue")).flatten(), description: text_attribute(element, "AXDescription"), actions: Vec::new(), window_title: None, sensitive })
}

fn attribute(element: AXUIElementRef, name: &str) -> Option<AXUIElementRef> {
    let name = cf_string(name)?; let mut value = null(); let status = unsafe { AXUIElementCopyAttributeValue(element, name, &mut value) }; unsafe { CFRelease(name); } (status == 0 && !value.is_null()).then_some(value)
}
fn text_attribute(element: AXUIElementRef, name: &str) -> Option<String> { let value = attribute(element, name)?; let result = string_value(value); unsafe { CFRelease(value); } result }
fn cf_string(value: &str) -> Option<CFStringRef> { let value = std::ffi::CString::new(value).ok()?; let result = unsafe { CFStringCreateWithCString(null(), value.as_ptr(), UTF8) }; (!result.is_null()).then_some(result) }
fn string_value(value: CFTypeRef) -> Option<String> { if unsafe { CFGetTypeID(value) } != unsafe { CFStringGetTypeID() } { return None; } let mut buf = vec![0u8; 4096]; if unsafe { CFStringGetCString(value, buf.as_mut_ptr().cast(), buf.len() as isize, UTF8) } == 0 { return None; } let end = buf.iter().position(|byte| *byte == 0)?; Some(String::from_utf8_lossy(&buf[..end]).into_owned()) }
fn now_ms() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64 }

pub struct MacGlobalInputObserver { runtime: Arc<dyn TapRuntime>, queue: Arc<Queue>, running: Option<RunningTap> }
impl Default for MacGlobalInputObserver { fn default() -> Self { Self { runtime: Arc::new(NativeRuntime), queue: Arc::new(Queue::default()), running: None } } }
impl MacGlobalInputObserver { pub fn available(&self) -> bool { self.runtime.trusted() } }
impl GlobalInputObserver for MacGlobalInputObserver {
    fn start(&mut self, scope: &RecordingScope) -> Result<(), BackendError> { if self.running.is_some() { return Err(operation("a global input observer session is already active")); } if !self.runtime.trusted() { return Err(operation("Accessibility permission is not granted")); } self.running = Some(self.runtime.spawn(scope.clone(), Arc::clone(&self.queue))?); Ok(()) }
    fn poll(&mut self, timeout: Duration) -> Result<Vec<RecordedInputEvent>, BackendError> { if self.running.is_none() { return Err(operation("no global input observer session is active")); } Ok(self.queue.drain(timeout)) }
    fn stop(&mut self) -> Result<(), BackendError> { if let Some(mut running) = self.running.take() { running.stop(); } self.queue.events.lock().unwrap().clear(); Ok(()) }
    fn is_recording(&self) -> bool { self.running.is_some() }
}
impl Drop for MacGlobalInputObserver { fn drop(&mut self) { let _ = self.stop(); } }

#[cfg(test)]
mod tests {
    use super::*;
    struct FakeRuntime { trusted: bool, stops: Arc<Mutex<usize>> }
    impl TapRuntime for FakeRuntime { fn trusted(&self) -> bool { self.trusted } fn spawn(&self, _: RecordingScope, _: Arc<Queue>) -> Result<RunningTap, BackendError> { let stops = Arc::clone(&self.stops); Ok(RunningTap { stop: Some(Box::new(move || *stops.lock().unwrap() += 1)), thread: None }) } }
    fn observer(trusted: bool, stops: Arc<Mutex<usize>>) -> MacGlobalInputObserver { MacGlobalInputObserver { runtime: Arc::new(FakeRuntime { trusted, stops }), queue: Arc::new(Queue::default()), running: None } }
    #[test] fn refuses_without_accessibility_permission() { let mut value = observer(false, Arc::default()); let error = value.start(&RecordingScope::AllApplications).unwrap_err(); assert!(error.to_string().contains("Accessibility permission")); assert!(!value.is_recording()); }
    #[test] fn refuses_duplicate_start_and_stop_is_idempotent() { let stops = Arc::new(Mutex::new(0)); let mut value = observer(true, Arc::clone(&stops)); value.start(&RecordingScope::AllApplications).unwrap(); assert!(value.start(&RecordingScope::AllApplications).unwrap_err().to_string().contains("already active")); value.stop().unwrap(); value.stop().unwrap(); assert_eq!(*stops.lock().unwrap(), 1); }
    #[test] fn drop_releases_active_provider() { let stops = Arc::new(Mutex::new(0)); { let mut value = observer(true, Arc::clone(&stops)); value.start(&RecordingScope::AllApplications).unwrap(); } assert_eq!(*stops.lock().unwrap(), 1); }
}