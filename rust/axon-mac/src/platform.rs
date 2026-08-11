use crate::{
    BackgroundPixelPointer, PixelDispatch, PixelDispatchError, PixelPlan, PixelTarget,
    PointerTargetVerifier, VisualObservation, VisualObservationProvider,
};
use axon_core::{
    AppQuery, Application, BackendError, Capability, CapabilityInfo, KeyboardIntent, Node,
    Observation, PlatformBackend, RecordedCall, Rect, Screenshot, Snapshot, SnapshotHandle, Window,
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
fn capture_node(element: Owned, depth: usize, count: &mut usize) -> Captured {
    *count += 1;
    let role = text_attribute(element.0, "AXRole").unwrap_or_else(|| "AXUnknown".into());
    let child_values = attribute(element.0, "AXChildren");
    let child_count = child_values.as_ref().and_then(|v| {
        (unsafe { CFGetTypeID(v.0) } == unsafe { CFArrayGetTypeID() })
            .then(|| unsafe { CFArrayGetCount(v.0) as usize })
    });
    let mut children = Vec::new();
    let mut elements = vec![element.clone()];
    let mut truncation_reason = None;
    if depth >= MAX_DEPTH && child_count.unwrap_or(0) > 0 {
        truncation_reason = Some("depth limit reached".into());
    } else if let Some(array) =
        child_values.filter(|v| unsafe { CFGetTypeID(v.0) } == unsafe { CFArrayGetTypeID() })
    {
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
            let captured = capture_node(Owned(unsafe { CFRetain(child) }), depth + 1, count);
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
            children,
            child_count,
            truncation_reason,
        },
        elements,
    }
}

pub struct MacBackend {
    handles: HashMap<SnapshotHandle, Owned>,
}
impl MacBackend {
    pub fn new() -> Result<Self, BackendError> {
        Ok(Self {
            handles: HashMap::new(),
        })
    }
    pub fn accessibility_enabled(&self) -> bool {
        unsafe { AXIsProcessTrusted() }
    }
    fn applications(&self) -> Vec<(i32, String)> {
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
                text_attribute(root.0, "AXTitle")
                    .filter(|name| !name.is_empty())
                    .map(|name| (pid, name))
            })
            .collect()
    }
    fn resolve(&self, app: &AppQuery) -> Result<(i32, String), BackendError> {
        let matches = self
            .applications()
            .into_iter()
            .filter(|(pid, name)| {
                app.identifier
                    .as_deref()
                    .is_none_or(|id| id == pid.to_string())
                    && app
                        .name
                        .as_deref()
                        .is_none_or(|wanted| name.eq_ignore_ascii_case(wanted))
            })
            .collect::<Vec<_>>();
        match matches.as_slice() {
            [one] => Ok(one.clone()),
            [] => Err(op("capture", "application not found")),
            _ => Err(op("capture", "application query is ambiguous")),
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

impl PlatformBackend for MacBackend {
    fn capabilities(&self) -> Result<Vec<CapabilityInfo>, BackendError> {
        let supported = [
            Capability::Enumerate,
            Capability::Capture,
            Capability::RetainedHandles,
            Capability::Invoke,
            Capability::ReadValue,
            Capability::SetValue,
            Capability::Focus,
            Capability::Scroll,
        ];
        Ok(Capability::ALL
            .into_iter()
            .map(|capability| {
                let usable = supported.contains(&capability) && self.accessibility_enabled();
                CapabilityInfo {
                    capability,
                    usable,
                    restriction: (!usable).then(|| {
                        if supported.contains(&capability) {
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
            .map(|(pid, name)| Application {
                name,
                identifier: Some(pid.to_string()),
                windows: Vec::new(),
            })
            .collect())
    }
    fn capture(&mut self, app: &AppQuery) -> Result<Snapshot, BackendError> {
        if !self.accessibility_enabled() {
            return Err(cap(
                Capability::Capture,
                "Accessibility permission is not granted",
            ));
        }
        let (pid, name) = self.resolve(app)?;
        let root = unsafe { AXUIElementCreateApplication(pid) };
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
            let captured = capture_node(Owned(unsafe { CFRetain(element) }), 0, &mut count);
            snapshot_windows.push(Window {
                title: captured.node.title.clone(),
                root: captured.node,
            });
            all_elements.extend(captured.elements);
        }
        let snapshot = Snapshot::new(Application {
            name,
            identifier: Some(pid.to_string()),
            windows: snapshot_windows,
        });
        self.handles = all_elements
            .into_iter()
            .enumerate()
            .map(|(i, element)| (snapshot.handle(i), element))
            .collect();
        Ok(snapshot)
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
    fn screenshot(&mut self, _: &AppQuery) -> Result<Screenshot, BackendError> {
        Err(cap(Capability::Screenshot, "excluded from v1"))
    }
    fn hit_test(&mut self, _: (f64, f64)) -> Result<Option<Node>, BackendError> {
        Err(cap(Capability::HitTest, "excluded from v1"))
    }
    fn recorded_calls(&self) -> Result<Vec<RecordedCall>, BackendError> {
        Err(cap(Capability::SerializeHistory, "excluded from v1"))
    }
    fn set_recording(&mut self, _: bool) -> Result<(), BackendError> {
        Err(cap(Capability::SerializeHistory, "excluded from v1"))
    }
    fn observe_global_input(&mut self, _: Duration) -> Result<Vec<RecordedCall>, BackendError> {
        Err(cap(Capability::ObserveGlobalInput, "excluded from v1"))
    }
}
impl VisualObservationProvider for MacBackend {
    fn observe_visuals(
        &mut self,
        _: &AppQuery,
        _: bool,
        _: bool,
    ) -> Result<VisualObservation, BackendError> {
        Ok(VisualObservation {
            screenshot: None,
            recognized_text: None,
        })
    }
}
impl axon_core::TextRecognitionProvider for MacBackend {
    fn recognize_text(
        &mut self,
        _: &AppQuery,
    ) -> Result<Vec<axon_core::RecognizedText>, BackendError> {
        Err(cap(Capability::Screenshot, "screen text excluded from v1"))
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
}
