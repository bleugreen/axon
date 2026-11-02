//! Apple Events consent for the browsers Axon can script, issued and remembered by the daemon.
//!
//! The daemon is the sender macOS attributes Apple events to, so it is the only process that can
//! truthfully ask whether a grant exists and the only one whose prompt mints the right grant. The
//! menu shell triggers the prompt (`automation.request`) and reads the state (`automation.status`)
//! over the socket; it never asks macOS itself.
//!
//! macOS resolves an authorization inside the sending process once the process holds an answer
//! for a sender/target pair, and a later `tccutil reset` cannot reach into a running process. The
//! ledger here records every answer this process received, from either determination, so the menu
//! can decide whether its item has anything left to offer without putting the question to macOS on
//! every open, and so a denial can say when it may be stale. The browser verbs consult the same
//! ledger silently before they send, and record the one answer only a sent event can produce: a
//! refusal of the event itself. This ports `AppleEventAnswerLedger`,
//! `AppleEventAuthorizationService`, and `BrowserAutomationConsentRequester` in
//! `Sources/AxonCore/BrowserAutomation.swift`.

use crate::browser::Dictionary;
use axon_core::{
    AutomationAuthorization, AutomationLeg, AutomationRequestReport, AutomationStatusReport,
    BrowserCapability, BrowserConsentState, BrowserError, BrowserRefusalData,
    BrowserRefusalReason, ConsentNeed, ConsentOutcome, JsonRpcError, consent_in_progress,
};
use std::{
    collections::HashMap,
    sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

pub(crate) const NO_ERR: i32 = 0;
pub(crate) use crate::apple_events::{EVENT_NOT_PERMITTED, WOULD_REQUIRE_CONSENT};

/// A browser Axon can script, and the one list every consent path and every verb resolves
/// against.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SupportedBrowser {
    pub bundle_identifier: &'static str,
    pub name: &'static str,
    pub dictionary: Dictionary,
}

pub(crate) const SAFARI: SupportedBrowser = SupportedBrowser {
    bundle_identifier: "com.apple.Safari",
    name: "Safari",
    dictionary: Dictionary::SAFARI,
};

pub(crate) const CHROME: SupportedBrowser = SupportedBrowser {
    bundle_identifier: "com.google.Chrome",
    name: "Google Chrome",
    dictionary: Dictionary::CHROME,
};

pub(crate) const SUPPORTED_BROWSERS: &[SupportedBrowser] = &[SAFARI, CHROME];

impl SupportedBrowser {
    /// The browser a caller named: by display name, Chrome's short name, or exact bundle
    /// identifier, ignoring case.
    pub(crate) fn named(query: &str) -> Option<Self> {
        match query.to_lowercase().as_str() {
            "safari" | "com.apple.safari" => Some(SAFARI),
            "google chrome" | "chrome" | "com.google.chrome" => Some(CHROME),
            _ => None,
        }
    }
}

/// Which surface asked for the authorization that was refused. Remediation depends on it: a
/// verb's refusal can send the user to the menu's consent gesture, and the gesture's own refusal
/// cannot send them back to itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Origin {
    BrowserVerb,
    ConsentGesture,
}

/// The two system facts consent depends on, separated so the decision logic can be exercised
/// without touching TCC.
pub(crate) trait AutomationHost: Send + Sync {
    /// `AEDeterminePermissionToAutomateTarget` for every event of `bundle_identifier`. With `ask`
    /// it may present the consent dialog and blocks until a person answers it.
    fn determine(&self, bundle_identifier: &str, ask: bool) -> i32;
    /// Whether an application with this bundle identifier is running. macOS can only resolve a
    /// grant for a running target.
    fn is_running(&self, bundle_identifier: &str) -> bool;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Answer {
    status: i32,
    leg: AutomationLeg,
}

struct Decision {
    status: i32,
    leg: AutomationLeg,
    answered_earlier_in_this_process: bool,
}

pub(crate) struct ConsentService {
    host: Box<dyn AutomationHost>,
    ledger: Mutex<HashMap<String, Answer>>,
    in_flight: AtomicBool,
}

/// Clears the one-request-at-a-time flag however the request ends.
struct InFlight<'a>(&'a AtomicBool);
impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

fn authorization(status: i32) -> AutomationAuthorization {
    match status {
        NO_ERR => AutomationAuthorization::Granted,
        EVENT_NOT_PERMITTED => AutomationAuthorization::Denied,
        WOULD_REQUIRE_CONSENT => AutomationAuthorization::NotDetermined,
        _ => AutomationAuthorization::Failed,
    }
}

fn failure_detail(app: &str, status: i32) -> String {
    format!("Could not determine Automation permission for {app} (OSStatus {status})")
}

/// Why an authorization was refused, worded for the surface that asked.
///
/// A verb's remediation names the menu's Browser Automation item, the one step the user has not
/// taken yet; until consent has been requested once there is no Axon row in System Settings, so an
/// undetermined grant is never pointed there. The gesture is the end of the road, so none of its
/// sentences may send the user back to it: a recorded denial is changed in System Settings, and an
/// undetermined answer after a prompt means macOS never showed the dialog, which only a fresh
/// daemon process can retry.
fn denial_message(
    app: &str,
    authorization: AutomationAuthorization,
    origin: Origin,
    answered_earlier_in_this_process: bool,
) -> String {
    let denied = authorization == AutomationAuthorization::Denied;
    let mut sentences = vec![format!(
        "Automation permission for {app} {}.",
        if denied {
            "is denied"
        } else {
            "has not been granted"
        }
    )];
    sentences.push(match (origin, denied) {
        (Origin::BrowserVerb, false) => "Open the Axon menu bar item and choose Browser \
             Automation... to grant it. Axon does not appear in System Settings > Privacy & \
             Security > Automation until consent has been requested once."
            .to_owned(),
        (Origin::BrowserVerb, true) => format!(
            "If Axon is listed in System Settings > Privacy & Security > Automation, enable {app} \
             beneath it. If it is not listed, open the Axon menu bar item and choose Browser \
             Automation... to request consent."
        ),
        (Origin::ConsentGesture, true) => format!(
            "macOS will not present the consent dialog again while a denial is recorded, so \
             enable {app} beneath Axon in System Settings > Privacy & Security > Automation. \
             If Axon is not listed there at all, macOS refused without recording anything, \
             which no setting on this Mac can change: install the latest Axon and try again."
        ),
        (Origin::ConsentGesture, false) => "macOS neither presented the consent dialog nor \
             recorded an answer, so there is nothing to enable in System Settings > Privacy & \
             Security > Automation yet. Restart the daemon with `launchctl kickstart -k \
             gui/$(id -u)/dev.axon.daemon` to retry from a fresh process; if the dialog still \
             does not appear, install the latest Axon."
            .to_owned(),
    });
    if answered_earlier_in_this_process {
        sentences.push(format!(
            "The Axon daemon already resolved Automation for {app} earlier in this session and \
             macOS can answer from what the process holds, so this may not reflect current \
             settings. Restart the daemon with `launchctl kickstart -k gui/$(id -u)/dev.axon.daemon` \
             to re-check."
        ));
    }
    sentences.join(" ")
}

/// The explanation for a consent request that did not end in a grant.
fn refusal_detail(app: &str, decision: &Decision) -> String {
    match authorization(decision.status) {
        status @ (AutomationAuthorization::Denied | AutomationAuthorization::NotDetermined) => {
            denial_message(
                app,
                status,
                Origin::ConsentGesture,
                decision.answered_earlier_in_this_process,
            )
        }
        AutomationAuthorization::Granted | AutomationAuthorization::Failed => {
            failure_detail(app, decision.status)
        }
    }
}

/// A browser verb's refusal for want of consent.
pub(crate) fn verb_denial(
    browser: &SupportedBrowser,
    authorization: AutomationAuthorization,
    leg: AutomationLeg,
    status: i32,
    answered_earlier_in_this_process: bool,
) -> BrowserError {
    BrowserError::NotGranted {
        message: denial_message(
            browser.name,
            authorization,
            Origin::BrowserVerb,
            answered_earlier_in_this_process,
        ),
        data: BrowserRefusalData {
            capability: BrowserCapability::BrowserAutomation,
            reason: BrowserRefusalReason::AutomationNotGranted,
            app: browser.name.into(),
            authorization,
            leg,
            native_status: Some(status),
        },
    }
}

impl ConsentService {
    pub(crate) fn new(host: Box<dyn AutomationHost>) -> Self {
        Self {
            host,
            ledger: Mutex::new(HashMap::new()),
            in_flight: AtomicBool::new(false),
        }
    }

    #[cfg(target_os = "macos")]
    pub(crate) fn system() -> Self {
        Self::new(Box::new(SystemAutomationHost))
    }

    pub(crate) fn is_running(&self, bundle_identifier: &str) -> bool {
        self.host.is_running(bundle_identifier)
    }

    fn held(&self, bundle_identifier: &str) -> Option<Answer> {
        self.ledger
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(bundle_identifier)
            .copied()
    }

    /// The one way an answer enters the ledger.
    ///
    /// An executed-leg denial contradicts a passing determination for the same target: the
    /// determination said yes and the event itself was refused. For the rest of this process's
    /// life the determination is known to answer wrongly there, so its `noErr` must not retire the
    /// denial, and with it the menu item carrying the only remediation. Only the dialog replaces
    /// it, because that answer is a person deciding now; otherwise the daemon restarts and the
    /// ledger starts empty.
    fn record(&self, bundle_identifier: &str, answer: Answer) {
        let mut ledger = self
            .ledger
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if ledger
            .get(bundle_identifier)
            .is_some_and(|held| held.leg == AutomationLeg::Executed)
            && answer.leg != AutomationLeg::Prompted
        {
            return;
        }
        ledger.insert(bundle_identifier.to_owned(), answer);
    }

    /// The silent check every browser verb makes before it sends: never prompts, and refuses
    /// with the remediation a verb's caller can act on.
    pub(crate) fn check(&self, browser: &SupportedBrowser) -> Result<(), BrowserError> {
        let answered_earlier = self.held(browser.bundle_identifier).is_some();
        let decision = self.determine(browser.bundle_identifier, false, answered_earlier);
        match authorization(decision.status) {
            AutomationAuthorization::Granted => Ok(()),
            status @ (AutomationAuthorization::Denied | AutomationAuthorization::NotDetermined) => {
                Err(verb_denial(
                    browser,
                    status,
                    AutomationLeg::Checked,
                    decision.status,
                    decision.answered_earlier_in_this_process,
                ))
            }
            AutomationAuthorization::Failed => Err(BrowserError::AuthorizationFailed {
                app: browser.name.into(),
                status: decision.status,
            }),
        }
    }

    /// The event itself was refused after the check passed. That is macOS answering this
    /// process, so the ledger takes it; otherwise the passing check would be the last word, the
    /// menu would retire its consent item, and this refusal, which names that item, would point at
    /// a surface that is gone.
    pub(crate) fn record_executed_denial(&self, browser: &SupportedBrowser) {
        self.record(
            browser.bundle_identifier,
            Answer {
                status: EVENT_NOT_PERMITTED,
                leg: AutomationLeg::Executed,
            },
        );
        eprintln!(
            "axon-mac: automation authorization target={} leg=executed status={EVENT_NOT_PERMITTED} \
             answeredEarlierInThisProcess=false",
            browser.bundle_identifier
        );
    }

    /// One determination, recorded and logged. The host call runs outside the ledger lock: the
    /// prompting leg can block for as long as the dialog is up, and `automation.status` must still
    /// answer meanwhile.
    fn determine(&self, bundle_identifier: &str, ask: bool, answered_earlier: bool) -> Decision {
        let status = self.host.determine(bundle_identifier, ask);
        let leg = if ask {
            AutomationLeg::Prompted
        } else {
            AutomationLeg::Checked
        };
        // Staleness is a property of the silent leg only: a prompted answer is a person deciding
        // in this moment, and no restart changes it.
        let answered_earlier_in_this_process = !ask && answered_earlier;
        // An unexpected status means the call failed rather than that macOS answered, so it must
        // not make a later denial claim this process holds a stale answer.
        if matches!(status, NO_ERR | EVENT_NOT_PERMITTED | WOULD_REQUIRE_CONSENT) {
            self.record(bundle_identifier, Answer { status, leg });
        }
        eprintln!(
            "axon-mac: automation authorization target={bundle_identifier} leg={} status={status} \
             answeredEarlierInThisProcess={answered_earlier_in_this_process}",
            leg_name(leg)
        );
        Decision {
            status,
            leg,
            answered_earlier_in_this_process,
        }
    }

    /// The answer this process already holds, or one silent determination when it holds none.
    ///
    /// Never prompts, and never re-asks macOS about a target it has been answered for: the menu
    /// asks this every time it opens, and must neither cost a TCC round trip each time nor make
    /// this process hold an answer earlier than a person's own use of Axon would.
    fn settled(&self, bundle_identifier: &str) -> Answer {
        if let Some(held) = self.held(bundle_identifier) {
            return held;
        }
        let decision = self.determine(bundle_identifier, false, false);
        Answer {
            status: decision.status,
            leg: decision.leg,
        }
    }

    /// `automation.status`: what the consent gesture still has to offer, resolved without
    /// prompting.
    pub(crate) fn status(&self) -> AutomationStatusReport {
        let mut need = ConsentNeed::None;
        let browsers = SUPPORTED_BROWSERS
            .iter()
            .map(|browser| {
                let running = self.host.is_running(browser.bundle_identifier);
                let answer = if running {
                    Some(self.settled(browser.bundle_identifier))
                } else {
                    self.held(browser.bundle_identifier)
                };
                let status = answer.map(|answer| authorization(answer.status));
                if running && let Some(status) = status {
                    need = need.max(ConsentNeed::of(status));
                }
                BrowserConsentState {
                    app: browser.name.into(),
                    bundle_identifier: browser.bundle_identifier.into(),
                    running,
                    status,
                    leg: answer.map(|answer| answer.leg),
                    detail: answer
                        .filter(|answer| {
                            authorization(answer.status) == AutomationAuthorization::Failed
                        })
                        .map(|answer| failure_detail(browser.name, answer.status)),
                }
            })
            .collect();
        AutomationStatusReport { need, browsers }
    }

    /// `automation.request`: a deliberate consent request for every running supported browser.
    ///
    /// Blocks while a dialog is up. Only one request may run at a time; a second is refused rather
    /// than queued behind a dialog nobody may be looking at.
    pub(crate) fn request(&self) -> Result<AutomationRequestReport, JsonRpcError> {
        if self
            .in_flight
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(consent_in_progress());
        }
        let _in_flight = InFlight(&self.in_flight);
        let outcomes = SUPPORTED_BROWSERS
            .iter()
            .filter(|browser| self.host.is_running(browser.bundle_identifier))
            .map(|browser| self.request_one(browser))
            .collect::<Vec<_>>();
        // The request just wrote its answers to the ledger, so the remaining need is read back
        // from it without asking macOS again.
        let need = SUPPORTED_BROWSERS
            .iter()
            .filter(|browser| {
                outcomes
                    .iter()
                    .any(|outcome| outcome.bundle_identifier == browser.bundle_identifier)
            })
            .filter_map(|browser| self.held(browser.bundle_identifier))
            .map(|answer| ConsentNeed::of(authorization(answer.status)))
            .max()
            .unwrap_or_default();
        Ok(AutomationRequestReport { need, outcomes })
    }

    fn request_one(&self, browser: &SupportedBrowser) -> ConsentOutcome {
        // Read once, before the first leg, so this request's own silent leg does not read back as
        // an earlier answer.
        let answered_earlier = self.held(browser.bundle_identifier).is_some();
        // An event macOS refused after a determination passed is a denial no determination will
        // reproduce: asking again returns the same wrong `noErr`, the gesture would report a grant
        // and retire its own item, and the refusal that sent the user here would lead nowhere.
        if let Some(held) = self.held(browser.bundle_identifier)
            && held.leg == AutomationLeg::Executed
            && held.status == EVENT_NOT_PERMITTED
        {
            eprintln!(
                "axon-mac: automation authorization target={} leg=executed status={} \
                 answeredEarlierInThisProcess=true source=ledger",
                browser.bundle_identifier, held.status
            );
            return ConsentOutcome {
                app: browser.name.into(),
                bundle_identifier: browser.bundle_identifier.into(),
                granted: false,
                detail: Some(denial_message(
                    browser.name,
                    AutomationAuthorization::Denied,
                    Origin::ConsentGesture,
                    answered_earlier,
                )),
            };
        }
        let initial = self.determine(browser.bundle_identifier, false, answered_earlier);
        // Only an undetermined grant can be prompted for. macOS will not present a dialog over a
        // recorded denial, so prompting there would only repeat the answer.
        let decision = if initial.status == WOULD_REQUIRE_CONSENT {
            self.determine(browser.bundle_identifier, true, answered_earlier)
        } else {
            initial
        };
        let granted = decision.status == NO_ERR;
        ConsentOutcome {
            app: browser.name.into(),
            bundle_identifier: browser.bundle_identifier.into(),
            granted,
            detail: (!granted).then(|| refusal_detail(browser.name, &decision)),
        }
    }
}

fn leg_name(leg: AutomationLeg) -> &'static str {
    match leg {
        AutomationLeg::Checked => "checked",
        AutomationLeg::Prompted => "prompted",
        AutomationLeg::Executed => "executed",
    }
}

#[cfg(target_os = "macos")]
pub(crate) struct SystemAutomationHost;

#[cfg(target_os = "macos")]
impl AutomationHost for SystemAutomationHost {
    fn determine(&self, bundle_identifier: &str, ask: bool) -> i32 {
        crate::apple_events::system::determine_permission(bundle_identifier, ask)
    }

    fn is_running(&self, bundle_identifier: &str) -> bool {
        !crate::workspace::processes_with_bundle(bundle_identifier).is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex as StdMutex, mpsc};

    /// A scripted host: per-browser running state, and the status each leg answers with.
    #[derive(Clone, Default)]
    struct Fake {
        running: Vec<&'static str>,
        checked: HashMap<&'static str, i32>,
        prompted: HashMap<&'static str, i32>,
        calls: Arc<StdMutex<Vec<(String, bool)>>>,
        gate: Option<Arc<StdMutex<mpsc::Receiver<()>>>>,
    }

    impl AutomationHost for Fake {
        fn determine(&self, bundle_identifier: &str, ask: bool) -> i32 {
            self.calls
                .lock()
                .unwrap()
                .push((bundle_identifier.into(), ask));
            if ask && let Some(gate) = &self.gate {
                gate.lock().unwrap().recv().unwrap();
            }
            let table = if ask { &self.prompted } else { &self.checked };
            *table.get(bundle_identifier).unwrap_or(&-600)
        }
        fn is_running(&self, bundle_identifier: &str) -> bool {
            self.running.contains(&bundle_identifier)
        }
    }

    const SAFARI: &str = "com.apple.Safari";
    const CHROME: &str = "com.google.Chrome";

    fn service(fake: &Fake) -> ConsentService {
        ConsentService::new(Box::new(fake.clone()))
    }

    #[test]
    fn status_never_prompts_and_reads_each_target_once() {
        let fake = Fake {
            running: vec![SAFARI],
            checked: HashMap::from([(SAFARI, WOULD_REQUIRE_CONSENT)]),
            ..Fake::default()
        };
        let consent = service(&fake);
        let first = consent.status();
        let second = consent.status();

        assert_eq!(first, second);
        assert_eq!(first.need, ConsentNeed::Request);
        assert_eq!(
            *fake.calls.lock().unwrap(),
            vec![(SAFARI.to_owned(), false)],
            "one silent determination, then the ledger"
        );
        let chrome = &first.browsers[1];
        assert!(!chrome.running);
        assert_eq!(
            chrome.status, None,
            "no claim about a browser macOS cannot answer for"
        );
    }

    #[test]
    fn explain_outranks_request_and_failures_explain() {
        let fake = Fake {
            running: vec![SAFARI, CHROME],
            checked: HashMap::from([
                (SAFARI, WOULD_REQUIRE_CONSENT),
                (CHROME, EVENT_NOT_PERMITTED),
            ]),
            ..Fake::default()
        };
        assert_eq!(service(&fake).status().need, ConsentNeed::Explain);

        let failing = Fake {
            running: vec![SAFARI],
            checked: HashMap::from([(SAFARI, -50)]),
            ..Fake::default()
        };
        let report = service(&failing).status();
        assert_eq!(report.need, ConsentNeed::Explain);
        assert_eq!(
            report.browsers[0].status,
            Some(AutomationAuthorization::Failed)
        );
        assert!(
            report.browsers[0]
                .detail
                .as_deref()
                .unwrap()
                .contains("OSStatus -50")
        );
    }

    #[test]
    fn a_failed_determination_is_not_remembered_as_an_answer() {
        let fake = Fake {
            running: vec![SAFARI],
            checked: HashMap::from([(SAFARI, -50)]),
            ..Fake::default()
        };
        let consent = service(&fake);
        consent.status();
        consent.status();
        assert_eq!(
            fake.calls.lock().unwrap().len(),
            2,
            "asked again: nothing was answered"
        );
    }

    #[test]
    fn request_prompts_only_for_an_undetermined_grant() {
        let fake = Fake {
            running: vec![SAFARI, CHROME],
            checked: HashMap::from([
                (SAFARI, WOULD_REQUIRE_CONSENT),
                (CHROME, EVENT_NOT_PERMITTED),
            ]),
            prompted: HashMap::from([(SAFARI, NO_ERR)]),
            ..Fake::default()
        };
        let consent = service(&fake);
        let report = consent.request().unwrap();

        assert_eq!(
            *fake.calls.lock().unwrap(),
            vec![
                (SAFARI.to_owned(), false),
                (SAFARI.to_owned(), true),
                (CHROME.to_owned(), false)
            ]
        );
        assert!(report.outcomes[0].granted);
        assert_eq!(report.outcomes[0].detail, None);
        assert!(!report.outcomes[1].granted);
        let detail = report.outcomes[1].detail.as_deref().unwrap();
        assert!(detail.starts_with("Automation permission for Google Chrome is denied."));
        assert!(
            !detail.contains("Browser Automation..."),
            "the gesture must not point at itself"
        );
        assert_eq!(report.need, ConsentNeed::Explain);

        // The prompt's answer retires the item without another round trip.
        let calls_before = fake.calls.lock().unwrap().len();
        let status = consent.status();
        assert_eq!(status.browsers[0].leg, Some(AutomationLeg::Prompted));
        assert_eq!(
            status.browsers[0].status,
            Some(AutomationAuthorization::Granted)
        );
        assert_eq!(fake.calls.lock().unwrap().len(), calls_before);
    }

    #[test]
    fn a_denial_after_an_earlier_answer_says_it_may_be_stale() {
        let fake = Fake {
            running: vec![SAFARI],
            checked: HashMap::from([(SAFARI, EVENT_NOT_PERMITTED)]),
            ..Fake::default()
        };
        let consent = service(&fake);
        let first = consent.request().unwrap();
        assert!(
            !first.outcomes[0]
                .detail
                .as_deref()
                .unwrap()
                .contains("earlier in this session")
        );
        let second = consent.request().unwrap();
        assert!(
            second.outcomes[0]
                .detail
                .as_deref()
                .unwrap()
                .contains("earlier in this session")
        );
    }

    #[test]
    fn no_running_browser_is_an_empty_request_not_a_failure() {
        let report = service(&Fake::default()).request().unwrap();
        assert!(report.outcomes.is_empty());
        assert_eq!(report.need, ConsentNeed::None);
    }

    #[test]
    fn a_second_request_while_one_waits_on_a_person_is_refused_and_status_still_answers() {
        let (release, gate) = mpsc::channel();
        let fake = Fake {
            running: vec![SAFARI],
            checked: HashMap::from([(SAFARI, WOULD_REQUIRE_CONSENT)]),
            prompted: HashMap::from([(SAFARI, NO_ERR)]),
            gate: Some(Arc::new(StdMutex::new(gate))),
            ..Fake::default()
        };
        let consent = Arc::new(service(&fake));
        let waiting = {
            let consent = Arc::clone(&consent);
            std::thread::spawn(move || consent.request())
        };
        while !fake.calls.lock().unwrap().iter().any(|(_, ask)| *ask) {
            std::thread::yield_now();
        }

        let refused = consent.request().unwrap_err();
        assert_eq!(refused.code, -32005);
        assert_eq!(refused.data.unwrap()["reason"], "consent-in-progress");
        assert_eq!(
            consent.status().need,
            ConsentNeed::Request,
            "status answers mid-dialog"
        );

        release.send(()).unwrap();
        assert!(waiting.join().unwrap().unwrap().outcomes[0].granted);
        // The scripted silent leg still answers undetermined, so the next request prompts again.
        release.send(()).unwrap();
        assert!(
            consent.request().is_ok(),
            "the flag clears when the request ends"
        );
    }

    fn shell_fixture(name: &str) -> serde_json::Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../schema/fixtures/shell")
            .join(name);
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    /// The service produces exactly the shapes shell-v1 pins, from the scenarios they describe.
    #[test]
    fn the_service_answers_with_the_pinned_shell_fixtures() {
        let undetermined = Fake {
            running: vec![SAFARI],
            checked: HashMap::from([(SAFARI, WOULD_REQUIRE_CONSENT)]),
            prompted: HashMap::from([(SAFARI, NO_ERR)]),
            ..Fake::default()
        };
        let consent = service(&undetermined);
        assert_eq!(
            serde_json::to_value(consent.status()).unwrap(),
            shell_fixture("automation-status.json")
        );
        assert_eq!(
            serde_json::to_value(consent.request().unwrap()).unwrap(),
            shell_fixture("automation-request.json")
        );
        assert_eq!(
            serde_json::to_value(service(&Fake::default()).request().unwrap()).unwrap(),
            shell_fixture("automation-request-no-browser.json")
        );
    }

    #[test]
    fn the_bundle_id_descriptor_type_codes_match_the_headers() {
        assert_eq!(TYPE_APPLICATION_BUNDLE_ID, 0x6275_6e64);
        assert_eq!(TYPE_WILD_CARD, 0x2a2a_2a2a);
        assert_eq!(std::mem::size_of::<AEDesc>(), 12);
    }
}
