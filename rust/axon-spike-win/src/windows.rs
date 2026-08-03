use std::{collections::BTreeMap, ffi::c_void, thread, time::Duration};

use uiautomation::{UIAutomation, UIElement, UITreeWalker, patterns::UIInvokePattern};

use crate::{Node, Options, matches_locator};

pub(super) fn run(options: &Options) -> Result<(), Box<dyn std::error::Error>> {
    let automation = UIAutomation::new()?;
    let walker = automation.get_control_view_walker()?;
    let root = automation.get_root_element()?;
    let windows = children(&walker, &root);

    println!("top_level_count={}", windows.len());
    for window in &windows {
        println!("{}", describe(window, 0));
    }

    let Some(window_query) = &options.window_name else {
        return Ok(());
    };
    let query = window_query.to_lowercase();
    let window = windows
        .iter()
        .find(|element| property(element.get_name()).to_lowercase() == query)
        .or_else(|| {
            windows
                .iter()
                .find(|element| property(element.get_name()).to_lowercase().contains(&query))
        })
        .cloned()
        .ok_or_else(|| format!("no top-level window name contains {window_query:?}"))?;

    if options.activate_msaa {
        let hwnd = window.get_native_window_handle()?;
        let activation = msaa::activate(hwnd.into());
        println!(
            "msaa_activation attempted_hwnds={} successful_queries={}",
            activation.attempted, activation.succeeded
        );
        thread::sleep(Duration::from_millis(1500));
    }

    let mut elements = Vec::new();
    capture(
        &walker,
        &window,
        0,
        options.max_depth,
        options.max_nodes,
        &mut elements,
    );
    let before = snapshot(&elements);
    print_stats(&before);
    println!(
        "capture window={:?} nodes={} max_depth={} max_nodes={}",
        property(window.get_name()),
        before.len(),
        options.max_depth,
        options.max_nodes
    );
    for node in &before {
        println!(
            "{:indent$}{}",
            "",
            format_node(node),
            indent = node.depth * 2
        );
    }

    let (Some(control_type), Some(name_contains)) = (&options.control_type, &options.name_contains)
    else {
        return Ok(());
    };
    let match_index = before
        .iter()
        .position(|node| matches_locator(node, control_type, name_contains))
        .ok_or_else(|| {
            format!("locator did not match: type={control_type:?}, name_contains={name_contains:?}")
        })?;
    println!("locator_match {}", format_node(&before[match_index]));

    if !options.invoke {
        return Ok(());
    }

    let dispatch = elements[match_index]
        .1
        .get_pattern::<UIInvokePattern>()
        .and_then(|pattern| pattern.invoke());
    match &dispatch {
        Ok(()) => println!("dispatch_success=true"),
        Err(error) => println!("dispatch_success=false error={error}"),
    }
    if let Err(error) = dispatch {
        println!("verification_attempted=false");
        println!("verified_outcome=false reason=dispatch_failed");
        return Err(format!("InvokePattern dispatch failed: {error}").into());
    }

    thread::sleep(Duration::from_millis(500));
    let mut after_elements = Vec::new();
    capture(
        &walker,
        &window,
        0,
        options.max_depth,
        options.max_nodes,
        &mut after_elements,
    );
    let after = snapshot(&after_elements);
    let changed = before != after;
    println!("verification_attempted=true");
    println!("verified_outcome={changed}");
    println!(
        "verification=bounded_tree_changed before_nodes={} after_nodes={}",
        before.len(),
        after.len()
    );
    if !changed {
        return Err("InvokePattern dispatched, but the bounded tree did not change".into());
    }
    Ok(())
}

fn print_stats(nodes: &[Node]) {
    let named = nodes.iter().filter(|node| !node.name.is_empty()).count();
    let identified = nodes
        .iter()
        .filter(|node| !node.automation_id.is_empty())
        .count();
    let mut control_types = BTreeMap::new();
    for node in nodes {
        *control_types
            .entry(node.control_type.as_str())
            .or_insert(0usize) += 1;
    }
    let types = control_types
        .into_iter()
        .map(|(name, count)| format!("{name}:{count}"))
        .collect::<Vec<_>>()
        .join(",");
    println!("stats named_nodes={named} automation_id_nodes={identified} control_types={types}");
}

mod msaa {
    use super::c_void;

    type Hwnd = isize;
    type Bool = i32;

    const OBJID_CLIENT: i32 = -4;
    const IID_IACCESSIBLE: Guid = Guid {
        data1: 0x618736e0,
        data2: 0x3c3d,
        data3: 0x11cf,
        data4: [0x81, 0x0c, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71],
    };

    #[repr(C)]
    struct Guid {
        data1: u32,
        data2: u16,
        data3: u16,
        data4: [u8; 8],
    }

    #[derive(Default)]
    pub(super) struct Activation {
        pub attempted: usize,
        pub succeeded: usize,
    }

    #[link(name = "oleacc")]
    unsafe extern "system" {
        fn AccessibleObjectFromWindow(
            hwnd: Hwnd,
            object_id: u32,
            interface_id: *const Guid,
            object: *mut *mut c_void,
        ) -> i32;
    }

    #[link(name = "user32")]
    unsafe extern "system" {
        fn EnumChildWindows(
            parent: Hwnd,
            callback: unsafe extern "system" fn(Hwnd, isize) -> Bool,
            parameter: isize,
        ) -> Bool;
    }

    pub(super) fn activate(hwnd: Hwnd) -> Activation {
        let mut result = Activation::default();
        touch(hwnd, &mut result);
        unsafe {
            EnumChildWindows(hwnd, visit, (&mut result as *mut Activation) as isize);
        }
        result
    }

    unsafe extern "system" fn visit(hwnd: Hwnd, parameter: isize) -> Bool {
        let result = unsafe { &mut *(parameter as *mut Activation) };
        touch(hwnd, result);
        1
    }

    fn touch(hwnd: Hwnd, result: &mut Activation) {
        result.attempted += 1;
        let mut object = std::ptr::null_mut();
        let status = unsafe {
            AccessibleObjectFromWindow(hwnd, OBJID_CLIENT as u32, &IID_IACCESSIBLE, &mut object)
        };
        if status >= 0 && !object.is_null() {
            result.succeeded += 1;
            unsafe { release(object) };
        }
    }

    unsafe fn release(object: *mut c_void) {
        let vtable = unsafe { *(object as *mut *mut *mut c_void) };
        let release: unsafe extern "system" fn(*mut c_void) -> u32 =
            unsafe { std::mem::transmute(*vtable.add(2)) };
        unsafe { release(object) };
    }
}

fn capture(
    walker: &UITreeWalker,
    element: &UIElement,
    depth: usize,
    max_depth: usize,
    max_nodes: usize,
    output: &mut Vec<(usize, UIElement)>,
) {
    if output.len() >= max_nodes {
        return;
    }
    output.push((depth, element.clone()));
    if depth >= max_depth {
        return;
    }
    for child in children(walker, element) {
        capture(walker, &child, depth + 1, max_depth, max_nodes, output);
        if output.len() >= max_nodes {
            break;
        }
    }
}

fn children(walker: &UITreeWalker, parent: &UIElement) -> Vec<UIElement> {
    let Ok(first) = walker.get_first_child(parent) else {
        return Vec::new();
    };
    let mut result = vec![first.clone()];
    let mut current = first;
    while let Ok(next) = walker.get_next_sibling(&current) {
        result.push(next.clone());
        current = next;
    }
    result
}

fn snapshot(elements: &[(usize, UIElement)]) -> Vec<Node> {
    elements
        .iter()
        .map(|(depth, element)| Node {
            depth: *depth,
            control_type: element
                .get_control_type()
                .map(|value| value.to_string())
                .unwrap_or_else(|_| "<unavailable>".to_owned()),
            name: property(element.get_name()),
            automation_id: property(element.get_automation_id()),
            rect: property(element.get_bounding_rectangle()).to_string(),
        })
        .collect()
}

fn describe(element: &UIElement, depth: usize) -> String {
    format_node(&Node {
        depth,
        control_type: element
            .get_control_type()
            .map(|value| value.to_string())
            .unwrap_or_else(|_| "<unavailable>".to_owned()),
        name: property(element.get_name()),
        automation_id: property(element.get_automation_id()),
        rect: property(element.get_bounding_rectangle()).to_string(),
    })
}

fn format_node(node: &Node) -> String {
    format!(
        "type={:?} name={:?} automation_id={:?} rect={}",
        node.control_type, node.name, node.automation_id, node.rect
    )
}

fn property<T: Default>(result: uiautomation::Result<T>) -> T {
    result.unwrap_or_default()
}
