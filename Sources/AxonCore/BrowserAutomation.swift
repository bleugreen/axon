import AppKit
import ApplicationServices
import Foundation

public enum BrowserAutomationAuthorization: String, Equatable, Sendable {
    case denied
    case notDetermined
}

/// Which step of the Apple Events authorization sequence produced a decision.
///
/// macOS answers the same question in three places — a silent determination, a determination that
/// may present the consent dialog, and the event send itself — and they mean different things. A
/// denial that does not say which step produced it cannot be acted on, which is exactly what made
/// the first field report of suppressed consent unreadable.
public enum BrowserAutomationAuthorizationLeg: String, Equatable, Sendable {
    /// `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`.
    case checked
    /// `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: true`, which blocks until a
    /// person answers the dialog. Only a deliberate user gesture reaches this leg.
    case prompted
    /// The Apple event itself was refused while the script ran, after a preflight had passed.
    case executed
}

/// Which targets this process has already received an Apple Events authorization answer for.
///
/// macOS resolves an authorization inside the sending process once that process holds an answer for
/// a sender/target pair. A later `tccutil reset` rewrites the TCC database but cannot reach into a
/// running process, so a repeat denial may be reporting an answer older than the current database —
/// and no remediation short of restarting the daemon will change it. The platform exposes no way to
/// tell those cases apart, so the daemon records what it observed within its own lifetime.
///
/// This tracks answers from *either* leg, not prompt attempts. The confounded trial never prompted
/// at all: it was the silent leg's answer that got reused, so a prompt-only flag would have stayed
/// false through the one sequence it exists to catch.
///
/// It keeps the answer itself, not merely that one arrived, because a surface that must not prompt
/// still has to know the grant: the menu decides whether its consent item has anything left to offer
/// from what this process already holds, rather than putting the question to macOS again.
final class AppleEventAnswerLedger: @unchecked Sendable {
    static let shared = AppleEventAnswerLedger()

    /// One answer macOS gave this process, and the leg that produced it.
    struct Answer: Equatable {
        let status: OSStatus
        let leg: BrowserAutomationAuthorizationLeg
    }

    private let lock = NSLock()
    private var answers: [String: Answer] = [:]

    /// Whether macOS has already answered this process for `bundleIdentifier`.
    func hasAnswer(for bundleIdentifier: String) -> Bool {
        answer(for: bundleIdentifier) != nil
    }

    /// The most recent answer this process holds for `bundleIdentifier`, if any.
    func answer(for bundleIdentifier: String) -> Answer? {
        lock.lock()
        defer { lock.unlock() }
        return answers[bundleIdentifier]
    }

    /// Records an answer, except where that would let a preflight overwrite an event macOS actually
    /// refused.
    ///
    /// An executed-leg denial is the one answer that contradicts a passing preflight for the same
    /// target: the determination said yes and then the event itself was refused. For the rest of
    /// this process's life the preflight is known to be answering wrongly there, so its `noErr` must
    /// not retire the denial — and with it the menu item carrying the only remediation the user has.
    /// Only the dialog replaces it, because that answer is a person deciding in this moment;
    /// otherwise the daemon restarts and the ledger starts empty.
    func recordAnswer(_ status: OSStatus, leg: BrowserAutomationAuthorizationLeg, for bundleIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        if answers[bundleIdentifier]?.leg == .executed, leg != .prompted {
            return
        }
        answers[bundleIdentifier] = Answer(status: status, leg: leg)
    }
}

struct AppleEventAuthorizationService {
    private struct Decision {
        let status: OSStatus
        let leg: BrowserAutomationAuthorizationLeg
        let answeredEarlierInThisProcess: Bool
    }

    let authorizer: any AppleEventAuthorizing
    let ledger: AppleEventAnswerLedger
    let log: (String) -> Void

    init(
        authorizer: any AppleEventAuthorizing,
        ledger: AppleEventAnswerLedger = .shared,
        log: @escaping (String) -> Void = AppleEventAuthorizationService.logToStandardError
    ) {
        self.authorizer = authorizer
        self.ledger = ledger
        self.log = log
    }

    /// Resolves the current authorization without ever presenting the consent dialog.
    ///
    /// Every agent-facing browser verb goes through here. The prompting leg blocks its thread until
    /// a person dismisses the dialog, and browser verbs run synchronously on the socket-handling
    /// thread, so prompting from here would stall an agent's call indefinitely on a dialog nobody
    /// asked for, possibly while the machine is unattended. An agent gets a decision immediately;
    /// consent is minted by the menu bar's Browser Automation item instead.
    func check(bundleIdentifier: String, appName: String) throws {
        let answeredEarlier = ledger.hasAnswer(for: bundleIdentifier)
        let decision = determine(
            bundleIdentifier: bundleIdentifier,
            askUserIfNeeded: false,
            answeredEarlierInThisProcess: answeredEarlier
        )
        try resolve(decision, appName: appName, origin: .browserVerb)
    }

    /// Resolves the authorization, presenting macOS's consent dialog when the grant is undetermined.
    ///
    /// This is the only path that passes `askUserIfNeeded: true`, and it blocks for as long as the
    /// dialog is on screen. Call it from a deliberate user gesture, off the main thread.
    func requestConsent(bundleIdentifier: String, appName: String) throws {
        // Read once, before the first leg, so the silent leg of this very request does not read back
        // as an earlier answer.
        let answeredEarlier = ledger.hasAnswer(for: bundleIdentifier)
        // An event macOS refused after the preflight passed is a denial the preflight will not
        // reproduce: asking it again returns the same `noErr` it already answered wrongly with. The
        // gesture would then report the browser as granted and retire its own menu item, leaving the
        // refusal the user came here from with nowhere to lead.
        if let held = ledger.answer(for: bundleIdentifier),
           held.leg == .executed, held.status == OSStatus(errAEEventNotPermitted) {
            log("automation authorization target=\(bundleIdentifier) leg=\(held.leg.rawValue) status=\(held.status) answeredEarlierInThisProcess=true source=ledger")
            throw denial(
                .denied,
                Decision(status: held.status, leg: .executed, answeredEarlierInThisProcess: answeredEarlier),
                appName: appName,
                origin: .consentGesture
            )
        }
        let initial = determine(
            bundleIdentifier: bundleIdentifier,
            askUserIfNeeded: false,
            answeredEarlierInThisProcess: answeredEarlier
        )
        // A recorded denial is final until the user changes it in System Settings; macOS will not
        // present a dialog for it, so prompting would only repeat the same answer.
        guard initial.status == OSStatus(errAEEventWouldRequireUserConsent) else {
            return try resolve(initial, appName: appName, origin: .consentGesture)
        }
        try resolve(
            determine(
                bundleIdentifier: bundleIdentifier,
                askUserIfNeeded: true,
                answeredEarlierInThisProcess: answeredEarlier
            ),
            appName: appName,
            origin: .consentGesture
        )
    }

    private func determine(
        bundleIdentifier: String,
        askUserIfNeeded: Bool,
        answeredEarlierInThisProcess: Bool
    ) -> Decision {
        let status = authorizer.determinePermission(bundleIdentifier: bundleIdentifier, askUserIfNeeded: askUserIfNeeded)
        let leg: BrowserAutomationAuthorizationLeg = askUserIfNeeded ? .prompted : .checked
        // Staleness is only ever a property of the silent leg. A prompted decision is macOS putting
        // the question to the user in this moment, so its answer is the one they just gave and no
        // restart can change it — even though the refusal that sent them to the menu did leave an
        // earlier answer in the ledger, which is the normal path to this line.
        let holdsEarlierAnswer = askUserIfNeeded ? false : answeredEarlierInThisProcess
        // An unexpected status means the call failed, not that macOS answered the authorization, so
        // it must not make the next denial claim this process is holding a stale answer.
        if [noErr, OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent)].contains(status) {
            ledger.recordAnswer(status, leg: leg, for: bundleIdentifier)
        }
        log("automation authorization target=\(bundleIdentifier) leg=\(leg.rawValue) status=\(status) answeredEarlierInThisProcess=\(holdsEarlierAnswer)")
        return Decision(status: status, leg: leg, answeredEarlierInThisProcess: holdsEarlierAnswer)
    }

    private func resolve(
        _ decision: Decision,
        appName: String,
        origin: BrowserAutomationDenialOrigin
    ) throws {
        switch decision.status {
        case noErr:
            return
        case OSStatus(errAEEventNotPermitted):
            throw denial(.denied, decision, appName: appName, origin: origin)
        case OSStatus(errAEEventWouldRequireUserConsent):
            throw denial(.notDetermined, decision, appName: appName, origin: origin)
        default:
            throw BrowserAutomationError.authorizationFailed(app: appName, status: decision.status)
        }
    }

    /// The authorization this process already holds for `bundleIdentifier`, or one silent
    /// determination when it holds none.
    ///
    /// Never prompts, and never re-asks macOS about a target it has already been answered for. Both
    /// halves matter to the caller this exists for — the menu, which is rebuilt whenever it is shown
    /// and must not cost a TCC round trip each time, and must not make this process start holding an
    /// answer any earlier than the person's own use of Axon already would.
    func settledStatus(bundleIdentifier: String) -> OSStatus {
        if let held = ledger.answer(for: bundleIdentifier) {
            return held.status
        }
        return determine(
            bundleIdentifier: bundleIdentifier,
            askUserIfNeeded: false,
            answeredEarlierInThisProcess: false
        ).status
    }

    private func denial(
        _ authorization: BrowserAutomationAuthorization,
        _ decision: Decision,
        appName: String,
        origin: BrowserAutomationDenialOrigin
    ) -> BrowserAutomationError {
        .automationNotGranted(BrowserAutomationDenial(
            app: appName,
            authorization: authorization,
            leg: decision.leg,
            status: decision.status,
            origin: origin,
            answeredEarlierInThisProcess: decision.answeredEarlierInThisProcess
        ))
    }

    /// The LaunchAgent routes the daemon's stderr to `~/Library/Logs/Axon/daemon.err.log`, so one
    /// line per decision is what makes a permission report readable without a bench protocol.
    static func logToStandardError(_ line: String) {
        FileHandle.standardError.write(Data("axon: \(line)\n".utf8))
    }
}

/// Requests macOS Automation consent for the browsers Axon can script.
///
/// Consent is a deliberate act: a background daemon serving an agent should never mint a privacy
/// grant as a side effect of a task, and the dialog belongs to a moment the user chose. This blocks
/// the calling thread for as long as the dialog is on screen, so callers must keep it off the main
/// thread or the menu bar app freezes along with it.
public struct BrowserAutomationConsentRequester {
    private let authorizer: any AppleEventAuthorizing
    private let isRunning: (String) -> Bool
    private let ledger: AppleEventAnswerLedger
    private let log: (String) -> Void

    public init() {
        self.init(authorizer: SystemAppleEventAuthorizer(), isRunning: { bundleIdentifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains { !$0.isTerminated }
        })
    }

    init(
        authorizer: any AppleEventAuthorizing,
        isRunning: @escaping (String) -> Bool,
        ledger: AppleEventAnswerLedger = .shared,
        log: @escaping (String) -> Void = AppleEventAuthorizationService.logToStandardError
    ) {
        self.authorizer = authorizer
        self.isRunning = isRunning
        self.ledger = ledger
        self.log = log
    }

    /// Requests consent for every supported browser that is currently running.
    ///
    /// macOS can only resolve a grant for a running target, so a browser that is not running is left
    /// out of the result rather than reported as a failure.
    public func requestForRunningBrowsers() -> [BrowserAutomationConsentOutcome] {
        let service = AppleEventAuthorizationService(authorizer: authorizer, ledger: ledger, log: log)
        return SupportedBrowser.allCases.filter { isRunning($0.rawValue) }.map { browser in
            do {
                try service.requestConsent(bundleIdentifier: browser.rawValue, appName: browser.name)
                return BrowserAutomationConsentOutcome(app: browser.name, bundleIdentifier: browser.rawValue, granted: true, detail: nil)
            } catch {
                return BrowserAutomationConsentOutcome(app: browser.name, bundleIdentifier: browser.rawValue, granted: false, detail: String(describing: error))
            }
        }
    }

    /// What this gesture still has to offer, resolved without ever prompting.
    ///
    /// The menu asks this while it is being built, so a browser this process has never been answered
    /// for — launched or installed since the daemon started — brings the item back. A grant changed
    /// after an answer is held, including by `tccutil reset`, does not: macOS resolves the
    /// authorization inside this process and answers from what it holds, so no reading here can
    /// observe that change and only a daemon restart clears it. Browsers that are not running are
    /// left out for the same reason the request skips them — macOS resolves a grant only for a
    /// running target — so a machine with no browser open has nothing to consent to either.
    public func outstandingConsent() -> BrowserAutomationConsentNeed {
        let service = AppleEventAuthorizationService(authorizer: authorizer, ledger: ledger, log: log)
        return SupportedBrowser.allCases
            .filter { isRunning($0.rawValue) }
            .map { BrowserAutomationConsentNeed(status: service.settledStatus(bundleIdentifier: $0.rawValue)) }
            .max { $0.precedence < $1.precedence } ?? .none
    }
}

/// What the menu bar's Browser Automation item still has to offer, and therefore whether it exists.
///
/// A consent gesture with nothing left to consent to is an invitation to a dead end, so the item is
/// built from this rather than shown unconditionally.
public enum BrowserAutomationConsentNeed: String, Equatable, Sendable {
    /// Every browser macOS can answer for is allowed. Nothing to request, so no menu item.
    case none
    /// At least one grant is undetermined and the gesture can still mint it.
    case request
    /// At least one grant stands denied — recorded in TCC, or refused without a row at all. macOS
    /// will not re-prompt over that, so the gesture explains instead of asking; the item stays,
    /// because hiding it would leave the refusal that sent the user here with nowhere to lead.
    case explain

    init(status: OSStatus) {
        switch status {
        case noErr: self = .none
        case OSStatus(errAEEventWouldRequireUserConsent): self = .request
        // A denial, and equally a determination that failed outright: neither is a grant, and both
        // are states the gesture can only describe.
        default: self = .explain
        }
    }

    /// Which browser's state decides the menu when they disagree. A standing denial outranks an
    /// undetermined grant because it is the state whose remediation lives nowhere else.
    var precedence: Int {
        switch self {
        case .none: return 0
        case .request: return 1
        case .explain: return 2
        }
    }
}

/// The result of a deliberate consent request for one browser.
public struct BrowserAutomationConsentOutcome: Equatable, Sendable {
    public let app: String
    public let bundleIdentifier: String
    public let granted: Bool
    /// Why consent was not granted, in the same words a browser verb would report.
    public let detail: String?
}

/// The browsers Axon can script, and the one list every browser-facing path resolves against.
enum SupportedBrowser: String, CaseIterable {
    case safari = "com.apple.Safari"
    case chrome = "com.google.Chrome"

    var name: String { self == .safari ? "Safari" : "Google Chrome" }

    static func named(_ query: String) -> SupportedBrowser? {
        switch query.lowercased() {
        case "safari", SupportedBrowser.safari.rawValue.lowercased(): return .safari
        case "google chrome", "chrome", SupportedBrowser.chrome.rawValue.lowercased(): return .chrome
        default: return nil
        }
    }
}

protocol AppleEventAuthorizing {
    func determinePermission(bundleIdentifier: String, askUserIfNeeded: Bool) -> OSStatus
}

struct SystemAppleEventAuthorizer: AppleEventAuthorizing {
    func determinePermission(bundleIdentifier: String, askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        return AEDeterminePermissionToAutomateTarget(
            target.aeDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
    }
}

/// Which surface asked for the authorization that was refused.
///
/// Remediation depends on it. A browser verb's refusal can send the user to the menu bar's consent
/// gesture, because that gesture is a step they have not taken yet. The gesture's own refusal
/// cannot: sending it back to itself describes an action the user just performed.
public enum BrowserAutomationDenialOrigin: String, Equatable, Sendable {
    /// An agent-facing browser verb — navigate, windows, or tabs.
    case browserVerb
    /// The daemon menu's Browser Automation... item, the one surface that asks macOS to prompt.
    case consentGesture
}

/// One refused Apple Events authorization, described well enough to act on.
public struct BrowserAutomationDenial: Equatable, Sendable {
    public let app: String
    public let authorization: BrowserAutomationAuthorization
    public let leg: BrowserAutomationAuthorizationLeg
    public let status: Int32?
    public let origin: BrowserAutomationDenialOrigin
    /// True when this process had already resolved an authorization for the same target before this
    /// request. macOS may answer from what the process holds, so such a denial does not necessarily
    /// describe the current TCC database.
    public let answeredEarlierInThisProcess: Bool

    public init(
        app: String,
        authorization: BrowserAutomationAuthorization,
        leg: BrowserAutomationAuthorizationLeg,
        status: Int32?,
        origin: BrowserAutomationDenialOrigin,
        answeredEarlierInThisProcess: Bool = false
    ) {
        self.app = app
        self.authorization = authorization
        self.leg = leg
        self.status = status
        self.origin = origin
        self.answeredEarlierInThisProcess = answeredEarlierInThisProcess
    }

    var message: String {
        var sentences = ["Automation permission for \(app) \(authorization == .denied ? "is denied" : "has not been granted")."]
        sentences.append(remediation)
        if answeredEarlierInThisProcess {
            sentences.append("The Axon daemon already resolved Automation for \(app) earlier in this session and macOS can answer from what the process holds, so this may not reflect current settings. Restart the daemon with `launchctl kickstart -k gui/$(id -u)/dev.axon.daemon` to re-check.")
        }
        return sentences.joined(separator: " ")
    }

    /// Remediation the user can actually perform from the state they are actually in, which is a
    /// different sentence for each surface.
    ///
    /// Until consent has been requested once there is no Axon row in System Settings and no way to
    /// add one, so pointing an undetermined grant at that pane describes an impossible action. And
    /// the consent gesture is the end of the road: whatever it reports, the answer cannot be to go
    /// perform the consent gesture.
    private var remediation: String {
        switch (origin, authorization) {
        case (.browserVerb, .notDetermined):
            return "Open the Axon menu bar item and choose Browser Automation... to grant it. Axon does not appear in System Settings > Privacy & Security > Automation until consent has been requested once."
        case (.browserVerb, .denied):
            return "If Axon is listed in System Settings > Privacy & Security > Automation, enable \(app) beneath it. If it is not listed, open the Axon menu bar item and choose Browser Automation... to request consent."
        case (.consentGesture, .denied):
            // macOS refuses a recorded denial without re-prompting, and refuses identically when it
            // will not let this build ask at all — the state that shipped through 0.3.6, where the
            // signature lacked the Apple Events entitlement. Whether an Axon row exists in the
            // Automation pane is what separates them, and it is the one thing the user can see and
            // Axon cannot, so the sentence hands them that test instead of guessing.
            return "macOS will not present the consent dialog again while a denial is recorded, so enable \(app) beneath Axon in System Settings > Privacy & Security > Automation. If Axon is not listed there at all, macOS refused without recording anything, which no setting on this Mac can change: install the latest Axon and try again."
        case (.consentGesture, .notDetermined):
            return "macOS neither presented the consent dialog nor recorded an answer, so there is nothing to enable in System Settings > Privacy & Security > Automation yet. Quit Axon and open it again to retry from a fresh process; if the dialog still does not appear, install the latest Axon."
        }
    }
}

public enum BrowserAutomationError: Error, Equatable, CustomStringConvertible {
    case unsupportedApp(String)
    case appNotRunning(String)
    case invalidURL(String)
    case invalidWindow(Int)
    case automationNotGranted(BrowserAutomationDenial)
    case authorizationFailed(app: String, status: Int32)
    case timeout(String)
    case executionFailed(String)

    public var description: String {
        switch self {
        case let .unsupportedApp(app): return "Unsupported browser: \(app). Supported browsers are Safari and Google Chrome."
        case let .appNotRunning(app): return "Browser is not running: \(app)"
        case let .invalidURL(reason): return "Invalid navigation URL: \(reason)"
        case let .invalidWindow(index): return "Window index must be greater than zero: \(index)"
        case let .automationNotGranted(denial): return denial.message
        case let .authorizationFailed(app, status): return "Could not determine Automation permission for \(app) (OSStatus \(status))"
        case let .timeout(app): return "Browser automation timed out waiting for \(app)"
        case let .executionFailed(message): return "Browser automation failed: \(message)"
        }
    }
}

/// Browser URL equality as an address bar means it.
///
/// A browser rewrites the URL it is handed into its own canonical spelling before reading it back:
/// ask for `https://news.ycombinator.com` and the tab reports `https://news.ycombinator.com/`.
/// Comparing those as strings calls a navigation that plainly succeeded a mismatch, so every
/// navigation verdict compares through here. Only spellings of the same address are folded together
/// — a different host, path, or query is a different page and stays one.
public enum BrowserURL {
    public static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    /// The canonical spelling of `raw`, or `raw` unchanged when it does not parse as a URL.
    public static func normalized(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if let port = components.port, port == defaultPort(for: components.scheme) { components.port = nil }
        // An empty path is the root path, which a browser spells with the slash.
        if components.path.isEmpty { components.path = "/" }
        // A bare trailing `?` or `#` carries nothing a browser distinguishes from its absence.
        if components.query?.isEmpty == true { components.query = nil }
        if components.fragment?.isEmpty == true { components.fragment = nil }
        return components.string ?? raw
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

/// How a navigation verdict was reached.
public enum BrowserNavigationVerification: String, Equatable, Sendable {
    /// The browser's dictionary read the requested address back from the tab.
    case dictionaryReadback = "dictionary_readback"
    /// The dictionary read a different address back: the tab is not showing what was requested.
    case dictionaryMismatch = "dictionary_mismatch"
}

/// One reading of a browser tab's dictionary state.
public struct BrowserTabReading: Equatable, Sendable {
    public let url: String
    public let title: String
    /// The browser's own answer to whether the tab is still loading, or nil when its dictionary
    /// does not expose one. Chrome publishes `loading`; Safari's tab has no equivalent, and asking
    /// its page through injected JavaScript is a capability Axon does not take.
    public let loading: Bool?

    public init(url: String, title: String, loading: Bool? = nil) {
        self.url = url
        self.title = title
        self.loading = loading
    }
}

/// What backs the claim that a navigated tab had come to rest.
///
/// The two kinds of evidence are not equally strong, and collapsing them into a bare boolean would
/// hide which one a caller got.
public enum BrowserNavigationSettleEvidence: String, Equatable, Sendable {
    /// The browser reported the tab finished loading. Proof, not inference.
    case loadingFlag = "loading_flag"
    /// The read-back held still for the whole stability window. This is inference, used for browsers
    /// whose dictionary exposes no loading state: a page that publishes nothing new for that long is
    /// treated as loaded, and a placeholder that outlasts the window would be believed.
    case stableReadback = "stable_readback"
    /// The bound expired first, so this reading is an intermediate state and not an outcome.
    case bound
}

public struct BrowserNavigationResult: Equatable, Sendable {
    public let app: String
    public let requestedURL: String
    public let url: String
    public let title: String
    /// What backs — or withholds — the claim that the tab had come to rest when this reading was
    /// taken.
    public let settleEvidence: BrowserNavigationSettleEvidence
    /// How long the settle poll ran before this reading was taken, in milliseconds.
    public let elapsedMs: Int

    public init(
        app: String,
        requestedURL: String,
        url: String,
        title: String,
        settleEvidence: BrowserNavigationSettleEvidence,
        elapsedMs: Int
    ) {
        self.app = app
        self.requestedURL = requestedURL
        self.url = url
        self.title = title
        self.settleEvidence = settleEvidence
        self.elapsedMs = elapsedMs
    }

    /// False means the reading is the honest intermediate state at the settle bound, not a finished
    /// page load.
    public var settled: Bool { settleEvidence != .bound }

    /// Whether the tab is showing the page that was requested.
    ///
    /// The verdict is a URL judgment and only a URL judgment. A title belongs to a page load that
    /// may still be in flight, while the URL is the browser's own answer to what it was asked to
    /// show; `settled` says whether the title alongside it can be trusted yet. A redirect lands
    /// somewhere the caller did not name, so it reads false with `url` naming where the tab is.
    public var success: Bool { BrowserURL.equivalent(url, requestedURL) }

    public var verification: BrowserNavigationVerification {
        success ? .dictionaryReadback : .dictionaryMismatch
    }
}

public struct BrowserWindow: Equatable, Sendable {
    public let id: String
    public let index: Int
    public let title: String
    public let active: Bool
}

public struct BrowserTab: Equatable, Sendable {
    public let id: String
    public let windowID: String
    public let windowIndex: Int
    public let index: Int
    public let title: String
    public let url: String
    public let active: Bool
}

/// Waits, boundedly, for a navigated tab to come to rest before its state is read as a verdict.
///
/// Setting a tab's URL returns as soon as the browser accepts the Apple event, so the very next
/// dictionary read can still describe the page being navigated away from — that is how a navigation
/// that plainly worked reported the previous page's title. The tab is polled until the reading is
/// backed by evidence of a finished load, and the bound is deliberately small: a page still loading
/// when it expires is reported as the intermediate state it is, never waited on indefinitely.
///
/// The evidence a browser can offer differs, so the settler takes the strongest it is given.
/// Chrome publishes `loading` on a tab, which ends the wait the moment it goes false. Safari
/// publishes nothing equivalent, so the only available evidence is that the read-back stopped
/// changing — and a single repeat is worth nothing, because a browser holds a placeholder title
/// (often the address itself) and an intermediate redirect hop still for many poll intervals. The
/// read-back must therefore hold still for a continuous window before it is believed, which is the
/// same bar `wait_for_stability` sets with `stableMs`. A placeholder that outlasts the window is
/// the honest limit of inference without a loading signal, and `settleEvidence` says which kind of
/// evidence a caller got.
struct BrowserNavigationSettler: Sendable {
    /// Long enough for a page to publish its own title over a normal connection and for the
    /// stability window to close inside it, short enough that an agent's synchronous call is never
    /// held hostage to a slow site.
    static let defaultTimeoutMs = 4_000
    static let defaultIntervalMs = 60
    /// How long an unchanging read-back must hold to stand in for a loading signal. Longer than the
    /// placeholder titles and redirect hops that a browser publishes on the way to a page, and long
    /// enough that several polls must agree rather than two adjacent ones.
    static let defaultStableMs = 480

    struct Outcome: Equatable {
        let reading: BrowserTabReading
        let evidence: BrowserNavigationSettleEvidence
        let elapsedMs: Int

        var settled: Bool { evidence != .bound }
    }

    let timeoutMs: Int
    let intervalMs: Int
    let stableMs: Int
    let now: @Sendable () -> Date
    let sleepMilliseconds: @Sendable (Int) -> Void

    static let live = BrowserNavigationSettler(
        timeoutMs: defaultTimeoutMs,
        intervalMs: defaultIntervalMs,
        stableMs: defaultStableMs,
        now: Date.init,
        sleepMilliseconds: { Thread.sleep(forTimeInterval: Double($0) / 1_000) }
    )

    /// Polls `read` until the tab settles or the bound expires, reporting whichever came first.
    func settle(
        requestedURL: String,
        before: BrowserTabReading,
        read: () throws -> BrowserTabReading
    ) rethrows -> Outcome {
        let startedAt = now()
        let deadline = startedAt.addingTimeInterval(Double(timeoutMs) / 1_000)
        var previous: BrowserTabReading?
        var unchangedSince = startedAt

        while true {
            let reading = try read()
            let observedAt = now()
            if reading != previous {
                previous = reading
                unchangedSince = observedAt
            }
            let elapsedMs = Self.milliseconds(from: startedAt, to: observedAt)
            if let evidence = evidence(
                requestedURL: requestedURL,
                before: before,
                reading: reading,
                unchangedForMs: Self.milliseconds(from: unchangedSince, to: observedAt)
            ) {
                return Outcome(reading: reading, evidence: evidence, elapsedMs: elapsedMs)
            }
            guard observedAt < deadline else {
                return Outcome(reading: reading, evidence: .bound, elapsedMs: elapsedMs)
            }
            let remainingMs = max(0, Int((deadline.timeIntervalSince(observedAt) * 1_000).rounded(.up)))
            sleepMilliseconds(min(intervalMs, remainingMs))
        }
    }

    /// What, if anything, proves `reading` is the finished navigation rather than a page in flight.
    private func evidence(
        requestedURL: String,
        before: BrowserTabReading,
        reading: BrowserTabReading,
        unchangedForMs: Int
    ) -> BrowserNavigationSettleEvidence? {
        guard describesTheNewPage(requestedURL: requestedURL, before: before, reading: reading) else { return nil }
        switch reading.loading {
        case false: return .loadingFlag
        // The browser says the load is still running, and no amount of a frozen read-back overrides
        // it: a page whose title has not changed yet reads exactly like one that never will.
        case true: return nil
        case nil: return unchangedForMs >= stableMs ? .stableReadback : nil
        }
    }

    /// Whether the tab has left the page it was navigated away from for the one that was asked for.
    ///
    /// This is a necessary condition, never a sufficient one: it says the reading is no longer the
    /// old page, while the evidence above says the new one has finished arriving.
    private func describesTheNewPage(
        requestedURL: String,
        before: BrowserTabReading,
        reading: BrowserTabReading
    ) -> Bool {
        guard BrowserURL.equivalent(reading.url, requestedURL) else {
            // Not the requested address. Only a page that actually replaced the one being navigated
            // away from — a redirect that has come to rest — is an outcome worth reporting;
            // anything else is still the pre-navigation state and the bound should keep waiting.
            return !BrowserURL.equivalent(reading.url, before.url) && reading.title != before.title
        }
        // The requested address is showing. Its title is trustworthy unless it is still the title of
        // the page being left, which is exactly the stale read this bound exists to outlast.
        // Re-navigating to the address already open has no title change to wait for.
        return reading.title != before.title || BrowserURL.equivalent(before.url, requestedURL)
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }
}

public protocol BrowserAutomationServing {
    func navigate(app: String, url: String) throws -> BrowserNavigationResult
    func windows(app: String) throws -> [BrowserWindow]
    func tabs(app: String, window: Int?) throws -> [BrowserTab]
}

public final class AppleScriptBrowserAutomation: BrowserAutomationServing {
    private let authorizer: any AppleEventAuthorizing
    private let isRunning: (String) -> Bool
    private let ledger: AppleEventAnswerLedger
    private let log: (String) -> Void
    private let settler: BrowserNavigationSettler
    /// Runs one navigation script and returns its list result. Injected so the dispatch-then-settle
    /// sequence can be exercised without a live browser; nil runs it as a real Apple event.
    private let runNavigationScript: ((String, String) throws -> [String])?

    public convenience init() {
        self.init(authorizer: SystemAppleEventAuthorizer(), isRunning: { bundleIdentifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains { !$0.isTerminated }
        })
    }

    init(
        authorizer: any AppleEventAuthorizing,
        isRunning: @escaping (String) -> Bool,
        ledger: AppleEventAnswerLedger = .shared,
        log: @escaping (String) -> Void = AppleEventAuthorizationService.logToStandardError,
        settler: BrowserNavigationSettler = .live,
        runNavigationScript: ((String, String) throws -> [String])? = nil
    ) {
        self.authorizer = authorizer
        self.isRunning = isRunning
        self.ledger = ledger
        self.log = log
        self.settler = settler
        self.runNavigationScript = runNavigationScript
    }

    public func navigate(app: String, url: String) throws -> BrowserNavigationResult {
        let validatedURL = try Self.validatedURL(url)
        let browser = try resolve(app)
        let before = try dispatchNavigation(to: validatedURL, in: browser)
        let outcome = try settler.settle(requestedURL: validatedURL, before: before) {
            try readActiveTab(browser)
        }
        return BrowserNavigationResult(
            app: browser.rawValue,
            requestedURL: validatedURL,
            url: outcome.reading.url,
            title: outcome.reading.title,
            settleEvidence: outcome.evidence,
            elapsedMs: outcome.elapsedMs
        )
    }

    /// Sends the navigation and returns what the tab held at the moment it was sent.
    ///
    /// Capturing the outgoing page in the same Apple event that starts the navigation is what makes
    /// the baseline trustworthy: read it separately and the tab could already have moved, leaving
    /// nothing to tell a stale readback from a fresh one.
    private func dispatchNavigation(to url: String, in browser: SupportedBrowser) throws -> BrowserTabReading {
        let source = """
        tell application id "\(browser.rawValue)"
            if (count of windows) is 0 then error "browser has no windows" number 1728
            set targetTab to \(Self.activeTabExpression(browser))
            set previousURL to URL of targetTab
            set previousName to name of targetTab
            \(Self.loadingProbe(browser))
            set URL of targetTab to "\(Self.appleScriptLiteral(url))"
            return {previousURL, previousName, loadingState}
        end tell
        """
        return try readTabReading(source, browser: browser)
    }

    private func readActiveTab(_ browser: SupportedBrowser) throws -> BrowserTabReading {
        let source = """
        tell application id "\(browser.rawValue)"
            if (count of windows) is 0 then error "browser has no windows" number 1728
            set targetTab to \(Self.activeTabExpression(browser))
            \(Self.loadingProbe(browser))
            return {URL of targetTab, name of targetTab, loadingState}
        end tell
        """
        return try readTabReading(source, browser: browser)
    }

    private func readTabReading(_ source: String, browser: SupportedBrowser) throws -> BrowserTabReading {
        let values = try runNavigationScript.map { try $0(source, browser.name) }
            ?? executeList(source, browser: browser)
        guard values.count == 3 else { throw BrowserAutomationError.executionFailed("unexpected navigation response") }
        return BrowserTabReading(url: values[0], title: values[1], loading: Self.loadingState(values[2]))
    }

    private static func activeTabExpression(_ browser: SupportedBrowser) -> String {
        browser == .safari ? "current tab of front window" : "active tab of front window"
    }

    /// Statements that leave `loadingState` holding `"true"`, `"false"`, or `"unknown"`.
    ///
    /// Safari's tab has no loading property, so asking would only raise an error to swallow and the
    /// settler falls back to its stability window. Chrome's `loading` is read inside a `try` so that
    /// a build whose dictionary lacks it degrades to that same fallback rather than failing the
    /// navigation outright.
    private static func loadingProbe(_ browser: SupportedBrowser) -> String {
        guard browser != .safari else { return "set loadingState to \"unknown\"" }
        return """
        set loadingState to "unknown"
            try
                if loading of targetTab then
                    set loadingState to "true"
                else
                    set loadingState to "false"
                end if
            end try
        """
    }

    private static func loadingState(_ value: String) -> Bool? {
        switch value {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    public func windows(app: String) throws -> [BrowserWindow] {
        let browser = try resolve(app)
        let source = """
        tell application id "\(browser.rawValue)"
            set output to {}
            repeat with i from 1 to count of windows
                set w to window i
                set end of output to {(i as text), (name of w as text), ((i is 1) as text)}
            end repeat
            return output
        end tell
        """
        return try executeRecords(source, browser: browser).map { record in
            guard record.count == 3, let index = Int(record[0]) else { throw BrowserAutomationError.executionFailed("unexpected window response") }
            return BrowserWindow(id: "window:\(index)", index: index, title: record[1], active: record[2] == "true")
        }
    }

    public func tabs(app: String, window: Int?) throws -> [BrowserTab] {
        if let window, window < 1 { throw BrowserAutomationError.invalidWindow(window) }
        let browser = try resolve(app)
        if let window, window > (try windows(app: app).count) { throw BrowserAutomationError.invalidWindow(window) }
        let windowStart = window ?? 1
        let windowEnd = window.map(String.init) ?? "count of windows"
        let activeIndex = browser == .safari ? "index of current tab of w" : "active tab index of w"
        let source = """
        tell application id "\(browser.rawValue)"
            if (count of windows) is 0 then return {}
            if \(windowStart) > (count of windows) then error "window not found" number 1728
            set output to {}
            repeat with wi from \(windowStart) to \(windowEnd)
                set w to window wi
                set selectedTab to \(activeIndex)
                repeat with ti from 1 to count of tabs of w
                    set t to tab ti of w
                    set end of output to {(wi as text), (ti as text), (name of t as text), (URL of t as text), ((ti is selectedTab) as text)}
                end repeat
            end repeat
            return output
        end tell
        """
        return try executeRecords(source, browser: browser).map { record in
            guard record.count == 5, let wi = Int(record[0]), let ti = Int(record[1]) else { throw BrowserAutomationError.executionFailed("unexpected tab response") }
            return BrowserTab(id: "window:\(wi):tab:\(ti)", windowID: "window:\(wi)", windowIndex: wi, index: ti, title: record[2], url: record[3], active: record[4] == "true")
        }
    }

    private func resolve(_ query: String) throws -> SupportedBrowser {
        guard let browser = SupportedBrowser.named(query) else { throw BrowserAutomationError.unsupportedApp(query) }
        guard isRunning(browser.rawValue) else {
            throw BrowserAutomationError.appNotRunning(browser.name)
        }
        // Check only: an agent's call must never block on a consent dialog it did not ask for.
        try AppleEventAuthorizationService(authorizer: authorizer, ledger: ledger, log: log).check(
            bundleIdentifier: browser.rawValue,
            appName: browser.name
        )
        return browser
    }

    static func validatedURL(_ raw: String) throws -> String {
        guard raw.utf8.count <= 8_192 else { throw BrowserAutomationError.invalidURL("URL exceeds 8192 bytes") }
        guard !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw BrowserAutomationError.invalidURL("control characters are not allowed") }
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme), components.host != nil else {
            throw BrowserAutomationError.invalidURL("an absolute http or https URL is required")
        }
        return raw
    }

    static func appleScriptLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func executeList(_ source: String, browser: SupportedBrowser) throws -> [String] {
        let descriptor = try execute(source, browser: browser)
        return descriptorStrings(descriptor)
    }

    private func executeRecords(_ source: String, browser: SupportedBrowser) throws -> [[String]] {
        let descriptor = try execute(source, browser: browser)
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).map { descriptorStrings(descriptor.atIndex($0)) }
    }

    /// The Apple event itself was refused, after the preflight determination had passed.
    ///
    /// That is macOS answering this process, so the ledger takes it like any other answer. Otherwise
    /// the allowed preflight would be the last word: the menu would go on treating the grant as
    /// settled and retire its consent item, leaving this refusal — which names that item — pointing
    /// at a surface that is no longer there.
    func executedRefusal(browser: SupportedBrowser, status: Int32) -> BrowserAutomationError {
        ledger.recordAnswer(OSStatus(errAEEventNotPermitted), leg: .executed, for: browser.rawValue)
        return .automationNotGranted(BrowserAutomationDenial(
            app: browser.name, authorization: .denied, leg: .executed, status: status,
            origin: .browserVerb
        ))
    }

    private func execute(_ source: String, browser: SupportedBrowser) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        let boundedSource = "with timeout of 15 seconds\n\(source)\nend timeout"
        guard let script = NSAppleScript(source: boundedSource), let result = script.executeAndReturnError(&error) as NSAppleEventDescriptor? else {
            let number = error?[NSAppleScript.errorNumber] as? Int
            if let number, number == Int(errAEEventNotPermitted) {
                // Only a browser verb sends Apple events; the consent gesture stops at the
                // authorization.
                throw executedRefusal(browser: browser, status: Int32(number))
            }
            if number == -1712 { throw BrowserAutomationError.timeout(browser.name) }
            throw BrowserAutomationError.executionFailed((error?[NSAppleScript.errorMessage] as? String) ?? "unknown Apple event error")
        }
        return result
    }

    private func descriptorStrings(_ descriptor: NSAppleEventDescriptor?) -> [String] {
        guard let descriptor else { return [] }
        if descriptor.numberOfItems == 0 { return [descriptor.stringValue ?? ""] }
        return (1...descriptor.numberOfItems).map { descriptor.atIndex($0)?.stringValue ?? "" }
    }
}