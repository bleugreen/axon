//! The Apple Events (Automation) consent vocabulary the daemon publishes.
//!
//! macOS gates scripting another application behind a per-sender, per-target TCC grant. The daemon
//! is the sender, so it alone can ask macOS about that grant and alone can mint it; a menu shell that
//! asked would mint the grant for its own identity, which is the wrong one. These types are what the
//! daemon tells the shell about consent, through `automation.status` and `automation.request`. They
//! live here rather than in the macOS backend so the fixtures in `schema/fixtures/shell` pin one
//! type that every build parses identically. See "macOS daemon and menu shell contract" in
//! `docs/cross-platform-internals.md`.

use crate::JsonRpcError;
use serde::{Deserialize, Serialize};
use serde_json::json;

/// What macOS answered about one sender/target authorization.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AutomationAuthorization {
    /// `noErr`: the daemon may send Apple events to the target.
    Granted,
    /// `errAEEventNotPermitted`: a denial is recorded, or macOS refused without recording anything.
    Denied,
    /// `errAEEventWouldRequireUserConsent`: nobody has answered yet, so a prompt can still mint it.
    NotDetermined,
    /// Any other status. The determination itself failed, which is not an answer.
    Failed,
}

/// Which step of the authorization sequence produced an answer.
///
/// macOS answers the same question in three places, and they mean different things, so an answer
/// that does not say which step produced it cannot be acted on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AutomationLeg {
    /// A determination that never presents the consent dialog.
    Checked,
    /// A determination that may present the dialog, and blocks until a person answers it.
    Prompted,
    /// The Apple event itself was refused after a determination passed.
    ///
    /// Reserved: only a browser verb sends Apple events, and the Rust daemon has none yet, so
    /// nothing produces this leg. It is part of the vocabulary now so a shell built against this
    /// contract can read a daemon that does.
    Executed,
}

/// What the menu's Browser Automation item still has to offer, and therefore whether it exists.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConsentNeed {
    /// Every running supported browser is granted, or none is running. No item.
    #[default]
    None,
    /// At least one grant is undetermined and the gesture can still mint it.
    Request,
    /// At least one grant stands denied or could not be determined. macOS will not prompt over a
    /// recorded denial, so the gesture explains instead of asking; the item stays, because hiding
    /// it would leave that refusal with nowhere to lead.
    Explain,
}

impl ConsentNeed {
    /// The need one browser's authorization creates.
    pub fn of(authorization: AutomationAuthorization) -> Self {
        match authorization {
            AutomationAuthorization::Granted => Self::None,
            AutomationAuthorization::NotDetermined => Self::Request,
            AutomationAuthorization::Denied | AutomationAuthorization::Failed => Self::Explain,
        }
    }
}

/// One supported browser as `automation.status` sees it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserConsentState {
    pub app: String,
    pub bundle_identifier: String,
    pub running: bool,
    /// Absent when the browser is not running and this daemon holds no answer for it: macOS
    /// resolves a grant only for a running target, so there is nothing true to report.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<AutomationAuthorization>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub leg: Option<AutomationLeg>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// The result of `automation.status`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AutomationStatusReport {
    /// The strongest need among running browsers: explain over request over none.
    pub need: ConsentNeed,
    pub browsers: Vec<BrowserConsentState>,
}

/// The outcome of a deliberate consent request for one running browser.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConsentOutcome {
    pub app: String,
    pub bundle_identifier: String,
    pub granted: bool,
    /// Why consent was not granted, in a sentence a person can act on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// The result of `automation.request`.
///
/// An empty `outcomes` means no supported browser was running, so there was nothing macOS could
/// grant; it is not a failure.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AutomationRequestReport {
    /// The need that remains after the request, so the shell can retire its item without asking
    /// again.
    pub need: ConsentNeed,
    pub outcomes: Vec<ConsentOutcome>,
}

/// The JSON-RPC error code shared by the daemon's one-at-a-time conflicts.
pub const CONFLICT_ERROR_CODE: i64 = -32005;

/// The refusal for a consent request made while another is still waiting on a person.
///
/// The prompting determination blocks until the dialog is answered, and two concurrent prompts
/// for the same daemon identity would race each other's dialogs.
pub fn consent_in_progress() -> JsonRpcError {
    JsonRpcError {
        code: CONFLICT_ERROR_CODE,
        message: "a consent request is already waiting on a person".into(),
        data: Some(json!({"reason":"consent-in-progress"})),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn need_follows_precedence_explain_over_request_over_none() {
        let strongest = [
            AutomationAuthorization::Granted,
            AutomationAuthorization::NotDetermined,
            AutomationAuthorization::Failed,
        ]
        .into_iter()
        .map(ConsentNeed::of)
        .max()
        .unwrap_or_default();
        assert_eq!(strongest, ConsentNeed::Explain);
        assert_eq!(
            [AutomationAuthorization::Granted, AutomationAuthorization::NotDetermined]
                .into_iter()
                .map(ConsentNeed::of)
                .max(),
            Some(ConsentNeed::Request)
        );
        assert_eq!(
            std::iter::empty().max().unwrap_or(ConsentNeed::default()),
            ConsentNeed::None
        );
    }
}
