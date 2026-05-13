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
            "name": .string("get_app_state"),
            "arguments": .object(["app": .string("com.example.App")])
        ])
    ))

    #expect(response?.error == nil)
    #expect(handler.requests == [
        JSONRPCRequest(
            id: .string("state"),
            method: "snapshot",
            params: .object([
                "app": .string("com.example.App"),
                "screenshot": .bool(false),
                "includeTree": .bool(true),
                "sensitive": .bool(false)
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
            "AXON_VISUAL_OVERLAY_RESULT_MS": "500",
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
    #expect(environment?["AXON_VISUAL_OVERLAY_RESULT_MS"] == "500")
    #expect(environment?["UNRELATED"] == nil)
}

@Test func daemonBinaryInstallerCopiesAndSignsInstalledExecutable() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-daemon-installer-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source/axon")
    let bundleURL = root.appendingPathComponent("install/Axon Daemon.app")
    let installURL = bundleURL.appendingPathComponent("Contents/MacOS/axon")
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    try FileManager.default.createDirectory(
        at: source.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("binary".utf8).write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

    var codesignArguments: [[String]] = []
    let installer = DaemonBinaryInstaller(
        sourcePath: source.path,
        installURL: installURL,
        signingIdentifier: "dev.axon.test",
        runCodesign: { arguments in
            codesignArguments.append(arguments)
            return ProcessResult(exitCode: 0)
        },
        resolveSigningIdentity: { "ABCDEF123456" }
    )

    let installedURL = try installer.install()

    #expect(installedURL == installURL)
    #expect(try String(contentsOf: installURL, encoding: .utf8) == "binary")
    #expect(FileManager.default.isExecutableFile(atPath: installURL.path))
    let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")),
        options: [],
        format: nil
    ) as? [String: Any]
    #expect(plist?["CFBundleIdentifier"] as? String == "dev.axon.test")
    #expect(plist?["CFBundleExecutable"] as? String == "axon")
    #expect(plist?["LSBackgroundOnly"] as? Bool == true)
    #expect(codesignArguments == [[
        "--force",
        "--sign",
        "ABCDEF123456",
        bundleURL.path
    ]])
}

@Test func daemonBinaryInstallerFallsBackToAdHocSigningWhenNoIdentityExists() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-daemon-installer-adhoc-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source/axon")
    let bundleURL = root.appendingPathComponent("install/Axon Daemon.app")
    let installURL = bundleURL.appendingPathComponent("Contents/MacOS/axon")
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    try FileManager.default.createDirectory(
        at: source.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("binary".utf8).write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

    var codesignArguments: [[String]] = []
    let installer = DaemonBinaryInstaller(
        sourcePath: source.path,
        installURL: installURL,
        runCodesign: { arguments in
            codesignArguments.append(arguments)
            return ProcessResult(exitCode: 0)
        },
        resolveSigningIdentity: { nil }
    )

    try installer.install()

    #expect(codesignArguments == [[
        "--force",
        "--sign",
        DaemonBinaryInstaller.adHocSigningIdentity,
        bundleURL.path
    ]])
}

@Test func preferredSigningIdentityChoosesStableDeveloperCertificate() {
    let output = """
      1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Ad Hoc Something"
      2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Example (TEAMID)"
         2 valid identities found
    """

    #expect(DaemonBinaryInstaller.preferredSigningIdentity(fromSecurityFindIdentityOutput: output) == "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
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
