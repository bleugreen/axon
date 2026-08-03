use std::{thread, time::Duration};

use uiautomation::{patterns::UIInvokePattern, UIAutomation, UIElement, UITreeWalker};

use crate::{matches_locator, Node, Options};

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
    let window = windows.into_iter().find(|element| {
        property(element.get_name()).to_lowercase().contains(&window_query.to_lowercase())
    }).ok_or_else(|| format!("no top-level window name contains {window_query:?}"))?;

    let mut elements = Vec::new();
    capture(&walker, &window, 0, options.max_depth, options.max_nodes, &mut elements);
    let before = snapshot(&elements);
    println!(
        "capture window={:?} nodes={} max_depth={} max_nodes={}",
        property(window.get_name()), before.len(), options.max_depth, options.max_nodes
    );
    for node in &before {
        println!("{:indent$}{}", "", format_node(node), indent = node.depth * 2);
    }

    let (Some(control_type), Some(name_contains)) =
        (&options.control_type, &options.name_contains) else { return Ok(()) };
    let match_index = before.iter().position(|node| {
        matches_locator(node, control_type, name_contains)
    }).ok_or_else(|| {
        format!("locator did not match: type={control_type:?}, name_contains={name_contains:?}")
    })?;
    println!("locator_match {}", format_node(&before[match_index]));

    if !options.invoke {
        return Ok(());
    }

    let dispatch = elements[match_index].1
        .get_pattern::<UIInvokePattern>()
        .and_then(|pattern| pattern.invoke());
    match &dispatch {
        Ok(()) => println!("dispatch_success=true"),
        Err(error) => println!("dispatch_success=false error={error}"),
    }
    if dispatch.is_err() {
        return Ok(());
    }

    thread::sleep(Duration::from_millis(500));
    let mut after_elements = Vec::new();
    capture(&walker, &window, 0, options.max_depth, options.max_nodes, &mut after_elements);
    let after = snapshot(&after_elements);
    println!("verified_outcome={}", before != after);
    println!(
        "verification=bounded_tree_changed before_nodes={} after_nodes={}",
        before.len(), after.len()
    );
    Ok(())
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
    elements.iter().map(|(depth, element)| Node {
        depth: *depth,
        control_type: property(element.get_control_type()).to_string(),
        name: property(element.get_name()),
        automation_id: property(element.get_automation_id()),
        rect: property(element.get_bounding_rectangle()).to_string(),
    }).collect()
}

fn describe(element: &UIElement, depth: usize) -> String {
    format_node(&Node {
        depth,
        control_type: property(element.get_control_type()).to_string(),
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
