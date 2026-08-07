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
                "screenshot": .bool(false),
                "tree": .bool(true)
            ])
        )
    ])
    #expect(response?.result?["structuredContent"]?["snapshot"]?["format"] == .string("observation"))
    #expect(response?.result?["structuredContent"]?["snapshot"]?["snapshot"] == .string("snapshot-1"))
}

@Test func launchAgentConfigurationBuildsDaemonPlist() throws {
    let configuration = LaunchAgentConfiguration(
        label: "dev.axon.test",
        executablePath: "/Users/mitch/projects/axon/.build/debug/axon",
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
            executablePath: "/Applications/Axon.app/Contents/Resources/bin/axon",
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
        path: "/Applications/Axon.app/Contents/Resources/bin/axon"
    ))
}

@Test func restartKeepsTheInstalledRegistrationRatherThanRepointingIt() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-restart-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let plistPath = root.appendingPathComponent("dev.axon.test.plist")

    let installed = "/Applications/Axon.app/Contents/Resources/bin/axon"
    try LaunchAgentManager(
        configuration: LaunchAgentConfiguration(
            label: "dev.axon.test",
            executablePath: installed,
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
            executablePath: "/tmp/build-slot/.build/debug/axon",
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
            executablePath: "/tmp/build-slot/.build/debug/axon",
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
        for: "/Applications/Axon.app/Contents/Resources/bin/axon"
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
        executablePath: "/tmp/axon",
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

private func socketPair() throws -> (reader: Int32, writer: Int32) {
    var descriptors = [Int32](repeating: 0, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw SocketError.operationFailed("socketpair")
    }
    return (descriptors[0], descriptors[1])
}
