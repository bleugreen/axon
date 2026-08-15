use axon_core::{
    ResolutionStatus, Snapshot, TextLocationResolver, TextLocationSource, TextLocationTarget,
    TextMatcher,
};

/// A Safari-shaped tree: a link with a correct role and frame whose every readable
/// attribute is empty, exactly the node an observation summarises as unreadable.
fn opaque_link_snapshot() -> Snapshot {
    serde_json::from_value(serde_json::json!({
        "id": "text-location-fixture",
        "app": {
            "name": "Example",
            "identifier": "com.example.App",
            "windows": [{
                "title": "Main",
                "root": {
                    "role": "AXWindow",
                    "title": "Main",
                    "frame": {"x": 50.0, "y": 60.0, "width": 500.0, "height": 400.0},
                    "children": [{
                        "role": "AXLink",
                        "frame": {"x": 100.0, "y": 50.0, "width": 80.0, "height": 20.0},
                        "children": []
                    }]
                }
            }]
        }
    }))
    .expect("fixture snapshot parses")
}

fn target(source: TextLocationSource) -> TextLocationTarget {
    TextLocationTarget {
        app: "com.example.App".into(),
        text: TextMatcher::Exact {
            value: "719 comments".into(),
            case_sensitive: false,
        },
        source,
    }
}

#[test]
fn ax_source_counts_opaque_nodes_when_nothing_matches() {
    let snapshot = opaque_link_snapshot();
    let resolution = TextLocationResolver::resolve(&target(TextLocationSource::Ax), &snapshot, &[]);

    assert_eq!(resolution.status, ResolutionStatus::Missing);
    // The window carries a title, so only the link itself is opaque.
    assert_eq!(resolution.opaque_node_count, 1);
}

#[test]
fn screenshot_source_never_pays_for_the_opaque_count() {
    let snapshot = opaque_link_snapshot();
    let resolution =
        TextLocationResolver::resolve(&target(TextLocationSource::Screenshot), &snapshot, &[]);

    assert_eq!(resolution.status, ResolutionStatus::Missing);
    assert_eq!(resolution.opaque_node_count, 0);
}

#[test]
fn a_successful_ax_match_reports_no_opaque_nodes() {
    let mut snapshot = opaque_link_snapshot();
    snapshot.app.windows[0].root.children[0].title = Some("719 comments".into());
    let resolution = TextLocationResolver::resolve(&target(TextLocationSource::Ax), &snapshot, &[]);

    assert_eq!(resolution.status, ResolutionStatus::Unique);
    assert_eq!(resolution.opaque_node_count, 0);
}

#[test]
fn text_in_value_still_matches_after_the_shared_attribute_list_refactor() {
    let mut snapshot = opaque_link_snapshot();
    snapshot.app.windows[0].root.children[0].value = Some("719 comments".into());
    let resolution = TextLocationResolver::resolve(&target(TextLocationSource::Ax), &snapshot, &[]);

    assert_eq!(resolution.status, ResolutionStatus::Unique);
    assert_eq!(
        resolution.best.expect("unique match").reasons[0]
            .split(' ')
            .next(),
        Some("value")
    );
}
