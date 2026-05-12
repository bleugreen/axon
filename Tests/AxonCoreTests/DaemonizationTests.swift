import Foundation
import Testing
@testable import AxonCore

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
        result: ["snapshot": .object(["id": .string("snapshot-1")])]
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
                "includeScreenshot": .bool(false),
                "includeTree": .bool(false)
            ])
        )
    ])
    #expect(response?.result?["structuredContent"]?["snapshot"]?["id"] == .string("snapshot-1"))
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
    #expect(environment?["AXON_SOCKET_PATH"] == "/tmp/axon-test.sock")
    #expect(environment?["AXON_VISUAL_OVERLAY"] == "1")
    #expect(environment?["AXON_VISUAL_OVERLAY_RESULT_MS"] == "500")
    #expect(environment?["UNRELATED"] == nil)
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
