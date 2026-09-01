use crate::global_input::MacGlobalInputObserver;
use crate::{
    BackgroundPixelPointer, PixelDispatch, PixelDispatchError, PixelPlan, PixelTarget,
    PointerTargetVerifier, ReadableStateProvider, VisualObservation, VisualObservationProvider,
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
    fn AXIsProcessTrusted() -> bool;
    fn AXValueGetValue(value: AXValueRef, value_type: i64, output: *mut c_void) -> bool;
}
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringCreateWithCString(
        alloc: *const c_void,
        text: *const c_char,
        encoding: u32,
    ) -> CFStringRef;
    fn CFStringGetCString(
        value: CFStringRef,
        buffer: *mut c_char,
        size: isize,
        encoding: u32,
    ) -> u8;
    fn CFGetTypeID(value: CFTypeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFBooleanGetTypeID() -> usize;
    fn CFBooleanGetValue(value: CFTypeRef) -> bool;
    fn CFArrayGetTypeID() -> usize;
    fn CFArrayGetCount(array: CFArrayRef) -> isize;
    fn CFArrayGetValueAtIndex(array: CFArrayRef, index: isize) -> *const c_void;
    fn CFRetain(value: CFTypeRef) -> CFTypeRef;
    fn CFRelease(value: CFTypeRef);
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
fn attribute(element: AXUIElementRef, name: &str) -> Option<Owned> {
    let name = cfstr(name).ok()?;
    let mut value = null();
    let status = unsafe { AXUIElementCopyAttributeValue(element, name.0, &mut value) };
    (status == 0 && !value.is_null()).then(|| Owned(value))
}
fn string_value(value: CFTypeRef) -> Option<String> {
    if unsafe { CFGetTypeID(value) } != unsafe { CFStringGetTypeID() } {
        return None;
    }
    let mut buffer = vec![0u8; 65_536];
    if unsafe {
        CFStringGetCString(
            value,
            buffer.as_mut_ptr().cast(),
            buffer.len() as isize,
            UTF8,
        )
    } == 0
    {
        return None;
    }
    let end = buffer.iter().position(|b| *b == 0)?;
    Some(String::from_utf8_lossy(&buffer[..end]).into_owned())
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
/// `RecordedAppIdentity`, drawn from the same source, so a query built from a recorded event can
/// resolve here.
#[derive(Clone, Debug)]
pub(crate) struct RunningApplication {
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
    fn matches(&self, query: &AppQuery) -> bool {
        query
            .process_id
            .is_none_or(|wanted| wanted == self.process_id as u32)
            && query
                .identifier
                .as_deref()
                .is_none_or(|wanted| self.bundle_identifier.as_deref() == Some(wanted))
            && query
                .name
                .as_deref()
                .is_none_or(|wanted| self.name.eq_ignore_ascii_case(wanted))
    }
}

/// The single application a query names, or why it named none or more than one.
///
/// Split from the live enumeration so the matching rule can be exercised against a synthetic list;
/// the native pid walk it is normally fed cannot be staged in a test.
pub(crate) fn resolve_running(
    applications: Vec<RunningApplication>,
    query: &AppQuery,
) -> Result<RunningApplication, BackendError> {
    let mut matches = applications
        .into_iter()
        .filter(|application| application.matches(query));
    match (matches.next(), matches.next()) {
        (Some(one), None) => Ok(one),
        (None, _) => Err(op("capture", "application not found")),
        (Some(_), Some(_)) => Err(op("capture", "application query is ambiguous")),
    }
}

/// The query naming the application a recorded input event was observed in.
pub(crate) fn recorded_app_query(app: &axon_core::RecordedAppIdentity) -> AppQuery {
    AppQuery {
        process_id: app.process_id,
        name: Some(app.name.clone()),
        identifier: app.bundle_identifier.clone(),
    }
}

pub struct MacBackend {
    handles: HashMap<SnapshotHandle, Owned>,
    global_input: MacGlobalInputObserver,
}
impl MacBackend {
    pub fn new() -> Result<Self, BackendError> {
        Ok(Self {
            handles: HashMap::new(),
            global_input: MacGlobalInputObserver::default(),
        })
    }
    pub fn accessibility_enabled(&self) -> bool {
        unsafe { AXIsProcessTrusted() }
    }
    fn applications(&self) -> Vec<RunningApplication> {
        let needed = unsafe { proc_listallpids(std::ptr::null_mut(), 0) };
        if needed <= 0 {
            return Vec::new();
        }
        let mut pids = vec![0i32; needed as usize];
        let returned = unsafe {
            proc_listallpids(
                pids.as_mut_ptr().cast(),
                (pids.len() * std::mem::size_of::<i32>()) as i32,
            )
        };
        pids.truncate(returned.max(0) as usize);
        pids.into_iter()
            .filter_map(|pid| {
                let mut path = vec![0u8; 4096];
                let length =
                    unsafe { proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
                if length <= 0 {
                    return None;
                }
                let path = String::from_utf8_lossy(&path[..length as usize]);
                if !path.contains(".app/Contents/MacOS/") || path.contains(".xpc/Contents/MacOS/") {
                    return None;
                }
                let root = unsafe { AXUIElementCreateApplication(pid) };
                if root.is_null() {
                    return None;
                }
                let root = Owned(root);
                // A non-empty AXTitle is what qualifies a process as an application here; the name
                // it is then reported and matched under is the one the recorder would stamp on an
                // event observed in it.
                text_attribute(root.0, "AXTitle")
                    .filter(|name| !name.is_empty())
                    .map(|accessibility_name| {
                        let (name, bundle_identifier) =
                            crate::global_input::application_identity(pid, accessibility_name);
                        RunningApplication {
                            process_id: pid,
                            name,
                            bundle_identifier,
                        }
                    })
            })
            .collect()
    }
    fn resolve(&self, app: &AppQuery) -> Result<RunningApplication, BackendError> {
        resolve_running(self.applications(), app)
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
        let accessibility_enabled = self.accessibility_enabled();
        let screen_recording_enabled = window_capture::screen_capture_enabled();
        let supported = [
            Capability::Enumerate,
            Capability::Capture,
            Capability::RetainedHandles,
            Capability::Invoke,
            Capability::ReadValue,
            Capability::SetValue,
            Capability::Focus,
            Capability::Scroll,
            Capability::Screenshot,
            Capability::SerializeHistory,
            Capability::ObserveGlobalInput,
        ];
        Ok(Capability::ALL
            .into_iter()
            .map(|capability| {
                let usable = if capability == Capability::SerializeHistory {
                    true
                } else if capability == Capability::Screenshot {
                    screenshot_restriction(accessibility_enabled, screen_recording_enabled)
                        .is_none()
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
                            "excluded from axon-mac v1".into()
                        }
                    }),
                }
            })
            .collect())
    }
    fn enumerate_applications(&self) -> Result<Vec<Application>, BackendError> {
        Ok(self
            .applications()
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
    fn keyboard(&mut self, _: &AppQuery, _: KeyboardIntent<'_>) -> Result<(), BackendError> {
        Err(cap(
            Capability::KeyboardInput,
            "keyboard has no semantic AX action and pixel/foreground delivery are not implemented in v1",
        ))
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
    fn pointer_click(&mut self, _: (f64, f64)) -> Result<(), BackendError> {
        Err(cap(
            Capability::PointerInput,
            "pixel and foreground delivery are not implemented in v1",
        ))
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
    fn hit_test(&mut self, _: (f64, f64)) -> Result<Option<Node>, BackendError> {
        Err(cap(Capability::HitTest, "excluded from v1"))
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
impl PointerTargetVerifier for MacBackend {
    fn verify_pointer_target(
        &mut self,
        _: &SnapshotHandle,
        _: (f64, f64),
    ) -> Result<bool, BackendError> {
        Ok(false)
    }
}
impl BackgroundPixelPointer for MacBackend {
    fn plan_pixel_click(
        &mut self,
        _: &SnapshotHandle,
        _: (f64, f64),
    ) -> Result<PixelPlan, BackendError> {
        Ok(PixelPlan::unavailable(
            "pixel delivery is not implemented in axon-mac v1",
        ))
    }
    fn dispatch_pixel_click(
        &mut self,
        _: &PixelTarget,
    ) -> Result<PixelDispatch, PixelDispatchError> {
        Err(PixelDispatchError::Backend(cap(
            Capability::PointerInput,
            "pixel delivery is not implemented in axon-mac v1",
        )))
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
        let capabilities = backend.capabilities().unwrap();
        assert_eq!(capabilities.len(), Capability::ALL.len());
        assert!(
            !capabilities
                .iter()
                .find(|info| info.capability == Capability::KeyboardInput)
                .unwrap()
                .usable
        );
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
        let resolved = resolve_running(
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

    #[test]
    fn identifier_matches_the_bundle_identifier_rather_than_the_process_id() {
        let applications = || vec![running(4242, "TextEdit", Some("com.apple.TextEdit"))];
        assert!(
            resolve_running(
                applications(),
                &query(None, None, Some("com.apple.TextEdit"))
            )
            .is_ok()
        );
        assert!(resolve_running(applications(), &query(None, None, Some("4242"))).is_err());
    }

    #[test]
    fn an_application_without_a_bundle_identifier_never_satisfies_an_identifier_query() {
        let helper = vec![running(4242, "Helper", None)];
        assert!(resolve_running(helper.clone(), &query(None, Some("Helper"), None)).is_ok());
        assert!(resolve_running(helper, &query(None, None, Some("com.example.Helper"))).is_err());
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
            resolve_running(shared(), &query(None, Some("Shared"), None))
                .unwrap_err()
                .to_string()
                .contains("ambiguous")
        );
        assert!(
            resolve_running(shared(), &query(None, Some("Missing"), None))
                .unwrap_err()
                .to_string()
                .contains("not found")
        );
        // The bundle identifier is what tells apart two applications sharing a display name.
        assert_eq!(
            resolve_running(
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
}
