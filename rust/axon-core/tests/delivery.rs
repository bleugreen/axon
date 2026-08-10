//! Conformance between the Rust delivery contract and the shared fixtures.
//!
//! `Tests/AxonCoreTests/SharedDeliveryConformanceTests.swift` runs the equivalent checks against
//! the same files. Both languages parsing the same bytes is what keeps a macOS refusal and a
//! Windows refusal one contract rather than two dialects.

use axon_core::{
    DeliveryCandidate, DeliveryCapability, DeliveryOutcome, DeliveryPolicy, DeliveryRefusal,
    DeliveryRefusalReason, DeliveryRung, DeliverySelection, ForegroundCleanup, select_delivery,
};
use serde_json::{Map, Value, json};
use std::{fs, path::PathBuf};

fn fixture(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../schema/fixtures/delivery")
        .join(name);
    serde_json::from_str(&fs::read_to_string(&path).expect("shared delivery fixture"))
        .expect("delivery fixture parses as JSON")
}

fn strings(value: &Value, key: &str) -> Vec<String> {
    value[key]
        .as_array()
        .unwrap_or_else(|| panic!("fixture key {key} is an array"))
        .iter()
        .map(|entry| {
            entry
                .as_str()
                .expect("fixture entry is a string")
                .to_string()
        })
        .collect()
}

#[test]
fn wire_vocabulary_matches_the_shared_fixture_in_canonical_order() {
    let vocabulary = fixture("vocabulary.json");

    let policies: Vec<String> = DeliveryPolicy::ALL
        .iter()
        .map(|policy| policy.key().to_string())
        .collect();
    assert_eq!(policies, strings(&vocabulary, "policies"));
    assert_eq!(
        DeliveryPolicy::default().key(),
        vocabulary["defaultPolicy"].as_str().unwrap()
    );

    let rungs: Vec<String> = DeliveryRung::ALL
        .iter()
        .map(|rung| rung.key().to_string())
        .collect();
    assert_eq!(rungs, strings(&vocabulary, "rungs"));

    let capabilities: Vec<String> = DeliveryCapability::ALL
        .iter()
        .map(|capability| capability.key().to_string())
        .collect();
    assert_eq!(capabilities, strings(&vocabulary, "capabilities"));

    let forbidden: Vec<String> = DeliveryCapability::ALL
        .iter()
        .filter(|capability| capability.is_forbidden())
        .map(|capability| capability.key().to_string())
        .collect();
    assert_eq!(forbidden, strings(&vocabulary, "forbiddenCapabilities"));

    let reasons: Vec<String> = DeliveryRefusalReason::ALL
        .iter()
        .map(|reason| reason.key().to_string())
        .collect();
    assert_eq!(reasons, strings(&vocabulary, "refusalReasons"));
}

#[test]
fn every_vocabulary_value_round_trips_through_serde_camel_case() {
    for policy in DeliveryPolicy::ALL {
        assert_eq!(json!(policy), json!(policy.key()));
        assert_eq!(
            serde_json::from_value::<DeliveryPolicy>(json!(policy.key())).unwrap(),
            policy
        );
    }
    for rung in DeliveryRung::ALL {
        assert_eq!(json!(rung), json!(rung.key()));
        assert_eq!(
            serde_json::from_value::<DeliveryRung>(json!(rung.key())).unwrap(),
            rung
        );
    }
    for capability in DeliveryCapability::ALL {
        assert_eq!(json!(capability), json!(capability.key()));
    }
    for reason in DeliveryRefusalReason::ALL {
        assert_eq!(json!(reason), json!(reason.key()));
    }
}

#[test]
fn every_fixture_result_case_round_trips_through_the_outcome_envelope() {
    for case in fixture("results.json")["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let policy: DeliveryPolicy =
            serde_json::from_value(case["deliveryPolicy"].clone()).unwrap();
        let delivery: Option<DeliveryRung> =
            serde_json::from_value(case["delivery"].clone()).unwrap();
        let refusal: Option<DeliveryRefusal> =
            serde_json::from_value(case["refusal"].clone()).unwrap();

        let outcome = DeliveryOutcome {
            policy,
            delivery,
            dispatch_success: case["dispatchSuccess"].as_bool().unwrap(),
            refusal: refusal.clone(),
        };
        let mut object = Map::new();
        outcome.merge_into(&mut object);

        assert_eq!(object["deliveryPolicy"], case["deliveryPolicy"], "{name}");
        assert_eq!(object["delivery"], case["delivery"], "{name}");
        assert_eq!(object["dispatchSuccess"], case["dispatchSuccess"], "{name}");
        assert_eq!(object["refusal"], case["refusal"], "{name}");

        // A refusal is decided before the mechanism it names acts, so it can never claim a rung.
        if refusal.is_some() && case["delivery"].is_null() {
            assert!(!outcome.dispatch_success, "{name} dispatch");
        }

        if let Some(foreground) = case.get("foreground") {
            let cleanup: ForegroundCleanup = serde_json::from_value(foreground.clone()).unwrap();
            assert_eq!(
                &serde_json::to_value(&cleanup).unwrap(),
                foreground,
                "{name}"
            );
        }
    }
}

fn semantic() -> DeliveryCandidate {
    DeliveryCandidate::available(
        DeliveryRung::Semantic,
        DeliveryCapability::SemanticAction,
        "UIA Invoke",
    )
}

fn pixel() -> DeliveryCandidate {
    DeliveryCandidate::available(
        DeliveryRung::Pixel,
        DeliveryCapability::BackgroundPixelInput,
        "HWND client message",
    )
}

fn foreground() -> DeliveryCandidate {
    DeliveryCandidate::available(
        DeliveryRung::Foreground,
        DeliveryCapability::GlobalInput,
        "SendInput",
    )
}

#[test]
fn planner_takes_the_lowest_rung_the_policy_and_runtime_allow() {
    let ladder = [semantic(), pixel(), foreground()];
    assert_eq!(
        select_delivery(&ladder, DeliveryPolicy::BackgroundOnly, None),
        DeliverySelection::Candidate(semantic())
    );
    assert_eq!(
        select_delivery(
            &ladder,
            DeliveryPolicy::BackgroundOnly,
            Some(DeliveryRung::Semantic)
        ),
        DeliverySelection::Candidate(pixel())
    );
    // foregroundPermitted widens the ceiling; it does not skip the quieter rungs.
    assert_eq!(
        select_delivery(&ladder, DeliveryPolicy::ForegroundPermitted, None),
        DeliverySelection::Candidate(semantic())
    );
    assert_eq!(
        select_delivery(
            &ladder,
            DeliveryPolicy::ForegroundPermitted,
            Some(DeliveryRung::Pixel)
        ),
        DeliverySelection::Candidate(foreground())
    );
}

#[test]
fn planner_refuses_the_foreground_rung_under_background_only() {
    let DeliverySelection::Refusal(refusal) = select_delivery(
        &[semantic(), pixel(), foreground()],
        DeliveryPolicy::BackgroundOnly,
        Some(DeliveryRung::Pixel),
    ) else {
        panic!("expected a refusal once only the foreground rung remained")
    };
    assert_eq!(
        refusal.reason,
        DeliveryRefusalReason::ForegroundNotPermitted
    );
    assert_eq!(refusal.required_rung, DeliveryRung::Foreground);
    assert_eq!(refusal.capability, Some(DeliveryCapability::GlobalInput));
}

#[test]
fn planner_reports_the_policy_boundary_ahead_of_a_lower_capability_gap() {
    let unbound = DeliveryCandidate::unavailable(
        DeliveryRung::Pixel,
        DeliveryCapability::BackgroundPixelInput,
        "HWND client message",
        DeliveryRefusalReason::BackgroundPixelUnsupported,
        "the control requires global input",
    );

    let DeliverySelection::Refusal(blocked) = select_delivery(
        &[unbound.clone(), foreground()],
        DeliveryPolicy::BackgroundOnly,
        None,
    ) else {
        panic!("expected a refusal when neither rung is usable")
    };
    assert_eq!(
        blocked.reason,
        DeliveryRefusalReason::ForegroundNotPermitted
    );

    let DeliverySelection::Refusal(gap) =
        select_delivery(&[unbound], DeliveryPolicy::ForegroundPermitted, None)
    else {
        panic!("expected a refusal when the only rung is unavailable")
    };
    assert_eq!(
        gap.reason,
        DeliveryRefusalReason::BackgroundPixelUnsupported
    );
    assert_eq!(gap.message, "the control requires global input");
}

#[test]
fn a_reported_refusal_carries_every_obstacle_the_ladder_walked_past() {
    // The pixel rung's obstacle is the product of the platform's own evidence work — the toolkit
    // and version that declined — and it is the only thing that answers "would the quiet rung ever
    // work against this target". Whichever reason wins the ranking, that sentence has to survive.
    let toolkit_refused = DeliveryCandidate::unavailable(
        DeliveryRung::Pixel,
        DeliveryCapability::BackgroundPixelInput,
        "XSendEvent",
        DeliveryRefusalReason::BackgroundPixelUnsupported,
        "the target application reports AT-SPI toolkit gtk 3.24.51, which does not accept a click \
         in the background",
    );
    let obstacle = axon_core::DeliveryObstacle {
        rung: DeliveryRung::Pixel,
        reason: DeliveryRefusalReason::BackgroundPixelUnsupported,
        message:
            "the target application reports AT-SPI toolkit gtk 3.24.51, which does not accept \
                  a click in the background"
                .into(),
    };

    // The policy boundary outranks the capability gap below it, and the gap still travels.
    let DeliverySelection::Refusal(policy_bound) = select_delivery(
        &[toolkit_refused.clone(), foreground()],
        DeliveryPolicy::BackgroundOnly,
        None,
    ) else {
        panic!("expected a refusal when the pixel rung is out and the policy forbids foreground")
    };
    assert_eq!(
        policy_bound.reason,
        DeliveryRefusalReason::ForegroundNotPermitted
    );
    assert_eq!(policy_bound.also_refused, vec![obstacle.clone()]);

    // Same ladder on a backend with no foreground mechanism at all: a different winning reason,
    // the same evidence underneath it.
    let no_global_input = DeliveryCandidate::unavailable(
        DeliveryRung::Foreground,
        DeliveryCapability::GlobalInput,
        "XTest",
        DeliveryRefusalReason::NoDeliveryCandidate,
        "this session exposes no global input device",
    );
    let DeliverySelection::Refusal(no_mechanism) = select_delivery(
        &[toolkit_refused, no_global_input],
        DeliveryPolicy::ForegroundPermitted,
        None,
    ) else {
        panic!("expected a refusal when neither rung exists")
    };
    assert_eq!(
        no_mechanism.reason,
        DeliveryRefusalReason::NoDeliveryCandidate
    );
    assert_eq!(no_mechanism.also_refused, vec![obstacle]);

    // The reported refusal is never also listed as one of the ones walked past.
    for refusal in [policy_bound, no_mechanism] {
        assert!(
            !refusal
                .also_refused
                .iter()
                .any(|other| other.message == refusal.message),
            "the winning refusal must not be duplicated in alsoRefused"
        );
    }
}

#[test]
fn a_refusal_with_nothing_below_it_reports_no_obstacles() {
    let DeliverySelection::Refusal(empty_ladder) =
        select_delivery(&[], DeliveryPolicy::ForegroundPermitted, None)
    else {
        panic!("an action with no mechanism cannot be delivered")
    };
    assert!(empty_ladder.also_refused.is_empty());

    let DeliverySelection::Refusal(only_rung) = select_delivery(
        &[foreground()],
        DeliveryPolicy::BackgroundOnly,
        Some(DeliveryRung::Pixel),
    ) else {
        panic!("the foreground rung is refused under backgroundOnly")
    };
    assert!(only_rung.also_refused.is_empty());
}

#[test]
fn an_obstacle_reaches_the_caller_through_the_refusal_result_envelope() {
    let DeliverySelection::Refusal(refusal) = select_delivery(
        &[
            DeliveryCandidate::unavailable(
                DeliveryRung::Pixel,
                DeliveryCapability::BackgroundPixelInput,
                "HWND client message",
                DeliveryRefusalReason::BackgroundPixelUnsupported,
                "window class Widget has no probe-verified client-coordinate message path",
            ),
            foreground(),
        ],
        DeliveryPolicy::BackgroundOnly,
        None,
    ) else {
        panic!("expected a refusal")
    };

    let result = DeliveryOutcome::refusal_result(DeliveryPolicy::BackgroundOnly, refusal);

    // The top-level message stays the winning reason's: it is what this caller can act on.
    assert_eq!(result["refusal"]["reason"], json!("foregroundNotPermitted"));
    let also = &result["refusal"]["alsoRefused"];
    assert_eq!(also[0]["rung"], json!("pixel"));
    assert_eq!(also[0]["reason"], json!("backgroundPixelUnsupported"));
    assert_eq!(
        also[0]["message"],
        json!("window class Widget has no probe-verified client-coordinate message path")
    );
}

#[test]
fn planner_never_offers_an_opt_in_to_a_mechanism_the_runtime_does_not_have() {
    // Reporting foregroundNotPermitted here would tell the caller to opt in to global input this
    // backend cannot produce, sending them after a permission that changes nothing.
    let missing = DeliveryCandidate::unavailable(
        DeliveryRung::Foreground,
        DeliveryCapability::GlobalInput,
        "XTest",
        DeliveryRefusalReason::NoDeliveryCandidate,
        "this session exposes no global input device",
    );

    for policy in DeliveryPolicy::ALL {
        let DeliverySelection::Refusal(refusal) =
            select_delivery(std::slice::from_ref(&missing), policy, None)
        else {
            panic!("a missing mechanism cannot be selected under {policy:?}")
        };
        assert_eq!(refusal.reason, DeliveryRefusalReason::NoDeliveryCandidate);
        assert_eq!(refusal.required_rung, DeliveryRung::Foreground);
        assert_eq!(
            refusal.message,
            "this session exposes no global input device"
        );
    }
}

#[test]
fn planner_never_selects_a_clipboard_candidate_at_any_policy() {
    let clipboard = DeliveryCandidate::available(
        DeliveryRung::Pixel,
        DeliveryCapability::Clipboard,
        "clipboard paste",
    );
    assert!(!clipboard.is_available());

    for policy in DeliveryPolicy::ALL {
        let DeliverySelection::Refusal(refusal) =
            select_delivery(std::slice::from_ref(&clipboard), policy, None)
        else {
            panic!("clipboard delivery must never be selected, including under {policy:?}")
        };
        assert_eq!(refusal.reason, DeliveryRefusalReason::ClipboardForbidden);
        assert_eq!(refusal.capability, Some(DeliveryCapability::Clipboard));
    }
}

#[test]
fn planner_refuses_an_empty_ladder_without_inventing_a_reason() {
    let DeliverySelection::Refusal(refusal) =
        select_delivery(&[], DeliveryPolicy::ForegroundPermitted, None)
    else {
        panic!("an action with no mechanism cannot be delivered")
    };
    assert_eq!(refusal.reason, DeliveryRefusalReason::NoDeliveryCandidate);
    assert_eq!(refusal.capability, None);
}

#[test]
fn omitted_policy_defaults_to_background_only_and_invalid_values_fail() {
    let empty = Map::new();
    assert_eq!(
        DeliveryPolicy::from_params(&empty).unwrap(),
        DeliveryPolicy::BackgroundOnly
    );

    let mut explicit = Map::new();
    explicit.insert("deliveryPolicy".into(), json!("foregroundPermitted"));
    assert_eq!(
        DeliveryPolicy::from_params(&explicit).unwrap(),
        DeliveryPolicy::ForegroundPermitted
    );

    let mut null = Map::new();
    null.insert("deliveryPolicy".into(), Value::Null);
    assert_eq!(
        DeliveryPolicy::from_params(&null).unwrap(),
        DeliveryPolicy::BackgroundOnly
    );

    let mut unknown = Map::new();
    unknown.insert("deliveryPolicy".into(), json!("whateverItTakes"));
    let error = DeliveryPolicy::from_params(&unknown).unwrap_err();
    assert!(error.contains("backgroundOnly"), "{error}");
    assert!(error.contains("foregroundPermitted"), "{error}");

    let mut wrong_type = Map::new();
    wrong_type.insert("deliveryPolicy".into(), json!(7));
    assert!(DeliveryPolicy::from_params(&wrong_type).is_err());
}

#[test]
fn a_refusal_result_carries_the_whole_envelope_without_claiming_a_dispatch() {
    let result = DeliveryOutcome::refusal_result(
        DeliveryPolicy::BackgroundOnly,
        DeliveryRefusal::new(
            DeliveryRefusalReason::ForegroundNotPermitted,
            DeliveryRung::Foreground,
            Some(DeliveryCapability::GlobalInput),
            "SendInput requires foreground delivery",
        ),
    );

    assert_eq!(result["success"], json!(false));
    assert_eq!(result["strategy"], json!("refused"));
    assert_eq!(result["deliveryPolicy"], json!("backgroundOnly"));
    assert_eq!(result["delivery"], Value::Null);
    assert_eq!(result["dispatchSuccess"], json!(false));
    assert_eq!(result["refusal"]["reason"], json!("foregroundNotPermitted"));
    assert_eq!(result["refusal"]["requiredRung"], json!("foreground"));
    assert_eq!(result["refusal"]["capability"], json!("globalInput"));
    assert_eq!(result["dispatch"]["success"], json!(false));
    assert_eq!(result["verification"]["verified"], json!(false));
}
