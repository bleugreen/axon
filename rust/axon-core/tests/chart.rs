use axon_core::*;
use std::{
    fs,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

fn node(title: &str, id: Option<&str>) -> Node {
    Node {
        role: "button".into(),
        subrole: None,
        name: None,
        title: Some(title.into()),
        label: None,
        value: None,
        description: None,
        identifier: id.map(str::to_owned),
        actions: vec!["invoke".into()],
        frame: Some(Rect {
            x: 1234.5,
            y: 2345.6,
            width: 3456.7,
            height: 4567.8,
        }),
        editable: false,
        children: vec![],
        child_count: None,
        truncation_reason: None,
    }
}
fn snapshot(id: &str, children: Vec<Node>) -> Snapshot {
    Snapshot {
        id: SnapshotId(id.into()),
        app: Application {
            name: "App".into(),
            identifier: Some("com.example.app".into()),
            windows: vec![Window {
                title: Some("Main".into()),
                root: Node {
                    role: "window".into(),
                    subrole: None,
                    name: None,
                    title: Some("Main".into()),
                    label: None,
                    value: None,
                    description: None,
                    identifier: None,
                    actions: vec![],
                    frame: None,
                    editable: false,
                    children,
                    child_count: None,
                    truncation_reason: None,
                },
            }],
        },
    }
}
fn directory(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "axon-chart-{label}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}
fn name_for(snapshot: &Snapshot, label: &str) -> String {
    SemanticNameDeriver::derive(snapshot)
        .into_iter()
        .find(|n| n.label == label)
        .unwrap()
        .name
}

#[test]
fn capture_upserts_and_exactly_reconciles_duplicate_identities() {
    let root = directory("reconcile");
    let mut store = ChartStore::new(root.clone());
    let first = snapshot(
        "first",
        vec![node("Share", Some("a")), node("Share", Some("b"))],
    );
    store.confirm_capture("com.example.app", &first, Some("1"), 10);
    let entries = store.chart("com.example.app").entries.clone();
    assert_eq!(entries.len(), 3);
    let duplicate = entries
        .iter()
        .find(|e| e.key.identity_key.contains("a"))
        .unwrap()
        .clone();
    store.record_success("com.example.app", &duplicate.key, 11);

    let reordered = snapshot(
        "second",
        vec![node("Share", Some("b")), node("Share", Some("a"))],
    );
    store.confirm_capture("com.example.app", &reordered, Some("2"), 20);
    let entries = &store.chart("com.example.app").entries;
    let same = entries
        .iter()
        .find(|e| e.key.identity_key == duplicate.key.identity_key)
        .unwrap();
    assert_eq!(
        (
            same.first_seen,
            same.last_seen,
            same.observations,
            same.resolution_successes
        ),
        (10, 20, 2, 1)
    );
    assert_eq!(same.last_confirmed_app_version.as_deref(), Some("2"));

    let changed = snapshot(
        "third",
        vec![node("Share", Some("c")), node("Share", Some("b"))],
    );
    store.confirm_capture("com.example.app", &changed, Some("2"), 30);
    let entries = &store.chart("com.example.app").entries;
    let replacement = entries
        .iter()
        .find(|e| e.key.identity_key.contains("c"))
        .unwrap();
    assert_eq!(
        (
            replacement.first_seen,
            replacement.observations,
            replacement.resolution_successes
        ),
        (30, 1, 0)
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn confidence_is_deterministic_monotonic_and_hysteretic() {
    let locator = ChartLocator::from(&Locator::default());
    let mut element = ChartElement {
        key: ChartKey {
            name: "a/b/c".into(),
            candidate_ordinal: None,
            identity_key: "id".into(),
        },
        role: "button".into(),
        label: "Save".into(),
        locator,
        first_seen: 0,
        last_seen: 0,
        last_confirmed_app_version: Some("1".into()),
        observations: 1,
        resolution_successes: 0,
        resolution_failures: 0,
    };
    let initial = confidence(&element, 0, Some("1"));
    element.observations = 2;
    assert!(confidence(&element, 0, Some("1")) > initial);
    let fresh = confidence(&element, 0, Some("1"));
    assert!((confidence(&element, 90 * 86_400, Some("1")) - fresh / 2.0).abs() < 1e-12);
    assert!((confidence(&element, 0, Some("2")) - fresh / 2.0).abs() < 1e-12);
    assert_eq!(confidence(&element, 0, None), fresh);
    element.resolution_failures = 2;
    let failed = confidence(&element, 0, Some("1"));
    assert!(failed < fresh);
    element.resolution_successes = 4;
    assert!(confidence(&element, 0, Some("1")) > failed);
    assert!(confidence(&element, 365 * 86_400, Some("1")) < SEED_CONFIDENCE_FLOOR);
    assert!(confidence(&element, 1_000 * 86_400, Some("1")) < EVICTION_CONFIDENCE_FLOOR);
    assert_eq!(
        confidence(&element, 0, Some("1")),
        confidence(&element, 0, Some("1"))
    );
}

#[test]
fn persistence_is_private_total_deterministic_and_per_app() {
    let root = directory("persistence");
    let mut sensitive = node("Save", Some("save"));
    sensitive.value = Some("SECRET_TEXT_FIELD_SENTINEL".into());
    let capture = snapshot("capture", vec![sensitive]);
    let mut store = ChartStore::new(root.clone());
    store.confirm_capture("com.example.app", &capture, Some("1"), 10);
    store.save("com.example.app", 10, Some("1"));
    let path = store.chart_path("com.example.app");
    let bytes = fs::read(&path).unwrap();
    let json = String::from_utf8(bytes.clone()).unwrap();
    assert!(!json.contains("SECRET_TEXT_FIELD_SENTINEL"));
    assert!(!json.contains("\"value\"") && !json.contains("\"frame\""));
    let mut loaded = ChartStore::new(root.clone());
    let chart = loaded.load("com.example.app");
    loaded.save("com.example.app", 10, Some("1"));
    assert_eq!(chart, loaded.chart("com.example.app").clone());
    assert_eq!(bytes, fs::read(path).unwrap());
    assert_ne!(
        loaded.chart_path("../evil"),
        loaded.chart_path("com.example.app")
    );

    fs::write(loaded.chart_path("broken"), b"{bad").unwrap();
    assert!(loaded.load("broken").entries.is_empty());
    let mut wrong = chart;
    wrong.app_identity = "other".into();
    fs::write(
        loaded.chart_path("mismatch"),
        serde_json::to_vec(&wrong).unwrap(),
    )
    .unwrap();
    assert!(loaded.load("mismatch").entries.is_empty());
    wrong.schema_version = 99;
    wrong.app_identity = "version".into();
    fs::write(
        loaded.chart_path("version"),
        serde_json::to_vec(&wrong).unwrap(),
    )
    .unwrap();
    assert!(loaded.load("version").entries.is_empty());
    assert!(loaded.load("missing").entries.is_empty());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn cold_resolution_records_outcomes_and_retained_evidence_bypasses_chart() {
    let root = directory("resolve");
    let observed = snapshot("old", vec![node("Save", Some("save"))]);
    let name = name_for(&observed, "Save");
    let mut store = ChartStore::new(root.clone());
    store.confirm_capture("com.example.app", &observed, Some("1"), 10);
    let key = store
        .chart("com.example.app")
        .entries
        .iter()
        .find(|e| e.key.name == name)
        .unwrap()
        .key
        .clone();
    let empty_registry = SemanticNameRegistry::default();
    let live = snapshot(
        "live",
        vec![node("Other", None), node("Save", Some("save"))],
    );
    match ChartSeededResolver::new(&empty_registry, &mut store).resolve(
        &WireElementTarget {
            app: "com.example.app".into(),
            name: name.clone(),
        },
        &live,
        "com.example.app",
        Some("1"),
        11,
    ) {
        SemanticLookup::Unique { handle, .. } => assert_eq!(handle, live.handle(2)),
        _ => panic!("cold chart seed did not resolve"),
    }
    assert_eq!(
        store
            .chart("com.example.app")
            .entries
            .iter()
            .find(|e| e.key == key)
            .unwrap()
            .resolution_successes,
        1
    );

    let missing = snapshot("missing", vec![node("Other", None)]);
    let _ = ChartSeededResolver::new(&empty_registry, &mut store).resolve(
        &WireElementTarget {
            app: "com.example.app".into(),
            name: name.clone(),
        },
        &missing,
        "com.example.app",
        Some("1"),
        12,
    );
    assert_eq!(
        store
            .chart("com.example.app")
            .entries
            .iter()
            .find(|e| e.key == key)
            .unwrap()
            .resolution_failures,
        1
    );

    let mut retained = SemanticNameRegistry::default();
    retained.register(&observed);
    let before = store.chart("com.example.app").entries.clone();
    let _ = ChartSeededResolver::new(&retained, &mut store).resolve(
        &WireElementTarget {
            app: "com.example.app".into(),
            name,
        },
        &missing,
        "com.example.app",
        Some("1"),
        13,
    );
    assert_eq!(before, store.chart("com.example.app").entries);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn duplicate_chart_seeds_remain_ambiguous_even_when_only_one_matches() {
    let root = directory("duplicates");
    let observed = snapshot("old", vec![node("Share", None), node("Share", None)]);
    let name = name_for(&observed, "Share");
    let mut store = ChartStore::new(root.clone());
    store.confirm_capture("com.example.app", &observed, None, 10);
    let registry = SemanticNameRegistry::default();
    let live = snapshot("live", vec![node("Share", Some("a"))]);
    match ChartSeededResolver::new(&registry, &mut store).resolve(
        &WireElementTarget {
            app: "App".into(),
            name,
        },
        &live,
        "com.example.app",
        None,
        11,
    ) {
        SemanticLookup::Ambiguous { .. } => {}
        _ => panic!("duplicate chart entries manufactured uniqueness"),
    }
    let duplicate_entries: Vec<_> = store
        .chart("com.example.app")
        .entries
        .iter()
        .filter(|e| e.key.candidate_ordinal.is_some())
        .collect();
    assert_eq!(duplicate_entries.len(), 2);
    assert!(duplicate_entries.iter().all(|e| e.resolution_failures == 1));
    let _ = fs::remove_dir_all(root);
}
