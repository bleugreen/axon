import Foundation
import Darwin
import Testing
@testable import AxonCore

@Test func socketLineReadTimesOutWhenPeerStalls() throws {
    let descriptors = try socketPair()
    defer {
        close(descriptors.reader)
        close(descriptors.writer)
    }

    do {
        _ = try readLineData(from: descriptors.reader, timeoutSeconds: 0.01, maxBytes: 1024)
        Issue.record("read should time out without a newline")
    } catch SocketError.readTimedOut {
        // Expected.
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func socketLineReadRejectsOversizedMessages() throws {
    let descriptors = try socketPair()
    defer {
        close(descriptors.reader)
        close(descriptors.writer)
    }
    try writeAll(Data("abcdef\n".utf8), to: descriptors.writer)

    do {
        _ = try readLineData(from: descriptors.reader, timeoutSeconds: 1.0, maxBytes: 3)
        Issue.record("read should reject oversized messages")
    } catch SocketError.messageTooLarge {
        // Expected.
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func socketLineReadReturnsDataBeforeNewline() throws {
    let descriptors = try socketPair()
    defer {
        close(descriptors.reader)
        close(descriptors.writer)
    }
    try writeAll(Data("hello\nignored".utf8), to: descriptors.writer)

    let data = try readLineData(from: descriptors.reader, timeoutSeconds: 1.0, maxBytes: 1024)

    #expect(String(decoding: data, as: UTF8.self) == "hello")
}

@Test func socketClientAllowsLongerDaemonResponsesThanRequestReads() {
    #expect(SocketClient.defaultResponseTimeoutSeconds > SocketServer.defaultClientReadTimeoutSeconds)
    #expect(SocketClient.defaultMaxResponseBytes > SocketServer.defaultMaxRequestBytes)
}

@Test func socketClientAllowsLongerBatchRunsThanSingleRequests() {
    #expect(SocketClient.defaultRunResponseTimeoutSeconds > SocketClient.defaultResponseTimeoutSeconds)
}

@Test func socketCommandRouterForwardsRequestsToSocketClient() throws {
    let request = JSONRPCRequest(id: .string("health"), method: "health")
    let router = SocketCommandRouter(path: "/tmp/axon-test.sock") { received in
        #expect(received == request)
        return JSONRPCResponse(id: received.id, result: ["status": .string("ok")])
    }

    let response = router.handle(request)

    #expect(response.error == nil)
    #expect(response.result?["status"] == .string("ok"))
}

@Test func socketCommandRouterReportsDaemonConnectionFailureAsJSONRPCError() {
    let router = SocketCommandRouter(path: "/tmp/missing-axon.sock") { _ in
        throw SocketError.connectionClosed
    }

    let response = router.handle(JSONRPCRequest(id: .int(1), method: "health"))

    #expect(response.error?.code == -32603)
    #expect(response.error?.message.contains("Axon daemon request failed at /tmp/missing-axon.sock") == true)
}

@Test func mcpToolsCallForwardsCommandRequestsToInjectedHandler() {
    let handler = RecordingCommandHandler(response: JSONRPCResponse(
        id: .string("state"),
        result: [
            "snapshot": .object([
                "id": .string("snapshot-1"),
                "app": .object([
                    "name": .string("Example"),
                    "pid": .int(123)
                ]),
                "windows": .array([
                    .object([
                        "handle": .string("snapshot-1:0"),
                        "role": .string("AXWindow"),
                        "title": .string("Main")
                    ])
                ])
            ])
        ]
    ))
    let router = MCPRouter(commandHandler: handler)

    let response = router.handle(JSONRPCRequest(
        id: .string("state"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object(["app": .string("com.example.App")])
        ])
    ))

    #expect(response?.error == nil)
    #expect(handler.requests == [
        JSONRPCRequest(
            id: .string("state"),
            method: "look",
            params: .object([
                "app": .string("com.example.App"),
                "screenshot": .bool(true),
                "tree": .bool(true)
            ])
        )
    ])
    #expect(response?.result?["structuredContent"]?["format"] == .string("observation"))
    #expect(response?.result?["structuredContent"]?["snapshot"] == .string("snapshot-1"))
}

/// Builds the shipped release layout: one `.app` holding the daemon app at `Contents/MacOS/Axon`
/// and the CLI that invokes `daemon install` at `Contents/Resources/bin/axon`.
///
/// Returns the CLI path, because that is what `daemon install` sees as its own executable and the
/// only input the registration decision gets.
@discardableResult
private func makeReleaseBundle(
    at bundleURL: URL,
    identifier: String? = "com.bleugreen.axon",
    executableName: String? = "Axon",
    createMainExecutable: Bool = true
) throws -> String {
    let fileManager = FileManager.default
    let macOS = bundleURL.appendingPathComponent("Contents/MacOS")
    let binDirectory = bundleURL.appendingPathComponent("Contents/Resources/bin")
    try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

    var info: [String: Any] = [:]
    info["CFBundleIdentifier"] = identifier
    info["CFBundleExecutable"] = executableName
    let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try infoData.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))

    if createMainExecutable, let executableName {
        fileManager.createFile(
            atPath: macOS.appendingPathComponent(executableName).path,
            contents: Data(),
            attributes: [.posixPermissions: 0o755]
        )
    }
    let cli = binDirectory.appendingPathComponent("axon").path
    fileManager.createFile(atPath: cli, contents: Data(), attributes: [.posixPermissions: 0o755])
    return cli
}

@Test func daemonInstallRegistersTheAppBundleRatherThanTheCLIBesideIt() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-bundle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Axon.app")
    let cli = try makeReleaseBundle(at: bundle)

    let program = DaemonProgram.resolved(invokedExecutable: cli)

    // macOS keys a privacy grant to the bundle only for the bundle's main executable. The CLI
    // lives in Resources, so registering it is what minted a new path-keyed Accessibility row on
    // every versioned upgrade.
    #expect(program.executablePath == bundle.appendingPathComponent("Contents/MacOS/Axon").path)
    #expect(program.identity == .appBundle(identifier: "com.bleugreen.axon"))
    // The app daemon serves the socket on its own; `serve` is a CLI verb and launchd launches the
    // app argument-less.
    #expect(program.arguments.isEmpty)
}

@Test func upgradingToANewVersionedPathKeepsTheSameTCCIdentity() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-upgrade-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = try makeReleaseBundle(at: root.appendingPathComponent("0.2.2/Axon.app"))
    let upgraded = try makeReleaseBundle(at: root.appendingPathComponent("0.3.1/Axon.app"))

    let before = DaemonProgram.resolved(invokedExecutable: installed)
    let after = DaemonProgram.resolved(invokedExecutable: upgraded)

    // This is the whole point of the change. The embedding contract puts every release at its own
    // path, so the registered executable necessarily moves; what must not move is who macOS thinks
    // is asking, because that is what decides whether a human has to revisit System Settings.
    #expect(before.executablePath != after.executablePath)
    #expect(before.identity == after.identity)
    #expect(after.identity == .appBundle(identifier: "com.bleugreen.axon"))
}

@Test func acceptRetriesAClientHangupRatherThanEndingTheDaemon() {
    // The registered daemon exits when accept throws, so this classification decides whether one
    // peer disappearing at the wrong moment takes the whole daemon down with it — and with it any
    // recording in progress. A signal and an aborted handshake are ordinary; a bad descriptor is
    // the server being done.
    #expect(SocketServer.isRetryableAcceptError(EINTR))
    #expect(SocketServer.isRetryableAcceptError(ECONNABORTED))
    #expect(!SocketServer.isRetryableAcceptError(EBADF))
    #expect(!SocketServer.isRetryableAcceptError(EINVAL))
    // Absent on purpose: the listener blocks, so EAGAIN would mean a state this loop cannot
    // interpret, and retrying it would spin.
    #expect(!SocketServer.isRetryableAcceptError(EAGAIN))
}

@Test func daemonInstallRefusesToAdoptABundleThatIsNotAxons() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-foreign-bundle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let consumer = root.appendingPathComponent("MyConsumerApp.app")
    let cli = try makeReleaseBundle(
        at: consumer,
        identifier: "com.example.myapp",
        executableName: "MyConsumerApp"
    )

    let program = DaemonProgram.resolved(invokedExecutable: cli)

    // The embedding contract invites a consumer to ship the CLI inside their own application, so
    // an enclosing `.app` is not evidence that the app is Axon. Adopting it would register their
    // program as the daemon: launched at every login by RunAtLoad, serving nothing, and restarted
    // by KeepAlive whenever the user quits it.
    #expect(program.executablePath == cli)
    #expect(program.identity == .executablePath)
    #expect(program.arguments == ["serve"])
}

@Test func enclosingBundleIsFoundEvenWithoutAReadableInfoPlist() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-plistless-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Axon.app")
    let binDirectory = bundle.appendingPathComponent("Contents/Resources/bin")
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    let cli = binDirectory.appendingPathComponent("axon").path
    FileManager.default.createFile(atPath: cli, contents: Data())

    let found = AppBundle.enclosing(cli)

    // `axon edit` finds the sibling editor app by walking to the enclosing bundle, and needs the
    // path even when the plist tells it nothing. Making this initializer failable would silently
    // send that lookup to its LaunchServices fallback instead.
    #expect(found?.path == bundle.path)
    #expect(found?.identifier == nil)
    #expect(found?.mainExecutablePath == nil)
    // Registration still declines it, because it cannot be shown to be Axon's own app.
    #expect(DaemonProgram.resolved(invokedExecutable: cli).identity == .executablePath)
}

@Test func daemonInstallRegistersAnUnbundledCLIAsItself() {
    // A dev build from `.build/` has no bundle to inherit from. Registering it as itself keeps
    // `daemon install` working there, with the path-keyed identity that implies.
    let program = DaemonProgram.resolved(invokedExecutable: "/Users/dev/axon/.build/debug/axon")

    #expect(program.executablePath == "/Users/dev/axon/.build/debug/axon")
    #expect(program.identity == .executablePath)
    #expect(program.arguments == ["serve"])
    #expect(program.identityDescription.contains("granted again"))
}

@Test func daemonInstallFallsBackToTheCLIWhenTheBundleNamesNoUsableExecutable() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-broken-bundle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = try makeReleaseBundle(
        at: root.appendingPathComponent("missing/Axon.app"),
        createMainExecutable: false
    )
    let unidentified = try makeReleaseBundle(
        at: root.appendingPathComponent("unidentified/Axon.app"),
        identifier: nil
    )

    // A registration that starts a daemon with a path-keyed identity beats one that starts
    // nothing, so a malformed bundle degrades to the old behavior rather than failing to install.
    #expect(DaemonProgram.resolved(invokedExecutable: missing)
        == DaemonProgram(executablePath: missing, identity: .executablePath))
    #expect(DaemonProgram.resolved(invokedExecutable: unidentified)
        == DaemonProgram(executablePath: unidentified, identity: .executablePath))
}

@Test func launchAgentPlistLaunchesTheAppDaemonWithoutArguments() throws {
    let configuration = LaunchAgentConfiguration(
        label: "dev.axon.test",
        program: DaemonProgram(
            executablePath: "/Applications/Axon.app/Contents/MacOS/Axon",
            identity: .appBundle(identifier: "com.bleugreen.axon")
        ),
        socketPath: "/tmp/axon-test.sock",
        environment: [:]
    )

    let plist = try PropertyListSerialization.propertyList(
        from: configuration.propertyListData(),
        options: [],
        format: nil
    ) as? [String: Any]

    #expect(plist?["ProgramArguments"] as? [String] == ["/Applications/Axon.app/Contents/MacOS/Axon"])
    // The app is a GUI process: it needs a login session, and the rest of the contract is unchanged
    // by which executable is registered.
    #expect(plist?["LimitLoadToSessionType"] as? String == "Aqua")
    let environment = plist?["EnvironmentVariables"] as? [String: String]
    #expect(environment?["AXON_SOCKET_PATH"] == "/tmp/axon-test.sock")
    // KeepAlive only restarts a process that exits, so the registered daemon has to be told it is
    // supervised. Without this the app absorbs a lost socket race and stays up answering nothing.
    #expect(environment?[AxonEnvironment.launchdManagedKey] == "1")
    #expect(AxonEnvironment.isLaunchdManaged(environment ?? [:]))
    #expect(!AxonEnvironment.isLaunchdManaged([:]))
}

@Test func updateRelaunchDefersToLaunchdWhenDaemonIsSupervised() {
    let managedEnvironment = [AxonEnvironment.launchdManagedKey: "1"]

    // KeepAlive replaces a managed daemon. Scheduling an independent app launch as well races that
    // replacement and leaves whichever process loses the socket lock alive as a broken menu item.
    #expect(!AxonEnvironment.requiresIndependentRelaunch(managedEnvironment))
    #expect(AxonEnvironment.requiresIndependentRelaunch([:]))
}

@Test func launchAgentConfigurationBuildsDaemonPlist() throws {
    let configuration = LaunchAgentConfiguration(
        label: "dev.axon.test",
        program: DaemonProgram(
            executablePath: "/Users/mitch/projects/axon/.build/debug/axon",
            identity: .executablePath
        ),
        socketPath: "/tmp/axon-test.sock",
        environment: [
            "AXON_VISUAL_OVERLAY": "1",
            "AXON_VISUAL_OVERLAY_DELAY_MS": "500",
            "AXON_VISUAL_OVERLAY_WAIT": "0",
            "UNRELATED": "ignored"
        ]
    )

    let plist = try PropertyListSerialization.propertyList(
        from: configuration.propertyListData(),
        options: [],
        format: nil
    ) as? [String: Any]
    let arguments = plist?["ProgramArguments"] as? [String]
    let environment = plist?["EnvironmentVariables"] as? [String: String]

    #expect(plist?["Label"] as? String == "dev.axon.test")
    #expect(arguments == ["/Users/mitch/projects/axon/.build/debug/axon", "serve"])
    #expect(plist?["RunAtLoad"] as? Bool == true)
    #expect(plist?["KeepAlive"] as? Bool == true)
    #expect(plist?["LimitLoadToSessionType"] as? String == "Aqua")
    #expect(plist?["ProcessType"] as? String == "Interactive")
    #expect(environment?["AXON_SOCKET_PATH"] == "/tmp/axon-test.sock")
    #expect(environment?["AXON_VISUAL_OVERLAY"] == "1")
    #expect(environment?["AXON_VISUAL_OVERLAY_DELAY_MS"] == "500")
    #expect(environment?["AXON_VISUAL_OVERLAY_WAIT"] == "0")
    #expect(environment?["UNRELATED"] == nil)
}

@Test func launchAgentRegistrationReportsTheInstalledExecutable() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-registration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let plistPath = root.appendingPathComponent("dev.axon.test.plist")
    let manager = LaunchAgentManager(
        configuration: LaunchAgentConfiguration(
            label: "dev.axon.test",
            program: DaemonProgram(
                executablePath: "/Applications/Axon.app/Contents/MacOS/Axon",
                identity: .appBundle(identifier: "com.bleugreen.axon")
            ),
            socketPath: "/tmp/axon-test.sock",
            environment: [:]
        ),
        plistPath: plistPath
    )

    #expect(manager.registration() == .absent(mechanism: .launchd))

    try manager.install()

    // The health document reports the path launchd will actually run, not the one this process
    // would have registered, so a stale registration is visible instead of assumed correct.
    #expect(manager.registration() == .present(
        mechanism: .launchd,
        path: "/Applications/Axon.app/Contents/MacOS/Axon"
    ))
}

@Test func restartKeepsTheInstalledRegistrationRatherThanRepointingIt() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-restart-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let plistPath = root.appendingPathComponent("dev.axon.test.plist")

    let installed = "/Applications/Axon.app/Contents/MacOS/Axon"
    try LaunchAgentManager(
        configuration: LaunchAgentConfiguration(
            label: "dev.axon.test",
            program: DaemonProgram(
                executablePath: installed,
                identity: .appBundle(identifier: "com.bleugreen.axon")
            ),
            socketPath: "/tmp/axon-test.sock",
            environment: [:]
        ),
        plistPath: plistPath
    ).install()

    // Restarting from an ephemeral build directory must not become an install of it. This is the
    // failure mode the whole permanent-path contract exists to prevent, reached by a verb that
    // was never meant to change registration at all.
    var commands: [[String]] = []
    let ephemeral = LaunchAgentManager(
        configuration: LaunchAgentConfiguration(
            label: "dev.axon.test",
            program: DaemonProgram(
                executablePath: "/tmp/build-slot/.build/debug/axon",
                identity: .executablePath
            ),
            socketPath: "/tmp/axon-test.sock",
            environment: [:]
        ),
        plistPath: plistPath,
        runProcess: { command in
            commands.append(command)
            return ProcessResult(exitCode: 0)
        }
    )

    try ephemeral.restart()

    #expect(ephemeral.registration() == .present(mechanism: .launchd, path: installed))
    #expect(commands.map(\.first) == ["bootout", "bootstrap"])
}

@Test func restartRefusesWhenNothingIsRegistered() {
    let plistPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-missing-\(UUID().uuidString).plist")
    let manager = LaunchAgentManager(
        configuration: LaunchAgentConfiguration(
            label: "dev.axon.test",
            program: DaemonProgram(
                executablePath: "/tmp/build-slot/.build/debug/axon",
                identity: .executablePath
            ),
            socketPath: "/tmp/axon-test.sock",
            environment: [:]
        ),
        plistPath: plistPath,
        runProcess: { _ in ProcessResult(exitCode: 0) }
    )

    // Restarting nothing is an operational failure that names the fix, not a silent install.
    #expect(throws: LaunchAgentError.self) {
        try manager.restart()
    }
}

@Test func buildDirectoryInstallPathsAreFlagged() {
    // The failure this guards against: installing from a build slot registers a path that
    // disappears, leaving a registration that can never start again.
    let warning = DaemonRegistrationPath.ephemeralWarning(
        for: "/Users/agent/.cairn/build-slots/AXN/slot-51/.build/debug/axon"
    )

    #expect(warning?.contains("permanent path") == true)
    #expect(DaemonRegistrationPath.ephemeralWarning(for: "/tmp/axon") != nil)
    #expect(DaemonRegistrationPath.ephemeralWarning(
        for: "/Applications/Axon.app/Contents/MacOS/Axon"
    ) == nil)
}

@Test func healthRequestAnswersWithTheDaemonReport() throws {
    let router = CommandRouter(services: CommandRouterServices(
        endpoint: "/tmp/axon-test.sock",
        daemonReport: { endpoint in
            Doctor.daemonReport(
                endpoint: endpoint,
                ready: true,
                processId: 4210,
                report: DoctorReport(
                    accessibility: PermissionReport(name: "Accessibility", status: .trusted),
                    screenRecording: PermissionReport(name: "Screen Recording", status: .denied)
                ),
                session: SessionHealth(interactive: true, graphical: true)
            )
        }
    ))

    let response = router.handle(JSONRPCRequest(id: .string("health"), method: "health"))
    let report = try DaemonReport(jsonObject: try #require(response.result))

    #expect(report.ready)
    #expect(report.processId == 4210)
    #expect(report.endpoint == "/tmp/axon-test.sock")
    #expect(report.version == AxonVersion.current)
    #expect(report.capabilities.count == AxonCapability.allCases.count)
    #expect(report.permissions.first { $0.name == HealthPermission.screenRecording }?.granted == false)
}

@Test func shutdownRequestIsAnsweredBeforeTheDaemonStops() {
    // The response has to reach the caller: a lifecycle command learns which process it stopped
    // from this reply, and cannot otherwise tell a clean stop from a crashed daemon.
    final class ShutdownSpy: @unchecked Sendable {
        var requested = false
    }
    let spy = ShutdownSpy()
    let router = CommandRouter(services: CommandRouterServices(requestShutdown: { spy.requested = true }))

    let response = router.handle(JSONRPCRequest(id: .string("shutdown"), method: "shutdown"))

    #expect(spy.requested)
    #expect(response.error == nil)
    #expect(response.result?["shutdown"] == .bool(true))
    #expect(response.result?["processId"] == .int(Int(ProcessInfo.processInfo.processIdentifier)))
}

@Test func launchAgentStartReloadsExistingServiceWhenBootstrapFails() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-launchagent-reload-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let plistPath = root.appendingPathComponent("dev.axon.test.plist")
    let configuration = LaunchAgentConfiguration(
        label: "dev.axon.test",
        program: DaemonProgram(executablePath: "/tmp/axon", identity: .executablePath),
        socketPath: "/tmp/axon.sock",
        environment: [:]
    )

    var commands: [[String]] = []
    let manager = LaunchAgentManager(
        configuration: configuration,
        plistPath: plistPath,
        runProcess: { command in
            commands.append(command)
            if commands.count == 1 {
                return ProcessResult(exitCode: 5, error: "Service is already loaded")
            }
            return ProcessResult(exitCode: 0)
        }
    )

    try manager.start()

    #expect(commands.count == 3)
    #expect(commands[0][0] == "bootstrap")
    #expect(commands[1][0] == "bootout")
    #expect(commands[2][0] == "bootstrap")
}

private final class RecordingCommandHandler: JSONRPCCommandHandling {
    private let response: JSONRPCResponse
    private(set) var requests: [JSONRPCRequest] = []

    init(response: JSONRPCResponse) {
        self.response = response
    }

    func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        requests.append(request)
        return response
    }
}

// MARK: - Socket ownership
//
// Exactly one server owns a socket path at a time, and the server enforces that itself rather than
// trusting a caller to check first. These tests pin the acquisition, refusal, and cleanup rules.

@Test func aSecondServerIsRefusedAndNamesTheProcessAlreadyServing() throws {
    let path = temporarySocketPath()
    defer { removeSocketArtifacts(at: path) }
    let incumbent = ServingThread(SocketServer(path: path, router: CommandRouter()))
    #expect(incumbent.waitUntilListening())

    // Waiting on a bounded finish rather than on a throw matters: a refused server returns right
    // away, while one that wrongly took the path would park in accept(). Asserting the throw
    // directly would turn that regression into a hang instead of a failure.
    let second = ServingThread(SocketServer(path: path, router: CommandRouter()))
    #expect(second.waitUntilFinished())
    guard case let .socketAlreadyServed(refusedPath, pid)? = second.failure as? SocketError else {
        Issue.record("expected an ownership refusal, got \(String(describing: second.failure))")
        return
    }
    #expect(refusedPath == path)
    #expect(pid == Int(getpid()))

    // The incumbent kept the endpoint rather than merely winning an argument about it.
    let response = try SocketClient(path: path, responseTimeoutSeconds: 5)
        .send(JSONRPCRequest(id: .string("health"), method: "health"))
    #expect(response.error == nil)
    #expect(incumbent.waitUntilFinished())
}

@Test func serversStartingTogetherProduceExactlyOneOwner() throws {
    let path = temporarySocketPath()
    defer { removeSocketArtifacts(at: path) }

    // The race this closes: asking whether anyone is serving and then binding is two steps, so
    // servers starting together all observe an empty path and all bind. Only the last one is
    // reachable, and the rest sit in accept() on sockets no client can arrive on.
    let servers = (0..<8).map { _ in ServingThread(SocketServer(path: path, router: CommandRouter())) }
    for server in servers {
        #expect(server.waitUntilSettled())
    }

    let owners = servers.filter(\.didListen)
    #expect(owners.count == 1)
    for loser in servers where !loser.didListen {
        #expect(loser.waitUntilFinished())
        guard case .socketAlreadyServed? = loser.failure as? SocketError else {
            Issue.record("expected an ownership refusal, got \(String(describing: loser.failure))")
            continue
        }
    }

    let response = try SocketClient(path: path, responseTimeoutSeconds: 5)
        .send(JSONRPCRequest(id: .string("health"), method: "health"))
    #expect(response.error == nil)
    #expect(owners.first?.waitUntilFinished() == true)
}

@Test func aSocketLeftBehindByADeadServerIsReclaimed() throws {
    let path = temporarySocketPath()
    defer { removeSocketArtifacts(at: path) }
    // What a crash leaves: the pathname still there, nothing serving it, no lock held.
    #expect(FileManager.default.createFile(atPath: path, contents: Data()))

    let server = ServingThread(SocketServer(path: path, router: CommandRouter()))
    #expect(server.waitUntilListening())

    let response = try SocketClient(path: path, responseTimeoutSeconds: 5)
        .send(JSONRPCRequest(id: .string("health"), method: "health"))
    #expect(response.error == nil)
    #expect(server.waitUntilFinished())
}

@Test func aServerThatPredatesLockOwnershipIsRefusedRatherThanReplaced() throws {
    let path = temporarySocketPath()
    defer { removeSocketArtifacts(at: path) }

    // An Axon older than lock-based ownership holds no lock at all, so on an upgrade in place the
    // lock alone would call its live socket debris and take the endpoint — the same silent
    // takeover, reappearing across a version boundary.
    let legacy = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(legacy >= 0)
    defer { close(legacy) }
    try withSocketAddress(path: path) { pointer, length in
        #expect(bind(legacy, pointer, length) == 0)
    }
    #expect(listen(legacy, 16) == 0)
    let legacyIdentity = fileIdentity(of: path)
    #expect(legacyIdentity != nil)

    let server = ServingThread(SocketServer(path: path, router: CommandRouter()))
    #expect(server.waitUntilFinished())
    guard case .socketAlreadyServed? = server.failure as? SocketError else {
        Issue.record("expected an ownership refusal, got \(String(describing: server.failure))")
        return
    }
    #expect(fileIdentity(of: path) == legacyIdentity)
}

@Test func theBoundSocketIsReachableOnlyByItsOwner() throws {
    let path = temporarySocketPath()
    defer { removeSocketArtifacts(at: path) }
    let server = ServingThread(SocketServer(path: path, router: CommandRouter()))
    #expect(server.waitUntilListening())

    // The socket's own mode is the access control, because it lives in a world-writable directory.
    var status = stat()
    #expect(lstat(path, &status) == 0)
    #expect(status.st_mode & 0o777 == 0o600)

    _ = try? SocketClient(path: path, responseTimeoutSeconds: 5)
        .send(JSONRPCRequest(id: .string("health"), method: "health"))
    #expect(server.waitUntilFinished())
}

@Test func aServerRemovesItsOwnSocketWhenItStops() throws {
    let path = temporarySocketPath()
    defer { removeSocketArtifacts(at: path) }
    let server = ServingThread(SocketServer(path: path, router: CommandRouter()))
    #expect(server.waitUntilListening())

    _ = try? SocketClient(path: path, responseTimeoutSeconds: 5)
        .send(JSONRPCRequest(id: .string("health"), method: "health"))
    #expect(server.waitUntilFinished())

    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func aStoppingServerLeavesASocketAnotherServerHasSinceBound() throws {
    let path = temporarySocketPath()
    defer { removeSocketArtifacts(at: path) }
    let first = ServingThread(SocketServer(path: path, router: CommandRouter()))
    #expect(first.waitUntilListening())

    // Connect before the swap, so the server still has a client to finish with once the pathname
    // no longer points at its socket. It then blocks reading a request, which is what makes the
    // rest of this deterministic rather than a race against its shutdown.
    let client = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(client >= 0)
    defer { close(client) }
    try withSocketAddress(path: path) { pointer, length in
        #expect(connect(client, pointer, length) == 0)
    }

    // Stand in for a successor that has since bound the same pathname. Unconditional cleanup on
    // the way out turns an orphan's late shutdown into the successor losing its socket to a
    // process that is already gone.
    unlink(path)
    #expect(FileManager.default.createFile(atPath: path, contents: Data()))
    let successor = fileIdentity(of: path)
    #expect(successor != nil)

    try writeAll(Data("{\"jsonrpc\":\"2.0\",\"id\":\"health\",\"method\":\"health\"}\n".utf8), to: client)
    #expect(first.waitUntilFinished())

    #expect(fileIdentity(of: path) == successor)
}

/// A socket path short enough for `sockaddr_un` and unique per test.
private func temporarySocketPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-own-\(UUID().uuidString.prefix(8)).sock").path
}

private func removeSocketArtifacts(at path: String) {
    unlink(path)
    unlink(SocketServer.lockPath(for: path))
}

/// A file's identity as the server sees it: device and inode, not name.
private func fileIdentity(of path: String) -> String? {
    var status = stat()
    guard lstat(path, &status) == 0 else {
        return nil
    }
    return "\(status.st_dev):\(status.st_ino)"
}

/// A server on its own thread, exposing the two edges a test needs: it settled, and how.
private final class ServingThread: @unchecked Sendable {
    enum Lifetime {
        case oneClient
        case untilStopped
    }

    private let settled = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    /// Whether the server reached the listening state. Safe to read once `waitUntilSettled()` has
    /// returned true, which is the happens-before edge that publishes it.
    private(set) var didListen = false
    /// Why the server stopped, published by `waitUntilFinished()` returning true.
    private(set) var failure: Error?

    init(_ server: SocketServer, lifetime: Lifetime = .oneClient) {
        let thread = Thread { [self] in
            do {
                switch lifetime {
                case .oneClient:
                    try server.runOnce { didListen = true; settled.signal() }
                case .untilStopped:
                    try server.run { didListen = true; settled.signal() }
                }
            } catch {
                failure = error
            }
            settled.signal()
            finished.signal()
        }
        thread.name = "axon-test-serving"
        thread.start()
    }

    /// Blocks until the server has either started listening or stopped trying.
    func waitUntilSettled(timeoutSeconds: Int = 10) -> Bool {
        settled.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success
    }

    func waitUntilListening(timeoutSeconds: Int = 10) -> Bool {
        waitUntilSettled(timeoutSeconds: timeoutSeconds) && didListen
    }

    func waitUntilFinished(timeoutSeconds: Int = 15) -> Bool {
        finished.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success
    }
}

private func socketPair() throws -> (reader: Int32, writer: Int32) {
    var descriptors = [Int32](repeating: 0, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw SocketError.failed("socketpair")
    }
    return (descriptors[0], descriptors[1])
}
