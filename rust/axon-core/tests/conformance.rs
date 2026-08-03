use axon_core::*;
use serde::Deserialize;
use serde_json::{Map, Value, json};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LocatorFixture {
    snapshot: Snapshot,
    cases: Vec<LocatorCase>,
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
}
impl ToolDispatcher for Dispatcher {
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
    let doc = AxnCodec::parse(include_str!("../fixtures/workflow.axn")).unwrap();
    let yaml = AxnCodec::to_yaml(&doc).unwrap();
    assert_eq!(AxnCodec::parse(&yaml).unwrap(), doc);
    let mut dispatcher = Dispatcher {
        calls: vec![],
        fail_at: Some(1),
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
    let doc = AxnCodec::parse(include_str!("../fixtures/workflow.axn")).unwrap();
    let mut dispatcher = Dispatcher {
        calls: vec![],
        fail_at: Some(1),
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
        serde_json::from_value::<JsonRpcResponse>(
            json!({"jsonrpc":"1.0","id":7,"result":{}})
        )
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
    let mut doc = AxnCodec::parse(include_str!("../fixtures/workflow.axn")).unwrap();
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
