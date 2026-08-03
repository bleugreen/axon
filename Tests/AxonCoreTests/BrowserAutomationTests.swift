import Foundation
import Testing
@testable import AxonCore

@Test func browserNavigationURLValidationAcceptsOnlyAbsoluteHTTPURLs() throws {
    #expect(try AppleScriptBrowserAutomation.validatedURL("https://example.com/path?q=1") == "https://example.com/path?q=1")
    #expect(throws: BrowserAutomationError.self) { try AppleScriptBrowserAutomation.validatedURL("file:///tmp/private") }
    #expect(throws: BrowserAutomationError.self) { try AppleScriptBrowserAutomation.validatedURL("javascript:alert(1)") }
    #expect(throws: BrowserAutomationError.self) { try AppleScriptBrowserAutomation.validatedURL("https://example.com/\nnext") }
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

    browser.error = .permissionRequired("Safari")
    let denied = CommandRouter(browserAutomation: browser).handle(JSONRPCRequest(
        id: .int(2), method: "windows", params: .object(["app": .string("Safari")])
    ))
    #expect(denied.error?.code == -32603)
    #expect(denied.error?.message.contains("Privacy & Security > Automation") == true)
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