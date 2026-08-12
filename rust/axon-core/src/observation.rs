use crate::BackendError;
use serde::Serialize;

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

pub fn screenshot_requested(explicit: Option<bool>, kind: LookObservationKind) -> bool {
    explicit.unwrap_or(matches!(kind, LookObservationKind::FullApp))
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
        assert!(!screenshot_requested(None, LookObservationKind::ChangeCheck));
        assert!(!screenshot_requested(None, LookObservationKind::ChildPage));
        assert!(!screenshot_requested(Some(false), LookObservationKind::FullApp));
        assert!(screenshot_requested(Some(true), LookObservationKind::ChangeCheck));
    }
}