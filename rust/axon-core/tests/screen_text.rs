use axon_core::{RecognizedText, format_screen_text};
use serde_json::Value;
use std::{fs, path::PathBuf};

#[test]
fn formatter_matches_shared_screen_text_fixture() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../schema/fixtures/screen-text.json");
    let fixture: Value = serde_json::from_str(&fs::read_to_string(path).expect("shared screenText fixture")).expect("screenText fixture parses");
    assert_eq!(fixture["maxItems"], 100);
    for case in fixture["cases"].as_array().expect("fixture cases") {
        let recognized: Vec<RecognizedText> = serde_json::from_value(case["input"].clone()).expect("recognized text input");
        assert_eq!(format_screen_text(&recognized, case["frames"].as_bool().unwrap()), case["expected"], "{}", case["name"].as_str().unwrap());
    }
}
