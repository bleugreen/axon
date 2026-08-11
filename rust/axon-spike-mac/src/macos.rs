use super::Options;
use std::ffi::{c_char, c_void};
use std::ptr::null;
use std::time::{Duration, Instant};

type CFTypeRef = *const c_void;
type CFStringRef = *const c_void;
type CFArrayRef = *const c_void;
type AXUIElementRef = *const c_void;

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXUIElementCreateApplication(pid: i32) -> AXUIElementRef;
    fn AXUIElementCopyAttributeValue(element: AXUIElementRef, attribute: CFStringRef, value: *mut CFTypeRef) -> i32;
    fn AXUIElementPerformAction(element: AXUIElementRef, action: CFStringRef) -> i32;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringCreateWithCString(alloc: *const c_void, text: *const c_char, encoding: u32) -> CFStringRef;
    fn CFStringGetCString(value: CFStringRef, buffer: *mut c_char, size: isize, encoding: u32) -> bool;
    fn CFGetTypeID(value: CFTypeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFArrayGetTypeID() -> usize;
    fn CFArrayGetCount(array: CFArrayRef) -> isize;
    fn CFArrayGetValueAtIndex(array: CFArrayRef, index: isize) -> *const c_void;
    fn CFRetain(value: CFTypeRef) -> CFTypeRef;
    fn CFRelease(value: CFTypeRef);
}

const UTF8: u32 = 0x0800_0100;

struct Owned(CFTypeRef);
impl Clone for Owned { fn clone(&self) -> Self { Self(unsafe { CFRetain(self.0) }) } }
impl Drop for Owned { fn drop(&mut self) { unsafe { CFRelease(self.0) } } }

fn cfstr(value: &str) -> Result<Owned, String> {
    let bytes = std::ffi::CString::new(value).map_err(|_| "string contains NUL")?;
    let value = unsafe { CFStringCreateWithCString(null(), bytes.as_ptr(), UTF8) };
    if value.is_null() { Err("CFString allocation failed".into()) } else { Ok(Owned(value)) }
}

fn attribute(element: AXUIElementRef, name: &str) -> Option<Owned> {
    eprintln!("probe: reading {name}");
    let name = cfstr(name).ok()?;
    eprintln!("probe: attribute name allocated");
    let mut value = null();
    let error = unsafe { AXUIElementCopyAttributeValue(element, name.0, &mut value) };
    eprintln!("probe: attribute call returned {error}");
    (error == 0 && !value.is_null()).then_some(Owned(value))
}

fn string_value(value: CFTypeRef) -> Option<String> {
    if unsafe { CFGetTypeID(value) } != unsafe { CFStringGetTypeID() } { return None; }
    let mut buffer = vec![0u8; 16_384];
    if !unsafe { CFStringGetCString(value, buffer.as_mut_ptr().cast(), buffer.len() as isize, UTF8) } { return None; }
    let end = buffer.iter().position(|byte| *byte == 0)?;
    Some(String::from_utf8_lossy(&buffer[..end]).into_owned())
}

fn text_attribute(element: AXUIElementRef, name: &str) -> String {
    attribute(element, name).and_then(|v| string_value(v.0)).unwrap_or_default()
}

struct Node { element: Owned, depth: usize, role: String, name: String, value: String }

fn capture(root: AXUIElementRef, options: &Options) -> Vec<Node> {
    let mut nodes = Vec::new();
    eprintln!("probe: retaining root");
    let retained_root = Owned(unsafe { CFRetain(root) });
    eprintln!("probe: root retained");
    let mut stack = vec![(retained_root, 0usize)];
    while let Some((element, depth)) = stack.pop() {
        if nodes.len() >= options.max_nodes { break; }
        let role = text_attribute(element.0, "AXRole");
        let title = text_attribute(element.0, "AXTitle");
        let description = text_attribute(element.0, "AXDescription");
        let value = text_attribute(element.0, "AXValue");
        let name = if !title.is_empty() { title } else { description };
        nodes.push(Node { element, depth, role, name, value });
        if depth >= options.max_depth { continue; }
        let element = nodes.last().unwrap().element.0;
        if let Some(children) = attribute(element, "AXChildren") {
            if unsafe { CFGetTypeID(children.0) } == unsafe { CFArrayGetTypeID() } {
                let count = unsafe { CFArrayGetCount(children.0) };
                for index in (0..count).rev() {
                    let child = unsafe { CFArrayGetValueAtIndex(children.0, index) };
                    if !child.is_null() { stack.push((Owned(unsafe { CFRetain(child) }), depth + 1)); }
                }
            }
        }
    }
    nodes
}

fn print_tree(nodes: &[Node]) {
    for node in nodes { println!("{}{} name={:?} value={:?}", "  ".repeat(node.depth), node.role, node.name, node.value); }
}

pub fn run(options: &Options) -> Result<(), String> {
    eprintln!("probe: creating application element for pid {}", options.pid);
    let root = unsafe { AXUIElementCreateApplication(options.pid) };
    if root.is_null() { return Err("AXUIElementCreateApplication returned null".into()); }
    eprintln!("probe: application element created; starting capture");
    let root = Owned(root);
    let started = Instant::now();
    let before = capture(root.0, options);
    eprintln!("probe: capture returned {} nodes", before.len());
    let elapsed = started.elapsed();
    print_tree(&before);
    println!("capture_nodes={} capture_ms={:.3}", before.len(), elapsed.as_secs_f64() * 1000.0);
    if !options.action { return Ok(()); }

    let expected_before = options.expect_before.as_deref().unwrap();
    let expected_after = options.expect_after.as_deref().unwrap();
    if !before.iter().any(|node| node.value == expected_before) { return Err(format!("expected before value {expected_before:?} not found")); }
    let role = options.role.as_deref().unwrap();
    let name = options.name_contains.as_deref().unwrap().to_lowercase();
    let target = before.iter().find(|node| node.role.eq_ignore_ascii_case(role) && node.name.to_lowercase().contains(&name))
        .ok_or_else(|| format!("action target role={role:?} name contains={name:?} not found"))?;
    let action = cfstr("AXPress")?;
    let action_started = Instant::now();
    let error = unsafe { AXUIElementPerformAction(target.element.0, action.0) };
    if error != 0 { return Err(format!("AXPress failed with AXError {error}")); }
    std::thread::sleep(Duration::from_millis(500));
    let after = capture(root.0, options);
    let verified = after.iter().any(|node| node.value == expected_after);
    println!("action=AXPress target_role={:?} target_name={:?} dispatch_error={} observed_before={:?} observed_after={:?} verified={} action_and_wait_ms={:.3}", target.role, target.name, error, expected_before, expected_after, verified, action_started.elapsed().as_secs_f64() * 1000.0);
    if !verified { return Err(format!("expected after value {expected_after:?} not found")); }
    Ok(())
}