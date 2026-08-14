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
    assert_eq!(
        value[0]["redaction"]["reasons"]["text"],
        "active-credential"
    );
}
