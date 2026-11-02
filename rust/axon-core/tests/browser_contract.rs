//! Conformance between the browser verbs' Rust contract and `schema/fixtures/browser`.
//!
//! Those files are the Swift daemon's own output, written by
//! `Tests/AxonCoreTests/BrowserContractConformanceTests.swift`. Here every success body decodes
//! into the Rust types and re-encodes to the same value, every refusal's message and data are
//! what `BrowserError` says, and every URL case gets Foundation's answer. The macOS router tests in
//! `axon-mac` then produce the same bodies end to end from a scripted browser.

use axon_core::{
    BrowserError, BrowserRefusalData, NavigateResult, TabsReport, WindowsReport, browser_url,
    validate_navigation_url,
};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::Value;
use std::{fs, path::PathBuf};

fn fixture(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../schema/fixtures/browser")
        .join(name);
    let body = fs::read_to_string(&path).unwrap_or_else(|error| panic!("{name}: {error}"));
    serde_json::from_str(&body).unwrap_or_else(|error| panic!("{name}: {error}"))
}

/// Decodes `value` and requires it to encode back to exactly itself.
fn round_trip<T: Serialize + DeserializeOwned>(name: &str, value: &Value) -> T {
    let decoded: T = serde_json::from_value(value.clone())
        .unwrap_or_else(|error| panic!("{name} does not decode: {error}"));
    assert_eq!(
        &serde_json::to_value(&decoded).unwrap(),
        value,
        "{name} does not re-encode to itself"
    );
    decoded
}

#[test]
fn navigate_results_round_trip() {
    for (name, success, settled) in [
        ("navigate-verified.json", true, true),
        ("navigate-redirect.json", false, true),
        ("navigate-unsettled.json", true, false),
    ] {
        let result: NavigateResult = round_trip(name, &fixture(name)["result"]);
        assert_eq!(result.navigation.success(), success, "{name}");
        assert_eq!(result.navigation.settled(), settled, "{name}");
    }
}

#[test]
fn windows_and_tabs_results_round_trip() {
    for name in ["windows-matched.json", "windows-partial.json"] {
        round_trip::<WindowsReport>(name, &fixture(name)["result"]);
    }
    let tabs: TabsReport = round_trip("tabs.json", &fixture("tabs.json")["result"]);
    assert_eq!(
        serde_json::to_value(TabsReport::new(tabs.tabs.clone())).unwrap(),
        fixture("tabs.json")["result"],
        "a tab answer always carries the same unavailable cross-check"
    );
}

/// The refusals whose wording is platform-neutral are exactly what `BrowserError` says; the
/// consent refusals' data decodes into the shared type.
#[test]
fn refusals_carry_the_pinned_codes_messages_and_data() {
    for (name, error) in [
        (
            "error-unsupported-app.json",
            BrowserError::UnsupportedApp("Firefox".into()),
        ),
        (
            "error-invalid-url.json",
            BrowserError::InvalidUrl("an absolute http or https URL is required".into()),
        ),
        ("error-invalid-window.json", BrowserError::InvalidWindow(0)),
        (
            "error-not-running.json",
            BrowserError::AppNotRunning("Safari".into()),
        ),
        (
            "error-no-windows.json",
            BrowserError::ExecutionFailed("browser has no windows".into()),
        ),
    ] {
        assert_eq!(
            serde_json::to_value(error.into_rpc()).unwrap(),
            fixture(name)["error"],
            "{name}"
        );
    }
    for name in [
        "error-not-determined-checked.json",
        "error-denied-checked.json",
        "error-denied-executed.json",
    ] {
        let error = &fixture(name)["error"];
        assert_eq!(error["code"], -32603, "{name}");
        round_trip::<BrowserRefusalData>(name, &error["data"]);
    }
}

#[test]
fn url_cases_get_foundations_answers() {
    let cases = fixture("url-cases.json");
    for case in cases["cases"].as_array().unwrap() {
        let input = case["input"].as_str().unwrap();
        let shown: String = input.chars().take(60).collect();
        assert_eq!(
            browser_url::normalized(input),
            case["normalized"].as_str().unwrap(),
            "normalized({shown:?})"
        );
        match validate_navigation_url(input) {
            Ok(()) => assert_eq!(case["valid"], true, "validate({shown:?}) accepted"),
            Err(error) => {
                assert_eq!(case["valid"], false, "validate({shown:?}) refused");
                assert_eq!(
                    error.message(),
                    case["error"].as_str().unwrap(),
                    "validate({shown:?})"
                );
            }
        }
    }
    for pair in cases["equivalence"].as_array().unwrap() {
        let (lhs, rhs) = (pair["lhs"].as_str().unwrap(), pair["rhs"].as_str().unwrap());
        assert_eq!(
            browser_url::equivalent(lhs, rhs),
            pair["equivalent"].as_bool().unwrap(),
            "equivalent({lhs:?}, {rhs:?})"
        );
    }
}
