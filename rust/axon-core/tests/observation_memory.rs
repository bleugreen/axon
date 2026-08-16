//! What describing an observation is allowed to cost, measured against the size of the
//! observation.
//!
//! On 2026-08-15 a Linux daemon was asked to look at GNOME Shell and was killed by the kernel
//! seven seconds later, having grown from 8 MiB to a gigabyte. The tree it had captured was
//! bounded and correct; naming the elements in it copied the whole thing once per element. The
//! same path runs on every backend, so the cost was quadratic everywhere and only a desktop shell
//! was large enough to make it fatal.
//!
//! A resident-memory bound would express that badly: it would be a number about one machine's
//! allocator, and it would flake. The honest statement is about scaling. Describing a tree of `n`
//! elements costs proportionally to `n`, and doubling the tree may not quadruple the cost. That
//! holds on any machine, states exactly the defect, and cannot be satisfied by accident.
//!
//! This is deliberately the whole of its test binary. The measurement is process-wide, so a
//! second test running beside it would be counted as part of it.

use axon_core::{Application, Node, SemanticNameRegistry, Snapshot, SnapshotId, Window};
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

struct Counting;

static ALLOCATED: AtomicUsize = AtomicUsize::new(0);
static LIVE: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATED.fetch_add(layout.size(), Ordering::Relaxed);
        LIVE.fetch_add(layout.size(), Ordering::Relaxed);
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        unsafe { System.dealloc(pointer, layout) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

fn allocated() -> usize {
    ALLOCATED.load(Ordering::Relaxed)
}

fn live() -> usize {
    LIVE.load(Ordering::Relaxed)
}

fn leaf(window: usize, index: usize) -> Node {
    Node {
        role: "push button".into(),
        subrole: None,
        name: Some(format!("control {window}.{index}")),
        title: Some(format!("Control {window}.{index}")),
        label: None,
        value: None,
        description: Some(format!("the {index}th control of panel {window}")),
        identifier: Some(format!("control-{window}-{index}")),
        actions: vec!["click".into(), "focus".into()],
        frame: None,
        editable: false,
        focused: None,
        enabled: Some(true),
        children: vec![],
        child_count: Some(0),
        truncation_reason: None,
    }
}

/// An observation shaped like the one that caused this: many sibling panels, each a shallow group
/// of controls. Breadth is what a desktop shell has, and breadth is what makes a per-element copy
/// of the whole tree expensive.
fn observation(elements: usize) -> Snapshot {
    let per_panel = 10;
    let panels = elements / per_panel;
    let windows = (0..panels)
        .map(|panel| Window {
            title: Some(format!("panel {panel}")),
            root: Node {
                children: (0..per_panel).map(|index| leaf(panel, index)).collect(),
                child_count: Some(per_panel),
                ..leaf(panel, 0)
            },
        })
        .collect();
    Snapshot {
        id: SnapshotId::fresh(),
        app: Application {
            name: "Shell".into(),
            process_id: Some(4242),
            identifier: Some("org.example.Shell".into()),
            windows,
        },
    }
}

/// Bytes allocated while registering an observation of this size, and bytes still held afterwards.
fn cost(elements: usize) -> (usize, usize) {
    let snapshot = observation(elements);

    let before_tree = live();
    let held_by_tree = {
        let copy = snapshot.clone();
        let size = live() - before_tree;
        drop(copy);
        size
    };

    let mut registry = SemanticNameRegistry::default();
    let before = (allocated(), live());
    registry.register(&snapshot);
    let spent = allocated() - before.0;
    let retained = live() - before.1;

    // Reported as multiples of the observation itself, so the numbers mean the same thing at
    // either size and a failure says how many copies of the tree were made.
    (spent / held_by_tree.max(1), retained / held_by_tree.max(1))
}

#[test]
fn describing_an_observation_costs_a_bounded_number_of_copies_of_it() {
    let small = 250;
    let large = 1_000;

    let (small_spent, small_retained) = cost(small);
    let (large_spent, large_retained) = cost(large);
    println!(
        "{small} elements: {small_spent} copies allocated, {small_retained} retained\n\
         {large} elements: {large_spent} copies allocated, {large_retained} retained"
    );

    // Describing an element legitimately costs a few times what storing it does: a draft name with
    // its lineage, and a locator carrying the element's own text and that of its nearest
    // ancestors. Measured at 13 copies allocated and 3 retained, flat across both sizes. The
    // ceiling is set well clear of that, because what it exists to catch is off by two orders of
    // magnitude -- one copy of the whole tree per element, which is hundreds of copies here.
    let ceiling = 24;
    assert!(
        large_spent <= ceiling,
        "registering a {large}-element observation allocated {large_spent} copies of it \
         (at most {ceiling} expected); the observation is being copied per element"
    );
    assert!(
        large_retained <= ceiling,
        "the registry kept {large_retained} copies of a {large}-element observation \
         (at most {ceiling} expected); a retained copy per element is a leak that survives \
         the request"
    );

    // The scaling statement, which is the one that cannot be satisfied by accident: cost per
    // element must not grow with the number of elements. Quadratic cost would show as a
    // fourfold rise across this fourfold size increase.
    assert!(
        large_spent <= small_spent * 2,
        "cost per element grew from {small_spent} copies at {small} elements to {large_spent} \
         at {large}; describing an observation is scaling worse than linearly in its size"
    );
}
