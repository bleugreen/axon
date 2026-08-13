use crate::{BackendError, DiffClassification, SemanticDiff, Snapshot, SnapshotId};
use serde::{Deserialize, Deserializer, Serialize};

/// The canonical image budget for every public `look` surface.
pub const OBSERVATION_SCREENSHOT_MAX_DIMENSION: u32 = 1280;
pub const OBSERVATION_SCREENSHOT_QUALITY: &str = "lossless";
pub const OBSERVATION_SCREENSHOT_MEDIA_TYPE: &str = "image/png";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LookObservationKind {
    AppList,
    FullApp,
    ChangeCheck,
    ChildPage,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub struct SinceToken(String);

impl<'de> Deserialize<'de> for SinceToken {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::parse(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

impl SinceToken {
    pub fn new(app_identity: &str, snapshot_id: &SnapshotId, observer_sequence: u64) -> Self {
        Self(format!(
            "obs-{}.{}.{}",
            hex_encode(app_identity.as_bytes()),
            hex_encode(snapshot_id.0.as_bytes()),
            observer_sequence
        ))
    }

    pub fn parse(value: impl Into<String>) -> Result<Self, SinceTokenError> {
        let value = value.into();
        validate_since_token(&value)?;
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn decode_component(value: &str) -> Option<Vec<u8>> {
    if value.is_empty() || !value.len().is_multiple_of(2) {
        return None;
    }
    value
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            std::str::from_utf8(pair)
                .ok()
                .and_then(|digits| u8::from_str_radix(digits, 16).ok())
        })
        .collect()
}

fn validate_since_token(value: &str) -> Result<(), SinceTokenError> {
    let body = value
        .strip_prefix("obs-")
        .ok_or(SinceTokenError::Malformed)?;
    let mut components = body.split('.');
    let app = components
        .next()
        .and_then(decode_component)
        .ok_or(SinceTokenError::Malformed)?;
    let snapshot = components
        .next()
        .and_then(decode_component)
        .ok_or(SinceTokenError::Malformed)?;
    let sequence = components.next().ok_or(SinceTokenError::Malformed)?;
    if components.next().is_some()
        || std::str::from_utf8(&app).ok().is_none_or(str::is_empty)
        || std::str::from_utf8(&snapshot)
            .ok()
            .is_none_or(str::is_empty)
        || sequence.is_empty()
        || sequence.parse::<u64>().is_err()
    {
        return Err(SinceTokenError::Malformed);
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum SinceTokenError {
    #[error("malformed observation token")]
    Malformed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum LookFallbackNote {
    BaselineExpired,
    DiffExceededThreshold,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum LookSinceResult {
    Unchanged(LookUnchanged),
    Diff(LookDiff),
    Full(LookFull),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LookUnchanged {
    pub app: String,
    #[serde(deserialize_with = "deserialize_true")]
    unchanged: bool,
    pub since: SinceToken,
}

fn deserialize_true<'de, D: Deserializer<'de>>(deserializer: D) -> Result<bool, D::Error> {
    let value = bool::deserialize(deserializer)?;
    if value {
        Ok(true)
    } else {
        Err(serde::de::Error::custom("unchanged must be true"))
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LookDiff {
    pub app: String,
    pub since: SinceToken,
    pub diff: SemanticDiff,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LookFull {
    pub app: String,
    pub observation: Snapshot,
    pub since: SinceToken,
    pub note: LookFallbackNote,
}

impl LookSinceResult {
    pub fn unchanged(app: impl Into<String>, since: SinceToken) -> Self {
        Self::Unchanged(LookUnchanged {
            app: app.into(),
            unchanged: true,
            since,
        })
    }

    pub fn diff(app: impl Into<String>, since: SinceToken, diff: SemanticDiff) -> Self {
        Self::Diff(LookDiff {
            app: app.into(),
            since,
            diff,
        })
    }

    pub fn fallback(
        app: impl Into<String>,
        observation: Snapshot,
        since: SinceToken,
        note: LookFallbackNote,
    ) -> Self {
        Self::Full(LookFull {
            app: app.into(),
            observation,
            since,
            note,
        })
    }

    pub fn observation_kind(&self) -> LookObservationKind {
        match self {
            Self::Unchanged(_) | Self::Diff(_) => LookObservationKind::ChangeCheck,
            Self::Full(_) => LookObservationKind::FullApp,
        }
    }
}

pub fn look_since_response(
    app: impl Into<String>,
    observation: Snapshot,
    since: SinceToken,
    comparison: Option<DiffClassification>,
) -> LookSinceResult {
    let app = app.into();
    match comparison {
        None => {
            LookSinceResult::fallback(app, observation, since, LookFallbackNote::BaselineExpired)
        }
        Some(DiffClassification::Unchanged) => LookSinceResult::unchanged(app, since),
        Some(DiffClassification::Diff(diff)) => LookSinceResult::diff(app, since, diff),
        Some(DiffClassification::ThresholdExceeded) => LookSinceResult::fallback(
            app,
            observation,
            since,
            LookFallbackNote::DiffExceededThreshold,
        ),
    }
}

pub fn screenshot_requested(explicit: Option<bool>, kind: LookObservationKind) -> bool {
    match kind {
        LookObservationKind::FullApp => explicit.unwrap_or(true),
        LookObservationKind::AppList
        | LookObservationKind::ChangeCheck
        | LookObservationKind::ChildPage => false,
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ScreenshotUnavailable {
    pub code: &'static str,
    pub reason: String,
}

impl ScreenshotUnavailable {
    pub fn from_backend_error(error: BackendError) -> Self {
        match error {
            BackendError::Capability { reason, .. } => {
                let code = if reason.contains("portal") {
                    "portal-authorization-required"
                } else {
                    "capability-unavailable"
                };
                Self { code, reason }
            }
            BackendError::Operation { message, .. } => Self {
                code: "capture-failed",
                reason: message,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_only_full_app_observations_to_screenshot() {
        assert!(screenshot_requested(None, LookObservationKind::FullApp));
        assert!(!screenshot_requested(None, LookObservationKind::AppList));
        assert!(!screenshot_requested(
            None,
            LookObservationKind::ChangeCheck
        ));
        assert!(!screenshot_requested(None, LookObservationKind::ChildPage));
        assert!(!screenshot_requested(
            Some(false),
            LookObservationKind::FullApp
        ));
        assert!(!screenshot_requested(
            Some(true),
            LookObservationKind::ChangeCheck
        ));
    }
}

#[cfg(test)]
mod since_tests {
    use super::*;
    use crate::{Application, Node, Window};

    fn snapshot() -> Snapshot {
        Snapshot {
            id: SnapshotId("fixture-1".into()),
            app: Application {
                name: "Fixture".into(),
                identifier: Some("fixture.app".into()),
                windows: vec![Window {
                    title: Some("Main".into()),
                    root: Node {
                        role: "window".into(),
                        subrole: None,
                        name: None,
                        title: Some("Main".into()),
                        label: None,
                        value: None,
                        description: None,
                        identifier: None,
                        actions: vec![],
                        frame: None,
                        editable: false,
                        focused: None,
                        enabled: None,
                        children: vec![],
                        child_count: None,
                        truncation_reason: None,
                    },
                }],
            },
        }
    }

    #[test]
    fn token_round_trip_and_validation() {
        let token = SinceToken::new("fixture.app", &SnapshotId("s.1/opaque".into()), 42);
        assert!(token.as_str().starts_with("obs-"));
        assert_eq!(SinceToken::parse(token.as_str()).unwrap(), token);
        for malformed in ["bad-00.00.1", "obs-", "obs-zz.00.1", "obs-00.00.no"] {
            assert!(SinceToken::parse(malformed).is_err());
        }
    }

    #[test]
    fn response_forms_are_strict_and_select_screenshot_policy() {
        let token = SinceToken::new("fixture.app", &SnapshotId("fixture-1".into()), 1);
        let unchanged = LookSinceResult::unchanged("Fixture", token.clone());
        assert_eq!(
            unchanged.observation_kind(),
            LookObservationKind::ChangeCheck
        );
        assert!(!screenshot_requested(
            Some(true),
            unchanged.observation_kind()
        ));

        let diff = LookSinceResult::diff("Fixture", token.clone(), SemanticDiff::default());
        assert!(!screenshot_requested(None, diff.observation_kind()));

        for note in [
            LookFallbackNote::BaselineExpired,
            LookFallbackNote::DiffExceededThreshold,
        ] {
            let full = LookSinceResult::fallback("Fixture", snapshot(), token.clone(), note);
            assert!(screenshot_requested(None, full.observation_kind()));
        }
        assert!(
            serde_json::from_str::<LookSinceResult>(
                r#"{"app":"Fixture","unchanged":true,"since":"obs-61.62.1","extra":1}"#
            )
            .is_err()
        );
        assert!(
            serde_json::from_str::<LookSinceResult>(
                r#"{"app":"Fixture","unchanged":true,"since":"garbage"}"#
            )
            .is_err()
        );
        assert!(
            serde_json::from_str::<LookSinceResult>(
                r#"{"app":"Fixture","unchanged":false,"since":"obs-61.62.1"}"#
            )
            .is_err()
        );
    }

    #[test]
    fn missing_baseline_is_a_full_fallback() {
        let token = SinceToken::new("fixture.app", &SnapshotId("fixture-1".into()), 2);
        let result = look_since_response("Fixture", snapshot(), token, None);
        assert!(matches!(
            result,
            LookSinceResult::Full(LookFull {
                note: LookFallbackNote::BaselineExpired,
                ..
            })
        ));
    }
}
