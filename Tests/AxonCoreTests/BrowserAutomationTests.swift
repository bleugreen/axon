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

private final class LogCollector {
    var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}

private struct NoRefusalRecorded: Error {}

/// Runs `body` and returns the Automation denial it refused with, so a test can assert on the whole
/// decision rather than only on the fact that something was thrown.
private func automationDenial(_ body: () throws -> Void) throws -> BrowserAutomationDenial {
    do {
        try body()
    } catch let error as BrowserAutomationError {
        guard case let .automationNotGranted(denial) = error else { throw error }
        return denial
    }
    throw NoRefusalRecorded()
}

private func browserAutomation(
    authorizer: AppleEventAuthorizerStub,
    ledger: AppleEventAnswerLedger = AppleEventAnswerLedger()
) -> AppleScriptBrowserAutomation {
    AppleScriptBrowserAutomation(authorizer: authorizer, isRunning: { _ in true }, ledger: ledger, log: { _ in })
}

private func authorizationService(
    _ authorizer: AppleEventAuthorizerStub,
    ledger: AppleEventAnswerLedger = AppleEventAnswerLedger(),
    log: @escaping (String) -> Void = { _ in }
) -> AppleEventAuthorizationService {
    AppleEventAuthorizationService(authorizer: authorizer, ledger: ledger, log: log)
}

@Test func grantedAutomationLetsABrowserVerbProceedWithoutEverPrompting() throws {
    let authorizer = AppleEventAuthorizerStub(results: [noErr])
    try authorizationService(authorizer).check(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    #expect(authorizer.requests == [false])
}

@Test func anUndeterminedGrantRefusesAnAgentVerbInsteadOfPrompting() throws {
    let authorizer = AppleEventAuthorizerStub(results: [OSStatus(errAEEventWouldRequireUserConsent)])
    let browser = browserAutomation(authorizer: authorizer)

    let denial = try automationDenial { _ = try browser.windows(app: "Safari") }

    #expect(denial.authorization == .notDetermined)
    #expect(denial.leg == .checked)
    #expect(denial.status == OSStatus(errAEEventWouldRequireUserConsent))
    // The prompting leg blocks until a person answers the dialog, so an agent's call must not reach
    // it: exactly one determination, and it did not ask for consent.
    #expect(authorizer.requests == [false])
    #expect(denial.message.contains("choose Browser Automation..."))
}

@Test func aDeniedGrantRefusesAtTheCheckedLegWithSettingsGuidance() throws {
    let authorizer = AppleEventAuthorizerStub(results: [OSStatus(errAEEventNotPermitted)])
    let browser = browserAutomation(authorizer: authorizer)

    let denial = try automationDenial { _ = try browser.windows(app: "Safari") }

    #expect(denial.authorization == .denied)
    #expect(denial.leg == .checked)
    #expect(denial.origin == .browserVerb)
    #expect(denial.answeredEarlierInThisProcess == false)
    #expect(denial.message.contains("System Settings > Privacy & Security > Automation"))
    // A verb's refusal is the one surface for which the menu gesture is a step the user has not
    // taken yet, so it is the one surface that keeps naming it.
    #expect(denial.message.contains("choose Browser Automation..."))
    #expect(authorizer.requests == [false])
}

/// The loop a user walked on a build whose signature carried no Apple Events entitlement: the menu
/// gesture was refused without a prompt, and the refusal told them to use the menu gesture. Whatever
/// the gesture reports, the remediation can never be the gesture itself.
@Test func theConsentGestureNeverPrescribesTheConsentGesture() throws {
    // A denial already recorded in TCC: macOS answers at the silent leg and does not re-prompt.
    let recordedDenial = AppleEventAuthorizerStub(results: [OSStatus(errAEEventNotPermitted)])
    let denied = try automationDenial {
        try authorizationService(recordedDenial).requestConsent(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    }
    // A prompt that never appeared and recorded nothing, leaving the grant exactly as undetermined
    // as it was before the user asked.
    let suppressedPrompt = AppleEventAuthorizerStub(results: [
        OSStatus(errAEEventWouldRequireUserConsent),
        OSStatus(errAEEventWouldRequireUserConsent)
    ])
    let unresolved = try automationDenial {
        try authorizationService(suppressedPrompt).requestConsent(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    }

    for denial in [denied, unresolved] {
        #expect(denial.origin == .consentGesture)
        #expect(denial.message.contains("Browser Automation...") == false)
    }
    #expect(denied.authorization == .denied)
    #expect(denied.message.contains("If Axon is not listed there at all"))
    #expect(unresolved.authorization == .notDetermined)
    #expect(unresolved.leg == .prompted)
    #expect(unresolved.message.contains("Quit Axon and open it again"))
}

/// The confounded 2026-08-14 trial, reproduced: two denials for the same target in one process with
/// no prompt in between. macOS can answer the second from what the process already holds, so a
/// `tccutil reset` between them changes nothing and the only remediation is restarting the daemon.
/// The stub recording `[false, false]` is the point — a flag that tracked prompt attempts would
/// have stayed silent through the exact sequence it exists to catch.
@Test func aSecondDenialInOneProcessNamesTheDaemonRestartRemediation() throws {
    let authorizer = AppleEventAuthorizerStub(results: [OSStatus(errAEEventNotPermitted), OSStatus(errAEEventNotPermitted)])
    let browser = browserAutomation(authorizer: authorizer)

    let first = try automationDenial { _ = try browser.windows(app: "Safari") }
    let second = try automationDenial { _ = try browser.windows(app: "Safari") }

    #expect(first.answeredEarlierInThisProcess == false)
    #expect(second.answeredEarlierInThisProcess)
    #expect(second.message.contains("launchctl kickstart -k gui/$(id -u)/dev.axon.daemon"))
    #expect(authorizer.requests == [false, false])
}

@Test func anUnexpectedStatusIsReportedAsAnUndeterminableAuthorization() {
    let authorizer = AppleEventAuthorizerStub(results: [-50])
    #expect(throws: BrowserAutomationError.authorizationFailed(app: "Safari", status: -50)) {
        try authorizationService(authorizer).check(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    }
}

/// A failed call is not macOS answering the authorization, so it must not make the next denial claim
/// this process is holding an answer it never received.
@Test func anUndeterminableStatusDoesNotCountAsAnAnswer() throws {
    let authorizer = AppleEventAuthorizerStub(results: [-50, OSStatus(errAEEventNotPermitted)])
    let browser = browserAutomation(authorizer: authorizer)

    #expect(throws: BrowserAutomationError.authorizationFailed(app: "Safari", status: -50)) {
        _ = try browser.windows(app: "Safari")
    }
    let denial = try automationDenial { _ = try browser.windows(app: "Safari") }

    #expect(denial.answeredEarlierInThisProcess == false)
}

@Test func consentPromptsOnlyForAnUndeterminedGrant() throws {
    let firstUse = AppleEventAuthorizerStub(results: [OSStatus(errAEEventWouldRequireUserConsent), noErr])
    try authorizationService(firstUse).requestConsent(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    #expect(firstUse.requests == [false, true])
    #expect(firstUse.bundleIdentifiers == ["com.apple.Safari", "com.apple.Safari"])

    let alreadyGranted = AppleEventAuthorizerStub(results: [noErr])
    try authorizationService(alreadyGranted).requestConsent(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    #expect(alreadyGranted.requests == [false])

    // macOS does not re-present the dialog for a recorded denial, so prompting would only repeat the
    // same answer.
    let recordedDenial = AppleEventAuthorizerStub(results: [OSStatus(errAEEventNotPermitted)])
    let denial = try automationDenial {
        try authorizationService(recordedDenial).requestConsent(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    }
    #expect(denial.leg == .checked)
    #expect(recordedDenial.requests == [false])
}

/// The normal path the UI directs users along: an agent verb refuses an undetermined grant, which
/// leaves an answer in the ledger, and the user then chooses Browser Automation and denies the
/// dialog. That denial is the answer they just gave, so it must not tell them to restart the daemon.
@Test func consentDeniedAfterAnAgentVerbAlreadyCheckedIsNotReportedAsStale() throws {
    let ledger = AppleEventAnswerLedger()
    let authorizer = AppleEventAuthorizerStub(results: [
        OSStatus(errAEEventWouldRequireUserConsent),
        OSStatus(errAEEventWouldRequireUserConsent),
        OSStatus(errAEEventNotPermitted)
    ])

    let refusal = try automationDenial {
        _ = try browserAutomation(authorizer: authorizer, ledger: ledger).windows(app: "Safari")
    }
    let denial = try automationDenial {
        try authorizationService(authorizer, ledger: ledger)
            .requestConsent(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    }

    #expect(refusal.leg == .checked)
    #expect(denial.leg == .prompted)
    #expect(denial.answeredEarlierInThisProcess == false)
    #expect(denial.message.contains("launchctl kickstart") == false)
    #expect(authorizer.requests == [false, false, true])
}

@Test func consentRefusedAtTheDialogReportsThePromptedLeg() throws {
    let authorizer = AppleEventAuthorizerStub(results: [OSStatus(errAEEventWouldRequireUserConsent), OSStatus(errAEEventNotPermitted)])

    let denial = try automationDenial {
        try authorizationService(authorizer).requestConsent(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    }

    #expect(denial.leg == .prompted)
    #expect(denial.authorization == .denied)
    #expect(authorizer.requests == [false, true])
    // The silent leg of this same request must not read as an earlier answer, or a fresh refusal
    // would tell the user to restart a daemon that just asked them the question.
    #expect(denial.answeredEarlierInThisProcess == false)
    #expect(denial.message.contains("launchctl kickstart") == false)
}

@Test func consentCoversEveryRunningBrowserAndReportsEachOutcome() {
    let authorizer = AppleEventAuthorizerStub(results: [OSStatus(errAEEventWouldRequireUserConsent), noErr, OSStatus(errAEEventNotPermitted)])
    let outcomes = BrowserAutomationConsentRequester(
        authorizer: authorizer,
        isRunning: { _ in true },
        ledger: AppleEventAnswerLedger(),
        log: { _ in }
    ).requestForRunningBrowsers()

    #expect(outcomes.map(\.bundleIdentifier) == ["com.apple.Safari", "com.google.Chrome"])
    #expect(outcomes.map(\.granted) == [true, false])
    #expect(outcomes[1].detail?.contains("Google Chrome") == true)
}

private func consentRequester(
    _ authorizer: AppleEventAuthorizerStub,
    ledger: AppleEventAnswerLedger = AppleEventAnswerLedger(),
    isRunning: @escaping (String) -> Bool = { _ in true }
) -> BrowserAutomationConsentRequester {
    BrowserAutomationConsentRequester(authorizer: authorizer, isRunning: isRunning, ledger: ledger, log: { _ in })
}

/// The ruling behind the item's presence: a consent gesture with nothing left to consent to is an
/// invitation to a dead end. Every state below is read without ever reaching the prompting leg,
/// because building a menu must not put a privacy dialog on someone's screen.
@Test func theConsentMenuItemDisappearsOnceEveryRunningBrowserIsAllowed() {
    let authorizer = AppleEventAuthorizerStub(results: [noErr, noErr])

    #expect(consentRequester(authorizer).outstandingConsent() == .none)
    #expect(authorizer.bundleIdentifiers == ["com.apple.Safari", "com.google.Chrome"])
    #expect(authorizer.requests == [false, false])
}

@Test func anUndeterminedGrantKeepsTheConsentMenuItemSoTheGrantCanStillBeMinted() {
    let authorizer = AppleEventAuthorizerStub(results: [noErr, OSStatus(errAEEventWouldRequireUserConsent)])

    #expect(consentRequester(authorizer).outstandingConsent() == .request)
    #expect(authorizer.requests == [false, false])
}

/// macOS will not present the dialog again over a standing denial, so this item exists to explain
/// rather than to ask. Hiding it would strand the user with a refusal that names System Settings and
/// no surface that says so.
@Test func aStandingDenialKeepsTheConsentMenuItemForTheExplanationItCarries() throws {
    let ledger = AppleEventAnswerLedger()
    let checked = AppleEventAuthorizerStub(results: [OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent)])

    #expect(consentRequester(checked, ledger: ledger).outstandingConsent() == .explain)
    #expect(checked.requests == [false, false])

    // Choosing the item that stayed: the gesture explains the denial without prescribing itself.
    let outcomes = consentRequester(
        AppleEventAuthorizerStub(results: [OSStatus(errAEEventNotPermitted), noErr]),
        ledger: ledger
    ).requestForRunningBrowsers()

    let refused = try #require(outcomes.first { !$0.granted })
    let detail = try #require(refused.detail)
    #expect(detail.contains("System Settings > Privacy & Security > Automation"))
    #expect(detail.contains("Browser Automation...") == false)
}

/// A determination is not free: it costs a TCC round trip, and it makes this process hold macOS's
/// answer for the rest of its life. The menu is rebuilt every time it opens, so presence is read
/// from the ledger once an answer is in it — the stub is out of results and would trap on a
/// redundant ask.
@Test func menuPresenceReadsTheLedgerRatherThanAskingMacOSAgain() {
    let ledger = AppleEventAnswerLedger()
    let authorizer = AppleEventAuthorizerStub(results: [noErr, OSStatus(errAEEventNotPermitted)])
    let requester = consentRequester(authorizer, ledger: ledger)

    #expect(requester.outstandingConsent() == .explain)
    #expect(requester.outstandingConsent() == .explain)
    #expect(authorizer.requests == [false, false])
}

/// macOS resolves a grant only for a running target, so a browser that is not running is not a
/// grant this gesture could mint — the same rule the request itself follows.
@Test func aBrowserThatIsNotRunningIsNotConsentTheMenuCanOffer() {
    let authorizer = AppleEventAuthorizerStub(results: [noErr])

    #expect(consentRequester(authorizer, isRunning: { $0 == "com.apple.Safari" }).outstandingConsent() == .none)
    #expect(authorizer.bundleIdentifiers == ["com.apple.Safari"])
}

/// An Apple event refused after the preflight passed is still macOS answering this process, so the
/// ledger takes that answer over the preflight's. Otherwise the refusal would name a menu item the
/// allowed preflight had already retired.
@Test func anEventRefusedAfterAPassingPreflightRestoresTheConsentMenuItem() {
    let ledger = AppleEventAnswerLedger()
    let settled = AppleEventAuthorizerStub(results: [noErr, noErr])
    #expect(consentRequester(settled, ledger: ledger).outstandingConsent() == .none)

    let refusal = browserAutomation(authorizer: AppleEventAuthorizerStub(results: []), ledger: ledger)
        .executedRefusal(browser: .safari, status: Int32(errAEEventNotPermitted))

    #expect(refusal.description.contains("choose Browser Automation..."))
    // Read back from the ledger alone: the stub holds no results and would trap on a fresh ask.
    let afterRefusal = AppleEventAuthorizerStub(results: [])
    #expect(consentRequester(afterRefusal, ledger: ledger).outstandingConsent() == .explain)
    #expect(afterRefusal.requests.isEmpty)
}

/// Following the restored item through to the click. The preflight that already answered wrongly
/// once will answer `noErr` again, so a gesture that simply re-determined would report the browser
/// as granted and retire the one surface carrying the remediation.
@Test func theGestureHonorsAnExecutedDenialThatAPassingPreflightWouldErase() throws {
    let ledger = AppleEventAnswerLedger()
    _ = browserAutomation(authorizer: AppleEventAuthorizerStub(results: []), ledger: ledger)
        .executedRefusal(browser: .safari, status: Int32(errAEEventNotPermitted))

    // Only Chrome reaches the authorizer: Safari is answered from the executed denial.
    let authorizer = AppleEventAuthorizerStub(results: [noErr])
    let outcomes = consentRequester(authorizer, ledger: ledger).requestForRunningBrowsers()

    let safari = try #require(outcomes.first { $0.app == "Safari" })
    let detail = try #require(safari.detail)
    #expect(safari.granted == false)
    #expect(detail.contains("System Settings > Privacy & Security > Automation"))
    #expect(detail.contains("Browser Automation...") == false)
    #expect(authorizer.bundleIdentifiers == ["com.google.Chrome"])
    // And the item the refusal points at survives the gesture.
    #expect(consentRequester(AppleEventAuthorizerStub(results: []), ledger: ledger).outstandingConsent() == .explain)
}

/// The same erasure by the other route: a browser verb's preflight, which passes for exactly the
/// same reason the event was refused anyway.
@Test func aPassingPreflightDoesNotRetireAnExecutedDenial() throws {
    let ledger = AppleEventAnswerLedger()
    _ = browserAutomation(authorizer: AppleEventAuthorizerStub(results: []), ledger: ledger)
        .executedRefusal(browser: .safari, status: Int32(errAEEventNotPermitted))

    try authorizationService(AppleEventAuthorizerStub(results: [noErr]), ledger: ledger)
        .check(bundleIdentifier: "com.apple.Safari", appName: "Safari")

    #expect(consentRequester(
        AppleEventAuthorizerStub(results: []),
        ledger: ledger,
        isRunning: { $0 == "com.apple.Safari" }
    ).outstandingConsent() == .explain)
}

/// A grant minted at the dialog retires the item on the spot: the prompted leg's answer is what the
/// ledger now holds, so the next menu build finds nothing left to consent to.
@Test func grantingConsentAtTheDialogRetiresTheMenuItem() throws {
    let ledger = AppleEventAnswerLedger()
    let authorizer = AppleEventAuthorizerStub(results: [
        OSStatus(errAEEventWouldRequireUserConsent), noErr,
        OSStatus(errAEEventWouldRequireUserConsent), noErr
    ])

    let outcomes = consentRequester(authorizer, ledger: ledger).requestForRunningBrowsers()

    #expect(outcomes.map(\.granted) == [true, true])
    #expect(consentRequester(authorizer, ledger: ledger).outstandingConsent() == .none)
    #expect(authorizer.requests == [false, true, false, true])
}

@Test func consentSkipsBrowsersThatAreNotRunning() {
    let authorizer = AppleEventAuthorizerStub(results: [noErr])
    let outcomes = BrowserAutomationConsentRequester(
        authorizer: authorizer,
        isRunning: { $0 == "com.apple.Safari" },
        ledger: AppleEventAnswerLedger(),
        log: { _ in }
    ).requestForRunningBrowsers()

    #expect(outcomes.map(\.app) == ["Safari"])
    #expect(authorizer.bundleIdentifiers == ["com.apple.Safari"])
}

@Test func everyAuthorizationDecisionIsLoggedWithItsLegAndStatus() throws {
    let collector = LogCollector()
    let authorizer = AppleEventAuthorizerStub(results: [OSStatus(errAEEventWouldRequireUserConsent), noErr])

    try authorizationService(authorizer, log: collector.append)
        .requestConsent(bundleIdentifier: "com.apple.Safari", appName: "Safari")

    #expect(collector.lines == [
        "automation authorization target=com.apple.Safari leg=checked status=-1744 answeredEarlierInThisProcess=false",
        "automation authorization target=com.apple.Safari leg=prompted status=0 answeredEarlierInThisProcess=false"
    ])
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

/// A browser answers with its own spelling of the address it was handed, so the verdict has to
/// compare addresses rather than strings. Everything below the fold is a different page, and stays
/// one.
@Test func navigationURLComparisonFoldsSpellingsOfTheSameAddress() {
    #expect(BrowserURL.equivalent("https://news.ycombinator.com", "https://news.ycombinator.com/"))
    #expect(BrowserURL.equivalent("HTTPS://News.YCombinator.com/", "https://news.ycombinator.com/"))
    #expect(BrowserURL.equivalent("https://example.com:443/docs", "https://example.com/docs"))
    #expect(BrowserURL.equivalent("http://example.com:80/", "http://example.com/"))
    #expect(BrowserURL.equivalent("https://example.com/?", "https://example.com/"))
    #expect(BrowserURL.equivalent("https://example.com/#", "https://example.com/"))

    #expect(BrowserURL.equivalent("https://example.com/docs", "https://example.com/docs/") == false)
    #expect(BrowserURL.equivalent("https://example.com", "https://www.example.com") == false)
    #expect(BrowserURL.equivalent("https://example.com", "http://example.com") == false)
    #expect(BrowserURL.equivalent("https://example.com/a?q=1", "https://example.com/a?q=2") == false)
    #expect(BrowserURL.equivalent("https://example.com/a#top", "https://example.com/a") == false)
}

/// The 2026-08-16 field report, with the intermediate states repeating the way real ones do: the
/// tab's URL updates the instant the browser accepts the event while the title still belongs to the
/// page being left, and the browser then publishes the address itself as a placeholder for several
/// polls before the real title arrives. Neither intermediate state may be mistaken for the outcome,
/// so a Safari-shaped reading (no loading flag) has to hold still for the whole stability window.
@Test func settlingOutlastsBothTheStaleTitleAndThePlaceholderThatFollowsIt() {
    let clock = SettleClock()
    let staleTitle = BrowserTabReading(url: "https://news.ycombinator.com/", title: "Why does Opus 5 feel worse to work with?")
    let placeholder = BrowserTabReading(url: "https://news.ycombinator.com/", title: "news.ycombinator.com")
    let loaded = BrowserTabReading(url: "https://news.ycombinator.com/", title: "Hacker News")
    // Five polls each at 60ms: 300ms apiece, well past two adjacent samples and still short of the
    // 480ms window, which is the whole point of measuring the window in time rather than in reads.
    let tab = ScriptedTab(readings: Array(repeating: staleTitle, count: 5)
        + Array(repeating: placeholder, count: 5)
        + [loaded])

    let outcome = settler(clock: clock).settle(
        requestedURL: "https://news.ycombinator.com",
        before: BrowserTabReading(url: "https://news.ycombinator.com/item?id=1", title: "Why does Opus 5 feel worse to work with?"),
        read: tab.read
    )

    #expect(outcome.reading == loaded)
    #expect(outcome.evidence == .stableReadback)
    #expect(outcome.elapsedMs >= BrowserNavigationSettler.defaultStableMs)
    #expect(navigationResult(requestedURL: "https://news.ycombinator.com", outcome).success)
}

/// The honest limit of inference, stated as a test rather than left to be discovered: with no
/// loading signal, a placeholder that outlasts the stability window is indistinguishable from a page
/// that has finished loading, and is believed. `settleEvidence` is what tells a caller which kind of
/// evidence they are holding — `stable_readback` is "nothing changed for long enough", not proof.
@Test func aPlaceholderThatOutlastsTheWindowIsBelievedAndSaysWhyItWasBelieved() {
    let clock = SettleClock()
    let placeholder = BrowserTabReading(url: "https://example.com/", title: "example.com")
    let tab = ScriptedTab(readings: [placeholder])

    let outcome = settler(clock: clock).settle(
        requestedURL: "https://example.com",
        before: BrowserTabReading(url: "https://start.example/", title: "Start"),
        read: tab.read
    )

    #expect(outcome.reading == placeholder)
    #expect(outcome.evidence == .stableReadback)
}

/// A redirect chain passes through addresses that are not the destination. A hop that holds for a
/// few polls must not be reported as where the navigation ended, or the caller learns about a URL
/// the tab has already left.
@Test func anIntermediateRedirectHopIsNotReportedAsTheDestination() {
    let clock = SettleClock()
    let hop = BrowserTabReading(url: "https://hop.example/redirect", title: "Redirecting")
    let destination = BrowserTabReading(url: "https://www.example.net/", title: "Elsewhere")
    let tab = ScriptedTab(readings: Array(repeating: hop, count: 6) + [destination])

    let outcome = settler(clock: clock).settle(
        requestedURL: "https://example.com",
        before: BrowserTabReading(url: "https://start.example/", title: "Start"),
        read: tab.read
    )
    let result = navigationResult(requestedURL: "https://example.com", outcome)

    #expect(outcome.reading == destination)
    #expect(result.url == "https://www.example.net/")
    // A settled address that is not the one requested is still a mismatch, reported with where the
    // tab actually landed.
    #expect(result.success == false)
    #expect(result.verification == .dictionaryMismatch)
    #expect(result.settled)
}

/// Chrome publishes `loading` on a tab, which is evidence rather than inference: the wait ends when
/// the browser says the load ended, without spending the stability window that exists only for
/// browsers offering nothing better.
@Test func aBrowsersOwnLoadingFlagEndsTheWaitWithoutTheStabilityWindow() {
    let clock = SettleClock()
    let loaded = BrowserTabReading(url: "https://example.com/", title: "Example", loading: false)
    let tab = ScriptedTab(readings: [
        BrowserTabReading(url: "https://example.com/", title: "example.com", loading: true),
        BrowserTabReading(url: "https://example.com/", title: "Example", loading: true),
        loaded
    ])

    let outcome = settler(clock: clock).settle(
        requestedURL: "https://example.com",
        before: BrowserTabReading(url: "https://start.example/", title: "Start", loading: false),
        read: tab.read
    )

    #expect(outcome.reading == loaded)
    #expect(outcome.evidence == .loadingFlag)
    #expect(outcome.elapsedMs < BrowserNavigationSettler.defaultStableMs)
}

/// A frozen read-back does not override the browser saying the load is still running: a title that
/// has not changed yet reads exactly like one that never will.
@Test func aTabThatKeepsSayingItIsLoadingIsNeverCalledSettled() {
    let clock = SettleClock()
    let tab = ScriptedTab(readings: [BrowserTabReading(url: "https://example.com/", title: "Example", loading: true)])

    let outcome = settler(clock: clock, timeoutMs: 1_000).settle(
        requestedURL: "https://example.com",
        before: BrowserTabReading(url: "https://start.example/", title: "Start", loading: false),
        read: tab.read
    )

    #expect(outcome.evidence == .bound)
    #expect(outcome.settled == false)
    #expect(navigationResult(requestedURL: "https://example.com", outcome).success)
}

/// Navigating to the address already open has no title change to wait for, so requiring one would
/// spend the whole bound on a navigation that was finished before it started.
@Test func settlingDoesNotWaitForATitleChangeThatCannotCome() {
    let clock = SettleClock()
    let reading = BrowserTabReading(url: "https://example.com/", title: "Example")
    let tab = ScriptedTab(readings: [reading])

    let outcome = settler(clock: clock).settle(requestedURL: "https://example.com", before: reading, read: tab.read)

    #expect(outcome.evidence == .stableReadback)
    #expect(outcome.elapsedMs < BrowserNavigationSettler.defaultStableMs * 2)
}

/// A page that never finishes loading must not spin the daemon: the bound expires, the last reading
/// is reported as the intermediate state it is, and the evidence says the bound is why.
@Test func aPageThatNeverSettlesIsReportedHonestlyAtTheBound() {
    let clock = SettleClock()
    let stale = BrowserTabReading(url: "https://start.example/", title: "Start")
    let tab = ScriptedTab(readings: [stale])

    let outcome = settler(clock: clock, timeoutMs: 1_000, intervalMs: 50).settle(
        requestedURL: "https://example.com",
        before: stale,
        read: tab.read
    )

    #expect(outcome.settled == false)
    #expect(outcome.evidence == .bound)
    #expect(outcome.reading == stale)
    #expect(outcome.elapsedMs >= 1_000)
    // Bounded, not unbounded: one read per interval and no more.
    #expect(tab.reads <= 22)
}

/// The whole sequence, without a browser: the outgoing page is captured by the same script that
/// starts the navigation, and every script after it only reads. A verdict taken from the dispatch
/// script's own reply is the race this exists to prevent, so the reply is a baseline and never an
/// answer.
@Test func navigateCapturesTheOutgoingPageInTheDispatchAndThenPollsForTheNewOne() throws {
    let clock = SettleClock()
    let outgoing = ["https://news.ycombinator.com/item?id=1", "Why does Opus 5 feel worse to work with?", "unknown"]
    let stale = ["https://news.ycombinator.com/", "Why does Opus 5 feel worse to work with?", "unknown"]
    let loaded = ["https://news.ycombinator.com/", "Hacker News", "unknown"]
    let scripts = ScriptedBrowser(replies: [outgoing] + Array(repeating: stale, count: 3) + [loaded])
    let browser = AppleScriptBrowserAutomation(
        authorizer: AppleEventAuthorizerStub(results: [noErr]),
        isRunning: { _ in true },
        ledger: AppleEventAnswerLedger(),
        log: { _ in },
        settler: settler(clock: clock),
        runNavigationScript: scripts.run
    )

    let result = try browser.navigate(app: "Safari", url: "https://news.ycombinator.com")

    #expect(result.success)
    #expect(result.verification == .dictionaryReadback)
    #expect(result.settled)
    #expect(result.settleEvidence == .stableReadback)
    #expect(result.title == "Hacker News")
    #expect(result.url == "https://news.ycombinator.com/")
    // Exactly one script navigates, and it is the first one.
    #expect(scripts.sources.filter { $0.contains("set URL of targetTab") } == [scripts.sources[0]])
    #expect(scripts.sources[0].contains("set previousName to name of targetTab"))
    #expect(scripts.sources.allSatisfy { $0.contains("current tab of front window") })
    // Safari's tab has no loading property, so its scripts must not ask for one.
    #expect(scripts.sources.allSatisfy { $0.contains("loading of targetTab") == false })
    #expect(scripts.sources.allSatisfy { $0.contains("set loadingState to \"unknown\"") })
}

/// Chrome does expose the flag, and it is read defensively: a build whose dictionary lacks it must
/// degrade to the stability window rather than fail the navigation.
@Test func chromeNavigationAsksTheTabWhetherItIsStillLoading() throws {
    let scripts = ScriptedBrowser(replies: [["https://start.example/", "Start", "false"], ["https://example.com/", "Example", "false"]])
    let browser = AppleScriptBrowserAutomation(
        authorizer: AppleEventAuthorizerStub(results: [noErr]),
        isRunning: { _ in true },
        ledger: AppleEventAnswerLedger(),
        log: { _ in },
        settler: settler(clock: SettleClock()),
        runNavigationScript: scripts.run
    )

    let result = try browser.navigate(app: "Chrome", url: "https://example.com")

    #expect(result.settleEvidence == .loadingFlag)
    #expect(result.title == "Example")
    #expect(scripts.sources.allSatisfy { $0.contains("active tab of front window") })
    #expect(scripts.sources.allSatisfy { $0.contains("if loading of targetTab then") })
    #expect(scripts.sources.allSatisfy { $0.contains("try") })
}

/// Replays scripted AppleScript replies and records the sources it was asked to run.
private final class ScriptedBrowser {
    private let replies: [[String]]
    private(set) var sources: [String] = []

    init(replies: [[String]]) { self.replies = replies }

    func run(_ source: String, _ appName: String) -> [String] {
        defer { sources.append(source) }
        return replies[min(sources.count, replies.count - 1)]
    }
}

/// The settler polls on the one thread that is serving the request, so this test clock is only ever
/// touched from there.
private final class SettleClock: @unchecked Sendable {
    private var current = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { current }
    func sleep(_ milliseconds: Int) { current = current.addingTimeInterval(Double(milliseconds) / 1_000) }
}

/// Replays scripted dictionary readings, holding on the last one the way a loaded page does.
private final class ScriptedTab {
    private let readings: [BrowserTabReading]
    private(set) var reads = 0

    init(readings: [BrowserTabReading]) { self.readings = readings }

    func read() -> BrowserTabReading {
        defer { reads += 1 }
        return readings[min(reads, readings.count - 1)]
    }
}

private func settler(
    clock: SettleClock,
    timeoutMs: Int = BrowserNavigationSettler.defaultTimeoutMs,
    intervalMs: Int = BrowserNavigationSettler.defaultIntervalMs,
    stableMs: Int = BrowserNavigationSettler.defaultStableMs
) -> BrowserNavigationSettler {
    BrowserNavigationSettler(
        timeoutMs: timeoutMs,
        intervalMs: intervalMs,
        stableMs: stableMs,
        now: clock.now,
        sleepMilliseconds: clock.sleep
    )
}

private func navigationResult(requestedURL: String, _ outcome: BrowserNavigationSettler.Outcome) -> BrowserNavigationResult {
    BrowserNavigationResult(
        app: "com.apple.Safari",
        requestedURL: requestedURL,
        url: outcome.reading.url,
        title: outcome.reading.title,
        settleEvidence: outcome.evidence,
        elapsedMs: outcome.elapsedMs
    )
}

/// The envelope reports the browser's own spelling of the address as the success it is, and carries
/// how the reading was obtained so a caller can tell a loaded page from one caught mid-load.
@Test func navigateReturnsVerifiedDictionaryReadback() {
    let browser = BrowserAutomationStub()
    browser.navigation = BrowserNavigationResult(
        app: "com.apple.Safari",
        requestedURL: "https://example.com",
        url: "https://example.com/",
        title: "Example",
        settleEvidence: .loadingFlag,
        elapsedMs: 120
    )
    let router = CommandRouter(browserAutomation: browser)

    let response = router.handle(JSONRPCRequest(id: .string("navigate"), method: "navigate", params: .object([
        "app": .string("Safari"), "url": .string("https://example.com")
    ])))

    #expect(response.error == nil)
    #expect(response.result?["navigation"]?["success"] == .bool(true))
    #expect(response.result?["navigation"]?["verification"] == .string("dictionary_readback"))
    #expect(response.result?["navigation"]?["url"] == .string("https://example.com/"))
    #expect(response.result?["navigation"]?["settled"] == .bool(true))
    #expect(response.result?["navigation"]?["settleEvidence"] == .string("loading_flag"))
    #expect(response.result?["navigation"]?["elapsedMs"] == .int(120))
    #expect(browser.navigationRequests.count == 1)
    #expect(browser.navigationRequests.first?.0 == "Safari")
    #expect(browser.navigationRequests.first?.1 == "https://example.com")
}

/// A tab still mid-load at the bound is reported as reached-but-unsettled rather than as a failure:
/// the address is the browser's answer to what it was asked to show, and the title is the part that
/// may still be catching up.
@Test func navigateReportsAnUnsettledPageWithoutCallingItAFailure() {
    let browser = BrowserAutomationStub()
    browser.navigation = BrowserNavigationResult(
        app: "com.apple.Safari",
        requestedURL: "https://news.ycombinator.com",
        url: "https://news.ycombinator.com/",
        title: "Why does Opus 5 feel worse to work with?",
        settleEvidence: .bound,
        elapsedMs: 4_000
    )

    let response = CommandRouter(browserAutomation: browser).handle(JSONRPCRequest(
        id: .string("navigate"), method: "navigate",
        params: .object(["app": .string("Safari"), "url": .string("https://news.ycombinator.com")])
    ))

    #expect(response.result?["navigation"]?["success"] == .bool(true))
    #expect(response.result?["navigation"]?["settled"] == .bool(false))
    #expect(response.result?["navigation"]?["settleEvidence"] == .string("bound"))
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

    browser.error = .automationNotGranted(BrowserAutomationDenial(app: "Safari", authorization: .denied, leg: .checked, status: -1743, origin: .browserVerb))
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
    #expect(denied.error?.data?["leg"] == .string("checked"))
}

@Test func automationDenialContractIsSharedByEveryBrowserVerbAndRoundTrips() throws {
    let browser = BrowserAutomationStub()
    browser.error = .automationNotGranted(BrowserAutomationDenial(app: "Google Chrome", authorization: .notDetermined, leg: .checked, status: -1744, origin: .browserVerb))
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
        #expect(response.error?.data?["app"] == .string("Google Chrome"))
        #expect(response.error?.data?["nativeStatus"] == .int(-1744))
        #expect(response.error?.data?["leg"] == .string("checked"))
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