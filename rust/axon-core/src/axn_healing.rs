use crate::{AxnAction, Confidence, ResolutionStatus};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TargetResolution {
    pub status: ResolutionStatus,
    pub confidence: Confidence,
    #[serde(default = "default_path")]
    pub path: String,
    #[serde(default)]
    pub context_complete: bool,
    #[serde(default)]
    pub candidates: Vec<Value>,
    #[serde(default)]
    pub reasons: Vec<String>,
    #[serde(default)]
    pub evidence: Vec<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observed_locator: Option<Value>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn action() -> AxnAction { serde_json::from_value(json!({"id":"submit","tool":"click","target":{"app":"Mail","name":"send","locator":{"role":"button","title":{"exact":"Send"}},"recording":{"ignored":true}}})).unwrap() }
    fn resolution(status: ResolutionStatus, observed: Option<Value>) -> TargetResolution { TargetResolution {
        status, confidence: Confidence::High, path: "fullSnapshot".into(), context_complete: true,
        candidates: vec![], reasons: vec![], evidence: vec![json!({"field":"title","outcome":"changed"})], observed_locator: observed,
    } }

    #[test]
    fn unique_drift_proposes_only_after_confidence_reverification() {
        let proposal = json!({"role":"button","title":{"exact":"Send now"}});
        let event = healing_event(&action(), 0, &resolution(ResolutionStatus::Unique, Some(proposal.clone())), &[], |actual, confidence| actual == &proposal && confidence == Confidence::High).unwrap();
        assert_eq!(event.status, LocatorHealStatus::Proposed);
        assert_eq!(event.proposal, Some(proposal));
        let halted = healing_event(&action(), 0, &resolution(ResolutionStatus::Unique, Some(json!({"role":"button"}))), &[], |_, _| false).unwrap();
        assert_eq!(halted.status, LocatorHealStatus::Halted);
        assert_eq!(halted.reason.as_deref(), Some("proposal did not resolve uniquely at equal or higher confidence"));
    }

    #[test]
    fn clean_resolution_emits_nothing_and_non_unique_halts() {
        let mut clean = resolution(ResolutionStatus::Unique, None); clean.evidence = vec![json!({"field":"title","outcome":"matched"})];
        assert!(healing_event(&action(), 0, &clean, &[], |_, _| true).is_none());
        let missing = healing_event(&action(), 0, &resolution(ResolutionStatus::Missing, None), &[], |_, _| true).unwrap();
        assert_eq!(missing.status, LocatorHealStatus::Halted);
        assert!(missing.proposal.is_none());
    }

    #[test]
    fn secrets_halt_without_leaking_and_revision_changes_only_locator() {
        let mut tainted = resolution(ResolutionStatus::Unique, Some(json!({"role":"button","title":{"exact":"token-123"}})));
        tainted.evidence = vec![json!({"field":"title","outcome":"changed","actual":"token-123","secretTainted":true})];
        let event = healing_event(&action(), 0, &tainted, &["token-123".into()], |_, _| true).unwrap();
        assert_eq!(event.status, LocatorHealStatus::Halted);
        assert!(!serde_json::to_string(&event).unwrap().contains("token-123"));

        let proposal = json!({"role":"button","title":{"exact":"Send now"}});
        let proposed = healing_event(&action(), 0, &resolution(ResolutionStatus::Unique, Some(proposal.clone())), &[], |_, _| true).unwrap();
        let doc = crate::AxnDocument { version: 2, arguments: vec![], actions: vec![action()], flags: Map::new() };
        let revised = revise(&doc, &[proposed.clone()]);
        assert_eq!(revised.actions[0].params["target"]["locator"], proposal);
        assert_eq!(revised.actions[0].params["target"]["recording"], json!({"ignored":true}));
        let yaml = reviewed_yaml(&doc, &[proposed]).unwrap();
        assert!(yaml.starts_with("# Axon healed locator proposals. Review before replaying.\n"));
    }
}

fn default_path() -> String { "fullSnapshot".into() }

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LocatorHealStatus { Proposed, Halted, Clean }

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocatorHealEvent {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action_id: Option<String>,
    pub action_index: usize,
    pub status: LocatorHealStatus,
    pub confidence: Confidence,
    pub path: String,
    pub evidence: Vec<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proposal: Option<Value>,
    pub diff: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

pub fn healing_event(
    action: &AxnAction,
    index: usize,
    resolution: &TargetResolution,
    secrets: &[String],
    verify: impl FnOnce(&Value, Confidence) -> bool,
) -> Option<LocatorHealEvent> {
    let drift = resolution.evidence.iter().any(|item| {
        let Some(o) = item.as_object() else { return false };
        o.get("field").and_then(Value::as_str) != Some("frame")
            && !matches!(o.get("outcome").and_then(Value::as_str), Some("matched" | "unevaluated"))
    });
    if resolution.status == ResolutionStatus::Unique && !drift { return None; }
    let identity = action.id.clone().unwrap_or_else(|| format!("actions[{index}]"));
    let halt = |detail: &str, reason: &str| LocatorHealEvent {
        action_id: action.id.clone(), action_index: index, status: LocatorHealStatus::Halted,
        confidence: resolution.confidence, path: resolution.path.clone(),
        evidence: redact_values(&resolution.evidence, secrets), proposal: None,
        diff: format!("{identity}  target.locator  healing halted: {detail}"), reason: Some(reason.into()),
    };
    if resolution.status != ResolutionStatus::Unique {
        return Some(halt(&format!("resolution {}", status_name(resolution.status)), "locator resolution was not unique"));
    }
    let target = action.params.get("target").and_then(Value::as_object);
    let Some(recorded) = target.and_then(|t| t.get("locator")).and_then(Value::as_object) else {
        return Some(halt("recorded locator unavailable", "the action did not contain a recorded locator"));
    };
    let Some(mut proposal) = resolution.observed_locator.as_ref().and_then(Value::as_object).cloned() else {
        return Some(halt("observed locator unavailable", "the resolver did not return an observed locator"));
    };
    if resolution.evidence.iter().any(|v| v.get("secretTainted") == Some(&Value::Bool(true))) {
        return Some(halt("resolution evidence contains an active secret", "resolution evidence contains an active secret"));
    }
    for item in &resolution.evidence {
        let Some(o) = item.as_object() else { continue };
        if o.get("outcome").and_then(Value::as_str) == Some("unevaluated") {
            if let Some((field, original)) = o.get("field").and_then(Value::as_str).and_then(|f| recorded.get(f).map(|v| (f, v))) {
                proposal.insert(field.into(), original.clone());
            }
        }
    }
    let proposal = Value::Object(proposal);
    if contains_secret(&proposal, secrets) {
        return Some(halt("proposal contains an active secret", "proposal contains an active secret"));
    }
    if target.and_then(|t| t.get("app")).and_then(Value::as_str).is_none_or(str::is_empty) {
        return Some(halt("locator target has no app", "locator target has no app"));
    }
    if !verify(&proposal, resolution.confidence) {
        return Some(halt("proposal verification failed", "proposal did not resolve uniquely at equal or higher confidence"));
    }
    Some(LocatorHealEvent {
        action_id: action.id.clone(), action_index: index, status: LocatorHealStatus::Proposed,
        confidence: resolution.confidence, path: resolution.path.clone(),
        evidence: resolution.evidence.clone(), proposal: Some(proposal.clone()),
        diff: render_diff(&identity, recorded, proposal.as_object().unwrap()), reason: None,
    })
}

pub fn revise(doc: &crate::AxnDocument, events: &[LocatorHealEvent]) -> crate::AxnDocument {
    let mut revised = doc.clone();
    for event in events.iter().filter(|e| e.status == LocatorHealStatus::Proposed) {
        let Some(proposal) = &event.proposal else { continue };
        let Some(Value::Object(target)) = revised.actions.get_mut(event.action_index).and_then(|a| a.params.get_mut("target")) else { continue };
        target.insert("locator".into(), proposal.clone());
    }
    revised
}

pub fn reviewed_yaml(doc: &crate::AxnDocument, events: &[LocatorHealEvent]) -> Result<String, crate::AxnError> {
    let mut lines = vec!["# Axon healed locator proposals. Review before replaying.".to_owned()];
    for line in events.iter().filter(|e| e.status == LocatorHealStatus::Proposed).flat_map(|e| e.diff.lines()) {
        lines.push(format!("# {line}"));
    }
    Ok(format!("{}\n{}", lines.join("\n"), crate::AxnCodec::to_yaml(&revise(doc, events))?))
}

fn status_name(status: ResolutionStatus) -> &'static str { match status { ResolutionStatus::Unique => "unique", ResolutionStatus::Ambiguous => "ambiguous", ResolutionStatus::Missing => "missing" } }
fn contains_secret(v: &Value, secrets: &[String]) -> bool { match v { Value::String(s) => secrets.iter().any(|x| !x.is_empty() && s.contains(x)), Value::Array(a) => a.iter().any(|v| contains_secret(v, secrets)), Value::Object(o) => o.values().any(|v| contains_secret(v, secrets)), _ => false } }
fn redact_values(values: &[Value], secrets: &[String]) -> Vec<Value> { values.iter().map(|v| redact(v, secrets)).collect() }
fn redact(v: &Value, secrets: &[String]) -> Value { match v { Value::String(s) if secrets.iter().any(|x| !x.is_empty() && s.contains(x)) => Value::String("<redacted: contains-secret>".into()), Value::Array(a) => Value::Array(redact_values(a, secrets)), Value::Object(o) => Value::Object(o.iter().map(|(k,v)| (k.clone(), redact(v, secrets))).collect()), _ => v.clone() } }
fn render_diff(identity: &str, before: &Map<String, Value>, after: &Map<String, Value>) -> String {
    let mut keys: Vec<_> = before.keys().chain(after.keys()).collect(); keys.sort(); keys.dedup();
    let mut lines = vec![format!("{identity}  target.locator")];
    for key in keys { if before.get(key) != after.get(key) { if let Some(v)=before.get(key){lines.push(format!("  - {key}: {v}"));} if let Some(v)=after.get(key){lines.push(format!("  + {key}: {v}"));} } }
    lines.join("\n")
}