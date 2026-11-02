use crate::global_input::MacGlobalInputObserver;
use crate::{
    ApplicationDispatch, ApplicationProcess, BackgroundApplicationKeyboard,
    BackgroundDispatchError, NativeInput, PointerTargetVerifier, ReadableStateProvider,
    VisualObservation, VisualObservationProvider,
    accessibility::{self, AxAccess},
    core_foundation::string_value,
    input::{self, native::Destination},
    workspace,
};
use serde_json::{Map, Value};

#[path = "capture.rs"]
mod window_capture;
use axon_core::{
    AppQuery, Application, BackendError, Capability, CapabilityInfo, CaptureBounds,
    ChildPageCapture, ChildPageRequest, KeyboardIntent, Node, Observation, PlatformBackend,
    RecordedFocusedEvidence, RecordedPoint, RecordedSettleEvidence, RecordedTargetEvidence,
    RecordingEvidenceProvider, Rect, Screenshot, Snapshot, SnapshotHandle, Window,
};
use std::{
    collections::HashMap,
    ffi::{CString, c_char, c_void},
    ptr::null,
    time::Duration,
};

type CFTypeRef = *const c_void;
type CFStringRef = *const c_void;
type CFArrayRef = *const c_void;
type AXUIElementRef = *const c_void;
type AXValueRef = *const c_void;

const UTF8: u32 = 0x0800_0100;
const MAX_DEPTH: usize = 24;
const MAX_NODES: usize = 5_000;
const AX_VALUE_CGPOINT: i64 = 1;
const AX_VALUE_CGSIZE: i64 = 2;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CGPoint {
    x: f64,
    y: f64,
}

fn child_count(element: AXUIElementRef) -> Option<usize> {
    let children = cfstr("AXChildren").ok()?;
    let mut count = 0;
    let status = unsafe { AXUIElementGetAttributeValueCount(element, children.0, &mut count) };
    (status == 0 && count >= 0).then_some(count as usize)
}

fn child_range(element: AXUIElementRef, offset: usize, limit: usize) -> Option<Owned> {
    if limit == 0 {
        return None;
    }
    let children = cfstr("AXChildren").ok()?;
    let mut values = null();
    let status = unsafe {
        AXUIElementCopyAttributeValues(
            element,
            children.0,
            CFRange {
                location: offset.try_into().ok()?,
                length: limit.try_into().ok()?,
            },
            &mut values,
        )
    };
    (status == 0 && !values.is_null()).then(|| Owned(values))
}

fn requested_range(total: usize, offset: usize, limit: Option<usize>) -> (usize, usize) {
    let offset = offset.min(total);
    let available = total - offset;
    (offset, limit.unwrap_or(available).min(available))
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CFRange {
    location: isize,
    length: isize,
}

impl ReadableStateProvider for MacBackend {
    fn readable_state(&self, target: &SnapshotHandle) -> Result<Map<String, Value>, BackendError> {
        let element = self.element(target)?;
        Ok([
            ("value", "AXValue"),
            ("title", "AXTitle"),
            ("description", "AXDescription"),
            ("identifier", "AXIdentifier"),
            ("help", "AXHelp"),
        ]
        .into_iter()
        .filter_map(|(field, attribute)| {
            text_attribute(element, attribute)
                .filter(|value| !value.is_empty())
                .map(|value| (field.into(), Value::String(value)))
        })
        .collect())
    }
}

/// The two macOS permissions this daemon answers for, read independently of each other.
///
/// They are independent in TCC — `kTCCServiceAccessibility` and `kTCCServiceScreenCapture` are
/// separate rows a user toggles separately — and the health report must say so. Capabilities are
/// free to *compose* them (a screenshot of a named application needs both on this backend, because
/// it resolves applications through the Accessibility API); the permission fields are not, and
/// deriving them from a composed capability is what made a denied-Accessibility daemon claim Screen
/// Recording was ungranted while its TCC row read granted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MacPermissions {
    pub accessibility: bool,
    pub screen_recording: bool,
}

impl MacPermissions {
    pub fn read() -> Self {
        Self {
            accessibility: accessibility::granted(),
            screen_recording: window_capture::screen_capture_enabled(),
        }
    }
}

/// The capability census, as a pure function of the two permissions.
///
/// Note that `screenshot` is unusable without Accessibility even though Screen Recording is what
/// TCC gates image capture on. That is honest for *this* backend: it names the window to capture by
/// resolving the application through the Accessibility API, so without that grant there is nothing
/// to point `CGWindowListCreateImage` at. The Swift daemon resolves applications through NSWorkspace
/// and so does not share the restriction; see docs/cross-platform-internals.md.
pub fn capability_report(permissions: MacPermissions) -> Vec<CapabilityInfo> {
    let MacPermissions {
        accessibility: accessibility_enabled,
        screen_recording: screen_recording_enabled,
    } = permissions;
    let supported = [
        Capability::Enumerate,
        Capability::Capture,
        Capability::RetainedHandles,
        Capability::Invoke,
        Capability::ReadValue,
        Capability::SetValue,
        Capability::Focus,
        Capability::Scroll,
        Capability::PointerInput,
        Capability::KeyboardInput,
        Capability::Screenshot,
        Capability::HitTest,
        Capability::SerializeHistory,
        Capability::ObserveGlobalInput,
    ];
    Capability::ALL
        .into_iter()
        .map(|capability| {
            let usable = if capability == Capability::SerializeHistory {
                true
            } else if capability == Capability::Screenshot {
                screenshot_restriction(accessibility_enabled, screen_recording_enabled).is_none()
            } else {
                supported.contains(&capability) && accessibility_enabled
            };
            CapabilityInfo {
                capability,
                usable,
                restriction: (!usable).then(|| {
                    if capability == Capability::Screenshot {
                        screenshot_restriction(accessibility_enabled, screen_recording_enabled)
                            .expect("an unusable screenshot capability has a restriction")
                            .into()
                    } else if supported.contains(&capability) {
                        "Accessibility permission is not granted".into()
                    } else {
                        "not implemented by axon-mac".into()
                    }
                }),
            }
        })
        .collect()
}

fn screenshot_restriction(
    accessibility_enabled: bool,
    screen_recording_enabled: bool,
) -> Option<&'static str> {
    if !accessibility_enabled {
        Some("Accessibility permission is not granted")
    } else if !screen_recording_enabled {
        Some("Screen Recording permission is not granted")
    } else {
        None
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CGSize {
    width: f64,
    height: f64,
}

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXUIElementCreateApplication(pid: i32) -> AXUIElementRef;
    fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    fn AXUIElementCopyElementAtPosition(
        root: AXUIElementRef,
        x: f32,
        y: f32,
        element: *mut AXUIElementRef,
    ) -> i32;
    fn AXUIElementGetPid(element: AXUIElementRef, pid: *mut i32) -> i32;
    fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: *mut CFTypeRef,
    ) -> i32;
    fn AXUIElementGetAttributeValueCount(
        element: AXUIElementRef,
        attribute: CFStringRef,
        count: *mut isize,
    ) -> i32;
    fn AXUIElementCopyAttributeValues(
        element: AXUIElementRef,
        attribute: CFStringRef,
        range: CFRange,
        values: *mut CFArrayRef,
    ) -> i32;
    fn AXUIElementPerformAction(element: AXUIElementRef, action: CFStringRef) -> i32;
    fn AXUIElementSetAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: CFTypeRef,
    ) -> i32;
    fn AXValueGetValue(value: AXValueRef, value_type: i64, output: *mut c_void) -> bool;
}
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringCreateWithCString(
        alloc: *const c_void,
        text: *const c_char,
        encoding: u32,
    ) -> CFStringRef;
    fn CFGetTypeID(value: CFTypeRef) -> usize;
    fn CFBooleanGetTypeID() -> usize;
    fn CFBooleanGetValue(value: CFTypeRef) -> bool;
    fn CFArrayGetTypeID() -> usize;
    fn CFArrayGetCount(array: CFArrayRef) -> isize;
    fn CFArrayGetValueAtIndex(array: CFArrayRef, index: isize) -> *const c_void;
    fn CFRetain(value: CFTypeRef) -> CFTypeRef;
    fn CFRelease(value: CFTypeRef);
    fn CFEqual(left: CFTypeRef, right: CFTypeRef) -> bool;
}
unsafe extern "C" {
    fn proc_listallpids(buffer: *mut c_void, buffersize: i32) -> i32;
    fn proc_pidpath(pid: i32, buffer: *mut c_void, buffersize: u32) -> i32;
}

#[derive(Debug)]
struct Owned(CFTypeRef);
impl Clone for Owned {
    fn clone(&self) -> Self {
        Self(unsafe { CFRetain(self.0) })
    }
}
impl Drop for Owned {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) }
    }
}

fn cap(capability: Capability, reason: impl Into<String>) -> BackendError {
    BackendError::Capability {
        capability,
        reason: reason.into(),
        diagnostic: None,
    }
}
fn op(operation: &str, message: impl Into<String>) -> BackendError {
    BackendError::Operation {
        operation: operation.into(),
        message: message.into(),
        diagnostic: None,
    }
}
fn cfstr(value: &str) -> Result<Owned, BackendError> {
    let bytes = CString::new(value).map_err(|_| op("string", "value contains NUL"))?;
    let value = unsafe { CFStringCreateWithCString(null(), bytes.as_ptr(), UTF8) };
    (!value.is_null())
        .then(|| Owned(value))
        .ok_or_else(|| op("string", "CoreFoundation allocation failed"))
}
/// An attribute value and the raw `AXError` the read returned.
///
/// The status is what distinguishes "this element has no title" from "the Accessibility API is
/// disabled for this process", and enumeration needs that distinction to refuse honestly. Every
/// attribute read in this module goes through here so there stays exactly one FFI call site.
fn attribute_status(element: AXUIElementRef, name: &str) -> (Option<Owned>, i32) {
    let Ok(name) = cfstr(name) else {
        return (None, accessibility::AX_ERROR_CANNOT_COMPLETE);
    };
    let mut value = null();
    let status = unsafe { AXUIElementCopyAttributeValue(element, name.0, &mut value) };
    let value = (!value.is_null()).then(|| Owned(value));
    (value.filter(|_| status == 0), status)
}
fn attribute(element: AXUIElementRef, name: &str) -> Option<Owned> {
    attribute_status(element, name).0
}
fn text_attribute(element: AXUIElementRef, name: &str) -> Option<String> {
    attribute(element, name).and_then(|v| string_value(v.0))
}
fn bool_attribute(element: AXUIElementRef, name: &str) -> Option<bool> {
    attribute(element, name).and_then(|value| {
        (unsafe { CFGetTypeID(value.0) } == unsafe { CFBooleanGetTypeID() })
            .then(|| unsafe { CFBooleanGetValue(value.0) })
    })
}
fn frame(element: AXUIElementRef) -> Option<Rect> {
    let position = attribute(element, "AXPosition")?;
    let size = attribute(element, "AXSize")?;
    let mut p = CGPoint::default();
    let mut s = CGSize::default();
    if !unsafe {
        AXValueGetValue(
            position.0,
            AX_VALUE_CGPOINT,
            (&mut p as *mut CGPoint).cast(),
        )
    } || !unsafe { AXValueGetValue(size.0, AX_VALUE_CGSIZE, (&mut s as *mut CGSize).cast()) }
    {
        return None;
    }
    Some(Rect {
        x: p.x,
        y: p.y,
        width: s.width,
        height: s.height,
    })
}
/// The deepest element at a screen point, by the system-wide hit test.
fn element_at(point: (f64, f64)) -> Option<Owned> {
    let system = Owned(unsafe { AXUIElementCreateSystemWide() });
    if system.0.is_null() {
        return None;
    }
    let mut element = null();
    let status = unsafe {
        AXUIElementCopyElementAtPosition(system.0, point.0 as f32, point.1 as f32, &mut element)
    };
    (status == 0 && !element.is_null()).then(|| Owned(element))
}

fn element_pid(element: AXUIElementRef) -> Option<i32> {
    let mut pid = 0;
    (unsafe { AXUIElementGetPid(element, &mut pid) } == 0).then_some(pid)
}

fn contains(frame: Rect, point: (f64, f64)) -> bool {
    point.0 >= frame.x
        && point.0 <= frame.x + frame.width
        && point.1 >= frame.y
        && point.1 <= frame.y + frame.height
}

/// The process holding the foreground.
///
/// Read from the Accessibility system-wide element, which asks the window server now.
/// `NSWorkspace.frontmostApplication` is only the fallback: it is refreshed by notifications on a
/// main run loop this daemon never spins, so it can report an application that has since lost the
/// foreground, which would make every activation look unproved.
fn frontmost_process() -> Option<i32> {
    let system = Owned(unsafe { AXUIElementCreateSystemWide() });
    if !system.0.is_null()
        && let Some(pid) =
            attribute(system.0, "AXFocusedApplication").and_then(|app| element_pid(app.0))
    {
        return Some(pid);
    }
    workspace::workspace_frontmost_process()
}

/// The identity a running process is compared and activated by: its bundle identifier, or
/// `pid:<n>` when it has none.
fn identity_for(pid: i32) -> String {
    workspace::identity_of(pid, workspace::running_application_identity(pid).1)
}

/// The single live process an identity names.
fn process_for_identity(identity: &str) -> Option<i32> {
    if let Some(pid) = identity.strip_prefix("pid:") {
        return pid.parse().ok().filter(|pid| workspace::is_running(*pid));
    }
    match workspace::processes_with_bundle(identity).as_slice() {
        [pid] => Some(*pid),
        _ => None,
    }
}

fn inferred_actions(role: &str) -> Vec<String> {
    match role {
        "AXButton" | "AXLink" | "AXCheckBox" | "AXRadioButton" | "AXMenuItem" | "AXMenuBarItem" => {
            vec!["AXPress".into()]
        }
        _ => Vec::new(),
    }
}
fn editable(role: &str) -> bool {
    matches!(role, "AXComboBox" | "AXTextArea" | "AXTextField")
}

struct Captured {
    node: Node,
    elements: Vec<Owned>,
}
fn capture_node(element: Owned, depth: usize, max_depth: usize, count: &mut usize) -> Captured {
    *count += 1;
    let role = text_attribute(element.0, "AXRole").unwrap_or_else(|| "AXUnknown".into());
    let child_count = child_count(element.0);
    let mut children = Vec::new();
    let mut elements = vec![element.clone()];
    let mut truncation_reason = None;
    if depth >= max_depth && child_count.unwrap_or(0) > 0 {
        truncation_reason = Some("depth limit reached".into());
    } else if let Some(array) = child_count.and_then(|total| child_range(element.0, 0, total)) {
        for index in 0..unsafe { CFArrayGetCount(array.0) } {
            if *count >= MAX_NODES {
                truncation_reason = Some("node limit reached".into());
                break;
            }
            let child = unsafe { CFArrayGetValueAtIndex(array.0, index) };
            if child.is_null() {
                continue;
            }
            // CFArray does not transfer ownership. Each child must survive the array release.
            let captured = capture_node(
                Owned(unsafe { CFRetain(child) }),
                depth + 1,
                max_depth,
                count,
            );
            children.push(captured.node);
            elements.extend(captured.elements);
        }
    }
    Captured {
        node: Node {
            role: role.clone(),
            subrole: text_attribute(element.0, "AXSubrole"),
            name: None,
            title: text_attribute(element.0, "AXTitle"),
            label: text_attribute(element.0, "AXDescription"),
            value: text_attribute(element.0, "AXValue"),
            description: text_attribute(element.0, "AXHelp"),
            identifier: text_attribute(element.0, "AXIdentifier"),
            actions: inferred_actions(&role),
            frame: frame(element.0),
            editable: editable(&role),
            focused: bool_attribute(element.0, "AXFocused"),
            enabled: bool_attribute(element.0, "AXEnabled"),
            children,
            child_count,
            truncation_reason,
        },
        elements,
    }
}

/// One running application as this backend identifies it.
///
/// These are the same three fields the recorder stamps onto every observed event as a
/// `RecordedAppIdentity`, drawn from the same source, so a recorded artifact calls an application
/// what `look` calls it.
#[derive(Clone, Debug)]
struct RunningApplication {
    process_id: i32,
    name: String,
    bundle_identifier: Option<String>,
}

impl RunningApplication {
    /// Whether this application satisfies every field the query constrains.
    ///
    /// `identifier` is the bundle identifier — what a caller, the Swift daemon, and the Windows and
    /// Linux backends all mean by an application identifier, and what this backend publishes in
    /// `Application::identifier`. An application without one cannot satisfy a query that names one.
    ///
    /// `name` is the single caller-facing `app` field, so it accepts either spelling: the display
    /// name, or the bundle identifier. The recorder writes the bundle identifier into `app` because
    /// it is the durable key, and the Swift daemon's `AppResolver` resolves it the same way.
    fn matches(&self, query: &AppQuery) -> bool {
        query
            .process_id
            .is_none_or(|wanted| wanted == self.process_id as u32)
            && query
                .identifier
                .as_deref()
                .is_none_or(|wanted| self.bundle_identifier.as_deref() == Some(wanted))
            && query.name.as_deref().is_none_or(|wanted| {
                self.name.eq_ignore_ascii_case(wanted)
                    || self
                        .bundle_identifier
                        .as_deref()
                        .is_some_and(|bundle| bundle.eq_ignore_ascii_case(wanted))
            })
    }
}

/// The refusal for a request whose Accessibility calls came back disabled.
///
/// Reuses the observer path's `accessibility-denied` code rather than inventing a third token. The
/// diagnostic reports what the call observed, not what it infers about the user's timeline: the
/// process reached an AX call at all, so its own trust check had already passed.
fn accessibility_revoked(capability: Capability) -> BackendError {
    BackendError::CapabilityReason {
        capability,
        code: "accessibility-denied",
        reason: "Accessibility permission is not granted".into(),
        diagnostic: Some(
            "the Accessibility API answered kAXErrorAPIDisabled (-25211) after this process's \
             trust check passed; the grant was withdrawn after that check"
                .into(),
        ),
    }
}

/// The single application a query names, or why it named none or more than one.
///
/// Split from the live enumeration so the matching rule can be exercised against a synthetic list;
/// the native pid walk it is normally fed cannot be staged in a test. `access` is the verdict that
/// walk folded: an empty list under `Denied` is a withdrawn grant, not a missing application, and
/// saying so is the difference between a typed refusal and a misleading `application not found`.
fn resolve_running(
    applications: Vec<RunningApplication>,
    query: &AppQuery,
    access: AxAccess,
) -> Result<RunningApplication, BackendError> {
    let enumerated_nothing = applications.is_empty();
    let mut matches = applications
        .into_iter()
        .filter(|application| application.matches(query));
    match (matches.next(), matches.next()) {
        (Some(one), None) => Ok(one),
        (None, _) if enumerated_nothing && access == AxAccess::Denied => {
            Err(accessibility_revoked(Capability::Capture))
        }
        (None, _) => Err(op("capture", "application not found")),
        (Some(_), Some(_)) => Err(op("capture", "application query is ambiguous")),
    }
}

/// The query naming the application a recorded input event was observed in.
///
/// One key, not three, following the precedence `RecordedAppIdentity::matches_runtime` already
/// defines: the process id, else the bundle identifier, else the name. A recorded identity is only
/// as strong as its strongest key, so constraining the weaker fields alongside it cannot make the
/// match more certain — it can only strand the evidence for an event that was genuinely observed
/// the moment any one of them drifts. A deserialized artifact reaches the bundle rung on its own,
/// because `process_id` is deliberately skipped by serde and never survives a session.
fn recorded_app_query(app: &axon_core::RecordedAppIdentity) -> AppQuery {
    match (app.process_id, &app.bundle_identifier) {
        (Some(process_id), _) => AppQuery {
            process_id: Some(process_id),
            name: None,
            identifier: None,
        },
        (None, Some(identifier)) => AppQuery {
            process_id: None,
            name: None,
            identifier: Some(identifier.clone()),
        },
        (None, None) => AppQuery {
            process_id: None,
            name: Some(app.name.clone()),
            identifier: None,
        },
    }
}

pub struct MacBackend {
    handles: HashMap<SnapshotHandle, Owned>,
    global_input: MacGlobalInputObserver,
    /// What each activation call since the last take did, by primitive and return value.
    activation_evidence: Vec<String>,
    /// When this backend last brought an application forward. A pointer post waits out
    /// [`POINTER_SETTLE_AFTER_ACTIVATION`] from here.
    last_activation: Option<std::time::Instant>,
}

/// How long a pointer post waits after an activation before it lands: the acceptance campaign's
/// foreground-control wait, which acted on every target it measured.
///
/// Being frontmost is not the same as having a key window, and AppKit's first-mouse rule makes a
/// click on a window that is not yet key a key-making click rather than a delivered one for views
/// such as `NSTextView`. A fixed wait stands in for the observable that would end it early; AX
/// publishes no key-window attribute, and `AXMain` persists while an application is inactive, so
/// it cannot tell the two states apart.

const POINTER_SETTLE_AFTER_ACTIVATION: Duration = Duration::from_millis(600);
impl MacBackend {
    pub fn new() -> Result<Self, BackendError> {
        Ok(Self {
            handles: HashMap::new(),
            global_input: MacGlobalInputObserver::default(),
            activation_evidence: Vec::new(),
            last_activation: None,
        })
    }
    /// Holds a pointer post until the most recent activation has had time to make its window key.
    fn settle_after_activation(&self) {
        if let Some(remaining) = self
            .last_activation
            .and_then(|at| POINTER_SETTLE_AFTER_ACTIVATION.checked_sub(at.elapsed()))
        {
            std::thread::sleep(remaining);
        }
    }
    pub fn accessibility_enabled(&self) -> bool {
        accessibility::granted()
    }
    /// Every running application this process can see, and what the Accessibility API said while
    /// it looked.
    ///
    /// Under a withdrawn grant every `AXTitle` read answers `kAXErrorAPIDisabled`, so every process
    /// is filtered out and the list comes back empty. Folding the statuses is what lets the callers
    /// tell that emptiness apart from a machine with no applications running.
    fn applications(&self) -> (Vec<RunningApplication>, AxAccess) {
        let needed = unsafe { proc_listallpids(std::ptr::null_mut(), 0) };
        if needed <= 0 {
            return (Vec::new(), AxAccess::Unknown);
        }
        let mut pids = vec![0i32; needed as usize];
        let returned = unsafe {
            proc_listallpids(
                pids.as_mut_ptr().cast(),
                (pids.len() * std::mem::size_of::<i32>()) as i32,
            )
        };
        pids.truncate(returned.max(0) as usize);
        let mut found = Vec::new();
        let mut access = AxAccess::Unknown;
        for pid in pids {
            let mut path = vec![0u8; 4096];
            let length = unsafe { proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
            if length <= 0 {
                continue;
            }
            let path = String::from_utf8_lossy(&path[..length as usize]);
            if !path.contains(".app/Contents/MacOS/") || path.contains(".xpc/Contents/MacOS/") {
                continue;
            }
            let root = unsafe { AXUIElementCreateApplication(pid) };
            if root.is_null() {
                continue;
            }
            let root = Owned(root);
            // A non-empty AXTitle is what qualifies a process as an application here. It is not
            // what the application is then called: AXTitle names windows and elements, while an
            // application is named the way the Swift daemon's AppResolver names one.
            let (title, status) = attribute_status(root.0, "AXTitle");
            access = access.fold(accessibility::classify(status));
            let Some(accessibility_name) = title
                .and_then(|value| string_value(value.0))
                .filter(|name| !name.is_empty())
            else {
                continue;
            };
            let (name, bundle_identifier) =
                workspace::application_identity(pid, accessibility_name);
            found.push(RunningApplication {
                process_id: pid,
                name,
                bundle_identifier,
            });
        }
        (found, access)
    }
    fn resolve(&self, app: &AppQuery) -> Result<RunningApplication, BackendError> {
        let (applications, access) = self.applications();
        resolve_running(applications, app, access)
    }
    /// The one application a query names, or `None` when it named none or more than one. A
    /// withdrawn grant is still an error: it is not the same answer as "no such application".
    fn resolve_process(&self, app: &AppQuery) -> Result<Option<RunningApplication>, BackendError> {
        match self.resolve(app) {
            Ok(application) => Ok(Some(application)),
            Err(BackendError::Operation { .. }) => Ok(None),
            Err(error) => Err(error),
        }
    }
    fn element(&self, handle: &SnapshotHandle) -> Result<AXUIElementRef, BackendError> {
        self.handles
            .get(handle)
            .map(|v| v.0)
            .ok_or_else(|| op("resolve", "snapshot handle is stale or unknown"))
    }
    fn set_attribute(
        &self,
        handle: &SnapshotHandle,
        attribute_name: &str,
        value: CFTypeRef,
        operation: &str,
    ) -> Result<(), BackendError> {
        let name = cfstr(attribute_name)?;
        let status = unsafe { AXUIElementSetAttributeValue(self.element(handle)?, name.0, value) };
        (status == 0)
            .then_some(())
            .ok_or_else(|| op(operation, format!("AXError {status}")))
    }
}

impl axon_core::GlobalInputObserver for MacBackend {
    fn start(&mut self, scope: &axon_core::RecordingScope) -> Result<(), BackendError> {
        axon_core::GlobalInputObserver::start(&mut self.global_input, scope)
    }

    fn poll(
        &mut self,
        timeout: Duration,
    ) -> Result<Vec<axon_core::RecordedInputEvent>, BackendError> {
        axon_core::GlobalInputObserver::poll(&mut self.global_input, timeout)
    }

    fn stop(&mut self) -> Result<(), BackendError> {
        axon_core::GlobalInputObserver::stop(&mut self.global_input)
    }

    fn is_recording(&self) -> bool {
        axon_core::GlobalInputObserver::is_recording(&self.global_input)
    }
}

impl RecordingEvidenceProvider for MacBackend {
    fn read_focused(&mut self) -> Result<Option<RecordedFocusedEvidence>, BackendError> {
        Ok(
            crate::global_input::focused_evidence().map(|(app, element)| {
                let value = element.value.clone();
                RecordedFocusedEvidence {
                    target: RecordedTargetEvidence {
                        app,
                        point: RecordedPoint::default(),
                        candidates: vec![element],
                    },
                    value,
                }
            }),
        )
    }

    fn capture_snapshot(
        &mut self,
        app: &axon_core::RecordedAppIdentity,
    ) -> Result<Option<Snapshot>, BackendError> {
        PlatformBackend::capture(self, &recorded_app_query(app)).map(Some)
    }

    fn settle(
        &mut self,
        _group_index: usize,
        _tool: &str,
    ) -> Result<RecordedSettleEvidence, BackendError> {
        Ok(RecordedSettleEvidence::default())
    }
}

impl PlatformBackend for MacBackend {
    fn global_input_observer(
        &mut self,
    ) -> Result<&mut dyn axon_core::GlobalInputObserver, BackendError> {
        if !self.global_input.available() {
            return Err(BackendError::CapabilityReason {
                capability: Capability::ObserveGlobalInput,
                code: "accessibility-denied",
                reason: "Accessibility permission is not granted".into(),
                diagnostic: None,
            });
        }
        Ok(&mut self.global_input)
    }

    fn capabilities(&self) -> Result<Vec<CapabilityInfo>, BackendError> {
        Ok(capability_report(MacPermissions::read()))
    }
    /// Every half of the transaction is here: the foreground is read from the window server,
    /// activation is requested and then read back, and the pointer is read and warped home. Posting
    /// to the HID tap needs the same Accessibility grant the reads do.
    fn supports_foreground_transaction(&self) -> bool {
        self.accessibility_enabled()
    }
    fn frontmost_application(&mut self) -> Result<Option<String>, BackendError> {
        Ok(frontmost_process().map(identity_for))
    }
    fn activate_application(&mut self, identity: &str) -> Result<bool, BackendError> {
        let Some(pid) = process_for_identity(identity) else {
            self.activation_evidence
                .push(format!("{identity}: no single running process to activate"));
            return Ok(false);
        };
        self.last_activation = Some(std::time::Instant::now());
        let (primitive, accepted) =
            workspace::activate(pid).unwrap_or(("NSRunningApplication lookup", false));
        self.activation_evidence
            .push(format!("{identity}: {primitive} returned {accepted}"));
        // Cooperative activation can acknowledge a request from a background process and leave the
        // foreground where it was. Asking the application itself through AXFrontmost is the
        // fallback, tried only when the first request has visibly not taken effect.
        let deadline = std::time::Instant::now() + Duration::from_millis(200);
        while std::time::Instant::now() < deadline {
            if frontmost_process() == Some(pid) {
                return Ok(accepted);
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        unsafe extern "C" {
            static kCFBooleanTrue: CFTypeRef;
        }
        let root = Owned(unsafe { AXUIElementCreateApplication(pid) });
        let status = match cfstr("AXFrontmost") {
            Ok(name) if !root.0.is_null() => unsafe {
                AXUIElementSetAttributeValue(root.0, name.0, kCFBooleanTrue)
            },
            _ => accessibility::AX_ERROR_CANNOT_COMPLETE,
        };
        self.activation_evidence
            .push(format!("{identity}: AXFrontmost returned AXError {status}"));
        Ok(accepted || status == 0)
    }
    fn resolve_application(&mut self, app: &AppQuery) -> Result<Option<String>, BackendError> {
        Ok(self
            .application_process(app)?
            .map(|process| process.identity))
    }
    fn application_process_identifier(&mut self, identity: &str) -> Option<i64> {
        process_for_identity(identity).map(i64::from)
    }
    fn pointer_location(&mut self) -> Result<Option<(f64, f64)>, BackendError> {
        input::native::pointer_location()
            .map(Some)
            .ok_or_else(|| op("pointerLocation", "CGEventCreate returned null"))
    }
    fn move_pointer(&mut self, to: (f64, f64)) -> Result<bool, BackendError> {
        Ok(input::native::warp(to))
    }
    fn enumerate_applications(&self) -> Result<Vec<Application>, BackendError> {
        let (applications, access) = self.applications();
        if applications.is_empty() && access == AxAccess::Denied {
            return Err(accessibility_revoked(Capability::Enumerate));
        }
        Ok(applications
            .into_iter()
            .map(|application| Application {
                process_id: Some(application.process_id as u32),
                name: application.name,
                identifier: application.bundle_identifier,
                windows: Vec::new(),
            })
            .collect())
    }
    fn capture(&mut self, app: &AppQuery) -> Result<Snapshot, BackendError> {
        self.capture_bounded(app, CaptureBounds::default())
    }
    fn capture_bounded(
        &mut self,
        app: &AppQuery,
        bounds: CaptureBounds,
    ) -> Result<Snapshot, BackendError> {
        if !self.accessibility_enabled() {
            return Err(cap(
                Capability::Capture,
                "Accessibility permission is not granted",
            ));
        }
        let application = self.resolve(app)?;
        let root = unsafe { AXUIElementCreateApplication(application.process_id) };
        if root.is_null() {
            return Err(op("capture", "AXUIElementCreateApplication returned null"));
        }
        let root = Owned(root);
        let windows = attribute(root.0, "AXWindows")
            .ok_or_else(|| op("capture", "application exposes no AXWindows"))?;
        if unsafe { CFGetTypeID(windows.0) } != unsafe { CFArrayGetTypeID() } {
            return Err(op("capture", "AXWindows was not an array"));
        }
        let mut snapshot_windows = Vec::new();
        let mut all_elements = Vec::new();
        let mut count = 0;
        for index in 0..unsafe { CFArrayGetCount(windows.0) } {
            let element = unsafe { CFArrayGetValueAtIndex(windows.0, index) };
            if element.is_null() {
                continue;
            }
            let captured = capture_node(
                Owned(unsafe { CFRetain(element) }),
                0,
                bounds.child_depth.unwrap_or(MAX_DEPTH).min(MAX_DEPTH),
                &mut count,
            );
            snapshot_windows.push(Window {
                title: captured.node.title.clone(),
                root: captured.node,
            });
            all_elements.extend(captured.elements);
        }
        let snapshot = Snapshot::new(Application {
            process_id: Some(application.process_id as u32),
            name: application.name,
            identifier: application.bundle_identifier,
            windows: snapshot_windows,
        });
        self.handles = all_elements
            .into_iter()
            .enumerate()
            .map(|(i, element)| (snapshot.handle(i), element))
            .collect();
        Ok(snapshot)
    }
    fn capture_child_page(
        &mut self,
        target: &SnapshotHandle,
        request: ChildPageRequest,
    ) -> Result<ChildPageCapture, BackendError> {
        let element = Owned(unsafe { CFRetain(self.element(target)?) });
        let total = child_count(element.0)
            .ok_or_else(|| op("captureChildPage", "AXChildren count is unavailable"))?;
        let (offset, limit) = requested_range(total, request.offset, request.limit);
        let mut parent = capture_node(element.clone(), 0, 0, &mut 0).node;
        // Paging describes the intentionally omitted direct children; it is not native truncation.
        parent.truncation_reason = None;

        let mut children = Vec::new();
        let mut all_elements = vec![element];
        let mut count = 1;
        if let Some(array) = child_range(all_elements[0].0, offset, limit) {
            for index in 0..unsafe { CFArrayGetCount(array.0) } {
                if count >= MAX_NODES {
                    parent.truncation_reason = Some("node limit reached".into());
                    break;
                }
                let child = unsafe { CFArrayGetValueAtIndex(array.0, index) };
                if child.is_null() {
                    continue;
                }
                let max_depth = if request.include_descendants {
                    MAX_DEPTH
                } else {
                    0
                };
                let captured =
                    capture_node(Owned(unsafe { CFRetain(child) }), 0, max_depth, &mut count);
                children.push(captured.node);
                all_elements.extend(captured.elements);
            }
        }
        let snapshot = axon_core::SnapshotId::fresh();
        self.handles = all_elements
            .into_iter()
            .enumerate()
            .map(|(index, element)| (SnapshotHandle(format!("{}:{index}", snapshot.0)), element))
            .collect();
        Ok(ChildPageCapture {
            snapshot,
            parent,
            offset,
            limit,
            total: Some(total),
            children,
        })
    }
    fn invoke(&mut self, target: &SnapshotHandle, action: &str) -> Result<(), BackendError> {
        let action = cfstr(action)?;
        let status = unsafe { AXUIElementPerformAction(self.element(target)?, action.0) };
        (status == 0)
            .then_some(())
            .ok_or_else(|| op("invoke", format!("AXError {status}")))
    }
    fn read_value(&self, target: &SnapshotHandle) -> Result<Option<String>, BackendError> {
        Ok(text_attribute(self.element(target)?, "AXValue"))
    }
    fn set_value(&mut self, target: &SnapshotHandle, value: &str) -> Result<(), BackendError> {
        let value = cfstr(value)?;
        self.set_attribute(target, "AXValue", value.0, "setValue")
    }
    fn focus(&mut self, target: &SnapshotHandle) -> Result<(), BackendError> {
        unsafe extern "C" {
            static kCFBooleanTrue: CFTypeRef;
        }
        self.set_attribute(target, "AXFocused", unsafe { kCFBooleanTrue }, "focus")
    }
    fn scroll(&mut self, target: &SnapshotHandle, _: (f64, f64)) -> Result<(), BackendError> {
        self.invoke(target, "AXScrollToVisible")
    }
    /// Global keyboard input through the HID tap. Only ever called inside a proved foreground
    /// transaction, so the keystrokes reach the application that was just brought forward.
    fn keyboard(&mut self, _: &AppQuery, intent: KeyboardIntent<'_>) -> Result<(), BackendError> {
        post_keyboard(Destination::HidTap, intent)
    }
    fn observe(&mut self, _: &AppQuery, _: Duration) -> Result<Observation, BackendError> {
        Err(cap(Capability::ObserveChanges, "excluded from v1"))
    }
    fn wait_for_value(
        &mut self,
        _: &SnapshotHandle,
        _: &serde_json::Value,
        _: Duration,
    ) -> Result<Observation, BackendError> {
        Err(cap(Capability::ObserveChanges, "excluded from v1"))
    }
    fn pointer_click(&mut self, point: (f64, f64)) -> Result<(), BackendError> {
        self.settle_after_activation();
        input::native::click(point)
    }
    fn pointer_drag(
        &mut self,
        _: (f64, f64),
        _: (f64, f64),
        _: Duration,
    ) -> Result<(), BackendError> {
        Err(cap(Capability::PointerInput, "drag excluded from v1"))
    }
    fn screenshot(&mut self, app: &AppQuery) -> Result<Screenshot, BackendError> {
        if !window_capture::screen_capture_enabled() {
            return Err(cap(
                Capability::Screenshot,
                "Screen Recording permission is not granted",
            ));
        }
        let pid = self.resolve(app)?.process_id;
        window_capture::capture(pid)?.screenshot()
    }
    fn hit_test(&mut self, point: (f64, f64)) -> Result<Option<Node>, BackendError> {
        Ok(element_at(point).map(|element| capture_node(element, 0, 0, &mut 0).node))
    }
}

fn post_keyboard(destination: Destination, intent: KeyboardIntent<'_>) -> Result<(), BackendError> {
    match intent {
        KeyboardIntent::Text(text) => input::native::post_text(destination, text),
        KeyboardIntent::Key(spec) => input::native::post_stroke(
            destination,
            input::stroke(spec).map_err(|error| cap(Capability::KeyboardInput, error))?,
        ),
    }
}

impl NativeInput for MacBackend {
    fn point_owner(&mut self, point: (f64, f64)) -> Result<Option<i32>, BackendError> {
        Ok(element_at(point).and_then(|element| element_pid(element.0)))
    }
    fn focused_window_frame(&mut self, app: &AppQuery) -> Result<Option<Rect>, BackendError> {
        let Some(application) = self.resolve_process(app)? else {
            return Ok(None);
        };
        let root = Owned(unsafe { AXUIElementCreateApplication(application.process_id) });
        if root.0.is_null() {
            return Ok(None);
        }
        Ok(["AXFocusedWindow", "AXMainWindow"]
            .into_iter()
            .find_map(|name| attribute(root.0, name).and_then(|window| frame(window.0))))
    }
    fn scroll_wheel(
        &mut self,
        point: (f64, f64),
        delta: (f64, f64),
    ) -> Result<Vec<(i32, i32)>, BackendError> {
        self.settle_after_activation();
        input::native::scroll(point, &input::wheel_steps(delta.0, delta.1))
    }
    fn modifier_state(&mut self) -> Option<crate::ModifierState> {
        let (combined_session, hid_system) = input::native::modifier_flags();
        Some(crate::ModifierState {
            combined_session,
            hid_system,
        })
    }
    fn take_activation_evidence(&mut self) -> Option<String> {
        (!self.activation_evidence.is_empty())
            .then(|| std::mem::take(&mut self.activation_evidence).join("; "))
    }
}

impl BackgroundApplicationKeyboard for MacBackend {
    fn application_process(
        &mut self,
        app: &AppQuery,
    ) -> Result<Option<ApplicationProcess>, BackendError> {
        Ok(self
            .resolve_process(app)?
            .map(|application| ApplicationProcess {
                process_identifier: application.process_id,
                identity: workspace::identity_of(
                    application.process_id,
                    application.bundle_identifier,
                ),
            }))
    }
    fn dispatch_application_keyboard(
        &mut self,
        process: &ApplicationProcess,
        intent: KeyboardIntent<'_>,
    ) -> Result<ApplicationDispatch, BackgroundDispatchError> {
        let pid = process.process_identifier;
        // A pid that exited can be reused by an unrelated process, and posting to it would type
        // into something nobody named. Checked immediately before the post, so nothing is sent.
        if !workspace::is_running(pid) || identity_for(pid) != process.identity {
            return Err(BackgroundDispatchError::Stale(format!(
                "{} is no longer running as process {pid}, so nothing was posted",
                process.identity
            )));
        }
        let frontmost_before = frontmost_process();
        let pointer_before = input::native::pointer_location();
        post_keyboard(Destination::Process(pid), intent)
            .map_err(BackgroundDispatchError::Backend)?;
        // A key handler that activates its application does so in response to the event; a short
        // settle lets that happen inside the window the two readings straddle.
        std::thread::sleep(Duration::from_millis(50));
        let pointer_after = input::native::pointer_location();
        Ok(ApplicationDispatch {
            frontmost_unchanged: frontmost_process() == frontmost_before,
            pointer_unchanged: match (pointer_before, pointer_after) {
                (Some(before), Some(after)) => {
                    (before.0 - after.0).abs() < 0.5 && (before.1 - after.1).abs() < 0.5
                }
                _ => false,
            },
        })
    }
}
impl VisualObservationProvider for MacBackend {
    fn observe_visuals(
        &mut self,
        app: &AppQuery,
        screenshot: bool,
        screen_text: bool,
    ) -> Result<VisualObservation, BackendError> {
        let pid = self.resolve(app)?.process_id;
        let captured = window_capture::capture(pid)?;
        Ok(VisualObservation {
            screenshot: screenshot.then(|| captured.screenshot()).transpose()?,
            recognized_text: screen_text.then(|| captured.recognize_text()).transpose()?,
        })
    }
}
impl axon_core::TextRecognitionProvider for MacBackend {
    fn recognize_text(
        &mut self,
        app: &AppQuery,
    ) -> Result<Vec<axon_core::RecognizedText>, BackendError> {
        let pid = self.resolve(app)?.process_id;
        window_capture::capture(pid)?.recognize_text()
    }
}
/// How far up the Accessibility hierarchy a hit is walked looking for the target. Deeper than any
/// real application nests, and a bound on a parent chain that a misbehaving one could make cyclic.
const MAX_ANCESTRY: usize = 64;

impl PointerTargetVerifier for MacBackend {
    /// Whether a pointer posted at `point` lands on the resolved element: the hit is the element or
    /// one of its descendants, or, for an element that does not hit-test as itself, the hit is in
    /// the same process and the point is inside the element's frame.
    fn verify_pointer_target(
        &mut self,
        handle: &SnapshotHandle,
        point: (f64, f64),
    ) -> Result<bool, BackendError> {
        let target = self.element(handle)?;
        let Some(hit) = element_at(point) else {
            return Ok(false);
        };
        let mut current = Some(hit.clone());
        for _ in 0..MAX_ANCESTRY {
            let Some(element) = current else { break };
            if unsafe { CFEqual(element.0, target) } {
                return Ok(true);
            }
            current = attribute(element.0, "AXParent");
        }
        Ok(element_pid(hit.0).is_some()
            && element_pid(hit.0) == element_pid(target)
            && frame(target).is_some_and(|frame| contains(frame, point)))
    }

    /// Recognized text has no element behind it, so the most the hit test can prove is that the
    /// point is over a window of the application the text was read from.
    fn verify_ocr_target(
        &mut self,
        app: &AppQuery,
        point: (f64, f64),
        _frame: Rect,
    ) -> Result<bool, BackendError> {
        let Some(application) = self.resolve_process(app)? else {
            return Ok(false);
        };
        Ok(self.point_owner(point)? == Some(application.process_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mirrors_swift_role_tables() {
        assert!(editable("AXTextField"));
        assert_eq!(inferred_actions("AXCheckBox"), vec!["AXPress"]);
        assert!(inferred_actions("AXGroup").is_empty());
    }
    #[test]
    fn all_capabilities_are_reported() {
        let backend = MacBackend::new().unwrap();
        assert_eq!(backend.capabilities().unwrap().len(), Capability::ALL.len());
    }

    /// Native input is usable exactly when Accessibility is, because posting to the HID tap, posting
    /// to a process, and hit testing all need that grant. What stays unimplemented says so rather
    /// than claiming a version it was excluded from.
    #[test]
    fn native_input_follows_the_accessibility_grant() {
        for accessibility in [true, false] {
            let report = capability_report(MacPermissions {
                accessibility,
                screen_recording: true,
            });
            for capability in [
                Capability::PointerInput,
                Capability::KeyboardInput,
                Capability::HitTest,
            ] {
                let info = report
                    .iter()
                    .find(|info| info.capability == capability)
                    .unwrap();
                assert_eq!(info.usable, accessibility, "{capability:?}");
                if !accessibility {
                    assert_eq!(
                        info.restriction.as_deref(),
                        Some("Accessibility permission is not granted")
                    );
                }
            }
            let observe = report
                .iter()
                .find(|info| info.capability == Capability::ObserveChanges)
                .unwrap();
            assert!(!observe.usable);
            if accessibility {
                assert_eq!(
                    observe.restriction.as_deref(),
                    Some("not implemented by axon-mac")
                );
            }
        }
    }

    /// A recorded point fallback writes the bundle identifier into `app` (axn/208), and the single
    /// `app` field resolves either spelling.
    #[test]
    fn an_app_string_resolves_by_display_name_or_bundle_identifier() {
        let listed = || {
            vec![
                running(4242, "TextEdit", Some("com.apple.TextEdit")),
                running(5150, "Notes", Some("com.apple.Notes")),
            ]
        };
        for spelling in ["TextEdit", "textedit", "com.apple.TextEdit"] {
            assert_eq!(
                resolve_listed(listed(), &query(None, Some(spelling), None))
                    .unwrap()
                    .process_id,
                4242,
                "{spelling}"
            );
        }
    }
    /// The matching rule under an Accessibility API that answered normally, which is what the
    /// resolution tests below are about. Only the withdrawn-access tests pass another verdict.
    fn resolve_listed(
        applications: Vec<RunningApplication>,
        query: &AppQuery,
    ) -> Result<RunningApplication, BackendError> {
        resolve_running(applications, query, AxAccess::Granted)
    }

    fn running(process_id: i32, name: &str, bundle: Option<&str>) -> RunningApplication {
        RunningApplication {
            process_id,
            name: name.into(),
            bundle_identifier: bundle.map(str::to_owned),
        }
    }

    fn query(process_id: Option<u32>, name: Option<&str>, identifier: Option<&str>) -> AppQuery {
        AppQuery {
            process_id,
            name: name.map(str::to_owned),
            identifier: identifier.map(str::to_owned),
        }
    }

    /// The recorder stamps every observed event with a name, a bundle identifier, and a pid, and
    /// `capture_snapshot` turns all three into the query that gathers that event's evidence. When
    /// the resolver read `identifier` as a process id rendered as a string, that query matched
    /// nothing, so every macOS recording stopped with zero actions.
    #[test]
    fn a_recorded_app_identity_resolves_to_the_application_it_was_observed_in() {
        let observed = axon_core::RecordedAppIdentity {
            name: "TextEdit".into(),
            bundle_identifier: Some("com.apple.TextEdit".into()),
            process_id: Some(4242),
        };
        let resolved = resolve_listed(
            vec![
                running(4242, "TextEdit", Some("com.apple.TextEdit")),
                running(5150, "Notes", Some("com.apple.Notes")),
            ],
            &recorded_app_query(&observed),
        )
        .expect("a recorded identity resolves to the application it was recorded from");
        assert_eq!(resolved.process_id, 4242);
        assert_eq!(
            resolved.bundle_identifier.as_deref(),
            Some("com.apple.TextEdit")
        );
    }

    /// A recorded identity holds one key as strongly as it can. A display label that disagrees
    /// between the recorder and the enumeration must not be able to strand the evidence for an
    /// event that was genuinely observed — the failure that constraining all three fields caused.
    #[test]
    fn a_recorded_capture_resolves_on_its_strongest_key_despite_a_disagreeing_name() {
        let observed = |process_id, bundle: Option<&str>| axon_core::RecordedAppIdentity {
            name: "Wi-Fi".into(),
            bundle_identifier: bundle.map(str::to_owned),
            process_id,
        };
        let listed = || vec![running(4242, "WiFiAgent", Some("com.apple.wifi.WiFiAgent"))];

        let by_pid = recorded_app_query(&observed(Some(4242), Some("com.apple.wifi.WiFiAgent")));
        assert_eq!(
            (by_pid.name.as_deref(), by_pid.identifier.as_deref()),
            (None, None)
        );
        assert_eq!(resolve_listed(listed(), &by_pid).unwrap().process_id, 4242);

        // A deserialized artifact carries no pid, so the bundle identifier is the strongest key.
        let by_bundle = recorded_app_query(&observed(None, Some("com.apple.wifi.WiFiAgent")));
        assert_eq!(by_bundle.name, None);
        assert_eq!(
            resolve_listed(listed(), &by_bundle).unwrap().process_id,
            4242
        );

        // With neither, the name is all that is left to try.
        let by_name = recorded_app_query(&observed(None, None));
        assert_eq!(by_name.name.as_deref(), Some("Wi-Fi"));
        assert_eq!(by_name.identifier, None);
    }

    #[test]
    fn identifier_matches_the_bundle_identifier_rather_than_the_process_id() {
        let applications = || vec![running(4242, "TextEdit", Some("com.apple.TextEdit"))];
        assert!(
            resolve_listed(
                applications(),
                &query(None, None, Some("com.apple.TextEdit"))
            )
            .is_ok()
        );
        assert!(resolve_listed(applications(), &query(None, None, Some("4242"))).is_err());
    }

    #[test]
    fn an_application_without_a_bundle_identifier_never_satisfies_an_identifier_query() {
        let helper = vec![running(4242, "Helper", None)];
        assert!(resolve_listed(helper.clone(), &query(None, Some("Helper"), None)).is_ok());
        assert!(resolve_listed(helper, &query(None, None, Some("com.example.Helper"))).is_err());
    }

    #[test]
    fn resolution_separates_no_match_from_ambiguity() {
        let shared = || {
            vec![
                running(1, "Shared", Some("com.example.one")),
                running(2, "Shared", Some("com.example.two")),
            ]
        };
        assert!(
            resolve_listed(shared(), &query(None, Some("Shared"), None))
                .unwrap_err()
                .to_string()
                .contains("ambiguous")
        );
        assert!(
            resolve_listed(shared(), &query(None, Some("Missing"), None))
                .unwrap_err()
                .to_string()
                .contains("not found")
        );
        // The bundle identifier is what tells apart two applications sharing a display name.
        assert_eq!(
            resolve_listed(
                shared(),
                &query(None, Some("Shared"), Some("com.example.two"))
            )
            .unwrap()
            .process_id,
            2
        );
    }

    #[test]
    fn screenshot_capability_requires_both_native_permissions() {
        assert_eq!(
            screenshot_restriction(false, true),
            Some("Accessibility permission is not granted")
        );
        assert_eq!(
            screenshot_restriction(true, false),
            Some("Screen Recording permission is not granted")
        );
        assert_eq!(screenshot_restriction(true, true), None);
    }

    /// A daemon whose Accessibility grant is withdrawn mid-run enumerates nothing, because every
    /// `AXTitle` read comes back disabled. Reporting that as `application not found` sends the
    /// caller looking for an application that is running and visible on screen.
    #[test]
    fn withdrawn_accessibility_refuses_typed_rather_than_reporting_no_such_application() {
        let error = resolve_running(
            Vec::new(),
            &query(None, Some("TextEdit"), None),
            AxAccess::Denied,
        )
        .unwrap_err();
        let BackendError::CapabilityReason {
            capability,
            code,
            diagnostic,
            ..
        } = &error
        else {
            panic!("expected a typed capability refusal, got {error:?}");
        };
        assert_eq!(*capability, Capability::Capture);
        assert_eq!(*code, "accessibility-denied");
        assert!(
            diagnostic
                .as_deref()
                .is_some_and(|text| text.contains("kAXErrorAPIDisabled"))
        );
    }

    /// An inconclusive verdict must not manufacture a permission story. A machine that genuinely
    /// has no matching application still says so.
    #[test]
    fn an_unknown_access_verdict_keeps_the_not_found_answer() {
        let error = resolve_running(
            Vec::new(),
            &query(None, Some("TextEdit"), None),
            AxAccess::Unknown,
        )
        .unwrap_err();
        assert!(error.to_string().contains("not found"), "{error:?}");
    }

    /// The composition the census makes, pinned against the permissions it composes.
    ///
    /// `screenshot` stays unusable without Accessibility even when Screen Recording is granted,
    /// because this backend resolves the window to capture through the Accessibility API. The
    /// shared Swift fixture claims the opposite for the Swift daemon, which resolves applications
    /// through NSWorkspace; both are right about their own implementation.
    #[test]
    fn the_census_composes_permissions_that_the_permission_fields_report_separately() {
        let report = capability_report(MacPermissions {
            accessibility: false,
            screen_recording: true,
        });
        let info = |capability| {
            report
                .iter()
                .find(|info: &&CapabilityInfo| info.capability == capability)
                .unwrap_or_else(|| panic!("{capability:?} is censused"))
        };
        let screenshot = info(Capability::Screenshot);
        assert!(!screenshot.usable);
        assert_eq!(
            screenshot.restriction.as_deref(),
            Some("Accessibility permission is not granted")
        );
        assert!(info(Capability::SerializeHistory).usable);
        assert!(!info(Capability::Capture).usable);

        let both = capability_report(MacPermissions {
            accessibility: true,
            screen_recording: true,
        });
        assert!(
            both.iter()
                .find(|info| info.capability == Capability::Screenshot)
                .unwrap()
                .usable
        );
    }
}
