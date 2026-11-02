//! The browser verbs' contract: what `navigate`, `windows`, and `tabs` answer, and the judgments
//! that turn a browser's scripting dictionary into those answers.
//!
//! A browser verb reads authority from the browser's own scripting dictionary rather than from
//! Accessibility, so its truth is whatever that dictionary reads back. Everything here is
//! platform-neutral: the wire types, URL equality as an address bar means it, the bounded settle
//! that decides when a navigated tab's read-back can be believed, and the Accessibility cross-check
//! for windows. Sending the Apple events lives in the macOS backend. The Swift daemon
//! (`Sources/AxonCore/BrowserAutomation.swift`) is the reference, and `schema/fixtures/browser` is
//! its output; `tests/browser_contract.rs` holds this module to those bytes.

use crate::{AutomationAuthorization, AutomationLeg, JsonRpcError};
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;

/// The longest URL `navigate` accepts, in UTF-8 bytes.
pub const MAX_NAVIGATION_URL_BYTES: usize = 8_192;

/// Why a tab answer carries no Accessibility cross-check.
pub const TAB_CROSS_CHECK_UNAVAILABLE: &str =
    "AX does not expose a portable authoritative tab model";

/// Where a window or tab enumeration's truth comes from.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum ScriptingAuthority {
    /// The browser's own scripting dictionary, never Accessibility.
    #[default]
    #[serde(rename = "application_scripting")]
    ApplicationScripting,
}

/// How a navigation verdict was reached.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NavigationVerification {
    /// The dictionary read the requested address back from the tab.
    DictionaryReadback,
    /// The dictionary read a different address back: the tab is not showing what was requested.
    DictionaryMismatch,
}

/// What backs the claim that a navigated tab had come to rest.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SettleEvidence {
    /// The browser reported the tab finished loading. Proof, not inference.
    LoadingFlag,
    /// The read-back held still for the whole stability window. Inference, for browsers whose
    /// dictionary exposes no loading state: a placeholder that outlasts the window is believed.
    StableReadback,
    /// The bound expired first, so the reading is an intermediate state and not an outcome.
    Bound,
}

/// One reading of a tab's dictionary state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TabReading {
    pub url: String,
    pub title: String,
    /// The browser's own answer to whether the tab is still loading, or `None` when its dictionary
    /// has no such property (Safari) or would not answer it.
    pub loading: Option<bool>,
}

/// The outcome of one navigation, as the dictionary read it back once the tab settled.
///
/// `success`, `verification`, and `settled` are judgments derived from the stored fields, so they
/// are computed on the wire rather than stored: a report cannot claim a success its URLs refute.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(into = "NavigationWire", try_from = "NavigationWire")]
pub struct NavigationReport {
    /// The browser's bundle identifier.
    pub app: String,
    /// The URL the caller asked for, exactly as given.
    pub requested_url: String,
    /// The URL the tab reads back.
    pub url: String,
    pub title: String,
    pub settle_evidence: SettleEvidence,
    /// How long the settle poll ran before this reading was taken.
    pub elapsed_ms: u64,
}

impl NavigationReport {
    /// Whether the tab is showing the page that was requested. A URL judgment only: a redirect
    /// lands somewhere the caller did not name, so it reads false with `url` naming where it is.
    pub fn success(&self) -> bool {
        browser_url::equivalent(&self.url, &self.requested_url)
    }

    pub fn verification(&self) -> NavigationVerification {
        if self.success() {
            NavigationVerification::DictionaryReadback
        } else {
            NavigationVerification::DictionaryMismatch
        }
    }

    /// False means the reading is the honest intermediate state at the settle bound.
    pub fn settled(&self) -> bool {
        self.settle_evidence != SettleEvidence::Bound
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NavigationWire {
    app: String,
    #[serde(rename = "requestedURL")]
    requested_url: String,
    url: String,
    title: String,
    success: bool,
    verification: NavigationVerification,
    settled: bool,
    settle_evidence: SettleEvidence,
    elapsed_ms: u64,
}

impl From<NavigationReport> for NavigationWire {
    fn from(report: NavigationReport) -> Self {
        Self {
            success: report.success(),
            verification: report.verification(),
            settled: report.settled(),
            app: report.app,
            requested_url: report.requested_url,
            url: report.url,
            title: report.title,
            settle_evidence: report.settle_evidence,
            elapsed_ms: report.elapsed_ms,
        }
    }
}

impl TryFrom<NavigationWire> for NavigationReport {
    type Error = String;
    fn try_from(wire: NavigationWire) -> Result<Self, String> {
        let report = Self {
            app: wire.app,
            requested_url: wire.requested_url,
            url: wire.url,
            title: wire.title,
            settle_evidence: wire.settle_evidence,
            elapsed_ms: wire.elapsed_ms,
        };
        if report.success() != wire.success
            || report.verification() != wire.verification
            || report.settled() != wire.settled
        {
            return Err("navigation verdict disagrees with the reading it was derived from".into());
        }
        Ok(report)
    }
}

/// The result of `navigate`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NavigateResult {
    pub navigation: NavigationReport,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BrowserWindow {
    /// `window:<index>`.
    pub id: String,
    /// One-based, front to back.
    pub index: u32,
    pub title: String,
    /// Only the frontmost window is active.
    pub active: bool,
}

impl BrowserWindow {
    pub fn new(index: u32, title: impl Into<String>) -> Self {
        Self {
            id: format!("window:{index}"),
            index,
            title: title.into(),
            active: index == 1,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BrowserTab {
    /// `window:<window>:tab:<index>`.
    pub id: String,
    #[serde(rename = "windowID")]
    pub window_id: String,
    pub window_index: u32,
    /// One-based, left to right.
    pub index: u32,
    pub title: String,
    pub url: String,
    pub active: bool,
}

impl BrowserTab {
    pub fn new(
        window_index: u32,
        index: u32,
        title: impl Into<String>,
        url: impl Into<String>,
        active: bool,
    ) -> Self {
        Self {
            id: format!("window:{window_index}:tab:{index}"),
            window_id: format!("window:{window_index}"),
            window_index,
            index,
            title: title.into(),
            url: url.into(),
            active,
        }
    }
}

/// How the scripted window list compares with what Accessibility sees.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "status",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum CrossCheck {
    /// Every scripted title matched an Accessibility title and the counts agree.
    Matched {
        scripted_window_count: u32,
        ax_window_count: u32,
        matching_titles: u32,
    },
    Partial {
        scripted_window_count: u32,
        ax_window_count: u32,
        matching_titles: u32,
    },
    Unavailable {
        reason: String,
    },
}

/// Compares scripted window titles with Accessibility's, each Accessibility title answering for
/// at most one scripted window so two windows sharing a title are not both matched by one.
pub fn window_cross_check(scripted_titles: &[String], ax_titles: &[String]) -> CrossCheck {
    let mut unmatched = ax_titles.to_vec();
    let mut matching = 0u32;
    for title in scripted_titles {
        if let Some(position) = unmatched.iter().position(|ax| ax == title) {
            unmatched.remove(position);
            matching += 1;
        }
    }
    let scripted_window_count = scripted_titles.len() as u32;
    let ax_window_count = ax_titles.len() as u32;
    if matching == scripted_window_count && ax_window_count == scripted_window_count {
        CrossCheck::Matched {
            scripted_window_count,
            ax_window_count,
            matching_titles: matching,
        }
    } else {
        CrossCheck::Partial {
            scripted_window_count,
            ax_window_count,
            matching_titles: matching,
        }
    }
}

/// The result of `windows`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WindowsReport {
    pub windows: Vec<BrowserWindow>,
    pub authority: ScriptingAuthority,
    pub cross_check: CrossCheck,
}

/// The result of `tabs`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TabsReport {
    pub tabs: Vec<BrowserTab>,
    pub authority: ScriptingAuthority,
    pub cross_check: CrossCheck,
}

impl TabsReport {
    pub fn new(tabs: Vec<BrowserTab>) -> Self {
        Self {
            tabs,
            authority: ScriptingAuthority::ApplicationScripting,
            cross_check: CrossCheck::Unavailable {
                reason: TAB_CROSS_CHECK_UNAVAILABLE.into(),
            },
        }
    }
}

/// The capability a browser refusal names.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum BrowserCapability {
    #[default]
    #[serde(rename = "browserAutomation")]
    BrowserAutomation,
}

/// The one reason a browser refusal carries; callers branch on it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum BrowserRefusalReason {
    #[default]
    #[serde(rename = "automation-not-granted")]
    AutomationNotGranted,
}

/// The `data` of a browser verb refused for want of Automation consent.
///
/// `authorization` is only ever `denied` or `notDetermined` here, and `leg` only `checked` or
/// `executed`: a verb never prompts.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BrowserRefusalData {
    pub capability: BrowserCapability,
    pub reason: BrowserRefusalReason,
    /// The browser's display name.
    pub app: String,
    pub authorization: AutomationAuthorization,
    pub leg: AutomationLeg,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub native_status: Option<i32>,
}

/// Every way a browser verb fails, worded as the Swift daemon words it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BrowserError {
    UnsupportedApp(String),
    AppNotRunning(String),
    InvalidUrl(String),
    InvalidWindow(i64),
    /// A caller-shape error that never reached the browser, such as a missing parameter.
    InvalidParams(String),
    NotGranted {
        message: String,
        data: BrowserRefusalData,
    },
    AuthorizationFailed {
        app: String,
        status: i32,
    },
    Timeout(String),
    ExecutionFailed(String),
}

impl BrowserError {
    pub fn message(&self) -> String {
        match self {
            Self::UnsupportedApp(app) => format!(
                "Unsupported browser: {app}. Supported browsers are Safari and Google Chrome."
            ),
            Self::AppNotRunning(app) => format!("Browser is not running: {app}"),
            Self::InvalidUrl(reason) => format!("Invalid navigation URL: {reason}"),
            Self::InvalidWindow(index) => {
                format!("Window index must be greater than zero: {index}")
            }
            Self::InvalidParams(message) => message.clone(),
            Self::NotGranted { message, .. } => message.clone(),
            Self::AuthorizationFailed { app, status } => {
                format!("Could not determine Automation permission for {app} (OSStatus {status})")
            }
            Self::Timeout(app) => format!("Browser automation timed out waiting for {app}"),
            Self::ExecutionFailed(message) => format!("Browser automation failed: {message}"),
        }
    }

    /// The JSON-RPC error: bad input is `-32602`, everything the browser or macOS refused is
    /// `-32603`, and only a consent refusal carries `data`.
    pub fn into_rpc(self) -> JsonRpcError {
        let message = self.message();
        match self {
            Self::UnsupportedApp(_)
            | Self::InvalidUrl(_)
            | Self::InvalidWindow(_)
            | Self::InvalidParams(_) => JsonRpcError {
                code: -32602,
                message,
                data: None,
            },
            Self::NotGranted { data, .. } => JsonRpcError {
                code: -32603,
                message,
                data: Some(serde_json::to_value(data).expect("refusal data serializes")),
            },
            Self::AppNotRunning(_)
            | Self::AuthorizationFailed { .. }
            | Self::Timeout(_)
            | Self::ExecutionFailed(_) => JsonRpcError {
                code: -32603,
                message,
                data: None,
            },
        }
    }
}

/// Rejects a URL `navigate` must not hand a browser, before anything else is asked of it.
pub fn validate_navigation_url(raw: &str) -> Result<(), BrowserError> {
    if raw.len() > MAX_NAVIGATION_URL_BYTES {
        return Err(BrowserError::InvalidUrl("URL exceeds 8192 bytes".into()));
    }
    if raw.chars().any(browser_url::is_control) {
        return Err(BrowserError::InvalidUrl(
            "control characters are not allowed".into(),
        ));
    }
    let absolute = browser_url::parse(raw).is_some_and(|components| {
        components.authority.is_some()
            && components.scheme.is_some_and(|scheme| {
                matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https")
            })
    });
    if !absolute {
        return Err(BrowserError::InvalidUrl(
            "an absolute http or https URL is required".into(),
        ));
    }
    Ok(())
}

/// Browser URL equality as an address bar means it.
///
/// A browser rewrites the URL it is handed into its own spelling before reading it back, so every
/// navigation verdict compares through here. This ports `BrowserURL` over Foundation's
/// `URLComponents(string:)`, including what that parser does on current macOS that a strict
/// RFC 3986 parser would not: it percent-encodes characters a component does not allow (a space,
/// `|`, brackets, a stray `%`, non-ASCII) and converts a non-ASCII host to its punycode spelling,
/// failing only on a host it cannot spell. `schema/fixtures/browser/url-cases.json` is Foundation's
/// own answer for each edge, and the tests hold this to it. A WHATWG parser would fold more than
/// that (dot segments, percent-encoding case) and change verdicts.
pub mod browser_url {
    use super::UnicodeNormalization;

    /// The parts of a URL, each already in its percent-encoded spelling.
    pub(crate) struct Components<'a> {
        pub scheme: Option<&'a str>,
        pub authority: Option<Authority>,
        pub path: String,
        pub query: Option<String>,
        pub fragment: Option<String>,
    }

    pub(crate) struct Authority {
        pub userinfo: Option<String>,
        pub host: String,
        pub port: Option<u64>,
    }

    pub fn equivalent(lhs: &str, rhs: &str) -> bool {
        normalized(lhs) == normalized(rhs)
    }

    /// The canonical spelling of `raw`, or `raw` unchanged when it does not parse.
    pub fn normalized(raw: &str) -> String {
        let Some(mut components) = parse(raw) else {
            return raw.to_owned();
        };
        let scheme = components.scheme.map(str::to_ascii_lowercase);
        if let Some(authority) = components.authority.as_mut() {
            authority.host = lowercase_host(&authority.host);
            let default_port = match scheme.as_deref() {
                Some("http") => Some(80),
                Some("https") => Some(443),
                _ => None,
            };
            if authority.port.is_some() && authority.port == default_port {
                authority.port = None;
            }
        }
        if components.path.is_empty() {
            components.path = "/".into();
        }
        if components.query.as_deref() == Some("") {
            components.query = None;
        }
        if components.fragment.as_deref() == Some("") {
            components.fragment = None;
        }
        let mut out = String::new();
        if let Some(scheme) = scheme {
            out.push_str(&scheme);
            out.push(':');
        }
        if let Some(authority) = components.authority {
            out.push_str("//");
            if let Some(userinfo) = authority.userinfo {
                out.push_str(&userinfo);
                out.push('@');
            }
            out.push_str(&authority.host);
            if let Some(port) = authority.port {
                out.push(':');
                out.push_str(&port.to_string());
            }
        }
        out.push_str(&components.path);
        if let Some(query) = components.query {
            out.push('?');
            out.push_str(&query);
        }
        if let Some(fragment) = components.fragment {
            out.push('#');
            out.push_str(&fragment);
        }
        out
    }

    /// `URLComponents`'s `host` getter decodes and its setter re-encodes, so lowercasing reaches
    /// letters but never the hex digits of a percent escape, which are left as written.
    fn lowercase_host(host: &str) -> String {
        let mut out = String::with_capacity(host.len());
        let mut escape = 0;
        for c in host.chars() {
            if escape > 0 {
                out.push(c);
                escape -= 1;
            } else if c == '%' {
                out.push(c);
                escape = 2;
            } else {
                out.push(c.to_ascii_lowercase());
            }
        }
        out
    }

    /// `CharacterSet.controlCharacters`: Unicode general categories Cc and Cf.
    pub fn is_control(c: char) -> bool {
        let c = c as u32;
        matches!(
            c,
            0x0000..=0x001F
                | 0x007F..=0x009F
                | 0x00AD
                | 0x0600..=0x0605
                | 0x061C
                | 0x06DD
                | 0x070F
                | 0x0890..=0x0891
                | 0x08E2
                | 0x180E
                | 0x200B..=0x200F
                | 0x202A..=0x202E
                | 0x2060..=0x2064
                | 0x2066..=0x206F
                | 0xFEFF
                | 0xFFF9..=0xFFFB
                | 0x110BD
                | 0x110CD
                | 0x13430..=0x1343F
                | 0x1BCA0..=0x1BCA3
                | 0x1D173..=0x1D17A
                | 0xE0001
                | 0xE0020..=0xE007F
        )
    }

    fn is_unreserved(b: u8) -> bool {
        b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~')
    }

    fn is_sub_delim(b: u8) -> bool {
        matches!(
            b,
            b'!' | b'$' | b'&' | b'\'' | b'(' | b')' | b'*' | b'+' | b',' | b';' | b'='
        )
    }

    fn is_pchar(b: u8) -> bool {
        is_unreserved(b) || is_sub_delim(b) || matches!(b, b':' | b'@')
    }

    /// `raw` with every character `allowed` refuses percent-encoded as UTF-8, except a `%` that
    /// already begins a valid escape.
    fn encode(raw: &str, allowed: fn(u8) -> bool) -> String {
        let bytes = raw.as_bytes();
        let mut out = String::with_capacity(raw.len());
        let mut index = 0;
        while index < bytes.len() {
            let byte = bytes[index];
            let escape = byte == b'%'
                && bytes.get(index + 1).is_some_and(u8::is_ascii_hexdigit)
                && bytes.get(index + 2).is_some_and(u8::is_ascii_hexdigit);
            if escape || (byte.is_ascii() && allowed(byte)) {
                out.push(byte as char);
            } else {
                out.push_str(&format!("%{byte:02X}"));
            }
            index += 1;
        }
        out
    }

    fn valid_scheme(scheme: &str) -> bool {
        let mut bytes = scheme.bytes();
        bytes.next().is_some_and(|b| b.is_ascii_alphabetic())
            && bytes.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.'))
    }

    /// A host as `URLComponents` spells it, or `None` when it cannot be spelled at all.
    fn host(raw: &str) -> Option<String> {
        if let Some(literal) = raw.strip_prefix('[') {
            let inner = literal.strip_suffix(']')?;
            return inner
                .bytes()
                .all(|b| b.is_ascii_hexdigit() || matches!(b, b':' | b'.'))
                .then(|| raw.to_owned());
        }
        let bytes = raw.as_bytes();
        let mut ascii = true;
        for (index, &byte) in bytes.iter().enumerate() {
            if !byte.is_ascii() {
                ascii = false;
            } else if byte == b'%' {
                if !(bytes.get(index + 1).is_some_and(u8::is_ascii_hexdigit)
                    && bytes.get(index + 2).is_some_and(u8::is_ascii_hexdigit))
                {
                    return None;
                }
            } else if !(is_unreserved(byte) || is_sub_delim(byte)) {
                return None;
            }
        }
        if ascii {
            return Some(raw.to_owned());
        }
        raw.to_lowercase()
            .nfc()
            .collect::<String>()
            .split('.')
            .map(|label| {
                if label.is_ascii() {
                    Some(label.to_owned())
                } else {
                    super::punycode(label).map(|encoded| format!("xn--{encoded}"))
                }
            })
            .collect::<Option<Vec<_>>>()
            .map(|labels| labels.join("."))
    }

    fn authority(raw: &str) -> Option<Authority> {
        let (userinfo, host_port) = match raw.rfind('@') {
            Some(at) => (Some(&raw[..at]), &raw[at + 1..]),
            None => (None, raw),
        };
        let host_end = if host_port.starts_with('[') {
            host_port.find(']').map(|end| end + 1)?
        } else {
            host_port.find(':').unwrap_or(host_port.len())
        };
        let (host_raw, port_raw) = host_port.split_at(host_end);
        let port = match port_raw.strip_prefix(':') {
            None if port_raw.is_empty() => None,
            None => return None,
            Some("") => None,
            Some(digits) if digits.bytes().all(|b| b.is_ascii_digit()) => {
                Some(digits.parse().ok()?)
            }
            Some(_) => return None,
        };
        Some(Authority {
            userinfo: userinfo.map(|userinfo| {
                encode(userinfo, |b| {
                    is_unreserved(b) || is_sub_delim(b) || b == b':'
                })
            }),
            host: host(host_raw)?,
            port,
        })
    }

    /// Splits `raw` the way RFC 3986's appendix B does, then spells each part.
    pub(crate) fn parse(raw: &str) -> Option<Components<'_>> {
        let (rest, fragment) = match raw.find('#') {
            Some(hash) => (&raw[..hash], Some(&raw[hash + 1..])),
            None => (raw, None),
        };
        let (rest, query) = match rest.find('?') {
            Some(mark) => (&rest[..mark], Some(&rest[mark + 1..])),
            None => (rest, None),
        };
        let (scheme, rest) = match rest.find(|c| matches!(c, ':' | '/')) {
            Some(colon) if rest.as_bytes()[colon] == b':' && colon > 0 => {
                let scheme = &rest[..colon];
                if !valid_scheme(scheme) {
                    return None;
                }
                (Some(scheme), &rest[colon + 1..])
            }
            _ => (None, rest),
        };
        let (authority, path) = match rest.strip_prefix("//") {
            Some(after) => {
                let end = after.find('/').unwrap_or(after.len());
                (Some(authority(&after[..end])?), &after[end..])
            }
            None => (None, rest),
        };
        let in_query = |b: u8| is_pchar(b) || matches!(b, b'/' | b'?');
        Some(Components {
            scheme,
            authority,
            path: encode(path, |b| is_pchar(b) || b == b'/'),
            query: query.map(|query| encode(query, in_query)),
            fragment: fragment.map(|fragment| encode(fragment, in_query)),
        })
    }
}

/// RFC 3492 punycode for one label, without the `xn--` prefix.
fn punycode(label: &str) -> Option<String> {
    const BASE: u32 = 36;
    const T_MIN: u32 = 1;
    const T_MAX: u32 = 26;
    const SKEW: u32 = 38;
    const DAMP: u32 = 700;

    fn adapt(delta: u32, points: u32, first: bool) -> u32 {
        let mut delta = if first { delta / DAMP } else { delta / 2 };
        delta += delta / points;
        let mut k = 0;
        while delta > ((BASE - T_MIN) * T_MAX) / 2 {
            delta /= BASE - T_MIN;
            k += BASE;
        }
        k + (BASE - T_MIN + 1) * delta / (delta + SKEW)
    }
    fn digit(value: u32) -> char {
        char::from(if value < 26 {
            b'a' + value as u8
        } else {
            b'0' + (value - 26) as u8
        })
    }

    let code_points: Vec<u32> = label.chars().map(u32::from).collect();
    let mut output: String = label.chars().filter(char::is_ascii).collect();
    let basic = output.len() as u32;
    let mut handled = basic;
    if basic > 0 {
        output.push('-');
    }
    let (mut n, mut delta, mut bias) = (128u32, 0u32, 72u32);
    while (handled as usize) < code_points.len() {
        let next = *code_points.iter().filter(|&&c| c >= n).min()?;
        delta = delta.checked_add((next - n).checked_mul(handled + 1)?)?;
        n = next;
        for &c in &code_points {
            if c < n {
                delta = delta.checked_add(1)?;
            }
            if c == n {
                let mut q = delta;
                let mut k = BASE;
                loop {
                    let t = if k <= bias {
                        T_MIN
                    } else if k >= bias + T_MAX {
                        T_MAX
                    } else {
                        k - bias
                    };
                    if q < t {
                        break;
                    }
                    output.push(digit(t + (q - t) % (BASE - t)));
                    q = (q - t) / (BASE - t);
                    k += BASE;
                }
                output.push(digit(q));
                bias = adapt(delta, handled + 1, handled == basic);
                delta = 0;
                handled += 1;
            }
        }
        delta = delta.checked_add(1)?;
        n += 1;
    }
    Some(output)
}

/// Time as the settle and the verbs' deadlines see it, injectable so both are tested without
/// waiting.
pub trait Clock: Send + Sync {
    /// Milliseconds since an arbitrary fixed origin.
    fn now_ms(&self) -> u64;
    fn sleep_ms(&self, milliseconds: u64);
}

/// The monotonic clock.
pub struct SystemClock(std::time::Instant);

impl Default for SystemClock {
    fn default() -> Self {
        Self(std::time::Instant::now())
    }
}

impl Clock for SystemClock {
    fn now_ms(&self) -> u64 {
        self.0.elapsed().as_millis() as u64
    }
    fn sleep_ms(&self, milliseconds: u64) {
        std::thread::sleep(std::time::Duration::from_millis(milliseconds));
    }
}

/// What the settle concluded: the reading it stopped on, and what backs it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SettleOutcome {
    pub reading: TabReading,
    pub evidence: SettleEvidence,
    pub elapsed_ms: u64,
}

/// Waits, boundedly, for a navigated tab to come to rest before its state is read as a verdict.
///
/// Setting a tab's URL returns as soon as the browser accepts the event, so the next read can
/// still describe the page being left. The tab is polled until a reading is backed by evidence of
/// a finished load: Chrome's `loading` flag going false, or, for Safari, which publishes nothing
/// equivalent, the read-back holding still for a continuous stability window. A browser holds a
/// placeholder title and intermediate redirect hops still for several polls, so one repeat is
/// worth nothing; the window is measured in time, not in reads.
///
/// The bound is wall-clock and includes the reads themselves: each reading is timed after it
/// returns, so a browser that answers slowly spends the same budget a fast one sleeps through, and
/// the poll ends at the first reading taken after the bound however long the reads took. This is a
/// line-for-line port of `BrowserNavigationSettler`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Settler {
    pub timeout_ms: u64,
    pub interval_ms: u64,
    pub stable_ms: u64,
}

impl Default for Settler {
    fn default() -> Self {
        Self {
            timeout_ms: Self::DEFAULT_TIMEOUT_MS,
            interval_ms: Self::DEFAULT_INTERVAL_MS,
            stable_ms: Self::DEFAULT_STABLE_MS,
        }
    }
}

impl Settler {
    /// Long enough for a page to publish its own title and for the stability window to close
    /// inside it, short enough that an agent's synchronous call is never held hostage to a slow
    /// site.
    pub const DEFAULT_TIMEOUT_MS: u64 = 4_000;
    pub const DEFAULT_INTERVAL_MS: u64 = 60;
    /// Longer than the placeholder titles and redirect hops a browser publishes on the way to a
    /// page, so several polls must agree rather than two adjacent ones.
    pub const DEFAULT_STABLE_MS: u64 = 480;

    /// Polls `read` until the tab settles or the bound expires, reporting whichever came first.
    pub fn settle<E>(
        &self,
        clock: &dyn Clock,
        requested_url: &str,
        before: &TabReading,
        mut read: impl FnMut() -> Result<TabReading, E>,
    ) -> Result<SettleOutcome, E> {
        let started = clock.now_ms();
        let deadline = started + self.timeout_ms;
        let mut previous: Option<TabReading> = None;
        let mut unchanged_since = started;
        loop {
            let reading = read()?;
            let observed = clock.now_ms();
            if previous.as_ref() != Some(&reading) {
                previous = Some(reading.clone());
                unchanged_since = observed;
            }
            let elapsed_ms = observed.saturating_sub(started);
            if let Some(evidence) = self.evidence(
                requested_url,
                before,
                &reading,
                observed.saturating_sub(unchanged_since),
            ) {
                return Ok(SettleOutcome {
                    reading,
                    evidence,
                    elapsed_ms,
                });
            }
            if observed >= deadline {
                return Ok(SettleOutcome {
                    reading,
                    evidence: SettleEvidence::Bound,
                    elapsed_ms,
                });
            }
            clock.sleep_ms(self.interval_ms.min(deadline - observed));
        }
    }

    fn evidence(
        &self,
        requested_url: &str,
        before: &TabReading,
        reading: &TabReading,
        unchanged_for_ms: u64,
    ) -> Option<SettleEvidence> {
        if !describes_the_new_page(requested_url, before, reading) {
            return None;
        }
        match reading.loading {
            Some(false) => Some(SettleEvidence::LoadingFlag),
            // The browser says the load is still running, and no frozen read-back overrides it.
            Some(true) => None,
            None => (unchanged_for_ms >= self.stable_ms).then_some(SettleEvidence::StableReadback),
        }
    }
}

/// Whether the tab has left the page it was navigated away from for the one that was asked for:
/// necessary, never sufficient.
fn describes_the_new_page(requested_url: &str, before: &TabReading, reading: &TabReading) -> bool {
    if !browser_url::equivalent(&reading.url, requested_url) {
        // Only a page that replaced the one being left, a redirect come to rest, is an outcome;
        // anything else is still the pre-navigation state.
        return !browser_url::equivalent(&reading.url, &before.url)
            && reading.title != before.title;
    }
    // The requested address is showing. Its title is trustworthy unless it is still the old
    // page's, and re-navigating to the address already open has no title change to wait for.
    reading.title != before.title || browser_url::equivalent(&before.url, requested_url)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    #[derive(Default)]
    struct FakeClock(AtomicU64);
    impl Clock for FakeClock {
        fn now_ms(&self) -> u64 {
            self.0.load(Ordering::SeqCst)
        }
        fn sleep_ms(&self, milliseconds: u64) {
            self.0.fetch_add(milliseconds, Ordering::SeqCst);
        }
    }

    fn reading(url: &str, title: &str, loading: Option<bool>) -> TabReading {
        TabReading {
            url: url.into(),
            title: title.into(),
            loading,
        }
    }

    /// Replays readings, holding on the last the way a loaded page does.
    struct Tab {
        readings: Vec<TabReading>,
        reads: usize,
    }
    impl Tab {
        fn new(readings: Vec<TabReading>) -> Self {
            Self { readings, reads: 0 }
        }
        fn read(&mut self) -> Result<TabReading, ()> {
            let reading = self.readings[self.reads.min(self.readings.len() - 1)].clone();
            self.reads += 1;
            Ok(reading)
        }
    }

    fn settle(
        settler: Settler,
        requested: &str,
        before: TabReading,
        tab: &mut Tab,
    ) -> SettleOutcome {
        settler
            .settle(&FakeClock::default(), requested, &before, || tab.read())
            .unwrap()
    }

    #[test]
    fn settling_outlasts_both_the_stale_title_and_the_placeholder_that_follows_it() {
        let stale = reading(
            "https://news.ycombinator.com/",
            "Why does Opus 5 feel worse to work with?",
            None,
        );
        let placeholder = reading(
            "https://news.ycombinator.com/",
            "news.ycombinator.com",
            None,
        );
        let loaded = reading("https://news.ycombinator.com/", "Hacker News", None);
        let mut tab =
            Tab::new([vec![stale; 5], vec![placeholder; 5], vec![loaded.clone()]].concat());
        let outcome = settle(
            Settler::default(),
            "https://news.ycombinator.com",
            reading(
                "https://news.ycombinator.com/item?id=1",
                "Why does Opus 5 feel worse to work with?",
                None,
            ),
            &mut tab,
        );
        assert_eq!(outcome.reading, loaded);
        assert_eq!(outcome.evidence, SettleEvidence::StableReadback);
        assert!(outcome.elapsed_ms >= Settler::DEFAULT_STABLE_MS);
    }

    #[test]
    fn a_placeholder_that_outlasts_the_window_is_believed() {
        let placeholder = reading("https://example.com/", "example.com", None);
        let outcome = settle(
            Settler::default(),
            "https://example.com",
            reading("https://start.example/", "Start", None),
            &mut Tab::new(vec![placeholder.clone()]),
        );
        assert_eq!(outcome.reading, placeholder);
        assert_eq!(outcome.evidence, SettleEvidence::StableReadback);
    }

    #[test]
    fn an_intermediate_redirect_hop_is_not_reported_as_the_destination() {
        let hop = reading("https://hop.example/redirect", "Redirecting", None);
        let destination = reading("https://www.example.net/", "Elsewhere", None);
        let outcome = settle(
            Settler::default(),
            "https://example.com",
            reading("https://start.example/", "Start", None),
            &mut Tab::new([vec![hop; 6], vec![destination.clone()]].concat()),
        );
        assert_eq!(outcome.reading, destination);
        assert_ne!(outcome.evidence, SettleEvidence::Bound);
    }

    #[test]
    fn a_browsers_own_loading_flag_ends_the_wait_without_the_stability_window() {
        let loaded = reading("https://example.com/", "Example", Some(false));
        let outcome = settle(
            Settler::default(),
            "https://example.com",
            reading("https://start.example/", "Start", Some(false)),
            &mut Tab::new(vec![
                reading("https://example.com/", "example.com", Some(true)),
                reading("https://example.com/", "Example", Some(true)),
                loaded.clone(),
            ]),
        );
        assert_eq!(outcome.reading, loaded);
        assert_eq!(outcome.evidence, SettleEvidence::LoadingFlag);
        assert!(outcome.elapsed_ms < Settler::DEFAULT_STABLE_MS);
    }

    #[test]
    fn a_tab_that_keeps_saying_it_is_loading_is_never_called_settled() {
        let outcome = settle(
            Settler {
                timeout_ms: 1_000,
                ..Settler::default()
            },
            "https://example.com",
            reading("https://start.example/", "Start", Some(false)),
            &mut Tab::new(vec![reading("https://example.com/", "Example", Some(true))]),
        );
        assert_eq!(outcome.evidence, SettleEvidence::Bound);
    }

    #[test]
    fn settling_does_not_wait_for_a_title_change_that_cannot_come() {
        let same = reading("https://example.com/", "Example", None);
        let outcome = settle(
            Settler::default(),
            "https://example.com",
            same.clone(),
            &mut Tab::new(vec![same]),
        );
        assert_eq!(outcome.evidence, SettleEvidence::StableReadback);
        assert!(outcome.elapsed_ms < Settler::DEFAULT_STABLE_MS * 2);
    }

    #[test]
    fn a_page_that_never_settles_is_reported_honestly_at_the_bound() {
        let stale = reading("https://start.example/", "Start", None);
        let mut tab = Tab::new(vec![stale.clone()]);
        let outcome = settle(
            Settler {
                timeout_ms: 1_000,
                interval_ms: 50,
                ..Settler::default()
            },
            "https://example.com",
            stale.clone(),
            &mut tab,
        );
        assert_eq!(outcome.evidence, SettleEvidence::Bound);
        assert_eq!(outcome.reading, stale);
        assert!(outcome.elapsed_ms >= 1_000);
        assert!(tab.reads <= 22, "one read per interval and no more");
    }

    /// A browser that answers each read slowly spends the bound in reads instead of sleeps: the
    /// poll still ends at the first reading after the bound.
    #[test]
    fn slow_reads_count_against_the_bound() {
        let clock = FakeClock::default();
        let mut reads = 0;
        let outcome = Settler::default()
            .settle(
                &clock,
                "https://example.com",
                &reading("https://start.example/", "Start", None),
                || {
                    reads += 1;
                    clock.sleep_ms(1_500);
                    Ok::<_, ()>(reading("https://start.example/", "Start", None))
                },
            )
            .unwrap();
        assert_eq!(outcome.evidence, SettleEvidence::Bound);
        assert_eq!(
            reads, 3,
            "reads at 1.5 s, 3.06 s, and the one that crosses 4 s"
        );
        assert!(outcome.elapsed_ms < Settler::DEFAULT_TIMEOUT_MS + 1_500 + 60);
    }

    #[test]
    fn punycode_matches_rfc_3492() {
        assert_eq!(punycode("bücher").as_deref(), Some("bcher-kva"));
        assert_eq!(punycode("münchen").as_deref(), Some("mnchen-3ya"));
        assert_eq!(punycode("例え").as_deref(), Some("r8jz45g"));
    }

    #[test]
    fn the_cross_check_consumes_duplicate_titles_only_once() {
        let check = window_cross_check(
            &["Same".into(), "Same".into()],
            &["Same".into(), "Different".into()],
        );
        assert_eq!(
            check,
            CrossCheck::Partial {
                scripted_window_count: 2,
                ax_window_count: 2,
                matching_titles: 1
            }
        );
    }

    #[test]
    fn a_report_whose_verdict_disagrees_with_its_urls_does_not_decode() {
        let forged = serde_json::json!({
            "app": "com.apple.Safari", "requestedURL": "https://example.com",
            "url": "https://elsewhere.example/", "title": "Elsewhere", "success": true,
            "verification": "dictionary_readback", "settled": true,
            "settleEvidence": "stable_readback", "elapsedMs": 480
        });
        assert!(serde_json::from_value::<NavigationReport>(forged).is_err());
    }
}
