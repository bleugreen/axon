import AxonClient
@testable import AxonMenuApp
import Foundation
import Testing

private let bundle = "/Applications/Axon.app"

private func report(
    version: String = "0.4.0",
    contract: Int? = ShellContract.version,
    accessibility: Bool = true,
    executable: String = "\(bundle)/Contents/MacOS/Axon"
) -> DaemonReport {
    DaemonReport(
        version: version,
        ready: accessibility,
        processId: 4242,
        endpoint: "/tmp/axon.sock",
        provenance: DaemonProvenance(backend: "rust-axon-mac", processId: 4242, executablePath: executable, version: version),
        shellContract: contract,
        session: SessionHealth(interactive: true, graphical: true),
        permissions: [
            PermissionState(name: "accessibility", granted: accessibility, reason: accessibility ? nil : "accessibility-not-granted"),
            PermissionState(name: "screenRecording", granted: true)
        ],
        capabilities: []
    )
}

private func inputs(_ daemon: DaemonState, executable: String? = nil) -> MenuInputs {
    var inputs = MenuInputs(enclosingBundlePath: bundle, shellVersion: "0.4.0", socketPath: "/tmp/axon.sock")
    inputs.daemon = daemon
    if case let .answered(report, _) = daemon {
        inputs.daemonExecutablePath = executable ?? report.provenance?.executablePath
    }
    return inputs
}

private func titles(_ entries: [MenuEntry]) -> [String] {
    entries.compactMap {
        switch $0 {
        case let .label(title): return title
        case let .action(title, _, _, _): return title
        case .separator: return nil
        }
    }
}

private func action(_ entries: [MenuEntry], _ wanted: MenuAction) -> (title: String, enabled: Bool)? {
    for case let .action(title, action, enabled, _) in entries where action == wanted {
        return (title, enabled)
    }
    return nil
}

@Test func anAbsentDaemonDisablesEverythingButOpenUpdatesAndQuit() {
    let entries = MenuModel.entries(inputs(.notRunning(socketPath: "/tmp/axon.sock")))
    #expect(titles(entries).contains("Axon daemon not running (/tmp/axon.sock)"))
    #expect(action(entries, .record)?.enabled == false)
    #expect(action(entries, .openAxnFile)?.enabled == true)
    #expect(action(entries, .checkForUpdates)?.enabled == true)
    #expect(action(entries, .quit)?.title == "Quit Axon Menu")
    #expect(action(entries, .browserAutomation) == nil)
    #expect(action(entries, .requestAccessibility) == nil)
}

@Test func aPresentDaemonDrivesTheMenuAndRecoveryNeedsNoRestart() {
    var state = inputs(.notRunning(socketPath: "/tmp/axon.sock"))
    #expect(action(MenuModel.entries(state), .record)?.enabled == false)
    state = inputs(.answered(report(), stale: false))
    let entries = MenuModel.entries(state)
    #expect(titles(entries).contains("Daemon 0.4.0: ready"))
    #expect(action(entries, .record)?.enabled == true)
    #expect(action(entries, .browserAutomation) != nil, "unknown need offers the item")
}

@Test func aStaleAnswerSaysSoAndKeepsTheLastState() {
    let entries = MenuModel.entries(inputs(.answered(report(), stale: true)))
    #expect(titles(entries).contains("Daemon 0.4.0: ready (not answering; last known state)"))
}

@Test func aMissingOrDifferentContractIsIncompatible() {
    for contract in [nil, 2] as [Int?] {
        let state = inputs(.answered(report(contract: contract), stale: false))
        guard case .incompatible = MenuModel.standing(state) else {
            Issue.record("contract \(String(describing: contract)) must be incompatible")
            continue
        }
        let entries = MenuModel.entries(state)
        #expect(titles(entries).contains { $0.hasPrefix("Incompatible daemon at \(bundle)/Contents/MacOS/Axon") })
        #expect(action(entries, .record)?.enabled == false)
        #expect(action(entries, .openAxnFile)?.enabled == true)
    }
    let unreadable = inputs(.unreadable("keyNotFound"))
    #expect(MenuModel.standing(unreadable) == .incompatible(path: "/tmp/axon.sock", reason: "keyNotFound"))
}

@Test func versionSkewIsNamedButNotDisabling() {
    let entries = MenuModel.entries(inputs(.answered(report(version: "0.4.1"), stale: false)))
    #expect(titles(entries).contains("Daemon 0.4.1 differs from this menu (0.4.0)"))
    #expect(action(entries, .record)?.enabled == true)
}

@Test func aDaemonFromAnotherBundleIsAnIncumbent() {
    let other = report(executable: "/Users/me/Downloads/Axon.app/Contents/MacOS/Axon")
    let entries = MenuModel.entries(inputs(.answered(other, stale: false)))
    #expect(titles(entries) == [
        "Axon",
        "Axon 0.4.0 at /Users/me/Downloads/Axon.app/Contents/MacOS/Axon (pid 4242) is already serving",
        "Use This Copy",
        "Quit Axon Menu"
    ])
    // A sibling bundle whose path merely starts with this one's is still another bundle.
    let sibling = report(executable: "/Applications/Axon.app2/Contents/MacOS/Axon")
    guard case .incumbent = MenuModel.standing(inputs(.answered(sibling, stale: false))) else {
        Issue.record("a prefix match is not containment")
        return
    }
}

@Test func anUngrantedDaemonOffersPermit() {
    let entries = MenuModel.entries(inputs(.answered(report(accessibility: false), stale: false)))
    #expect(titles(entries).contains("Accessibility not granted"))
    #expect(action(entries, .requestAccessibility) != nil)
    #expect(action(MenuModel.entries(inputs(.answered(report(), stale: false))), .requestAccessibility) == nil)
}

@Test func theConsentItemFollowsTheDaemonsNeed() {
    var state = inputs(.answered(report(), stale: false))
    for (need, present) in [(ConsentNeed.none, false), (.request, true), (.explain, true)] {
        state.consentNeed = need
        #expect((action(MenuModel.entries(state), .browserAutomation) != nil) == present, "\(need)")
    }
}

@Test func anEditorStartedRecordingShowsAndStopsFromTheMenu() {
    var state = inputs(.answered(report(), stale: false))
    #expect(!MenuModel.isRecording(state))
    state.recording = RecordingStatus(
        recording: true,
        sessionId: "recording-0001",
        scope: .allApplications,
        destination: RecordingDestination(documentId: "doc", beforeBlockId: nil)
    )
    let entries = MenuModel.entries(state)
    #expect(MenuModel.isRecording(state))
    #expect(titles(entries).contains("Recording All Running Apps for the editor"))
    #expect(action(entries, .stopRecording) != nil)
    #expect(action(entries, .record) == nil)
    // The icon follows only a daemon the shell can drive.
    state.daemon = .notRunning(socketPath: "/tmp/axon.sock")
    #expect(!MenuModel.isRecording(state))
}

@Test func anUpdateInProgressSurvivesARecording() {
    var state = inputs(.answered(report(), stale: false))
    state.update = .downloading(version: "0.5.0", progress: 0.42)
    state.recording = RecordingStatus(recording: true, sessionId: "r", scope: .allApplications)
    let entries = titles(MenuModel.entries(state))
    #expect(entries.contains("Downloading 0.5.0... 42%"))
    #expect(entries.contains("Stop Recording..."))
    state.recording = .idle
    #expect(titles(MenuModel.entries(state)).contains("Downloading 0.5.0... 42%"))
}

@Test func thePickerListsEachApplicationOnceWithoutPids() {
    let scopes = RecordingScope.pickerScopes(for: [
        AppIdentity(bundleIdentifier: "com.apple.Safari", name: "Safari", processIdentifier: 10),
        AppIdentity(bundleIdentifier: "com.apple.Safari", name: "Safari", processIdentifier: 11),
        AppIdentity(bundleIdentifier: nil, name: "Tool", processIdentifier: 12)
    ])
    #expect(scopes == [
        .application(RecordingApp(name: "Safari", bundleIdentifier: "com.apple.Safari")),
        .application(RecordingApp(name: "Tool", bundleIdentifier: nil)),
        .allApplications
    ])
    #expect(scopes.map(\.displayName) == ["Safari", "Tool", "All Running Apps"])
}
