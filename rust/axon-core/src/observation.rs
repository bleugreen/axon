use crate::{
    AppQuery, BackendError, DiffClassification, RecognizedText, SemanticDiff, Snapshot, SnapshotId,
    WireElementTarget,
};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};

/// The canonical image budget for every public `look` surface.
pub const OBSERVATION_SCREENSHOT_MAX_DIMENSION: u32 = 1280;
pub const OBSERVATION_SCREENSHOT_QUALITY: &str = "lossless";
pub const OBSERVATION_SCREENSHOT_MEDIA_TYPE: &str = "image/png";

pub const OBSERVATION_SCREEN_TEXT_MAX_ITEMS: usize = 100;

/// Formats platform OCR results for the public observation contract.
///
/// Geometry remains on RecognizedText for text-location resolution even when frames is false;
/// this boundary alone controls whether frames appear on the wire.
pub fn format_screen_text(recognized: &[RecognizedText], frames: bool) -> Value {
    let mut items: Vec<&RecognizedText> = recognized
        .iter()
        .filter(|item| {
            !item.text.is_empty()
                && item.frame.x.is_finite()
                && item.frame.y.is_finite()
                && item.frame.width.is_finite()
                && item.frame.height.is_finite()
                && item.frame.width > 0.0
                && item.frame.height > 0.0
        })
        .collect();
    items.sort_by(|left, right| {
        left.frame
            .y
            .total_cmp(&right.frame.y)
            .then_with(|| left.frame.x.total_cmp(&right.frame.x))
    });

    Value::Array(
        items
            .into_iter()
            .take(OBSERVATION_SCREEN_TEXT_MAX_ITEMS)
            .map(|item| {
                let mut object = Map::new();
                object.insert("text".into(), Value::String(item.text.clone()));
                if let Some(confidence) = item.confidence.filter(|value| value.is_finite()) {
                    object.insert("confidence".into(), Value::from(confidence));
                }
                if frames {
                    object.insert(
                        "frame".into(),
                        serde_json::to_value(item.frame)
                            .expect("recognized text frame serialization cannot fail"),
                    );
                }
                Value::Object(object)
            })
            .collect(),
    )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LookObservationKind {
    AppList,
    FullApp,
    ChangeCheck,
    ChildPage,
}

pub fn format_snapshot(snapshot: &Snapshot, options: &LookDisplayOptions) -> Value {
    let mut value = serde_json::to_value(snapshot).expect("snapshot serialization cannot fail");
    fn format_node(node: &mut Map<String, Value>, depth: usize, options: &LookDisplayOptions) {
        if !options.frames {
            node.remove("frame");
        }
        if depth == 0 || !options.tree {
            node.remove("children");
            return;
        }
        if let Some(children) = node.get_mut("children").and_then(Value::as_array_mut) {
            for child in children {
                if let Some(child) = child.as_object_mut() {
                    format_node(child, depth - 1, options);
                }
            }
        }
    }
    let depth = options.depth.unwrap_or(usize::MAX);
    if let Some(windows) = value
        .pointer_mut("/app/windows")
        .and_then(Value::as_array_mut)
    {
        for window in windows {
            if let Some(root) = window.get_mut("root").and_then(Value::as_object_mut) {
                format_node(root, depth, options);
            }
        }
    }
    if options.format == LookFormat::Debug {
        let mut envelope = Map::new();
        envelope.insert("format".into(), Value::String("debug".into()));
        envelope.insert("observation".into(), value);
        Value::Object(envelope)
    } else {
        value
    }
}

pub fn format_child_page(
    capture: &crate::ChildPageCapture,
    parent: &WireElementTarget,
    rendered: &Snapshot,
    options: &LookDisplayOptions,
) -> Value {
    let mut tree = format_snapshot(rendered, options);
    if options.format == LookFormat::Debug {
        tree = tree.get("observation").cloned().unwrap_or(Value::Null);
    }
    let tree = tree
        .pointer("/app/windows/0/root/children")
        .cloned()
        .map(|children| serde_json::to_string(&children).expect("rendered children serialize"))
        .unwrap_or_default();
    let next_offset = capture.total.and_then(|total| {
        let next = capture.offset.saturating_add(capture.children.len());
        (next < total).then_some(next)
    });
    serde_json::json!({
        "format": "children",
        "snapshot": capture.snapshot,
        "parent": parent,
        "offset": capture.offset,
        "limit": capture.limit,
        "total": capture.total,
        "nextOffset": next_offset,
        "tree": tree,
    })
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum LookFormat {
    #[default]
    Observation,
    Debug,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LookDisplayOptions {
    pub depth: Option<usize>,
    pub tree: bool,
    pub frames: bool,
    pub format: LookFormat,
}

#[derive(Clone, Debug, PartialEq)]
pub enum LookMode {
    AppList {
        all: bool,
    },
    FullApp {
        app: AppQuery,
        child_depth: Option<usize>,
    },
    ChildPage {
        target: WireElementTarget,
        offset: usize,
        limit: Option<usize>,
        direct: bool,
    },
    ChangeCheck {
        app: AppQuery,
        since: SinceToken,
        child_depth: Option<usize>,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct LookRequest {
    pub mode: LookMode,
    pub display: LookDisplayOptions,
    pub screenshot: Option<bool>,
    pub screen_text: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
#[error("invalid look request: {0}")]
pub struct LookRequestError(pub String);

impl LookRequest {
    pub fn decode(params: &Map<String, Value>) -> Result<Self, LookRequestError> {
        fn number(
            params: &Map<String, Value>,
            key: &str,
        ) -> Result<Option<usize>, LookRequestError> {
            params
                .get(key)
                .map(|v| {
                    v.as_u64()
                        .and_then(|n| usize::try_from(n).ok())
                        .ok_or_else(|| {
                            LookRequestError(format!("{key} must be a nonnegative integer"))
                        })
                })
                .transpose()
        }
        let app = params
            .get("app")
            .map(|value| {
                if let Some(value) = value.as_str() {
                    let process_id = value.strip_prefix("pid:").unwrap_or(value).parse().ok();
                    Ok(AppQuery {
                        process_id,
                        name: process_id.is_none().then(|| value.to_owned()),
                        identifier: None,
                    })
                } else {
                    serde_json::from_value::<AppQuery>(value.clone())
                        .map_err(|error| LookRequestError(format!("app: {error}")))
                }
            })
            .transpose()?;
        let target = params
            .get("target")
            .map(|v| {
                serde_json::from_value::<WireElementTarget>(v.clone())
                    .map_err(|e| LookRequestError(format!("target: {e}")))
                    .and_then(|t| t.validate().map_err(|e| LookRequestError(e.to_string())))
            })
            .transpose()?;
        let since = params
            .get("since")
            .map(|v| {
                v.as_str()
                    .ok_or_else(|| LookRequestError("since must be a string".into()))
                    .and_then(|v| SinceToken::parse(v).map_err(|e| LookRequestError(e.to_string())))
            })
            .transpose()?;
        if app.is_some() && target.is_some() {
            return Err(LookRequestError(
                "app and target are mutually exclusive".into(),
            ));
        }
        let all = params.get("all").and_then(Value::as_bool).unwrap_or(false);
        let direct = params
            .get("direct")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let offset = number(params, "offset")?.unwrap_or(0);
        let raw_limit = number(params, "limit")?;
        let child_depth = number(params, "childDepth")?;
        let depth = number(params, "depth")?;
        let format = match params
            .get("format")
            .and_then(Value::as_str)
            .unwrap_or("observation")
        {
            "observation" => LookFormat::Observation,
            "debug" => LookFormat::Debug,
            value => return Err(LookRequestError(format!("unsupported format {value:?}"))),
        };
        let mode = match (app, target, since) {
            (None, None, None) => {
                reject(
                    params,
                    &[
                        "offset",
                        "limit",
                        "direct",
                        "childDepth",
                        "depth",
                        "tree",
                        "frames",
                        "since",
                    ],
                    "application list",
                )?;
                LookMode::AppList {
                    all: all || format == LookFormat::Debug,
                }
            }
            (Some(app), None, None) => {
                reject(
                    params,
                    &["offset", "limit", "direct", "all"],
                    "full application observation",
                )?;
                LookMode::FullApp { app, child_depth }
            }
            (Some(app), None, Some(since)) => {
                reject(
                    params,
                    &["offset", "limit", "direct", "all"],
                    "change check",
                )?;
                LookMode::ChangeCheck {
                    app,
                    since,
                    child_depth,
                }
            }
            (None, Some(target), None) => {
                reject(
                    params,
                    &["childDepth", "since", "screenshot", "screenText"],
                    "child page",
                )?;
                let limit = if all {
                    raw_limit.filter(|n| *n > 0)
                } else {
                    Some(raw_limit.unwrap_or(24).clamp(1, 24))
                };
                LookMode::ChildPage {
                    target,
                    offset,
                    limit,
                    direct,
                }
            }
            (Some(_), Some(_), None) => unreachable!("app/target exclusivity checked above"),
            (_, _, Some(_)) => {
                return Err(LookRequestError(
                    "since requires app and cannot be combined with target".into(),
                ));
            }
        };
        Ok(Self {
            mode,
            display: LookDisplayOptions {
                depth,
                tree: params
                    .get("tree")
                    .and_then(Value::as_bool)
                    .unwrap_or(format != LookFormat::Debug),
                frames: params
                    .get("frames")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                format,
            },
            screenshot: params.get("screenshot").and_then(Value::as_bool),
            screen_text: params
                .get("screenText")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        })
    }
}

fn reject(params: &Map<String, Value>, keys: &[&str], mode: &str) -> Result<(), LookRequestError> {
    fn is_schema_default(key: &str, value: &Value) -> bool {
        match key {
            "offset" => value.as_u64() == Some(0),
            "direct" | "frames" | "screenText" => value.as_bool() == Some(false),
            "screenshot" => value.as_bool() == Some(true),
            _ => false,
        }
    }
    if let Some(key) = keys.iter().find(|key| {
        params
            .get(**key)
            .is_some_and(|value| !is_schema_default(key, value))
    }) {
        Err(LookRequestError(format!("{key} has no meaning for {mode}")))
    } else {
        Ok(())
    }
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
pub(crate) mod since_tests {
    use super::*;
    use crate::{Application, Node, Window};

    pub(crate) fn snapshot() -> Snapshot {
        Snapshot {
            id: SnapshotId("fixture-1".into()),
            app: Application {
                process_id: None,
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
