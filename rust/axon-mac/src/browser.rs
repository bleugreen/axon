//! `navigate`, `windows`, and `tabs` on macOS: questions put to a browser's scripting dictionary
//! through Apple events the daemon sends itself.
//!
//! Each verb resolves its browser in the order Swift does (`AppleScriptBrowserAutomation`):
//! `navigate` validates its URL before anything else, so bad input never reaches the Automation
//! boundary; then the browser is named, must be running, and must pass the consent ledger's silent
//! check. Only then is an event sent, and an event macOS refuses is recorded as the executed leg
//! the check could not see. The questions are the ones Swift's scripts ask, one event each, so the
//! answers are the same ones.
//!
//! Every event waits at most 15 seconds (Swift's `with timeout of 15 seconds`), and every verb
//! spends its events from one budget, so a browser that is slow without being hung cannot hold
//! the serialized backend worker past the socket client's 30-second request timeout. `navigate`
//! spends at most 15 seconds dispatching, the settle's 4-second wall-clock bound, and one trailing
//! read.

use crate::{
    apple_events::{AeError, AeQuery, AeValue, AppleEventTransport, Code, Spec},
    automation::{ConsentService, SupportedBrowser, verb_denial},
};
use axon_core::{
    AutomationAuthorization, AutomationLeg, BrowserError, BrowserTab, BrowserWindow, Clock,
    NavigateResult, NavigationReport, Settler, TabReading, validate_navigation_url,
};
use std::{sync::Arc, time::Duration};

const WINDOW: Code = Code::of(b"cwin");
const NAME: Code = Code::of(b"pnam");
const INDEX: Code = Code::of(b"pidx");

/// The longest one event may wait for its reply.
const EVENT_TIMEOUT_MS: u64 = 15_000;
/// What `navigate` may spend before its navigation is sent: the window count, the baseline
/// reading, and the `set`.
const DISPATCH_BUDGET_MS: u64 = 15_000;
/// What the reading in flight when the settle bound passes may still take.
const TRAILING_READ_MS: u64 = 5_000;
/// What a whole `windows` or `tabs` enumeration may spend.
const ENUMERATION_BUDGET_MS: u64 = 25_000;

/// How a browser reports which of a window's tabs is active.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ActiveIndex {
    /// `index of current tab of window`: Safari, whose window has no index property for it.
    OfCurrentTab,
    /// A window property holding the index: Chrome's `active tab index`.
    WindowProperty(Code),
}

/// The codes one browser's scripting dictionary uses for what the verbs ask, measured from its
/// sdef (Safari 26.4 and 26.6, Chrome 154) and from AppleScript's own events.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Dictionary {
    pub tab_class: Code,
    pub url: Code,
    /// The window property naming its current (Safari) or active (Chrome) tab.
    pub current_tab: Code,
    pub active_index: ActiveIndex,
    /// The tab's loading flag, which only Chrome publishes.
    pub loading: Option<Code>,
}

impl Dictionary {
    pub const SAFARI: Self = Self {
        tab_class: Code::of(b"bTab"),
        url: Code::of(b"pURL"),
        current_tab: Code::of(b"cTab"),
        active_index: ActiveIndex::OfCurrentTab,
        loading: None,
    };
    pub const CHROME: Self = Self {
        tab_class: Code::of(b"CrTb"),
        url: Code::of(b"URL "),
        current_tab: Code::of(b"acTa"),
        active_index: ActiveIndex::WindowProperty(Code::of(b"acTI")),
        loading: Some(Code::of(b"ldng")),
    };

    /// Window `index`, front to back. `front window` is window 1, as AppleScript sends it.
    pub fn window(index: i32) -> Spec {
        Spec::element(WINDOW, index, Spec::Application)
    }

    pub fn window_name(index: i32) -> Spec {
        Spec::property(NAME, Self::window(index))
    }

    pub fn count_windows(&self) -> AeQuery {
        AeQuery::Count {
            container: Spec::Application,
            class: WINDOW,
        }
    }

    pub fn count_tabs(&self, window: i32) -> AeQuery {
        AeQuery::Count {
            container: Self::window(window),
            class: self.tab_class,
        }
    }

    pub fn active_index(&self, window: i32) -> AeQuery {
        AeQuery::Get(match self.active_index {
            ActiveIndex::OfCurrentTab => Spec::property(
                INDEX,
                Spec::property(self.current_tab, Self::window(window)),
            ),
            ActiveIndex::WindowProperty(code) => Spec::property(code, Self::window(window)),
        })
    }

    pub fn active_tab_property(&self, window: i32, code: Code) -> Spec {
        Spec::property(code, Spec::property(self.current_tab, Self::window(window)))
    }

    pub fn tab_property(&self, window: i32, tab: i32, code: Code) -> Spec {
        Spec::property(
            code,
            Spec::element(self.tab_class, tab, Self::window(window)),
        )
    }
}

/// The browser verbs as the router calls them.
pub(crate) trait BrowserVerbs: Send {
    fn navigate(&self, app: &str, url: &str) -> Result<NavigateResult, BrowserError>;
    fn windows(&self, app: &str) -> Result<Vec<BrowserWindow>, BrowserError>;
    fn tabs(&self, app: &str, window: Option<i64>) -> Result<Vec<BrowserTab>, BrowserError>;
}

pub(crate) struct BrowserService {
    consent: Arc<ConsentService>,
    transport: Box<dyn AppleEventTransport>,
    clock: Arc<dyn Clock>,
    settler: Settler,
}

impl BrowserService {
    pub(crate) fn new(
        consent: Arc<ConsentService>,
        transport: Box<dyn AppleEventTransport>,
        clock: Arc<dyn Clock>,
    ) -> Self {
        Self {
            consent,
            transport,
            clock,
            settler: Settler::default(),
        }
    }

    /// The daemon's service: real events, real time, and the ledger `automation.*` answers from.
    #[cfg(target_os = "macos")]
    pub(crate) fn system(consent: Arc<ConsentService>) -> Self {
        Self::new(
            consent,
            Box::new(crate::apple_events::system::SystemTransport),
            Arc::new(axon_core::SystemClock::default()),
        )
    }

    fn resolve(&self, app: &str) -> Result<SupportedBrowser, BrowserError> {
        let browser =
            SupportedBrowser::named(app).ok_or_else(|| BrowserError::UnsupportedApp(app.into()))?;
        if !self.consent.is_running(browser.bundle_identifier) {
            return Err(BrowserError::AppNotRunning(browser.name.into()));
        }
        // Check only: an agent's call must never block on a consent dialog it did not ask for.
        self.consent.check(&browser)?;
        Ok(browser)
    }

    fn deadline(&self, budget_ms: u64) -> u64 {
        self.clock.now_ms() + budget_ms
    }

    /// One event, waiting no longer than the event limit or what remains of `deadline`.
    fn send(
        &self,
        browser: &SupportedBrowser,
        query: &AeQuery,
        deadline: u64,
    ) -> Result<AeValue, BrowserError> {
        let now = self.clock.now_ms();
        if now >= deadline {
            return Err(BrowserError::Timeout(browser.name.into()));
        }
        let timeout = Duration::from_millis((deadline - now).min(EVENT_TIMEOUT_MS));
        self.transport
            .send(browser.bundle_identifier, query, timeout)
            .map_err(|error| self.refused(browser, error))
    }

    fn refused(&self, browser: &SupportedBrowser, error: AeError) -> BrowserError {
        match error {
            // The event itself was refused after the check passed: the one answer only a sent
            // event produces, and the one the ledger must keep.
            AeError::NotPermitted => {
                self.consent.record_executed_denial(browser);
                verb_denial(
                    browser,
                    AutomationAuthorization::Denied,
                    AutomationLeg::Executed,
                    crate::apple_events::EVENT_NOT_PERMITTED,
                    false,
                )
            }
            // Reported, not recorded: Swift records only a refused event, and a grant nobody has
            // answered is not one.
            AeError::WouldRequireConsent => verb_denial(
                browser,
                AutomationAuthorization::NotDetermined,
                AutomationLeg::Executed,
                crate::apple_events::WOULD_REQUIRE_CONSENT,
                false,
            ),
            AeError::Timeout => BrowserError::Timeout(browser.name.into()),
            AeError::Failed { status, message } => BrowserError::ExecutionFailed(
                message.unwrap_or_else(|| format!("OSStatus {status}")),
            ),
        }
    }

    fn count(
        &self,
        browser: &SupportedBrowser,
        query: &AeQuery,
        deadline: u64,
        what: &str,
    ) -> Result<i32, BrowserError> {
        match self.send(browser, query, deadline)? {
            AeValue::Int(count) => Ok(count.clamp(0, i64::from(i32::MAX)) as i32),
            _ => Err(unexpected(what)),
        }
    }

    /// A property read `as text`, the way Swift's enumeration scripts coerce it.
    fn text(
        &self,
        browser: &SupportedBrowser,
        spec: Spec,
        deadline: u64,
        what: &str,
    ) -> Result<String, BrowserError> {
        match self.send(browser, &AeQuery::Get(spec), deadline)? {
            AeValue::Text(text) => Ok(text),
            AeValue::Missing => Ok("missing value".into()),
            AeValue::Int(number) => Ok(number.to_string()),
            AeValue::Bool(flag) => Ok(flag.to_string()),
            AeValue::Null => Ok(String::new()),
            AeValue::List(_) => Err(unexpected(what)),
        }
    }

    /// The active tab of the front window: its URL, its name, and, where the dictionary has one,
    /// its loading flag. A loading flag the browser will not answer degrades to the stability
    /// window rather than failing the navigation, as Swift's `try` does; a consent refusal or a
    /// timeout is still reported.
    fn read_active_tab(
        &self,
        browser: &SupportedBrowser,
        deadline: u64,
    ) -> Result<TabReading, BrowserError> {
        let dictionary = browser.dictionary;
        let read = |code: Code| {
            self.send(
                browser,
                &AeQuery::Get(dictionary.active_tab_property(1, code)),
                deadline,
            )
        };
        let text = |value: AeValue| match value {
            AeValue::Text(text) => Ok(text),
            AeValue::Missing | AeValue::Null => Ok(String::new()),
            _ => Err(unexpected("navigation")),
        };
        let url = text(read(dictionary.url)?)?;
        let title = text(read(NAME)?)?;
        let loading = match dictionary.loading {
            None => None,
            Some(code) => match read(code) {
                Ok(AeValue::Bool(flag)) => Some(flag),
                Ok(_) | Err(BrowserError::ExecutionFailed(_)) => None,
                Err(error) => return Err(error),
            },
        };
        Ok(TabReading {
            url,
            title,
            loading,
        })
    }
}

fn unexpected(what: &str) -> BrowserError {
    BrowserError::ExecutionFailed(format!("unexpected {what} response"))
}

impl BrowserVerbs for BrowserService {
    fn navigate(&self, app: &str, url: &str) -> Result<NavigateResult, BrowserError> {
        validate_navigation_url(url)?;
        let browser = self.resolve(app)?;
        let dictionary = browser.dictionary;
        let dispatch = self.deadline(DISPATCH_BUDGET_MS);
        if self.count(
            &browser,
            &dictionary.count_windows(),
            dispatch,
            "navigation",
        )? == 0
        {
            return Err(BrowserError::ExecutionFailed(
                "browser has no windows".into(),
            ));
        }
        // The baseline is read before the navigation is sent, so the settle can tell the page
        // being left from the one arriving.
        let before = self.read_active_tab(&browser, dispatch)?;
        self.send(
            &browser,
            &AeQuery::Set(
                dictionary.active_tab_property(1, dictionary.url),
                url.into(),
            ),
            dispatch,
        )?;
        let reads = self.deadline(self.settler.timeout_ms + TRAILING_READ_MS);
        let outcome = self.settler.settle(&*self.clock, url, &before, || {
            self.read_active_tab(&browser, reads)
        })?;
        Ok(NavigateResult {
            navigation: NavigationReport {
                app: browser.bundle_identifier.into(),
                requested_url: url.into(),
                url: outcome.reading.url,
                title: outcome.reading.title,
                settle_evidence: outcome.evidence,
                elapsed_ms: outcome.elapsed_ms,
            },
        })
    }

    fn windows(&self, app: &str) -> Result<Vec<BrowserWindow>, BrowserError> {
        let browser = self.resolve(app)?;
        let deadline = self.deadline(ENUMERATION_BUDGET_MS);
        let count = self.count(
            &browser,
            &browser.dictionary.count_windows(),
            deadline,
            "window",
        )?;
        (1..=count)
            .map(|index| {
                let title =
                    self.text(&browser, Dictionary::window_name(index), deadline, "window")?;
                Ok(BrowserWindow::new(index as u32, title))
            })
            .collect()
    }

    fn tabs(&self, app: &str, window: Option<i64>) -> Result<Vec<BrowserTab>, BrowserError> {
        if let Some(window) = window
            && window < 1
        {
            return Err(BrowserError::InvalidWindow(window));
        }
        let browser = self.resolve(app)?;
        let dictionary = browser.dictionary;
        let deadline = self.deadline(ENUMERATION_BUDGET_MS);
        let count = self.count(&browser, &dictionary.count_windows(), deadline, "tab")?;
        if let Some(window) = window
            && window > i64::from(count)
        {
            return Err(BrowserError::InvalidWindow(window));
        }
        let windows = match window {
            Some(window) => window as i32..=window as i32,
            None => 1..=count,
        };
        let mut tabs = Vec::new();
        for window in windows {
            let active = match self.send(&browser, &dictionary.active_index(window), deadline)? {
                AeValue::Int(index) => index,
                _ => return Err(unexpected("tab")),
            };
            let tab_count =
                self.count(&browser, &dictionary.count_tabs(window), deadline, "tab")?;
            for index in 1..=tab_count {
                let title = self.text(
                    &browser,
                    dictionary.tab_property(window, index, NAME),
                    deadline,
                    "tab",
                )?;
                let url = self.text(
                    &browser,
                    dictionary.tab_property(window, index, dictionary.url),
                    deadline,
                    "tab",
                )?;
                tabs.push(BrowserTab::new(
                    window as u32,
                    index as u32,
                    title,
                    url,
                    i64::from(index) == active,
                ));
            }
        }
        Ok(tabs)
    }
}

/// A scripted browser, a scripted consent host, and a clock that only moves when told, shared by
/// these tests and the router's.
#[cfg(test)]
pub(crate) mod fake {
    use super::*;
    use crate::automation::{AutomationHost, ConsentService};
    use std::sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    };

    #[derive(Default)]
    pub(crate) struct FakeClock(AtomicU64);
    impl Clock for FakeClock {
        fn now_ms(&self) -> u64 {
            self.0.load(Ordering::SeqCst)
        }
        fn sleep_ms(&self, milliseconds: u64) {
            self.0.fetch_add(milliseconds, Ordering::SeqCst);
        }
    }

    /// Answers every silent determination with `status`, and records each one.
    pub(crate) struct Host {
        pub running: bool,
        pub status: i32,
        pub calls: Arc<Mutex<Vec<(String, bool)>>>,
    }
    impl AutomationHost for Host {
        fn determine(&self, bundle_identifier: &str, ask: bool) -> i32 {
            self.calls
                .lock()
                .unwrap()
                .push((bundle_identifier.into(), ask));
            self.status
        }
        fn is_running(&self, _: &str) -> bool {
            self.running
        }
    }

    pub(crate) struct Window {
        pub title: String,
        pub tabs: Vec<(String, String)>,
        /// One-based.
        pub active: i64,
    }

    #[derive(Default)]
    pub(crate) struct State {
        pub windows: Vec<Window>,
        /// What the front window's active tab reads before the navigation is sent.
        pub before: Option<TabReading>,
        /// What it reads after, one entry per reading, holding on the last.
        pub after: Vec<TabReading>,
        navigated: bool,
        readings: usize,
        current: Option<TabReading>,
        pub queries: Vec<AeQuery>,
        /// What every event answers instead, when set.
        pub refuse: Option<AeError>,
        /// How long each event takes to answer.
        pub latency_ms: u64,
    }

    /// A browser that answers exactly the questions a verb asks, from `State`.
    pub(crate) struct Browser {
        pub dictionary: Dictionary,
        pub state: Arc<Mutex<State>>,
        pub clock: Arc<FakeClock>,
    }

    impl Browser {
        fn answer(&self, state: &mut State, query: &AeQuery) -> Result<AeValue, AeError> {
            let d = self.dictionary;
            let window_index = |spec: &Spec| match spec {
                Spec::Element { class, index, from }
                    if *class == WINDOW && **from == Spec::Application =>
                {
                    Some(*index)
                }
                _ => None,
            };
            let missing = || AeError::Failed {
                status: -1728,
                message: Some("Can’t get object.".into()),
            };
            match query {
                AeQuery::Count {
                    container: Spec::Application,
                    class,
                } if *class == WINDOW => Ok(AeValue::Int(state.windows.len() as i64)),
                AeQuery::Count { container, class } if *class == d.tab_class => {
                    let window = window_index(container).ok_or_else(missing)?;
                    let window = state.windows.get(window as usize - 1).ok_or_else(missing)?;
                    Ok(AeValue::Int(window.tabs.len() as i64))
                }
                AeQuery::Set(spec, _) if *spec == d.active_tab_property(1, d.url) => {
                    state.navigated = true;
                    Ok(AeValue::Null)
                }
                AeQuery::Get(spec) => {
                    for window in 1..=state.windows.len() as i32 {
                        if *spec == Dictionary::window_name(window) {
                            return Ok(AeValue::Text(
                                state.windows[window as usize - 1].title.clone(),
                            ));
                        }
                        if AeQuery::Get(spec.clone()) == d.active_index(window) {
                            return Ok(AeValue::Int(state.windows[window as usize - 1].active));
                        }
                        for tab in 1..=state.windows[window as usize - 1].tabs.len() as i32 {
                            let (title, url) =
                                &state.windows[window as usize - 1].tabs[tab as usize - 1];
                            if *spec == d.tab_property(window, tab, NAME) {
                                return Ok(AeValue::Text(title.clone()));
                            }
                            if *spec == d.tab_property(window, tab, d.url) {
                                return Ok(AeValue::Text(url.clone()));
                            }
                        }
                    }
                    if *spec == d.active_tab_property(1, d.url) {
                        let reading = if state.navigated {
                            let index = state.readings.min(state.after.len() - 1);
                            state.readings += 1;
                            state.after[index].clone()
                        } else {
                            state.before.clone().ok_or_else(missing)?
                        };
                        state.current = Some(reading.clone());
                        return Ok(AeValue::Text(reading.url));
                    }
                    let current = state.current.clone().ok_or_else(missing)?;
                    if *spec == d.active_tab_property(1, NAME) {
                        return Ok(AeValue::Text(current.title));
                    }
                    if d.loading
                        .is_some_and(|code| *spec == d.active_tab_property(1, code))
                    {
                        return current.loading.map(AeValue::Bool).ok_or_else(missing);
                    }
                    Err(missing())
                }
                _ => Err(missing()),
            }
        }
    }

    impl AppleEventTransport for Browser {
        fn send(&self, _: &str, query: &AeQuery, timeout: Duration) -> Result<AeValue, AeError> {
            let mut state = self.state.lock().unwrap();
            state.queries.push(query.clone());
            let timeout = timeout.as_millis() as u64;
            if state.latency_ms > timeout {
                self.clock.sleep_ms(timeout);
                return Err(AeError::Timeout);
            }
            self.clock.sleep_ms(state.latency_ms);
            if let Some(refusal) = state.refuse.clone() {
                return Err(refusal);
            }
            self.answer(&mut state, query)
        }
    }

    /// Everything one scripted verb call needs, with handles on what it observed.
    pub(crate) struct Rig {
        pub service: BrowserService,
        pub consent: Arc<ConsentService>,
        pub state: Arc<Mutex<State>>,
        pub clock: Arc<FakeClock>,
        pub determinations: Arc<Mutex<Vec<(String, bool)>>>,
    }

    pub(crate) fn rig(dictionary: Dictionary, status: i32, state: State) -> Rig {
        rig_with(dictionary, status, true, state)
    }

    pub(crate) fn rig_with(
        dictionary: Dictionary,
        status: i32,
        running: bool,
        state: State,
    ) -> Rig {
        let clock = Arc::new(FakeClock::default());
        let state = Arc::new(Mutex::new(state));
        let determinations = Arc::new(Mutex::new(Vec::new()));
        let consent = Arc::new(ConsentService::new(Box::new(Host {
            running,
            status,
            calls: Arc::clone(&determinations),
        })));
        let service = BrowserService::new(
            Arc::clone(&consent),
            Box::new(Browser {
                dictionary,
                state: Arc::clone(&state),
                clock: Arc::clone(&clock),
            }),
            clock.clone(),
        );
        Rig {
            service,
            consent,
            state,
            clock,
            determinations,
        }
    }

    pub(crate) fn reading(url: &str, title: &str, loading: Option<bool>) -> TabReading {
        TabReading {
            url: url.into(),
            title: title.into(),
            loading,
        }
    }

    pub(crate) fn window(title: &str, tabs: &[(&str, &str)], active: i64) -> Window {
        Window {
            title: title.into(),
            tabs: tabs
                .iter()
                .map(|(title, url)| ((*title).into(), (*url).into()))
                .collect(),
            active,
        }
    }

    /// The pages each `navigate` fixture describes, scripted so the real settle reaches it.
    pub(crate) fn navigation_state(fixture: &str) -> (Dictionary, State) {
        let start = reading("https://start.example/", "Start", None);
        let one_window = || vec![window("Start", &[("Start", "https://start.example/")], 1)];
        match fixture {
            "navigate-verified.json" => (
                Dictionary::SAFARI,
                State {
                    windows: one_window(),
                    before: Some(start),
                    after: vec![reading("https://example.com/", "Example Domain", None)],
                    ..State::default()
                },
            ),
            "navigate-redirect.json" => (
                Dictionary::CHROME,
                State {
                    windows: one_window(),
                    before: Some(reading("https://start.example/", "Start", Some(false))),
                    after: vec![
                        reading("https://example.com/navigated", "Navigated", Some(true)),
                        reading("https://example.com/navigated", "Navigated", Some(false)),
                    ],
                    ..State::default()
                },
            ),
            "navigate-unsettled.json" => (
                Dictionary::CHROME,
                State {
                    windows: one_window(),
                    before: Some(reading("https://start.example/", "Start", Some(false))),
                    after: vec![reading(
                        "https://example.com/slow",
                        "example.com/slow",
                        Some(true),
                    )],
                    ..State::default()
                },
            ),
            other => panic!("no navigation scripted for {other}"),
        }
    }

    pub(crate) fn tabs_state() -> State {
        State {
            windows: vec![
                window(
                    "Navigated",
                    &[
                        ("Example Domain", "https://example.com/"),
                        ("Navigated", "https://example.com/navigated"),
                    ],
                    2,
                ),
                window("Second", &[("Second", "https://example.org/")], 1),
            ],
            ..State::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::*;
    use super::*;
    use crate::automation::{EVENT_NOT_PERMITTED, NO_ERR, WOULD_REQUIRE_CONSENT};
    use axon_core::{AutomationAuthorization, SettleEvidence};

    fn refusal(error: BrowserError) -> axon_core::BrowserRefusalData {
        match error {
            BrowserError::NotGranted { data, .. } => data,
            other => panic!("expected a consent refusal, got {other:?}"),
        }
    }

    #[test]
    fn invalid_navigation_input_never_reaches_the_automation_boundary() {
        let rig = rig(Dictionary::SAFARI, NO_ERR, State::default());
        assert_eq!(
            rig.service
                .navigate("Safari", "file:///tmp/private")
                .unwrap_err(),
            BrowserError::InvalidUrl("an absolute http or https URL is required".into())
        );
        assert!(rig.determinations.lock().unwrap().is_empty());
        assert!(rig.state.lock().unwrap().queries.is_empty());

        assert_eq!(
            rig.service.windows("Firefox").unwrap_err(),
            BrowserError::UnsupportedApp("Firefox".into())
        );
        assert_eq!(
            rig.service.tabs("Safari", Some(0)).unwrap_err(),
            BrowserError::InvalidWindow(0)
        );
        assert!(rig.determinations.lock().unwrap().is_empty());
    }

    #[test]
    fn a_browser_that_is_not_running_is_refused_before_consent_is_checked() {
        let calls = Arc::new(std::sync::Mutex::new(Vec::new()));
        let consent = Arc::new(ConsentService::new(Box::new(Host {
            running: false,
            status: NO_ERR,
            calls: Arc::clone(&calls),
        })));
        let clock = Arc::new(FakeClock::default());
        let service = BrowserService::new(
            consent,
            Box::new(Browser {
                dictionary: Dictionary::SAFARI,
                state: Default::default(),
                clock: clock.clone(),
            }),
            clock,
        );
        assert_eq!(
            service.windows("com.apple.Safari").unwrap_err(),
            BrowserError::AppNotRunning("Safari".into())
        );
        assert!(calls.lock().unwrap().is_empty());
    }

    /// Exactly one event navigates, it follows the baseline, and Safari is never asked for a
    /// loading flag it does not have.
    #[test]
    fn safari_navigation_reads_a_baseline_sends_one_set_and_settles_by_stability() {
        let (dictionary, state) = navigation_state("navigate-verified.json");
        let rig = rig(dictionary, NO_ERR, state);
        let result = rig
            .service
            .navigate("Safari", "https://example.com")
            .unwrap();

        assert!(result.navigation.success());
        assert_eq!(
            result.navigation.settle_evidence,
            SettleEvidence::StableReadback
        );
        assert_eq!(result.navigation.title, "Example Domain");
        assert_eq!(result.navigation.app, "com.apple.Safari");
        let queries = rig.state.lock().unwrap().queries.clone();
        assert_eq!(
            queries[..4],
            [
                dictionary.count_windows(),
                AeQuery::Get(dictionary.active_tab_property(1, dictionary.url)),
                AeQuery::Get(dictionary.active_tab_property(1, NAME)),
                AeQuery::Set(
                    dictionary.active_tab_property(1, dictionary.url),
                    "https://example.com".into()
                ),
            ]
        );
        assert_eq!(
            queries
                .iter()
                .filter(|query| matches!(query, AeQuery::Set(..)))
                .count(),
            1
        );
        assert!(!queries.iter().any(|query| matches!(query, AeQuery::Get(Spec::Property { code, .. }) if *code == Code::of(b"ldng"))));
        assert_eq!(
            *rig.determinations.lock().unwrap(),
            vec![("com.apple.Safari".to_owned(), false)]
        );
    }

    #[test]
    fn chrome_navigation_asks_the_active_tab_whether_it_is_still_loading() {
        let (dictionary, state) = navigation_state("navigate-redirect.json");
        let rig = rig(dictionary, NO_ERR, state);
        let result = rig
            .service
            .navigate("Chrome", "https://example.com/redirect")
            .unwrap();

        assert_eq!(
            result.navigation.settle_evidence,
            SettleEvidence::LoadingFlag
        );
        assert!(!result.navigation.success(), "a redirect is a mismatch");
        let queries = rig.state.lock().unwrap().queries.clone();
        assert_eq!(
            queries[3],
            AeQuery::Get(dictionary.active_tab_property(1, Code::of(b"ldng")))
        );
        assert!(matches!(queries[4], AeQuery::Set(..)));
        assert_eq!(dictionary.current_tab, Code::of(b"acTa"));
    }

    #[test]
    fn a_browser_with_no_windows_says_so() {
        let rig = rig(Dictionary::SAFARI, NO_ERR, State::default());
        assert_eq!(
            rig.service
                .navigate("Safari", "https://example.com")
                .unwrap_err(),
            BrowserError::ExecutionFailed("browser has no windows".into())
        );
        assert_eq!(rig.service.windows("Safari").unwrap(), vec![]);
        assert_eq!(rig.service.tabs("Safari", None).unwrap(), vec![]);
        assert_eq!(
            rig.service.tabs("Safari", Some(1)).unwrap_err(),
            BrowserError::InvalidWindow(1)
        );
    }

    #[test]
    fn windows_and_tabs_read_every_index_in_order() {
        for dictionary in [Dictionary::SAFARI, Dictionary::CHROME] {
            let rig = rig(dictionary, NO_ERR, tabs_state());
            let windows = rig.service.windows("Safari").unwrap();
            assert_eq!(
                windows,
                vec![
                    BrowserWindow::new(1, "Navigated"),
                    BrowserWindow::new(2, "Second")
                ]
            );
            assert!(windows[0].active && !windows[1].active);

            let tabs = rig.service.tabs("Safari", None).unwrap();
            assert_eq!(
                tabs,
                vec![
                    BrowserTab::new(1, 1, "Example Domain", "https://example.com/", false),
                    BrowserTab::new(1, 2, "Navigated", "https://example.com/navigated", true),
                    BrowserTab::new(2, 1, "Second", "https://example.org/", true),
                ]
            );
            assert_eq!(
                rig.service.tabs("Safari", Some(2)).unwrap(),
                vec![BrowserTab::new(
                    2,
                    1,
                    "Second",
                    "https://example.org/",
                    true
                )]
            );
            assert_eq!(
                rig.service.tabs("Safari", Some(3)).unwrap_err(),
                BrowserError::InvalidWindow(3)
            );
        }
    }

    /// The refusal only a sent event produces is recorded as the executed leg, and the passing
    /// check that follows cannot erase it: the next send is refused the same way.
    #[test]
    fn a_refused_event_records_the_executed_leg_and_stays_refused() {
        let rig = rig(
            Dictionary::SAFARI,
            NO_ERR,
            State {
                refuse: Some(AeError::NotPermitted),
                ..navigation_state("navigate-verified.json").1
            },
        );
        for _ in 0..2 {
            let data = refusal(
                rig.service
                    .navigate("Safari", "https://example.com")
                    .unwrap_err(),
            );
            assert_eq!(data.authorization, AutomationAuthorization::Denied);
            assert_eq!(data.leg, AutomationLeg::Executed);
            assert_eq!(data.native_status, Some(EVENT_NOT_PERMITTED));
            let status = rig.consent.status();
            assert_eq!(status.browsers[0].leg, Some(AutomationLeg::Executed));
            assert_eq!(
                status.browsers[0].status,
                Some(AutomationAuthorization::Denied)
            );
        }
        let gesture = rig.consent.request().unwrap();
        assert!(!gesture.outcomes[0].granted);
    }

    #[test]
    fn an_event_that_would_require_consent_is_reported_but_not_recorded() {
        let rig = rig(
            Dictionary::CHROME,
            NO_ERR,
            State {
                refuse: Some(AeError::WouldRequireConsent),
                ..tabs_state()
            },
        );
        let data = refusal(rig.service.windows("Chrome").unwrap_err());
        assert_eq!(data.authorization, AutomationAuthorization::NotDetermined);
        assert_eq!(data.leg, AutomationLeg::Executed);
        assert_eq!(data.native_status, Some(WOULD_REQUIRE_CONSENT));
        let status = rig.consent.status();
        assert_eq!(status.browsers[1].leg, Some(AutomationLeg::Checked));
        assert_eq!(
            status.browsers[1].status,
            Some(AutomationAuthorization::Granted)
        );
    }

    #[test]
    fn a_browser_error_is_an_execution_failure_and_a_timeout_names_the_browser() {
        let rig = rig(
            Dictionary::SAFARI,
            NO_ERR,
            State {
                refuse: Some(AeError::Failed {
                    status: -1728,
                    message: None,
                }),
                ..tabs_state()
            },
        );
        assert_eq!(
            rig.service.windows("Safari").unwrap_err(),
            BrowserError::ExecutionFailed("OSStatus -1728".into())
        );
        rig.state.lock().unwrap().refuse = Some(AeError::Timeout);
        assert_eq!(
            rig.service.tabs("Safari", None).unwrap_err(),
            BrowserError::Timeout("Safari".into())
        );
    }

    /// However slowly a browser answers, `navigate` ends inside the dispatch budget, the settle
    /// bound, and one trailing read, which keeps it inside the socket client's 30-second timeout.
    #[test]
    fn navigate_is_bounded_in_wall_clock_time_however_slowly_the_browser_answers() {
        let bound = DISPATCH_BUDGET_MS + Settler::DEFAULT_TIMEOUT_MS + TRAILING_READ_MS;
        for latency_ms in [
            0, 400, 1_000, 2_500, 3_000, 3_900, 5_000, 7_000, 14_000, 16_000, 120_000,
        ] {
            for (fixture, app) in [
                ("navigate-unsettled.json", "Chrome"),
                ("navigate-verified.json", "Safari"),
            ] {
                let (dictionary, state) = navigation_state(fixture);
                let rig = rig(
                    dictionary,
                    NO_ERR,
                    State {
                        latency_ms,
                        ..state
                    },
                );
                let outcome = rig.service.navigate(app, "https://example.com/slow");
                let spent = rig.clock.now_ms();
                assert!(
                    spent <= bound,
                    "{app} at {latency_ms} ms per event spent {spent} ms"
                );
                assert!(
                    matches!(outcome, Ok(_) | Err(BrowserError::Timeout(_))),
                    "{app} at {latency_ms} ms: {outcome:?}"
                );
            }
        }
        let (dictionary, state) = navigation_state("navigate-unsettled.json");
        let hung = rig(
            dictionary,
            NO_ERR,
            State {
                latency_ms: 120_000,
                ..state
            },
        );
        assert_eq!(
            hung.service
                .navigate("Chrome", "https://example.com/slow")
                .unwrap_err(),
            BrowserError::Timeout("Google Chrome".into())
        );
        assert_eq!(
            hung.clock.now_ms(),
            EVENT_TIMEOUT_MS,
            "the first event's timeout ends the call"
        );
    }

    #[test]
    fn an_enumeration_spends_one_budget_across_all_its_events() {
        let rig = rig(
            Dictionary::SAFARI,
            NO_ERR,
            State {
                latency_ms: 4_000,
                ..tabs_state()
            },
        );
        assert_eq!(
            rig.service.tabs("Safari", None).unwrap_err(),
            BrowserError::Timeout("Safari".into())
        );
        assert!(rig.clock.now_ms() <= ENUMERATION_BUDGET_MS);
    }
}
