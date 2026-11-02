@testable import AxonClient
import ApplicationServices
import Foundation
import Testing
@testable import AxonCore

/// The browser verbs' wire contract, as the Swift router answers it.
///
/// `schema/fixtures/browser` is Swift's own output, not a transcription: every file is produced
/// here by `CommandRouter` over `AppleScriptBrowserAutomation` (with a scripted authorizer) or over
/// a scripted service, and `BrowserURL` / `validatedURL` answer the URL cases. The Rust daemon
/// (`rust/axon-core/tests/browser_contract.rs` and the router tests in `rust/axon-mac`) is held to
/// these bytes, so the two daemons answer navigate, windows, and tabs identically.
///
/// After a deliberate contract change, `AXON_BLESS_BROWSER_FIXTURES=1 swift test --filter
/// BrowserContractConformance` rewrites the files; the Rust tests then say whether Rust still
/// agrees.
private let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("schema/fixtures/browser")

private func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

private func pin(_ name: String, _ value: JSONValue) throws {
    let url = fixtureDirectory.appendingPathComponent(name)
    if ProcessInfo.processInfo.environment["AXON_BLESS_BROWSER_FIXTURES"] != nil {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        var data = try encoder.encode(value)
        data.append(0x0A)
        try data.write(to: url)
    }
    let pinned = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    #expect(pinned == value, "\(name) does not match what the Swift router answers")
}

/// One request and the router's whole answer to it: the result object, or the error object.
private func exchange(_ router: CommandRouter, _ method: String, _ params: [String: JSONValue]) throws -> JSONValue {
    let response = router.handle(JSONRPCRequest(id: .int(1), method: method, params: .object(params)))
    var body: [String: JSONValue] = ["method": .string(method), "params": .object(params)]
    if let error = response.error {
        body["error"] = try jsonValue(error)
    } else {
        body["result"] = .object(response.result ?? [:])
    }
    return .object(body)
}

private struct FixedAuthorizer: AppleEventAuthorizing {
    let status: OSStatus
    func determinePermission(bundleIdentifier: String, askUserIfNeeded: Bool) -> OSStatus { status }
}

/// The production service with a scripted authorization answer, so every refusal it raises before
/// an Apple event is sent is Swift's real behavior rather than a stubbed error.
private func realService(status: OSStatus = noErr, running: Bool = true) -> AppleScriptBrowserAutomation {
    AppleScriptBrowserAutomation(
        authorizer: FixedAuthorizer(status: status),
        isRunning: { _ in running },
        ledger: AppleEventAnswerLedger(),
        log: { _ in },
        runNavigationScript: { _, _ in throw BrowserAutomationError.executionFailed("no script may run in a fixture") }
    )
}

private final class ScriptedService: BrowserAutomationServing {
    var navigation: BrowserNavigationResult?
    var windowResults: [BrowserWindow] = []
    var tabResults: [BrowserTab] = []
    var error: BrowserAutomationError?

    func navigate(app: String, url: String) throws -> BrowserNavigationResult {
        if let error { throw error }
        return navigation!
    }

    func windows(app: String) throws -> [BrowserWindow] {
        if let error { throw error }
        return windowResults
    }

    func tabs(app: String, window: Int?) throws -> [BrowserTab] {
        if let error { throw error }
        return tabResults
    }
}

private func axSnapshot(titles: [String]) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("browser-cross-check"),
        app: AppIdentity(bundleIdentifier: "com.apple.Safari", name: "Safari", processIdentifier: 42),
        windows: titles.map { AXNode(role: "AXWindow", title: $0) },
        screenshot: nil
    )
}

@Test func navigateAnswersMatchTheSharedFixtures() throws {
    let service = ScriptedService()
    let router = CommandRouter(browserAutomation: service)

    service.navigation = BrowserNavigationResult(
        app: "com.apple.Safari", requestedURL: "https://example.com", url: "https://example.com/",
        title: "Example Domain", settleEvidence: .stableReadback, elapsedMs: 480
    )
    try pin("navigate-verified.json", exchange(router, "navigate", ["app": .string("Safari"), "url": .string("https://example.com")]))

    service.navigation = BrowserNavigationResult(
        app: "com.google.Chrome", requestedURL: "https://example.com/redirect", url: "https://example.com/navigated",
        title: "Navigated", settleEvidence: .loadingFlag, elapsedMs: 60
    )
    try pin("navigate-redirect.json", exchange(router, "navigate", ["app": .string("Google Chrome"), "url": .string("https://example.com/redirect")]))

    service.navigation = BrowserNavigationResult(
        app: "com.google.Chrome", requestedURL: "https://example.com/slow", url: "https://example.com/slow",
        title: "example.com/slow", settleEvidence: .bound, elapsedMs: 4_000
    )
    try pin("navigate-unsettled.json", exchange(router, "navigate", ["app": .string("Chrome"), "url": .string("https://example.com/slow")]))
}

@Test func windowsAndTabsAnswersMatchTheSharedFixtures() throws {
    let service = ScriptedService()
    service.windowResults = [
        BrowserWindow(id: "window:1", index: 1, title: "Example Domain", active: true),
        BrowserWindow(id: "window:2", index: 2, title: "Second", active: false)
    ]
    try pin("windows-matched.json", exchange(
        CommandRouter(captureSnapshot: { _, _ in axSnapshot(titles: ["Second", "Example Domain"]) }, browserAutomation: service),
        "windows", ["app": .string("Safari")]
    ))

    service.windowResults = [
        BrowserWindow(id: "window:1", index: 1, title: "Same", active: true),
        BrowserWindow(id: "window:2", index: 2, title: "Same", active: false)
    ]
    try pin("windows-partial.json", exchange(
        CommandRouter(captureSnapshot: { _, _ in axSnapshot(titles: ["Same", "Different"]) }, browserAutomation: service),
        "windows", ["app": .string("Safari")]
    ))

    service.tabResults = [
        BrowserTab(id: "window:1:tab:1", windowID: "window:1", windowIndex: 1, index: 1, title: "Example Domain", url: "https://example.com/", active: false),
        BrowserTab(id: "window:1:tab:2", windowID: "window:1", windowIndex: 1, index: 2, title: "Navigated", url: "https://example.com/navigated", active: true),
        BrowserTab(id: "window:2:tab:1", windowID: "window:2", windowIndex: 2, index: 1, title: "Second", url: "https://example.org/", active: true)
    ]
    try pin("tabs.json", exchange(CommandRouter(browserAutomation: service), "tabs", ["app": .string("Google Chrome")]))
}

@Test func browserRefusalsMatchTheSharedFixtures() throws {
    try pin("error-not-determined-checked.json", exchange(
        CommandRouter(browserAutomation: realService(status: OSStatus(errAEEventWouldRequireUserConsent))),
        "navigate", ["app": .string("Chrome"), "url": .string("https://example.com")]
    ))
    try pin("error-denied-checked.json", exchange(
        CommandRouter(browserAutomation: realService(status: OSStatus(errAEEventNotPermitted))),
        "windows", ["app": .string("Safari")]
    ))

    let executed = ScriptedService()
    executed.error = realService().executedRefusal(browser: .safari, status: Int32(errAEEventNotPermitted))
    try pin("error-denied-executed.json", exchange(
        CommandRouter(browserAutomation: executed),
        "navigate", ["app": .string("Safari"), "url": .string("https://example.com")]
    ))

    // AppleScript's `error "browser has no windows" number 1728` reaches the service as that
    // message, which is the one part of this file that stands in for a live script.
    let noWindows = ScriptedService()
    noWindows.error = .executionFailed("browser has no windows")
    try pin("error-no-windows.json", exchange(
        CommandRouter(browserAutomation: noWindows),
        "navigate", ["app": .string("Safari"), "url": .string("https://example.com")]
    ))

    let real = CommandRouter(browserAutomation: realService())
    try pin("error-unsupported-app.json", exchange(real, "windows", ["app": .string("Firefox")]))
    try pin("error-invalid-url.json", exchange(real, "navigate", ["app": .string("Safari"), "url": .string("file:///tmp/private")]))
    try pin("error-invalid-window.json", exchange(real, "tabs", ["app": .string("Safari"), "window": .int(0)]))
    try pin("error-window-not-integer.json", exchange(real, "tabs", ["app": .string("Safari"), "window": .string("2")]))
    try pin("error-missing-url.json", exchange(real, "navigate", ["app": .string("Safari")]))
    try pin("error-missing-app.json", exchange(real, "windows", [:]))
    try pin("error-not-running.json", exchange(
        CommandRouter(browserAutomation: realService(running: false)),
        "windows", ["app": .string("com.apple.Safari")]
    ))
}

/// Every input is run through both `validatedURL` and `BrowserURL.normalized`, so the Rust port is
/// held to Foundation's `URLComponents` on exactly the edges where a hand-written parser drifts.
@Test func browserURLCasesMatchTheSharedFixture() throws {
    let overLength = "https://example.com/" + String(repeating: "a", count: 8_173)
    let atLength = "https://example.com/" + String(repeating: "a", count: 8_172)
    let inputs = [
        "https://example.com",
        "https://example.com/",
        "HTTPS://News.YCombinator.com/",
        "HTTP://EXAMPLE.COM",
        "https://example.com:443/docs",
        "http://example.com:80/",
        "http://example.com:8080/",
        "https://example.com:80/",
        "https://example.com:0443/",
        "https://example.com:/x",
        "https://example.com/?",
        "https://example.com/#",
        "https://example.com?q",
        "https://example.com#frag",
        "https://example.com/a?q=1#top",
        "https://user:pass@Example.COM/Path",
        "https://example.com/docs/",
        "https://example.com/%7Euser",
        "https://example.com/%zz",
        "https://example.com/a b",
        "https://exa mple.com/",
        "https://example.com/a|b",
        "https://example.com/a?b=[1]",
        "https://example.com/a{b}",
        "https://b\u{FC}cher.example/",
        "https://example.com/caf\u{E9}",
        "https://example.com/\u{200B}",
        "https://example.com/\u{00AD}",
        "https://example.com/\u{FEFF}",
        "https://example.com/\nnext",
        "https://example.com/\u{0085}",
        "https://example.com/\u{7F}",
        "https://[::1]:8443/x",
        "https://[::1]:443/",
        "https://127.0.0.1:8000/page?n=1",
        "https:///path",
        "https:example.com",
        "https://",
        "//example.com/",
        "example.com",
        "ftp://example.com/",
        "file:///tmp/private",
        "javascript:alert(1)",
        "",
        atLength,
        overLength
    ]
    let cases: [JSONValue] = inputs.map { input in
        var entry: [String: JSONValue] = ["input": .string(input), "normalized": .string(BrowserURL.normalized(input))]
        do {
            entry["valid"] = .bool(try AppleScriptBrowserAutomation.validatedURL(input) == input)
        } catch {
            entry["valid"] = .bool(false)
            entry["error"] = .string(String(describing: error))
        }
        return .object(entry)
    }
    let pairs: [(String, String)] = [
        ("https://news.ycombinator.com", "https://news.ycombinator.com/"),
        ("HTTPS://News.YCombinator.com/", "https://news.ycombinator.com/"),
        ("https://example.com:443/docs", "https://example.com/docs"),
        ("http://example.com:80/", "http://example.com/"),
        ("https://example.com/?", "https://example.com/"),
        ("https://example.com/#", "https://example.com/"),
        ("https://example.com/docs", "https://example.com/docs/"),
        ("https://example.com", "https://www.example.com"),
        ("https://example.com", "http://example.com"),
        ("https://example.com/a?q=1", "https://example.com/a?q=2"),
        ("https://example.com/a#top", "https://example.com/a"),
        ("https://example.com/A", "https://example.com/a"),
        ("https://example.com/a b", "https://example.com/a b"),
        ("https://example.com/a b", "https://example.com/a%20b")
    ]
    let equivalence: [JSONValue] = pairs.map { lhs, rhs in
        .object(["lhs": .string(lhs), "rhs": .string(rhs), "equivalent": .bool(BrowserURL.equivalent(lhs, rhs))])
    }
    try pin("url-cases.json", .object(["cases": .array(cases), "equivalence": .array(equivalence)]))
}
