//! Conformance between the Rust health model, the published schema, and the shared fixtures.
//!
//! `Tests/AxonCoreTests/HealthStatusTests.swift` runs the equivalent checks against the same
//! files. Both languages parsing the same bytes is what keeps a macOS document and a Linux
//! document one contract rather than two dialects.

use axon_core::{Capability, HEALTH_SCHEMA_VERSION, HealthReport};
use serde_json::Value;
use std::{fs, path::PathBuf};

fn schema_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../schema")
}

fn fixtures() -> Vec<(String, String)> {
    let mut found = fs::read_dir(schema_root().join("fixtures/health"))
        .expect("shared health fixtures directory")
        .filter_map(Result::ok)
        .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "json"))
        .map(|entry| {
            let body = fs::read_to_string(entry.path()).expect("fixture is readable");
            (entry.file_name().to_string_lossy().into_owned(), body)
        })
        .collect::<Vec<_>>();
    found.sort();
    assert!(!found.is_empty(), "expected shared health fixtures");
    found
}

/// The kebab-case shape `$defs/reason` requires. Reason codes are what a consumer branches on, so
/// a typo reaching a fixture would become a contract someone copies.
fn is_kebab_case(value: &str) -> bool {
    !value.is_empty()
        && value.split('-').all(|part| {
            !part.is_empty()
                && part
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        })
}

fn schema() -> Value {
    let body =
        fs::read_to_string(schema_root().join("health-v1.schema.json")).expect("schema file");
    serde_json::from_str(&body).expect("schema parses")
}

#[test]
fn schema_vocabulary_matches_the_capability_enum() {
    let schema = schema();
    let published = schema["$defs"]["knownCapabilities"]["enum"]
        .as_array()
        .expect("knownCapabilities is an enum")
        .iter()
        .map(|value| value.as_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    let implemented = Capability::ALL
        .iter()
        .map(|capability| capability.key().to_owned())
        .collect::<Vec<_>>();

    assert_eq!(published, implemented);
}

#[test]
fn schema_declares_the_supported_major() {
    assert_eq!(
        schema()["properties"]["schemaVersion"]["const"]
            .as_str()
            .unwrap(),
        HEALTH_SCHEMA_VERSION
    );
}

#[test]
fn every_fixture_round_trips_through_the_model() {
    for (name, body) in fixtures() {
        let original: Value = serde_json::from_str(&body).expect(&name);
        let report: HealthReport =
            serde_json::from_str(&body).unwrap_or_else(|error| panic!("{name}: {error}"));
        let encoded = serde_json::to_value(&report).expect(&name);

        // An exact match, not a subset: a field the model silently drops would leave a consumer
        // reading a document the producer never meant to publish.
        assert_eq!(encoded, original, "{name} did not round-trip");
    }
}

#[test]
fn every_fixture_reports_the_complete_capability_vocabulary() {
    for (name, body) in fixtures() {
        let report: HealthReport = serde_json::from_str(&body).expect(&name);
        let reported = report
            .capabilities
            .iter()
            .map(|state| state.capability.as_str())
            .collect::<Vec<_>>();
        let expected = Capability::ALL
            .iter()
            .map(|capability| capability.key())
            .collect::<Vec<_>>();

        assert_eq!(reported, expected, "{name} capability map is incomplete");
    }
}

#[test]
fn every_fixture_reason_code_is_a_stable_kebab_case_token() {
    for (name, body) in fixtures() {
        let report: HealthReport = serde_json::from_str(&body).expect(&name);
        let mut codes = vec![
            report.daemon.reason.clone(),
            report.registration.reason.clone(),
            report.session.reason.clone(),
        ];
        codes.extend(report.permissions.iter().map(|state| state.reason.clone()));
        codes.extend(report.capabilities.iter().map(|state| state.reason.clone()));

        for code in codes.into_iter().flatten() {
            assert!(is_kebab_case(&code), "{name}: reason {code:?} is not kebab-case");
        }
    }
}

#[test]
fn every_fixture_explains_each_unusable_capability() {
    for (name, body) in fixtures() {
        let report: HealthReport = serde_json::from_str(&body).expect(&name);
        for state in report.capabilities.iter().filter(|state| !state.usable) {
            assert!(
                state.reason.is_some(),
                "{name}: {} is unusable without a reason",
                state.capability
            );
        }
    }
}
