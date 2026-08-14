use crate::{
    DiffClassification, DiffPolicy, JsonRpcError, JsonRpcRequest, JsonRpcResponse,
    SemanticNameDeriver, Snapshot, classify_semantic_diff,
};

/// Private router parameter used by daemon transports to make one atomic stability capture.
pub const SINGLE_STABILITY_CAPTURE: &str = "_axonSingleStabilityCapture";
use serde_json::{Map, Value, json};
use std::{
    thread,
    time::{Duration, Instant},
};

fn invalid(message: impl Into<String>) -> JsonRpcError {
    JsonRpcError {
        code: -32602,
        message: message.into(),
        data: None,
    }
}

fn bounded_ms(
    params: &Map<String, Value>,
    key: &str,
    default: u64,
    min: u64,
    max: u64,
) -> Result<Duration, JsonRpcError> {
    let value = match params.get(key) {
        None | Some(Value::Null) => default,
        Some(value) => value
            .as_u64()
            .ok_or_else(|| invalid(format!("{key} must be an integer")))?,
    };
    if !(min..=max).contains(&value) {
        return Err(invalid(format!("{key} must be between {min} and {max}")));
    }
    Ok(Duration::from_millis(value))
}

/// Runs a daemon wait as atomic, zero-time router polls.
///
/// `poll` owns the router lock for one call. It has returned before `sleep` is entered, so ordinary
/// requests may acquire the canonical router between polls without interleaving inside a poll.
pub fn poll_wait_request(
    request: JsonRpcRequest,
    mut poll: impl FnMut(JsonRpcRequest) -> Option<JsonRpcResponse>,
) -> Option<JsonRpcResponse> {
    poll_wait_request_with(request, &mut poll, thread::sleep)
}

fn poll_wait_request_with(
    mut request: JsonRpcRequest,
    poll: &mut impl FnMut(JsonRpcRequest) -> Option<JsonRpcResponse>,
    mut sleep: impl FnMut(Duration),
) -> Option<JsonRpcResponse> {
    let id = request.id.clone()?;
    let mut params = request
        .params
        .take()
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default();
    let timeout = match bounded_ms(&params, "timeoutMs", 5_000, 0, 60_000) {
        Ok(value) => value,
        Err(error) => return Some(JsonRpcResponse::failure(id, error)),
    };
    let stability = request.method == "wait_for_stability";
    let stable_for = if stability {
        match bounded_ms(&params, "stableMs", 300, 0, 10_000) {
            Ok(value) => value,
            Err(error) => return Some(JsonRpcResponse::failure(id, error)),
        }
    } else {
        Duration::ZERO
    };
    let interval = match bounded_ms(
        &params,
        "intervalMs",
        100,
        10,
        timeout.as_millis().max(100) as u64,
    ) {
        Ok(value) => value,
        Err(error) => return Some(JsonRpcResponse::failure(id, error)),
    };
    params.insert("timeoutMs".into(), json!(0));
    if stability {
        // Each router call contributes exactly one capture. The daemon helper retains the baseline,
        // last observation, and stable duration across those atomic calls.
        params.insert("stableMs".into(), json!(0));
        params.insert(SINGLE_STABILITY_CAPTURE.into(), json!(true));
    }
    request.params = Some(Value::Object(params.clone()));

    let condition = params
        .get("condition")
        .and_then(Value::as_str)
        .unwrap_or("stable");
    let started = Instant::now();
    let mut baseline: Option<(Snapshot, Vec<crate::SemanticElementName>)> = None;
    let mut last: Option<(Snapshot, Vec<crate::SemanticElementName>)> = None;
    let mut stable_since = started;
    loop {
        let had_baseline = baseline.is_some();
        let response = poll(request.clone())?;
        let JsonRpcResponse::Success(mut success) = response else {
            return Some(response);
        };
        if !stability {
            if success
                .result
                .pointer("/wait/success")
                .and_then(Value::as_bool)
                == Some(true)
                || started.elapsed() >= timeout
            {
                success.result["wait"]["elapsedMs"] = json!(started.elapsed().as_millis());
                return Some(JsonRpcResponse::Success(success));
            }
        } else {
            let snapshot = match serde_json::from_value::<Snapshot>(
                success.result["wait"]["snapshot"].clone(),
            ) {
                Ok(snapshot) => snapshot,
                Err(_) => return Some(JsonRpcResponse::Success(success)),
            };
            let names = SemanticNameDeriver::derive(&snapshot);
            let changed_from_last = last.as_ref().is_some_and(|(old, old_names)| {
                !matches!(
                    classify_semantic_diff(
                        old,
                        old_names,
                        &snapshot,
                        &names,
                        DiffPolicy::default()
                    ),
                    Ok(DiffClassification::Unchanged)
                )
            });
            if changed_from_last {
                stable_since = Instant::now();
            }
            let changed_from_first = baseline.as_ref().is_some_and(|(first, first_names)| {
                !matches!(
                    classify_semantic_diff(
                        first,
                        first_names,
                        &snapshot,
                        &names,
                        DiffPolicy::default()
                    ),
                    Ok(DiffClassification::Unchanged)
                )
            });
            if baseline.is_none() {
                stable_since = Instant::now();
                baseline = Some((snapshot.clone(), names.clone()));
            }
            last = Some((snapshot, names));
            let satisfied = if condition == "changed" {
                changed_from_first
            } else {
                stable_since.elapsed() >= stable_for
            };
            if satisfied || started.elapsed() >= timeout {
                success.result["wait"]["success"] = json!(satisfied);
                success.result["wait"]["status"] =
                    json!(if satisfied { "satisfied" } else { "timeout" });
                success.result["wait"]["elapsedMs"] = json!(started.elapsed().as_millis());
                success.result["wait"]["stableMs"] = json!(stable_since.elapsed().as_millis());
                return Some(JsonRpcResponse::Success(success));
            }
        }
        // The original stability operation captures its baseline and first comparison back-to-back.
        // Preserve that timing while still releasing the router between the two atomic captures.
        if !stability || had_baseline {
            sleep(interval.min(timeout.saturating_sub(started.elapsed())));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{JsonRpcId, JsonRpcResponse};

    fn snapshot(value: &str) -> Snapshot {
        serde_json::from_value(json!({
            "id": format!("snapshot-{value}"),
            "app": {
                "name": "App",
                "windows": [{
                    "title": "Window",
                    "root": {"role": "window", "value": value}
                }]
            }
        }))
        .unwrap()
    }

    #[test]
    fn stability_changed_compares_the_first_two_single_captures() {
        let request = JsonRpcRequest::new(
            Some(JsonRpcId::Integer(8)),
            "wait_for_stability",
            Some(json!({
                "app":"App",
                "condition":"changed",
                "timeoutMs":100,
                "intervalMs":10
            })),
        );
        let captures = [snapshot("Before"), snapshot("After")];
        let mut polls = 0;
        let mut sleeps = 0;
        let mut poll = |request: JsonRpcRequest| {
            assert_eq!(
                request.params.as_ref().unwrap()[SINGLE_STABILITY_CAPTURE],
                true
            );
            let current = captures[polls].clone();
            polls += 1;
            Some(JsonRpcResponse::success(
                request.id.unwrap(),
                json!({"wait":{"success":false,"status":"polling","snapshot":current}}),
            ))
        };

        let response = poll_wait_request_with(request, &mut poll, |_| sleeps += 1).unwrap();
        let JsonRpcResponse::Success(success) = response else {
            panic!("expected success envelope")
        };
        assert_eq!(success.result["wait"]["success"], true);
        assert_eq!(
            polls, 2,
            "the first change must not require a third capture"
        );
        assert_eq!(sleeps, 0, "the first comparison is immediate");
    }

    #[test]
    fn another_request_can_run_between_atomic_polls_and_timeout_keeps_final_envelope() {
        let request = JsonRpcRequest::new(
            Some(JsonRpcId::Integer(7)),
            "wait_for_value",
            Some(json!({"contains":"ready","timeoutMs":10,"intervalMs":10})),
        );
        let mut polls = 0;
        let mut interleaved = false;
        let mut poll = |request: JsonRpcRequest| {
            assert_eq!(request.params.as_ref().unwrap()["timeoutMs"], 0);
            polls += 1;
            Some(JsonRpcResponse::success(
                request.id.unwrap(),
                json!({"wait":{"success":false,"status":"predicate_timeout","elapsedMs":0,"matched":null}}),
            ))
        };
        let response = poll_wait_request_with(request, &mut poll, |_| interleaved = true).unwrap();
        assert!(
            interleaved,
            "the router is released while the interval elapses"
        );
        assert!(polls >= 2);
        let JsonRpcResponse::Success(success) = response else {
            panic!("expected success envelope")
        };
        assert_eq!(success.result["wait"]["success"], false);
        assert_eq!(success.result["wait"]["status"], "predicate_timeout");
        assert!(success.result["wait"]["elapsedMs"].as_u64().unwrap() >= 10);
    }
}
