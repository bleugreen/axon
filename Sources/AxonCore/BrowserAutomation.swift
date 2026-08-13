import AppKit
import ApplicationServices
import Foundation

public enum BrowserAutomationAuthorization: String, Equatable, Sendable {
    case denied
    case notDetermined
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

public enum BrowserAutomationError: Error, Equatable, CustomStringConvertible {
    case unsupportedApp(String)
    case appNotRunning(String)
    case invalidURL(String)
    case invalidWindow(Int)
    case automationNotGranted(app: String, authorization: BrowserAutomationAuthorization, status: Int32?)
    case authorizationFailed(app: String, status: Int32)
    case timeout(String)
    case executionFailed(String)

    public var description: String {
        switch self {
        case let .unsupportedApp(app): return "Unsupported browser: \(app). Supported browsers are Safari and Google Chrome."
        case let .appNotRunning(app): return "Browser is not running: \(app)"
        case let .invalidURL(reason): return "Invalid navigation URL: \(reason)"
        case let .invalidWindow(index): return "Window index must be greater than zero: \(index)"
        case let .automationNotGranted(app, authorization, _): return "Automation permission for \(app) is \(authorization.rawValue). Allow Axon to control it in System Settings > Privacy & Security > Automation."
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
    private enum Browser: String {
        case safari = "com.apple.Safari"
        case chrome = "com.google.Chrome"

        var name: String { self == .safari ? "Safari" : "Google Chrome" }
    }

    private let authorizer: any AppleEventAuthorizing
    private let isRunning: (String) -> Bool

    public convenience init() {
        self.init(authorizer: SystemAppleEventAuthorizer(), isRunning: { bundleIdentifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains { !$0.isTerminated }
        })
    }

    init(authorizer: any AppleEventAuthorizing, isRunning: @escaping (String) -> Bool) {
        self.authorizer = authorizer
        self.isRunning = isRunning
    }

    public func navigate(app: String, url: String) throws -> BrowserNavigationResult {
        let browser = try resolve(app)
        let validatedURL = try Self.validatedURL(url)
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

    private func resolve(_ query: String) throws -> Browser {
        let normalized = query.lowercased()
        let browser: Browser?
        switch normalized {
        case "safari", Browser.safari.rawValue.lowercased(): browser = .safari
        case "google chrome", "chrome", Browser.chrome.rawValue.lowercased(): browser = .chrome
        default: browser = nil
        }
        guard let browser else { throw BrowserAutomationError.unsupportedApp(query) }
        guard isRunning(browser.rawValue) else {
            throw BrowserAutomationError.appNotRunning(browser.name)
        }
        try authorize(browser)
        return browser
    }

    private func authorize(_ browser: Browser) throws {
        let initial = authorizer.determinePermission(bundleIdentifier: browser.rawValue, askUserIfNeeded: false)
        switch initial {
        case noErr:
            return
        case OSStatus(errAEEventWouldRequireUserConsent):
            let prompted = authorizer.determinePermission(bundleIdentifier: browser.rawValue, askUserIfNeeded: true)
            switch prompted {
            case noErr:
                return
            case OSStatus(errAEEventNotPermitted):
                throw BrowserAutomationError.automationNotGranted(app: browser.name, authorization: .denied, status: prompted)
            case OSStatus(errAEEventWouldRequireUserConsent):
                throw BrowserAutomationError.automationNotGranted(app: browser.name, authorization: .notDetermined, status: prompted)
            default:
                throw BrowserAutomationError.authorizationFailed(app: browser.name, status: prompted)
            }
        case OSStatus(errAEEventNotPermitted):
            throw BrowserAutomationError.automationNotGranted(app: browser.name, authorization: .denied, status: initial)
        default:
            throw BrowserAutomationError.authorizationFailed(app: browser.name, status: initial)
        }
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
            if number == Int(errAEEventNotPermitted) { throw BrowserAutomationError.automationNotGranted(app: appName, authorization: .denied, status: Int32(number!)) }
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