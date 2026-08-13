import Foundation
import ApplicationServices
import Testing
@testable import AxonCore

@Test func browserNavigationURLValidationAcceptsOnlyAbsoluteHTTPURLs() throws {
    #expect(try AppleScriptBrowserAutomation.validatedURL("https://example.com/path?q=1") == "https://example.com/path?q=1")
    #expect(throws: BrowserAutomationError.self) { try AppleScriptBrowserAutomation.validatedURL("file:///tmp/private") }
    #expect(throws: BrowserAutomationError.self) { try AppleScriptBrowserAutomation.validatedURL("javascript:alert(1)") }
    #expect(throws: BrowserAutomationError.self) { try AppleScriptBrowserAutomation.validatedURL("https://example.com/\nnext") }
}

@Test func invalidNavigationInputDoesNotCrossAutomationPermissionBoundary() {
    let authorizer = AppleEventAuthorizerStub(results: [])
    let browser = AppleScriptBrowserAutomation(authorizer: authorizer, isRunning: { _ in true })

    #expect(throws: BrowserAutomationError.invalidURL("an absolute http or https URL is required")) {
        try browser.navigate(app: "Safari", url: "file:///tmp/private")
    }
    #expect(authorizer.requests.isEmpty)
}

private final class AppleEventAuthorizerStub: AppleEventAuthorizing {
    private var results: [OSStatus]
    var requests: [Bool] = []
    var bundleIdentifiers: [String] = []

    init(results: [OSStatus]) { self.results = results }

    func determinePermission(bundleIdentifier: String, askUserIfNeeded: Bool) -> OSStatus {
        bundleIdentifiers.append(bundleIdentifier)
        requests.append(askUserIfNeeded)
        return results.removeFirst()
    }
}

@Test func appleEventAuthorizationPreflightsBeforePromptingAndPromptsOnlyWhenNeeded() throws {
    let alreadyGranted = AppleEventAuthorizerStub(results: [noErr])
    try AppleEventAuthorizationService(authorizer: alreadyGranted).authorize(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    #expect(alreadyGranted.requests == [false])

    let firstUse = AppleEventAuthorizerStub(results: [OSStatus(errAEEventWouldRequireUserConsent), noErr])
    try AppleEventAuthorizationService(authorizer: firstUse).authorize(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    #expect(firstUse.requests == [false, true])
    #expect(firstUse.bundleIdentifiers == ["com.apple.Safari", "com.apple.Safari"])
}

@Test func appleEventAuthorizationClassifiesDeniedUndeterminedAndUnexpectedStatuses() {
    let cases: [([OSStatus], BrowserAutomationError)] = [
        ([OSStatus(errAEEventNotPermitted)], .automationNotGranted(app: "Safari", authorization: .denied, status: OSStatus(errAEEventNotPermitted))),
        ([OSStatus(errAEEventWouldRequireUserConsent), OSStatus(errAEEventNotPermitted)], .automationNotGranted(app: "Safari", authorization: .denied, status: OSStatus(errAEEventNotPermitted))),
        ([OSStatus(errAEEventWouldRequireUserConsent), OSStatus(errAEEventWouldRequireUserConsent)], .automationNotGranted(app: "Safari", authorization: .notDetermined, status: OSStatus(errAEEventWouldRequireUserConsent))),
        ([-50], .authorizationFailed(app: "Safari", status: -50))
    ]
    for (results, expected) in cases {
        let authorizer = AppleEventAuthorizerStub(results: results)
        #expect(throws: expected) {
            try AppleEventAuthorizationService(authorizer: authorizer).authorize(bundleIdentifier: "com.apple.Safari", appName: "Safari")
        }
    }
}

@Test func tabsReturnsApplicationScriptingShapeWithoutClaimingAXAuthority() {
    let browser = BrowserAutomationStub()
    browser.tabResults = [BrowserTab(
        id: "window:1:tab:2", windowID: "window:1", windowIndex: 1, index: 2,
        title: "Example", url: "https://example.com", active: true
    )]
    let response = CommandRouter(browserAutomation: browser).handle(JSONRPCRequest(
        id: .string("tabs"), method: "tabs", params: .object(["app": .string("Safari")])
    ))

    #expect(response.error == nil)
    #expect(response.result?["authority"] == .string("application_scripting"))
    #expect(response.result?["tabs"]?[0]?["id"] == .string("window:1:tab:2"))
    #expect(response.result?["crossCheck"]?["status"] == .string("unavailable"))
}

@Test func windowCrossCheckConsumesDuplicateTitlesOnlyOnce() {
    let browser = BrowserAutomationStub()
    browser.windowResults = [
        BrowserWindow(id: "window:1", index: 1, title: "Same", active: true),
        BrowserWindow(id: "window:2", index: 2, title: "Same", active: false)
    ]
    let router = CommandRouter(
        captureSnapshot: { _, _ in browserSnapshot(titles: ["Same", "Different"]) },
        browserAutomation: browser
    )
    let response = router.handle(JSONRPCRequest(id: .int(3), method: "windows", params: .object(["app": .string("Safari")])))
    #expect(response.result?["crossCheck"]?["status"] == .string("partial"))
    #expect(response.result?["crossCheck"]?["matchingTitles"] == .int(1))
}

@Test func navigateReturnsVerifiedDictionaryReadback() {
    let browser = BrowserAutomationStub()
    browser.navigation = BrowserNavigationResult(
        app: "com.apple.Safari",
        requestedURL: "https://example.com",
        url: "https://example.com",
        title: "Example"
    )
    let router = CommandRouter(browserAutomation: browser)

    let response = router.handle(JSONRPCRequest(id: .string("navigate"), method: "navigate", params: .object([
        "app": .string("Safari"), "url": .string("https://example.com")
    ])))

    #expect(response.error == nil)
    #expect(response.result?["navigation"]?["success"] == .bool(true))
    #expect(response.result?["navigation"]?["verification"] == .string("dictionary_readback"))
    #expect(browser.navigationRequests.count == 1)
    #expect(browser.navigationRequests.first?.0 == "Safari")
    #expect(browser.navigationRequests.first?.1 == "https://example.com")
}

@Test func windowsUsesScriptingAuthorityAndCrossChecksAX() {
    let browser = BrowserAutomationStub()
    browser.windowResults = [
        BrowserWindow(id: "window:1", index: 1, title: "First", active: true),
        BrowserWindow(id: "window:2", index: 2, title: "Second", active: false)
    ]
    let router = CommandRouter(
        captureSnapshot: { _, _ in browserSnapshot(titles: ["First", "Second"]) },
        browserAutomation: browser
    )

    let response = router.handle(JSONRPCRequest(id: .string("windows"), method: "windows", params: .object([
        "app": .string("Safari")
    ])))

    #expect(response.error == nil)
    #expect(response.result?["authority"] == .string("application_scripting"))
    #expect(response.result?["crossCheck"]?["status"] == .string("matched"))
    #expect(response.result?["windows"]?[0]?["id"] == .string("window:1"))
}

@Test func browserErrorsPreserveInvalidInputAndPermissionSemantics() {
    let browser = BrowserAutomationStub()
    browser.error = .unsupportedApp("Firefox")
    let invalid = CommandRouter(browserAutomation: browser).handle(JSONRPCRequest(
        id: .int(1), method: "windows", params: .object(["app": .string("Firefox")])
    ))
    #expect(invalid.error?.code == -32602)

    browser.error = .automationNotGranted(app: "Safari", authorization: .denied, status: -1743)
    let denied = CommandRouter(browserAutomation: browser).handle(JSONRPCRequest(
        id: .int(2), method: "windows", params: .object(["app": .string("Safari")])
    ))
    #expect(denied.error?.code == -32603)
    #expect(denied.error?.message.contains("Privacy & Security > Automation") == true)
    #expect(denied.error?.data?["capability"] == .string("browserAutomation"))
    #expect(denied.error?.data?["reason"] == .string("automation-not-granted"))
    #expect(denied.error?.data?["app"] == .string("Safari"))
    #expect(denied.error?.data?["authorization"] == .string("denied"))
    #expect(denied.error?.data?["nativeStatus"] == .int(-1743))
}

@Test func automationDenialContractIsSharedByEveryBrowserVerbAndRoundTrips() throws {
    let browser = BrowserAutomationStub()
    browser.error = .automationNotGranted(app: "Google Chrome", authorization: .notDetermined, status: -1744)
    let router = CommandRouter(browserAutomation: browser)
    let requests = [
        JSONRPCRequest(id: .int(1), method: "navigate", params: .object(["app": .string("Chrome"), "url": .string("https://example.com")])),
        JSONRPCRequest(id: .int(2), method: "windows", params: .object(["app": .string("Chrome")])),
        JSONRPCRequest(id: .int(3), method: "tabs", params: .object(["app": .string("Chrome")]))
    ]

    for request in requests {
        let response = router.handle(request)
        #expect(response.error?.code == -32603)
        #expect(response.error?.data?["reason"] == .string("automation-not-granted"))
        #expect(response.error?.data?["authorization"] == .string("notDetermined"))
        let encoded = try JSONEncoder().encode(response)
        #expect(try JSONDecoder().decode(JSONRPCResponse.self, from: encoded) == response)
    }
}

private final class BrowserAutomationStub: BrowserAutomationServing {
    var navigation: BrowserNavigationResult?
    var windowResults: [BrowserWindow] = []
    var tabResults: [BrowserTab] = []
    var error: BrowserAutomationError?
    var navigationRequests: [(String, String)] = []

    func navigate(app: String, url: String) throws -> BrowserNavigationResult {
        if let error { throw error }
        navigationRequests.append((app, url))
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

private func browserSnapshot(titles: [String]) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("browser-cross-check"),
        app: AppIdentity(bundleIdentifier: "com.apple.Safari", name: "Safari", processIdentifier: 42),
        windows: titles.map { AXNode(role: "AXWindow", title: $0) },
        screenshot: nil
    )
}