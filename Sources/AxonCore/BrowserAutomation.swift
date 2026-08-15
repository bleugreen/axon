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
final class AppleEventAnswerLedger: @unchecked Sendable {
    static let shared = AppleEventAnswerLedger()

    private let lock = NSLock()
    private var answered: Set<String> = []

    /// Whether macOS has already answered this process for `bundleIdentifier`.
    func hasAnswer(for bundleIdentifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return answered.contains(bundleIdentifier)
    }

    func recordAnswer(for bundleIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        answered.insert(bundleIdentifier)
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
        try resolve(decision, appName: appName)
    }

    /// Resolves the authorization, presenting macOS's consent dialog when the grant is undetermined.
    ///
    /// This is the only path that passes `askUserIfNeeded: true`, and it blocks for as long as the
    /// dialog is on screen. Call it from a deliberate user gesture, off the main thread.
    func requestConsent(bundleIdentifier: String, appName: String) throws {
        // Read once, before the first leg, so the silent leg of this very request does not read back
        // as an earlier answer.
        let answeredEarlier = ledger.hasAnswer(for: bundleIdentifier)
        let initial = determine(
            bundleIdentifier: bundleIdentifier,
            askUserIfNeeded: false,
            answeredEarlierInThisProcess: answeredEarlier
        )
        // A recorded denial is final until the user changes it in System Settings; macOS will not
        // present a dialog for it, so prompting would only repeat the same answer.
        guard initial.status == OSStatus(errAEEventWouldRequireUserConsent) else {
            return try resolve(initial, appName: appName)
        }
        try resolve(
            determine(
                bundleIdentifier: bundleIdentifier,
                askUserIfNeeded: true,
                answeredEarlierInThisProcess: answeredEarlier
            ),
            appName: appName
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
            ledger.recordAnswer(for: bundleIdentifier)
        }
        log("automation authorization target=\(bundleIdentifier) leg=\(leg.rawValue) status=\(status) answeredEarlierInThisProcess=\(holdsEarlierAnswer)")
        return Decision(status: status, leg: leg, answeredEarlierInThisProcess: holdsEarlierAnswer)
    }

    private func resolve(_ decision: Decision, appName: String) throws {
        switch decision.status {
        case noErr:
            return
        case OSStatus(errAEEventNotPermitted):
            throw denial(.denied, decision, appName: appName)
        case OSStatus(errAEEventWouldRequireUserConsent):
            throw denial(.notDetermined, decision, appName: appName)
        default:
            throw BrowserAutomationError.authorizationFailed(app: appName, status: decision.status)
        }
    }

    private func denial(
        _ authorization: BrowserAutomationAuthorization,
        _ decision: Decision,
        appName: String
    ) -> BrowserAutomationError {
        .automationNotGranted(BrowserAutomationDenial(
            app: appName,
            authorization: authorization,
            leg: decision.leg,
            status: decision.status,
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

/// One refused Apple Events authorization, described well enough to act on.
public struct BrowserAutomationDenial: Equatable, Sendable {
    public let app: String
    public let authorization: BrowserAutomationAuthorization
    public let leg: BrowserAutomationAuthorizationLeg
    public let status: Int32?
    /// True when this process had already resolved an authorization for the same target before this
    /// request. macOS may answer from what the process holds, so such a denial does not necessarily
    /// describe the current TCC database.
    public let answeredEarlierInThisProcess: Bool

    public init(
        app: String,
        authorization: BrowserAutomationAuthorization,
        leg: BrowserAutomationAuthorizationLeg,
        status: Int32?,
        answeredEarlierInThisProcess: Bool = false
    ) {
        self.app = app
        self.authorization = authorization
        self.leg = leg
        self.status = status
        self.answeredEarlierInThisProcess = answeredEarlierInThisProcess
    }

    /// Remediation the user can actually perform from the state they are actually in. Until consent
    /// has been requested once there is no Axon row in System Settings and no way to add one, so
    /// pointing an undetermined grant at that pane describes an impossible action.
    var message: String {
        var sentences = ["Automation permission for \(app) \(authorization == .denied ? "is denied" : "has not been granted")."]
        if authorization == .notDetermined {
            sentences.append("Open the Axon menu bar item and choose Browser Automation... to grant it. Axon does not appear in System Settings > Privacy & Security > Automation until consent has been requested once.")
        } else {
            sentences.append("If Axon is listed in System Settings > Privacy & Security > Automation, enable \(app) beneath it. If it is not listed, open the Axon menu bar item and choose Browser Automation... to request consent.")
        }
        if answeredEarlierInThisProcess {
            sentences.append("The Axon daemon already resolved Automation for \(app) earlier in this session and macOS can answer from what the process holds, so this may not reflect current settings. Restart the daemon with `launchctl kickstart -k gui/$(id -u)/dev.axon.daemon` to re-check.")
        }
        return sentences.joined(separator: " ")
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

public struct BrowserNavigationResult: Equatable, Sendable {
    public let app: String
    public let requestedURL: String
    public let url: String
    public let title: String
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

    public convenience init() {
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

    public func navigate(app: String, url: String) throws -> BrowserNavigationResult {
        let validatedURL = try Self.validatedURL(url)
        let browser = try resolve(app)
        let tabExpression = browser == .safari ? "current tab of front window" : "active tab of front window"
        let source = """
        tell application id "\(browser.rawValue)"
            if (count of windows) is 0 then error "browser has no windows" number 1728
            set targetTab to \(tabExpression)
            set URL of targetTab to "\(Self.appleScriptLiteral(validatedURL))"
            return {URL of targetTab, name of targetTab}
        end tell
        """
        let values = try executeList(source, appName: browser.name)
        guard values.count == 2 else { throw BrowserAutomationError.executionFailed("unexpected navigation response") }
        return BrowserNavigationResult(app: browser.rawValue, requestedURL: validatedURL, url: values[0], title: values[1])
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
        return try executeRecords(source, appName: browser.name).map { record in
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
        return try executeRecords(source, appName: browser.name).map { record in
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

    private func executeList(_ source: String, appName: String) throws -> [String] {
        let descriptor = try execute(source, appName: appName)
        return descriptorStrings(descriptor)
    }

    private func executeRecords(_ source: String, appName: String) throws -> [[String]] {
        let descriptor = try execute(source, appName: appName)
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).map { descriptorStrings(descriptor.atIndex($0)) }
    }

    private func execute(_ source: String, appName: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        let boundedSource = "with timeout of 15 seconds\n\(source)\nend timeout"
        guard let script = NSAppleScript(source: boundedSource), let result = script.executeAndReturnError(&error) as NSAppleEventDescriptor? else {
            let number = error?[NSAppleScript.errorNumber] as? Int
            if let number, number == Int(errAEEventNotPermitted) {
                throw BrowserAutomationError.automationNotGranted(BrowserAutomationDenial(
                    app: appName, authorization: .denied, leg: .executed, status: Int32(number)
                ))
            }
            if number == -1712 { throw BrowserAutomationError.timeout(appName) }
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