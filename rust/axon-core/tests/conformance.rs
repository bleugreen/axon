use axon_core::*;
use serde::Deserialize;
use serde_json::{Map, Value, json};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LocatorFixture {
    snapshot: Snapshot,
    cases: Vec<LocatorCase>,
}

#[test]
fn v2_replay_registers_locator_and_strips_recording_metadata() {
    let doc = AxnCodec::parse(include_str!("../fixtures/swift-action-history-v2.yaml")).unwrap();
    let mut dispatcher = Dispatcher {
        calls: vec![],
        fail_at: None,
        registrations: vec![],
    };
    AxnRunner::new(&mut dispatcher)
        .with_source("op", |_: &str| Ok(Some("secret".into())))
        .with_source("env", |_: &str| Ok(Some("/tmp/report".into())))
        .run(
            &doc,
            &serde_json::from_value(json!({"recipient":"test@example.com"})).unwrap(),
            RunOptions {
                dry_run: None,
                continue_on_error: None,
            },
        )
        .unwrap();
    assert_eq!(dispatcher.registrations.len(), 1);
    assert_eq!(dispatcher.registrations[0].0, "Example");
    assert_eq!(dispatcher.registrations[0].1, "submit-button");
    assert_eq!(
        dispatcher.calls[0].1["target"],
        json!({"app":"Example","name":"submit-button"})
    );
}

#[test]
fn v1_and_malformed_v2_targets_are_rejected_for_replay() {
    let v1 = AxnCodec::parse(include_str!("../fixtures/workflow.axn")).unwrap();
    let mut dispatcher = NoDispatch;
    let error = AxnRunner::new(&mut dispatcher)
        .run(
            &v1,
            &Map::new(),
            RunOptions {
                dry_run: None,
                continue_on_error: None,
            },
        )
        .unwrap_err()
        .to_string();
    assert!(error.contains("version 1 targets are obsolete"));
    let malformed = AxnCodec::parse(
        "version: 2\nactions:\n- tool: click\n  target: {app: Example, name: submit}\n",
    )
    .unwrap();
    let error = AxnRunner::new(&mut dispatcher)
        .run(
            &malformed,
            &Map::new(),
            RunOptions {
                dry_run: None,
                continue_on_error: None,
            },
        )
        .unwrap_err()
        .to_string();
    assert!(error.contains("attached locator"));
}

#[test]
fn parameter_validation_is_strict_before_dispatch() {
    let source = r#"{"version":2,"args":[{"name":"token","type":"secret","source":"env://TOKEN"}],"actions":[{"tool":"type","target":{"app":"Example","name":"field","locator":{}},"value":"{{ missing }}"}]}"#;
    let doc = AxnCodec::parse(source).unwrap();
    let mut dispatcher = Dispatcher {
        calls: vec![],
        fail_at: None,
        registrations: vec![],
    };
    let mut runner =
        AxnRunner::new(&mut dispatcher).with_source("env", |_: &str| Ok(Some("secret".into())));
    let error = runner
        .run(
            &doc,
            &Map::new(),
            RunOptions {
                dry_run: None,
                continue_on_error: None,
            },
        )
        .unwrap_err()
        .to_string();
    assert!(error.contains("undeclared arg reference: missing"));
    drop(runner);
    assert!(dispatcher.calls.is_empty());
}

fn replayable_workflow() -> AxnDocument {
    let mut doc = AxnCodec::parse(include_str!("../fixtures/workflow.axn")).unwrap();
    doc.version = 2;
    for action in &mut doc.actions {
        if action.params.contains_key("target") {
            action.params.insert("target".into(), json!({"app":"Example","name":"field","locator":{"role":"AXTextField"},"recording":{"ignored":true}}));
        }
    }
    doc
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AmbiguousDiffFixture {
    baseline: Vec<AmbiguousDiffName>,
    fresh: Vec<AmbiguousDiffName>,
    expected_matched: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AmbiguousDiffName {
    name: String,
    candidate_label: String,
    identity_key: String,
}

#[test]
fn ambiguous_duplicate_order_never_authorizes_identity_pairing() {
    let fixture: AmbiguousDiffFixture = serde_json::from_str(include_str!(
        "../../../schema/fixtures/semantic-diff-ambiguous.json"
    ))
    .unwrap();
    let matched = fixture
        .fresh
        .iter()
        .filter(|fresh| {
            fixture.baseline.iter().any(|baseline| {
                baseline.name == fresh.name
                    && baseline.candidate_label == fresh.candidate_label
                    && baseline.identity_key == fresh.identity_key
            })
        })
        .map(|name| name.candidate_label.clone())
        .collect::<Vec<_>>();
    assert_eq!(matched, fixture.expected_matched);
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LookSinceWireFixture {
    unchanged: String,
    diff: String,
    baseline_expired: String,
    threshold: String,
}

#[test]
fn look_since_response_forms_are_byte_exact() {
    let fixture: LookSinceWireFixture = serde_json::from_str(include_str!(
        "../../../schema/fixtures/look-since-responses.json"
    ))
    .unwrap();
    let observation = Snapshot {
        id: SnapshotId("fixture-1".into()),
        app: Application {
            name: "Fixture".into(),
            identifier: Some("fixture.app".into()),
            windows: vec![],
        },
    };
    let token = SinceToken::new("fixture.app", &observation.id, 7);
    let diff = SemanticDiff {
        added: vec![],
        removed: vec![],
        changed: vec![FieldChange {
            name: "field/search".into(),
            field: "value".into(),
            from: Value::Null,
            to: json!("axon"),
        }],
    };
    let responses = [
        (
            LookSinceResult::unchanged("Fixture", token.clone()),
            fixture.unchanged,
        ),
        (
            LookSinceResult::diff("Fixture", token.clone(), diff),
            fixture.diff,
        ),
        (
            LookSinceResult::fallback(
                "Fixture",
                observation.clone(),
                token.clone(),
                LookFallbackNote::BaselineExpired,
            ),
            fixture.baseline_expired,
        ),
        (
            LookSinceResult::fallback(
                "Fixture",
                observation,
                token,
                LookFallbackNote::DiffExceededThreshold,
            ),
            fixture.threshold,
        ),
    ];
    for (response, expected) in responses {
        assert_eq!(serde_json::to_string(&response).unwrap(), expected);
    }
}

#[test]
fn wire_element_targets_are_strictly_app_scoped_semantic_names() {
    let target: WireElementTarget = serde_json::from_value(json!({
        "app": "Calculator",
        "name": "keypad/seven"
    }))
    .unwrap();
    assert_eq!(target.app, "Calculator");
    assert_eq!(target.name, "keypad/seven");
    assert!(target.validate().is_ok());

    assert!(serde_json::from_value::<WireElementTarget>(json!("s1:12")).is_err());
    assert!(
        serde_json::from_value::<WireElementTarget>(json!({
            "app": "Calculator",
            "locator": {"role": "Button", "title": "7"}
        }))
        .is_err()
    );
    assert!(
        serde_json::from_value::<WireElementTarget>(json!({
            "app": "Calculator",
            "name": "keypad/seven",
            "locator": {"role": "Button"}
        }))
        .is_err()
    );
    assert!(
        WireElementTarget {
            app: " ".into(),
            name: "seven".into()
        }
        .validate()
        .is_err()
    );
    assert!(
        WireElementTarget {
            app: "Calculator".into(),
            name: " ".into()
        }
        .validate()
        .is_err()
    );
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LocatorCase {
    name: String,
    locator: Locator,
    status: ResolutionStatus,
    confidence: Confidence,
    best_index: Option<usize>,
}

#[test]
fn locator_fixture_covers_filtering_scoring_and_explanations() {
    let fixture: LocatorFixture =
        serde_json::from_str(include_str!("../fixtures/locator-cases.json")).unwrap();
    for case in fixture.cases {
        let result = LocatorResolver::resolve(&case.locator, &fixture.snapshot);
        assert_eq!(result.status, case.status, "{} status", case.name);
        assert_eq!(
            result.confidence, case.confidence,
            "{} confidence",
            case.name
        );
        assert_eq!(
            result.best.as_ref().map(|c| c.index),
            case.best_index,
            "{} best",
            case.name
        );
        for candidate in result.candidates {
            assert!(!candidate.reasons.is_empty(), "{} explanation", case.name)
        }
    }
}

#[test]
fn handles_fail_across_snapshot_lifetimes() {
    let fixture: LocatorFixture =
        serde_json::from_str(include_str!("../fixtures/locator-cases.json")).unwrap();
    let handle = fixture.snapshot.handle(2);
    let mut newer = fixture.snapshot.clone();
    newer.id = SnapshotId("fixture-2".into());
    assert!(matches!(
        newer.index_for_handle(&handle),
        Err(HandleError::Stale { .. })
    ));
}

struct Dispatcher {
    calls: Vec<(String, Map<String, Value>)>,
    fail_at: Option<usize>,
    registrations: Vec<(String, String, Locator)>,
}
impl ToolDispatcher for Dispatcher {
    fn register_replay_target(
        &mut self,
        app: &str,
        name: &str,
        locator: &Locator,
    ) -> Result<(), String> {
        self.registrations
            .push((app.into(), name.into(), locator.clone()));
        Ok(())
    }
    fn dispatch(&mut self, tool: &str, params: &Map<String, Value>) -> DispatchOutcome {
        let index = self.calls.len();
        self.calls.push((tool.into(), params.clone()));
        if self.fail_at == Some(index) {
            DispatchOutcome {
                success: false,
                result: Value::Null,
                error: Some("boom".into()),
                resolution: None,
            }
        } else {
            DispatchOutcome {
                success: true,
                result: json!({"ok":true}),
                error: None,
                resolution: None,
            }
        }
    }
    fn verify(&mut self, _fact: &ExpectedFact) -> Result<(), String> {
        Ok(())
    }
}

#[test]
fn axn_round_trip_binding_and_trace_semantics() {
    let doc = replayable_workflow();
    let yaml = AxnCodec::to_yaml(&doc).unwrap();
    assert_eq!(AxnCodec::parse(&yaml).unwrap(), doc);
    let mut dispatcher = Dispatcher {
        calls: vec![],
        fail_at: Some(1),
        registrations: vec![],
    };
    let mut runner = AxnRunner::new(&mut dispatcher).with_source("env", |source: &str| {
        Ok((source == "env://TOKEN").then(|| "s3cr3t".into()))
    });
    let args = serde_json::from_value(json!({"recipient":"ada@example.com"})).unwrap();
    let result = runner
        .run(
            &doc,
            &args,
            RunOptions {
                dry_run: Some(false),
                continue_on_error: Some(false),
            },
        )
        .unwrap();
    assert!(!result.success);
    assert_eq!(result.trace.len(), 2);
    assert_eq!(result.trace[1].index, 1);
    assert_eq!(result.trace[1].tool, "click");
    assert_eq!(result.trace[1].error.as_deref(), Some("boom"));
}

#[test]
fn continue_on_error_preserves_trace_and_secret_is_redacted() {
    let doc = replayable_workflow();
    let mut dispatcher = Dispatcher {
        calls: vec![],
        fail_at: Some(1),
        registrations: vec![],
    };
    let mut runner =
        AxnRunner::new(&mut dispatcher).with_source("env", |_: &str| Ok(Some("s3cr3t".into())));
    let args = serde_json::from_value(json!({"recipient":"ada@example.com"})).unwrap();
    let result = runner
        .run(
            &doc,
            &args,
            RunOptions {
                dry_run: Some(false),
                continue_on_error: Some(true),
            },
        )
        .unwrap();
    assert_eq!(result.trace.len(), 3);
    assert_eq!(
        result.trace[2].result,
        Some(Value::String("<redacted: contains-secret>".into()))
    );
    drop(runner);
    assert_eq!(dispatcher.calls[2].1["value"], "Bearer s3cr3t");
}

#[test]
fn rpc_envelopes_preserve_jsonrpc_and_batch_wire_shape() {
    let response = JsonRpcResponse::success(
        JsonRpcId::Integer(7),
        serde_json::to_value(RunEnvelope {
            batch: json!({"success":true}),
        })
        .unwrap(),
    );
    assert_eq!(
        serde_json::to_value(response).unwrap(),
        json!({"jsonrpc":"2.0","id":7,"result":{"batch":{"success":true}}})
    );
    assert!(
        serde_json::from_value::<JsonRpcResponse>(
            json!({"jsonrpc":"2.0","id":7,"result":{},"error":{"code":-1,"message":"bad"}})
        )
        .is_err()
    );
    assert!(
        serde_json::from_value::<JsonRpcResponse>(json!({"jsonrpc":"2.0","result":{}})).is_err()
    );
    assert!(
        serde_json::from_value::<JsonRpcResponse>(json!({"jsonrpc":"1.0","id":7,"result":{}}))
            .is_err()
    );
}

struct NoDispatch;
impl ToolDispatcher for NoDispatch {
    fn dispatch(&mut self, _tool: &str, _params: &Map<String, Value>) -> DispatchOutcome {
        panic!("dry run dispatched")
    }
    fn verify(&mut self, _fact: &ExpectedFact) -> Result<(), String> {
        panic!("dry run verified")
    }
}

#[test]
fn document_flags_drive_dry_run_without_backend_verification() {
    let mut doc = replayable_workflow();
    doc.flags.insert("dryRun".into(), Value::Bool(true));
    doc.flags
        .insert("continueOnError".into(), Value::Bool(true));
    let mut dispatcher = NoDispatch;
    let mut runner =
        AxnRunner::new(&mut dispatcher).with_source("env", |_: &str| Ok(Some("secret".into())));
    let args = serde_json::from_value(json!({"recipient":"ada@example.com"})).unwrap();
    let result = runner
        .run(
            &doc,
            &args,
            RunOptions {
                dry_run: None,
                continue_on_error: None,
            },
        )
        .unwrap();
    assert!(result.dry_run);
    assert!(result.continue_on_error);
    assert_eq!(result.trace.len(), 3);
    assert!(!result.success);
    assert_eq!(
        result.trace[1].error.as_deref(),
        Some("required fact is unavailable: email.value")
    );
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SemanticFixture {
    snapshot: Snapshot,
    expected: Vec<ExpectedSemanticName>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExpectedSemanticName {
    source_index: usize,
    name: String,
    resolution: SemanticNameResolution,
    candidate_label: Option<String>,
}

#[test]
fn semantic_names_match_the_shared_language_neutral_fixture() {
    let fixture: SemanticFixture =
        serde_json::from_str(include_str!("../../../schema/fixtures/semantic-names.json")).unwrap();
    let actual = SemanticNameDeriver::derive(&fixture.snapshot);
    assert_eq!(actual.len(), fixture.expected.len());
    for expected in fixture.expected {
        let actual = actual
            .iter()
            .find(|name| name.source_index == expected.source_index)
            .unwrap();
        assert_eq!(actual.name, expected.name);
        assert_eq!(actual.resolution, expected.resolution);
        assert_eq!(actual.candidate_label, expected.candidate_label);
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LookScreenshotPolicyFixture {
    default_screenshot: bool,
    carve_outs: Map<String, Value>,
    explicit: Map<String, Value>,
    encoding: ScreenshotEncodingFixture,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScreenshotEncodingFixture {
    max_dimension: u32,
    media_type: String,
    quality: String,
}

#[test]
fn shared_look_screenshot_policy_is_byte_exact() {
    let fixture: LookScreenshotPolicyFixture = serde_json::from_str(include_str!(
        "../../../schema/fixtures/look-screenshot-policy.json"
    ))
    .unwrap();

    assert!(fixture.default_screenshot);
    assert_eq!(fixture.carve_outs["appList"], false);
    assert_eq!(fixture.carve_outs["since"], false);
    assert_eq!(fixture.carve_outs["childPage"], false);
    assert_eq!(fixture.explicit["true"], true);
    assert_eq!(fixture.explicit["false"], false);
    assert_eq!(
        fixture.encoding.max_dimension,
        OBSERVATION_SCREENSHOT_MAX_DIMENSION
    );
    assert_eq!(
        fixture.encoding.media_type,
        OBSERVATION_SCREENSHOT_MEDIA_TYPE
    );
    assert_eq!(fixture.encoding.quality, OBSERVATION_SCREENSHOT_QUALITY);
}

#[test]
fn swift_shaped_semantic_facts_cover_supported_state_vocabulary() {
    let cases = [
        (
            json!({"id":"exists","kind":"exists","target":{"app":"Example","locator":{"role":"AXButton"}}}),
            json!({"exists":true}),
        ),
        (
            json!({"id":"window","kind":"window","target":{"app":"Example","locator":{"role":"AXWindow"}}}),
            json!({"exists":true}),
        ),
        (
            json!({"id":"focused","kind":"focused","target":{"app":"Example","locator":{"role":"AXTextField"}},"state":{"focused":true}}),
            json!({"focused":true}),
        ),
        (
            json!({"id":"enabled","kind":"enabled","target":{"app":"Example","locator":{"role":"AXButton"}},"state":{"enabled":{"equals":false}}}),
            json!({"enabled":false}),
        ),
        (
            json!({"id":"value","kind":"value","target":{"app":"Example","locator":{"role":"AXTextField"}},"state":{"value":{"contains":"HELLO"}}}),
            json!({"value":"hello world"}),
        ),
        (
            json!({"id":"selected","kind":"selected","target":{"app":"Example","locator":{"role":"AXCheckBox"}},"state":{"selected":{"exact":"1","caseSensitive":true}}}),
            json!({"selected":"1"}),
        ),
    ];
    for (fact, observed) in cases {
        let fact: ExpectedFact = serde_json::from_value(fact).unwrap();
        verify_expected_fact_state(&fact, observed.as_object().unwrap()).unwrap();
    }
}

struct SemanticDispatcher {
    states: Vec<Map<String, Value>>,
    cursor: usize,
    dispatched: usize,
    fail_dispatch: bool,
    changed_captures: Vec<Value>,
}
impl ToolDispatcher for SemanticDispatcher {
    fn dispatch(&mut self, _tool: &str, _params: &Map<String, Value>) -> DispatchOutcome {
        self.dispatched += 1;
        DispatchOutcome {
            success: !self.fail_dispatch,
            result: json!({"dispatchOnly":self.fail_dispatch}),
            error: None,
            resolution: None,
        }
    }
    fn verify(&mut self, fact: &ExpectedFact) -> Result<(), String> {
        let state = &self.states[self.cursor.min(self.states.len() - 1)];
        self.cursor += 1;
        verify_expected_fact_state(fact, state)
    }
    fn capture_changed_baseline(&mut self, _fact: &ExpectedFact) -> Result<Value, String> {
        Ok(self.changed_captures.first().cloned().unwrap())
    }
    fn verify_changed(&mut self, fact: &ExpectedFact, baseline: &Value) -> Result<(), String> {
        let current = self.changed_captures.get(1).unwrap();
        (current != baseline)
            .then_some(())
            .ok_or_else(|| format!("fact {} did not verify: app did not change", fact.id))
    }
}

fn semantic_doc(actions: Value) -> AxnDocument {
    serde_json::from_value(json!({"version":2,"actions":actions})).unwrap()
}

#[test]
fn changed_captures_before_dispatch_and_dispatch_only_can_succeed_causally() {
    let doc = semantic_doc(json!([{
        "id":"click","tool":"click","target":{"app":"Example","name":"button","locator":{"role":"AXButton"}},
        "expects":[{"id":"click.changed.1","kind":"changed","target":{"app":"Example","locator":{"role":"AXWindow"}}}]
    }]));
    let mut dispatcher = SemanticDispatcher {
        states: vec![Map::new()],
        cursor: 0,
        dispatched: 0,
        fail_dispatch: true,
        changed_captures: vec![json!({"value":"before"}), json!({"value":"after"})],
    };
    let result = AxnRunner::new(&mut dispatcher)
        .run(
            &doc,
            &Map::new(),
            RunOptions {
                dry_run: Some(false),
                continue_on_error: Some(false),
            },
        )
        .unwrap();
    assert!(result.success);
    assert!(result.trace[0].success);
    assert_eq!(dispatcher.dispatched, 1);
}

#[test]
fn requires_reverifies_the_established_fact_before_dispatch() {
    let fact = json!({"id":"first.value.1","kind":"value","target":{"app":"Example","locator":{"role":"AXTextField"}},"state":{"value":"ready"}});
    let doc = semantic_doc(json!([
        {"tool":"click","target":{"app":"Example","name":"button","locator":{"role":"AXButton"}},"expects":[fact]},
        {"tool":"click","target":{"app":"Example","name":"button","locator":{"role":"AXButton"}},"requires":["first.value.1"]}
    ]));
    let mut dispatcher = SemanticDispatcher {
        states: vec![
            json!({"value":"ready"}).as_object().unwrap().clone(),
            json!({"value":"ready"}).as_object().unwrap().clone(),
            json!({"value":"stale"}).as_object().unwrap().clone(),
        ],
        cursor: 0,
        dispatched: 0,
        fail_dispatch: false,
        changed_captures: vec![],
    };
    let result = AxnRunner::new(&mut dispatcher)
        .run(
            &doc,
            &Map::new(),
            RunOptions {
                dry_run: Some(false),
                continue_on_error: Some(false),
            },
        )
        .unwrap();
    assert!(!result.success);
    assert_eq!(dispatcher.dispatched, 1);
    assert!(
        result.trace[1]
            .error
            .as_deref()
            .unwrap()
            .contains("expectation failed")
    );
}

#[test]
fn expanded_swift_fixture_prepares_every_parameter_type_without_dispatch() {
    let doc = AxnCodec::parse(include_str!("../fixtures/swift-user-recording-v2.yaml")).unwrap();
    let mut dispatcher = NoDispatch;
    let mut runner = AxnRunner::new(&mut dispatcher)
        .with_source("op", |source: &str| {
            Ok((source == "op://Engineering/Axon/token").then(|| "fixture-secret".into()))
        })
        .with_source("env", |source: &str| {
            Ok((source == "env://AXON_REPORT_PATH").then(|| "/tmp/report".into()))
        });
    let args = serde_json::from_value(json!({"recipient":"Ada"})).unwrap();
    let result = runner
        .run(
            &doc,
            &args,
            RunOptions {
                dry_run: Some(true),
                continue_on_error: Some(true),
            },
        )
        .unwrap();
    assert!(result.dry_run);
    assert_eq!(result.trace.len(), 5);
    assert_eq!(
        result.trace[0].result.as_ref().unwrap()["text"],
        "Send /tmp/report/2026-08-12 to Ada <owner@example.com> after 3 tries"
    );
    assert_eq!(
        result.trace[1].result,
        Some(Value::String("<redacted: contains-secret>".into()))
    );
    assert!(result.trace.iter().all(|entry| {
        serde_json::to_string(entry)
            .unwrap()
            .find("fixture-secret")
            .is_none()
    }));
}

#[test]
fn notes_round_trip_but_do_not_dispatch() {
    let doc = AxnCodec::parse(
        "version: 2\nactions:\n- id: n001\n  note: explain this step\n  color: blue\n- tool: keyboard\n  app: Example\n  key: Return\n",
    )
    .unwrap();
    assert_eq!(doc.actions[0].params["color"], "blue");
    let mut dispatcher = NoDispatch;
    let result = AxnRunner::new(&mut dispatcher)
        .run(
            &doc,
            &Map::new(),
            RunOptions {
                dry_run: Some(true),
                continue_on_error: None,
            },
        )
        .unwrap();
    assert_eq!(result.trace.len(), 1);
    assert_eq!(result.trace[0].tool, "keyboard");
}
