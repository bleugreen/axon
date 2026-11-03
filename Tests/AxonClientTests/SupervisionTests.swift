@testable import AxonClient
import Foundation
import Testing

/// A `launchctl` that remembers which labels are loaded, so the order of a transaction and the
/// state it leaves are both checkable. `failBootstrap` names labels whose bootstrap fails.
private final class FakeLaunchd: @unchecked Sendable {
    var loaded: [String: Int] = [:]
    var calls: [String] = []
    var failBootstrap: Set<String> = []
    private var nextPid = 500

    func run(_ arguments: [String]) -> ProcessResult {
        let verb = arguments[0]
        let label: String
        if verb == "bootstrap" {
            label = URL(fileURLWithPath: arguments[2]).deletingPathExtension().lastPathComponent
        } else {
            label = String(arguments.last!.split(separator: "/").last!)
        }
        if verb != "print" {
            calls.append("\(verb) \(label)")
        }
        switch verb {
        case "bootstrap":
            if failBootstrap.contains(label) || loaded[label] != nil {
                return ProcessResult(exitCode: 5, error: "Bootstrap failed: 5: Input/output error")
            }
            nextPid += 1
            loaded[label] = nextPid
            return ProcessResult(exitCode: 0)
        case "bootout":
            guard loaded.removeValue(forKey: label) != nil else {
                return ProcessResult(exitCode: 3, error: "Boot-out failed: 3: No such process")
            }
            return ProcessResult(exitCode: 0)
        case "print":
            guard let pid = loaded[label] else {
                return ProcessResult(exitCode: 113, error: "Could not find service \"\(label)\" in domain")
            }
            return ProcessResult(exitCode: 0, output: "gui/501/\(label) = {\n\tstate = running\n\tpid = \(pid)\n}\n")
        case "kickstart":
            return ProcessResult(exitCode: loaded[label] == nil ? 113 : 0)
        default:
            return ProcessResult(exitCode: 1)
        }
    }
}

private struct Fixture {
    let root: URL
    let agents: URL
    let bundle: URL
    let launchd = FakeLaunchd()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-supervision-\(UUID().uuidString)")
        agents = root.appendingPathComponent("LaunchAgents")
        bundle = root.appendingPathComponent("0.4.0/Axon.app")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        for executable in [mainExecutable, menuExecutable] {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: executable).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: executable, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
    }

    var mainExecutable: String { bundle.appendingPathComponent("Contents/MacOS/Axon").path }
    var menuExecutable: String {
        bundle.appendingPathComponent("Contents/Library/Applications/Axon Menu.app/Contents/MacOS/AxonMenu").path
    }
    var daemonPlist: URL { agents.appendingPathComponent("dev.axon.daemon.plist") }
    var menuPlist: URL { agents.appendingPathComponent("dev.axon.menu.plist") }

    func bundled() -> Supervision {
        let launchd = launchd
        return Supervision.bundled(
            program: DaemonProgram(executablePath: mainExecutable, identity: .appBundle(identifier: "com.bleugreen.axon")),
            bundlePath: bundle.path,
            socketPath: "/tmp/axon-test.sock",
            environment: [:],
            launchAgentsDirectory: agents,
            runProcess: { launchd.run($0) }
        )
    }

    func registered() -> Supervision {
        let launchd = launchd
        return Supervision.registered(socketPath: "/tmp/axon-test.sock", launchAgentsDirectory: agents, runProcess: { launchd.run($0) })
    }

    /// A registration as 0.3.x wrote it: the daemon job alone, pointing at another versioned path.
    func writeSingleJobRegistration(program: String = "/Users/dev/.local/lib/axon/0.3.6/Axon-0.3.6/Axon.app/Contents/MacOS/Axon") throws {
        let plist: [String: Any] = [
            "Label": "dev.axon.daemon",
            "ProgramArguments": [program],
            "EnvironmentVariables": ["AXON_SOCKET_PATH": "/tmp/axon.sock", "AXON_DAEMON_MANAGED_BY_LAUNCHD": "1"]
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: daemonPlist)
    }

    func program(in plist: URL) -> String? {
        LaunchAgentManager.registration(atPlistPath: plist).path
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private let readyReport = DaemonReport(
    version: "0.4.0",
    ready: true,
    processId: 501,
    endpoint: "/tmp/axon-test.sock",
    session: SessionHealth(interactive: true, graphical: true),
    permissions: [],
    capabilities: []
)

@Test func aFirstInstallWritesBothJobsAndStartsTheMenuOnlyAfterTheDaemonIsReady() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    var readyChecks: [Bool] = []

    try fixture.bundled().install(waitUntilReady: {
        readyChecks.append(fixture.launchd.loaded["dev.axon.menu"] == nil)
        return readyReport
    })

    #expect(fixture.program(in: fixture.daemonPlist) == fixture.mainExecutable)
    #expect(fixture.program(in: fixture.menuPlist) == fixture.menuExecutable)
    #expect(fixture.launchd.calls == [
        "bootout dev.axon.menu", "bootout dev.axon.daemon",
        "bootstrap dev.axon.daemon", "bootstrap dev.axon.menu"
    ])
    // Health was waited on while the menu was still out.
    #expect(readyChecks == [true])
    #expect(Set(fixture.launchd.loaded.keys) == ["dev.axon.daemon", "dev.axon.menu"])
}

@Test func installOverASingleJobRegistrationAddsTheMenuAndRepointsTheDaemon() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.writeSingleJobRegistration()
    fixture.launchd.loaded["dev.axon.daemon"] = 42

    try fixture.bundled().install(waitUntilReady: { readyReport })

    #expect(fixture.program(in: fixture.daemonPlist) == fixture.mainExecutable)
    #expect(fixture.program(in: fixture.menuPlist) == fixture.menuExecutable)
    #expect(fixture.launchd.loaded["dev.axon.daemon"] != 42)
    #expect(fixture.launchd.loaded["dev.axon.menu"] != nil)
}

@Test func aMenuThatFailsToStartRollsBackToThePreviousRegistration() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.writeSingleJobRegistration()
    let before = try Data(contentsOf: fixture.daemonPlist)
    fixture.launchd.loaded["dev.axon.daemon"] = 42
    fixture.launchd.failBootstrap = ["dev.axon.menu"]

    #expect {
        try fixture.bundled().install(waitUntilReady: { readyReport })
    } throws: { error in
        guard case let .installRolledBack(step, _, restoreFailures)? = error as? SupervisionError else { return false }
        return step == "start the menu" && restoreFailures.isEmpty
    }

    #expect(try Data(contentsOf: fixture.daemonPlist) == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.menuPlist.path))
    // The daemon that was loaded before is loaded again; the menu that was not is not.
    #expect(fixture.launchd.loaded["dev.axon.daemon"] != nil)
    #expect(fixture.launchd.loaded["dev.axon.menu"] == nil)
}

@Test func aDaemonThatNeverBecomesReadyRollsBackWithoutStartingTheMenu() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    #expect(throws: SupervisionError.self) {
        try fixture.bundled().install(waitUntilReady: { throw SupervisionError.incompleteBundle("timed out") })
    }
    #expect(!fixture.launchd.calls.contains("bootstrap dev.axon.menu"))
    #expect(!FileManager.default.fileExists(atPath: fixture.daemonPlist.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.menuPlist.path))
    #expect(fixture.launchd.loaded.isEmpty)
}

@Test func installRefusesABundleWithoutItsMenu() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try FileManager.default.removeItem(atPath: fixture.menuExecutable)

    #expect(throws: SupervisionError.self) {
        try fixture.bundled().install(waitUntilReady: { readyReport })
    }
    #expect(fixture.launchd.calls.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.daemonPlist.path))
}

@Test func restartBouncesBothJobsMenuFirstAndDaemonReadyBeforeTheMenu() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.bundled().install(waitUntilReady: { readyReport })
    fixture.launchd.calls = []

    try fixture.registered().restart(waitUntilReady: {
        #expect(fixture.launchd.loaded["dev.axon.menu"] == nil)
        return readyReport
    })

    #expect(fixture.launchd.calls == [
        "bootout dev.axon.menu", "bootout dev.axon.daemon",
        "bootstrap dev.axon.daemon", "bootstrap dev.axon.menu"
    ])
}

@Test func restartOfASingleJobRegistrationBouncesOnlyTheDaemonAndAddsNothing() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.writeSingleJobRegistration()
    fixture.launchd.loaded["dev.axon.daemon"] = 42

    try fixture.registered().restart(waitUntilReady: { readyReport })

    #expect(fixture.launchd.calls == ["bootout dev.axon.daemon", "bootstrap dev.axon.daemon"])
    #expect(!FileManager.default.fileExists(atPath: fixture.menuPlist.path))
}

@Test func restartWithNothingRegisteredRefuses() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    #expect(throws: LaunchAgentError.self) {
        try fixture.registered().restart(waitUntilReady: { readyReport })
    }
}

@Test func stopUnloadsMenuThenDaemonAndKeepsBothPlists() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.bundled().install(waitUntilReady: { readyReport })
    fixture.launchd.calls = []

    try fixture.registered().stop()

    #expect(fixture.launchd.calls == ["bootout dev.axon.menu", "bootout dev.axon.daemon"])
    #expect(fixture.launchd.loaded.isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.daemonPlist.path))
    #expect(FileManager.default.fileExists(atPath: fixture.menuPlist.path))
}

@Test func uninstallRemovesBothJobs() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.bundled().install(waitUntilReady: { readyReport })

    try fixture.registered().uninstall()

    #expect(fixture.launchd.loaded.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.daemonPlist.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.menuPlist.path))
}

@Test func statusReportsEachJobSeparately() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.writeSingleJobRegistration(program: fixture.mainExecutable)
    fixture.launchd.loaded["dev.axon.daemon"] = 77

    let states = fixture.registered().jobStates()

    #expect(states == [
        JobState(label: "dev.axon.daemon", loaded: true, processId: 77, path: fixture.mainExecutable),
        JobState(label: "dev.axon.menu", loaded: false, processId: nil, path: nil)
    ])
}

// MARK: - The start table

@Test func startInstallsWhenNothingIsRegistered() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    #expect(fixture.registered().startPlan(mainExecutable: fixture.mainExecutable) == .install)
}

@Test func startInstallsWhenThisCopyIsRegisteredWithoutItsMenu() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.writeSingleJobRegistration(program: fixture.mainExecutable)
    #expect(fixture.registered().startPlan(mainExecutable: fixture.mainExecutable) == .install)
}

@Test func startInstallsOverAStaleRegistrationOfThisCopy() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.bundled().install(waitUntilReady: { readyReport })
    // A plist without the launchd-managed key would send the main executable down the launcher
    // path instead of serving.
    let plist: [String: Any] = ["Label": "dev.axon.daemon", "ProgramArguments": [fixture.mainExecutable]]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: fixture.daemonPlist)
    #expect(fixture.registered().startPlan(mainExecutable: fixture.mainExecutable) == .install)
}

@Test func startInstallsWhenTheMenuIsRegisteredFromAnotherCopy() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.bundled().install(waitUntilReady: { readyReport })
    let plist: [String: Any] = [
        "Label": "dev.axon.menu",
        "ProgramArguments": ["/Applications/Other.app/Contents/Library/Applications/Axon Menu.app/Contents/MacOS/AxonMenu"]
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: fixture.menuPlist)
    #expect(fixture.bundled().startPlan(mainExecutable: fixture.mainExecutable) == .install)
}

@Test func aRestartWhoseDaemonNeverAnswersStillBringsTheMenuBack() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.bundled().install(waitUntilReady: { readyReport })

    #expect(throws: SupervisionError.self) {
        try fixture.registered().restart(waitUntilReady: { throw SupervisionError.incompleteBundle("timed out") })
    }
    #expect(fixture.launchd.loaded["dev.axon.menu"] != nil)
}

@Test func startResumesACompleteRegistrationAndBringsBackAQuitMenu() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.bundled().install(waitUntilReady: { readyReport })
    #expect(fixture.registered().startPlan(mainExecutable: fixture.mainExecutable) == .resume)

    // Both out, as after `axon shutdown`: the menu is registered but not running.
    fixture.launchd.loaded.removeValue(forKey: "dev.axon.daemon")
    fixture.launchd.loaded.removeValue(forKey: "dev.axon.menu")
    fixture.launchd.calls = []
    try fixture.bundled().resume()

    #expect(fixture.launchd.calls == ["bootstrap dev.axon.daemon", "bootstrap dev.axon.menu"])
}

@Test func startLeavesAnotherCopysRegistrationAloneAndStartsItsMenu() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let other = "/Applications/Axon.app/Contents/MacOS/Axon"
    try fixture.writeSingleJobRegistration(program: other)
    let before = try Data(contentsOf: fixture.daemonPlist)

    let supervision = fixture.registered()
    #expect(supervision.startPlan(mainExecutable: fixture.mainExecutable) == .elsewhere(registeredPath: other))
    try supervision.startRegisteredMenu()

    #expect(try Data(contentsOf: fixture.daemonPlist) == before)
    #expect(fixture.launchd.calls.isEmpty, "no menu plist, so nothing to start")
}

@Test func anUnbundledStartNeverInstalls() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    #expect(fixture.registered().startPlan(mainExecutable: nil) == .nothingRegistered)
    try fixture.writeSingleJobRegistration()
    #expect(fixture.registered().startPlan(mainExecutable: nil)
        == .elsewhere(registeredPath: "/Users/dev/.local/lib/axon/0.3.6/Axon-0.3.6/Axon.app/Contents/MacOS/Axon"))
}

@Test func aHealthReportMustComeFromTheRegisteredProgramWhenItSaysWhereItRuns() {
    var report = readyReport
    #expect(Supervision.report(report, isFrom: "/Applications/Axon.app/Contents/MacOS/Axon"), "no provenance, nothing to contradict")
    report.provenance = DaemonProvenance(backend: "rust-axon-mac", processId: 501, executablePath: "/tmp/other/Axon", version: "0.4.0")
    #expect(!Supervision.report(report, isFrom: "/Applications/Axon.app/Contents/MacOS/Axon"))
    #expect(Supervision.report(report, isFrom: "/tmp/other/Axon"))
}

@Test func aDaemonAnsweringFromOutsideLaunchdIsTheOneInstallMustStop() {
    #expect(Supervision.unsupervisedIncumbent(answering: nil, launchdPid: nil) == nil, "nothing answering")
    #expect(Supervision.unsupervisedIncumbent(answering: readyReport, launchdPid: 501) == nil, "launchd's own daemon")
    #expect(Supervision.unsupervisedIncumbent(answering: readyReport, launchdPid: nil) == readyReport, "opened, not registered")
    #expect(Supervision.unsupervisedIncumbent(answering: readyReport, launchdPid: 900) == readyReport, "a stray beside the job")
}

@Test func resumeLeavesARunningMenuAlone() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.bundled().install(waitUntilReady: { readyReport })
    fixture.launchd.calls = []

    try fixture.bundled().resume()

    #expect(fixture.launchd.calls.isEmpty)
}

// MARK: - Update finisher

@Test func aRunningUpdateFinisherIsNotReapedAndRetiresItsOwnPlist() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let plist = fixture.agents.appendingPathComponent("dev.axon.updater.plist")
    FileManager.default.createFile(atPath: plist.path, contents: Data())
    fixture.launchd.loaded["dev.axon.updater"] = 900
    let launchd = fixture.launchd

    LaunchAgentManager.reapUpdateFinisher(plistPath: plist, runProcess: { launchd.run($0) })
    #expect(launchd.loaded["dev.axon.updater"] == 900)
    #expect(FileManager.default.fileExists(atPath: plist.path))

    LaunchAgentManager.retireUpdateFinisher(ownedBy: 901, plistPath: plist, runProcess: { launchd.run($0) })
    #expect(FileManager.default.fileExists(atPath: plist.path), "another process is not the finisher")
    LaunchAgentManager.retireUpdateFinisher(ownedBy: 900, plistPath: plist, runProcess: { launchd.run($0) })
    #expect(!FileManager.default.fileExists(atPath: plist.path))
    #expect(launchd.loaded["dev.axon.updater"] == 900, "a job cannot boot itself out")
}

@Test func processIdentifierIsReadFromLaunchctlPrint() {
    #expect(LaunchAgentManager.processIdentifier(inPrintOutput: "gui/501/x = {\n\tactive count = 1\n\tpid = 4242\n") == 4242)
    #expect(LaunchAgentManager.processIdentifier(inPrintOutput: "gui/501/x = {\n\tstate = not running\n") == nil)
}

// MARK: - Editor-facing contract pieces

@Test func theDebuggerRefusalIsReadAsNotImplemented() {
    let refusal = JSONRPCError(
        code: -32004,
        message: "tool debug.create requires unavailable capability DebugSession",
        data: .object([
            "code": .string("capability-unavailable"),
            "tool": .string("debug.create"),
            "capability": .string("DebugSession"),
            "reason": .string("not-implemented")
        ])
    )
    #expect(DaemonRefusal(refusal) == .notImplemented(capability: DaemonRefusal.debugSessionCapability))
    let other = JSONRPCError(code: -32004, message: "x", data: .object(["code": .string("accessibility-denied")]))
    #expect(DaemonRefusal(other) == .accessibilityDenied)
    #expect(DaemonRefusal(JSONRPCError(code: -32602, message: "bad", data: nil)) == nil)
}

@Test func thePickerScopeEncodesAsTheRecordingWireShape() throws {
    let scopes = RecordingScope.pickerScopes(for: [
        AppIdentity(bundleIdentifier: "com.apple.calculator", name: "Calculator", processIdentifier: 1),
        AppIdentity(bundleIdentifier: "com.apple.calculator", name: "Calculator", processIdentifier: 2)
    ])
    #expect(scopes.count == 2)
    #expect(try scopes[0].jsonValue() == .object([
        "scope": .string("application"),
        "app": .object(["name": .string("Calculator"), "bundleIdentifier": .string("com.apple.calculator")])
    ]))
    #expect(try scopes[1].jsonValue() == .object(["scope": .string("allApplications")]))
}
