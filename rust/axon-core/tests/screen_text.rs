use axon_core::{ObservationRedactionContext, RecognizedText, format_screen_text};
use serde_json::Value;
use std::{fs, path::PathBuf};

#[test]
fn formatter_matches_shared_screen_text_fixture() {
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../schema/fixtures/screen-text.json");
    let fixture: Value =
        serde_json::from_str(&fs::read_to_string(path).expect("shared screenText fixture"))
            .expect("screenText fixture parses");
    assert_eq!(fixture["maxItems"], 100);
    for case in fixture["cases"].as_array().expect("fixture cases") {
        let recognized: Vec<RecognizedText> =
            serde_json::from_value(case["input"].clone()).expect("recognized text input");
        assert_eq!(
            format_screen_text(
                &recognized,
                case["frames"].as_bool().unwrap(),
                &Default::default()
            ),
            case["expected"],
            "{}",
            case["name"].as_str().unwrap()
        );
    }
}

#[test]
fn deterministic_patterns_are_replaced_at_the_ocr_boundary() {
    let recognized: Vec<RecognizedText> = serde_json::from_value(serde_json::json!([{
        "text": "Contact person@example.com",
        "frame": {"x": 1.0, "y": 2.0, "width": 3.0, "height": 4.0}
    }, {
        "text": "Card 4111 1111 1111 1111",
        "frame": {"x": 1.0, "y": 3.0, "width": 3.0, "height": 4.0}
    }]))
    .unwrap();

    let value = format_screen_text(&recognized, false, &Default::default());
    assert_eq!(value[0]["text"], "<redacted: pii-identifier>");
    assert_eq!(value[1]["text"], "<redacted: financial-data>");
    let serialized = serde_json::to_string(&value).unwrap();
    assert!(!serialized.contains("person@example.com"));
    assert!(!serialized.contains("4111 1111 1111 1111"));
}

#[test]
fn recursive_gate_redacts_nested_active_secrets_patterns_and_sensitive_values() {
    let active_secret = "active-secret-canary";
    let mut observation = serde_json::json!({
        "warning": active_secret,
        "locatorEvidence": {
            "summary": "SSN 123-45-6789",
            "nested": [{
                "role": "AXSecureTextField",
                "title": "Sign in",
                "value": "secure-role-canary",
                "children": [{"label": "API key", "value": "secret-label-canary"}]
            }]
        },
        "unchanged": "ordinary text"
    });
    ObservationRedactionContext::from_active_secrets([active_secret.into()])
        .redact_value(&mut observation);

    assert_eq!(observation["warning"], "<redacted: active-credential>");
    assert_eq!(
        observation["locatorEvidence"]["summary"],
        "<redacted: pii-identifier>"
    );
    assert_eq!(
        observation["locatorEvidence"]["nested"][0]["value"],
        "<redacted: auth-credential>"
    );
    assert_eq!(
        observation["locatorEvidence"]["nested"][0]["children"][0]["value"],
        "<redacted: auth-credential>"
    );
    assert_eq!(observation["unchanged"], "ordinary text");
    let serialized = serde_json::to_string(&observation).unwrap();
    for canary in [
        active_secret,
        "123-45-6789",
        "secure-role-canary",
        "secret-label-canary",
    ] {
        assert!(
            !serialized.contains(canary),
            "raw canary survived: {canary}"
        );
    }
}

#[test]
fn numeric_controls_do_not_treat_luhn_valid_values_as_cards() {
    let mut observation = serde_json::json!({
        "role": "AXSlider",
        "value": "4111111111111111"
    });
    ObservationRedactionContext::default().redact_value(&mut observation);
    assert_eq!(observation["value"], "4111111111111111");
}

#[test]
fn active_secret_text_is_replaced_at_the_observation_boundary() {
    let recognized: Vec<RecognizedText> = serde_json::from_value(serde_json::json!([{
        "text": "configured-secret",
        "frame": {"x": 1.0, "y": 2.0, "width": 3.0, "height": 4.0}
    }]))
    .unwrap();
    let context = ObservationRedactionContext::from_active_secrets(["configured-secret".into()]);
    let value = format_screen_text(&recognized, false, &context);
    let serialized = serde_json::to_string(&value).unwrap();
    assert!(!serialized.contains("configured-secret"));
    assert_eq!(value[0]["text"], "<redacted: active-credential>");
    assert_eq!(value[0].as_object().unwrap().len(), 1);
}
