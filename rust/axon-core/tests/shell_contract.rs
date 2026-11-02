//! Conformance between the daemon's shell-v1 types and `schema/fixtures/shell`.
//!
//! The macOS menu shell is Swift and the daemon is Rust, and they meet only on the socket.
//! `Tests/AxonClientTests/ShellContractConformanceTests.swift` decodes these same files into the
//! shell's models, so both languages agreeing on these bytes is what makes shell-v1 one contract.
//! Each fixture is produced here by the code path the daemon actually answers with, not written
//! by hand, except the two requests, which are what the shell sends.
//!
//! The macOS-only shapes (the Accessibility refusal and the consent service's answers) are pinned
//! by tests in `axon-mac`, which owns the code that produces them.
//!
//! After a deliberate contract change, `AXON_BLESS_SHELL_FIXTURES=1 cargo test -p axon-core --test
//! shell_contract` rewrites the files; the Swift conformance test then says whether the shell
//! still reads them.

use axon_core::{
    AccessibilityTrust, AutomationAuthorization, AutomationLeg, AutomationRequestReport,
    AutomationStatusReport, BrowserConsentState, Capability, CapabilityInfo, CapabilityState,
    ConsentNeed, ConsentOutcome, DaemonProvenance, DaemonRecordingOwner, DaemonReport,
    HealthPlatform, JsonRpcError, JsonRpcRequest, PermissionState, PermitResult,
    RecordedUserAction, RecordedUserEventGroup, RecordingResult, RecordingStatus,
    SHELL_CONTRACT_VERSION, SessionHealth, consent_in_progress,
};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Map, Value};
use std::{fs, path::PathBuf};

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../schema/fixtures/shell")
        .join(name)
}

fn fixture(name: &str) -> Value {
    let body =
        fs::read_to_string(fixture_path(name)).unwrap_or_else(|error| panic!("{name}: {error}"));
    serde_json::from_str(&body).unwrap_or_else(|error| panic!("{name}: {error}"))
}

/// Requires `produced` to serialize to exactly the fixture, and the fixture to decode back into the
/// same value. An exact match, not a subset: a field one side drops is a contract the other side
/// was never told about.
fn pin<T: Serialize + DeserializeOwned + PartialEq + std::fmt::Debug>(name: &str, produced: &T) {
    let encoded = serde_json::to_value(produced).unwrap();
    if std::env::var_os("AXON_BLESS_SHELL_FIXTURES").is_some() {
        let mut body = serde_json::to_string_pretty(&encoded).unwrap();
        body.push('\n');
        fs::create_dir_all(fixture_path(name).parent().unwrap()).unwrap();
        fs::write(fixture_path(name), body).unwrap();
    }
    assert_eq!(
        encoded,
        fixture(name),
        "{name} does not match what the daemon answers"
    );
    let decoded: T = serde_json::from_value(fixture(name)).unwrap();
    assert_eq!(
        &decoded, produced,
        "{name} does not decode to what was produced"
    );
}

fn params(request: &str) -> Map<String, Value> {
    let request: JsonRpcRequest = serde_json::from_value(fixture(request)).unwrap();
    request.params.unwrap().as_object().unwrap().clone()
}

#[test]
fn daemon_report_carries_the_shell_contract_version() {
    let reported = Capability::ALL
        .iter()
        .map(|capability| CapabilityInfo {
            capability: *capability,
            usable: true,
            restriction: None,
        })
        .collect::<Vec<_>>();
    let report = DaemonReport {
        version: "0.4.0".into(),
        platform: HealthPlatform::Macos,
        ready: true,
        process_id: 4242,
        endpoint: "/tmp/axon.sock".into(),
        provenance: Some(DaemonProvenance {
            backend: "rust-axon-mac".into(),
            process_id: 4242,
            executable_path: "/Applications/Axon.app/Contents/MacOS/Axon".into(),
            version: "0.4.0".into(),
        }),
        shell_contract: Some(SHELL_CONTRACT_VERSION),
        session: SessionHealth::usable(None),
        permissions: vec![
            PermissionState::granted("accessibility"),
            PermissionState::granted("screenRecording"),
        ],
        capabilities: CapabilityState::complete(&reported),
    };
    pin("daemon-report.json", &report);
    assert_eq!(fixture("daemon-report.json")["shellContract"], 1);
}

#[test]
fn the_shell_requests_are_accepted_and_produce_the_pinned_statuses() {
    for request in [
        "recording-start-application.request.json",
        "recording-start-all.request.json",
    ] {
        let parsed: JsonRpcRequest = serde_json::from_value(fixture(request)).unwrap();
        assert_eq!(parsed.method, "recording.start", "{request}");
        assert_eq!(
            serde_json::to_value(&parsed).unwrap(),
            fixture(request),
            "{request}"
        );
    }

    let mut owner = DaemonRecordingOwner::default();
    pin("recording-status-idle.json", &owner.status());
    let started = owner
        .start(&params("recording-start-application.request.json"))
        .unwrap();
    assert_eq!(started, owner.status());
    pin("recording-status-application.json", &owner.status());

    let mut all = DaemonRecordingOwner::default();
    all.start(&params("recording-start-all.request.json"))
        .unwrap();
    assert!(all.status().recording);
    assert!(all.status().destination.is_none());
}

#[test]
fn editor_started_recordings_carry_their_destination() {
    let mut owner = DaemonRecordingOwner::default();
    let mut from_here = Map::new();
    from_here.insert("documentId".into(), "doc-7F3A".into());
    from_here.insert("beforeBlockId".into(), "block-12".into());
    owner.record_from_here(&from_here).unwrap();
    pin("recording-status-editor.json", &owner.status());
}

#[test]
fn stop_returns_the_authored_script() {
    let mut owner = DaemonRecordingOwner::default();
    owner
        .start(&params("recording-start-application.request.json"))
        .unwrap();
    owner
        .push_group(RecordedUserEventGroup::new(RecordedUserAction::TypeText {
            app: "Calculator".into(),
            text: "12".into(),
        }))
        .unwrap();
    let stopped: RecordingResult =
        serde_json::from_value(owner.stop(&Map::new()).unwrap()).unwrap();
    assert_eq!(stopped.action_count, 1);
    assert!(stopped.destination.is_none());
    pin("recording-stop.json", &stopped);
    // `destination` is routed on, so it is present as null rather than absent.
    assert!(
        fixture("recording-stop.json")
            .as_object()
            .unwrap()
            .contains_key("destination")
    );
}

#[test]
fn recording_conflicts_are_typed() {
    let mut owner = DaemonRecordingOwner::default();
    let inactive = owner.stop(&Map::new()).unwrap_err();
    pin("error-recording-inactive.json", &inactive);
    owner
        .start(&params("recording-start-all.request.json"))
        .unwrap();
    let active = owner
        .start(&params("recording-start-all.request.json"))
        .unwrap_err();
    pin("error-recording-active.json", &active);
    for error in [&inactive, &active] {
        assert_eq!(error.code, -32005);
    }
}

#[test]
fn permit_reports_trust_after_prompting() {
    pin(
        "permit.json",
        &PermitResult {
            accessibility: AccessibilityTrust::Trusted,
            prompted: true,
        },
    );
}

#[test]
fn automation_shapes_round_trip() {
    pin(
        "automation-status.json",
        &AutomationStatusReport {
            need: ConsentNeed::Request,
            browsers: vec![
                BrowserConsentState {
                    app: "Safari".into(),
                    bundle_identifier: "com.apple.Safari".into(),
                    running: true,
                    status: Some(AutomationAuthorization::NotDetermined),
                    leg: Some(AutomationLeg::Checked),
                    detail: None,
                },
                BrowserConsentState {
                    app: "Google Chrome".into(),
                    bundle_identifier: "com.google.Chrome".into(),
                    running: false,
                    status: None,
                    leg: None,
                    detail: None,
                },
            ],
        },
    );
    pin(
        "automation-request.json",
        &AutomationRequestReport {
            need: ConsentNeed::None,
            outcomes: vec![ConsentOutcome {
                app: "Safari".into(),
                bundle_identifier: "com.apple.Safari".into(),
                granted: true,
                detail: None,
            }],
        },
    );
    pin(
        "automation-request-no-browser.json",
        &AutomationRequestReport {
            need: ConsentNeed::None,
            outcomes: vec![],
        },
    );
    let in_progress: JsonRpcError = consent_in_progress();
    pin("error-consent-in-progress.json", &in_progress);
    assert_eq!(in_progress.code, -32005);
}

#[test]
fn the_status_fixture_is_a_recording_status() {
    for name in [
        "recording-status-idle.json",
        "recording-status-application.json",
        "recording-status-editor.json",
    ] {
        let _: RecordingStatus = serde_json::from_value(fixture(name)).unwrap();
    }
}
