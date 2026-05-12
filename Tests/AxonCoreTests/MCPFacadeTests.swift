import Testing
@testable import AxonCore

@Test func mcpInitializeReturnsServerCapabilities() {
    let response = MCPRouter(commandRouter: CommandRouter()).handle(JSONRPCRequest(
        id: .int(1),
        method: "initialize",
        params: .object([
            "protocolVersion": .string("2025-11-25"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("test"), "version": .string("1")])
        ])
    ))

    #expect(response?.error == nil)
    #expect(response?.result?["protocolVersion"] == .string("2025-11-25"))
    #expect(response?.result?["capabilities"]?["tools"] != nil)
    #expect(response?.result?["serverInfo"]?["name"] == .string("axon"))
}

@Test func mcpToolsListUsesPlainOperationNames() {
    let response = MCPRouter(commandRouter: CommandRouter()).handle(JSONRPCRequest(
        id: .string("tools"),
        method: "tools/list"
    ))

    let tools = response?.result?["tools"]
    #expect(response?.error == nil)
    #expect(toolNames(in: tools).contains("list_apps"))
    #expect(toolNames(in: tools).contains("get_app_state"))
    #expect(toolNames(in: tools).contains("click"))
    #expect(toolNames(in: tools).allSatisfy { !$0.contains("mcp") })
}

@Test func mcpToolsCallReturnsStructuredContentFromCommandRouter() {
    let commandRouter = CommandRouter(
        listApps: {
            [AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7)]
        }
    )
    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("call"),
        method: "tools/call",
        params: .object([
            "name": .string("list_apps"),
            "arguments": .object([:])
        ])
    ))

    #expect(response?.error == nil)
    #expect(response?.result?["isError"] == .bool(false))
    #expect(response?.result?["structuredContent"]?["apps"]?[0]?["name"] == .string("Example"))
    #expect(response?.result?["content"]?[0]?["type"] == .string("text"))
}

@Test func mcpToolsCallReportsCommandErrorsAsToolErrors() {
    let response = MCPRouter(commandRouter: CommandRouter()).handle(JSONRPCRequest(
        id: .string("call-error"),
        method: "tools/call",
        params: .object([
            "name": .string("click"),
            "arguments": .object([:])
        ])
    ))

    #expect(response?.error == nil)
    #expect(response?.result?["isError"] == .bool(true))
    #expect(response?.result?["structuredContent"]?["error"]?["code"] == .int(-32602))
}

@Test func mcpNotificationDoesNotProduceResponse() {
    let response = MCPRouter(commandRouter: CommandRouter()).handle(JSONRPCRequest(
        id: nil,
        method: "notifications/initialized"
    ))

    #expect(response == nil)
}

private func toolNames(in value: JSONValue?) -> [String] {
    guard case let .array(tools) = value else {
        return []
    }
    return tools.compactMap { tool in
        guard case let .string(name) = tool["name"] else {
            return nil
        }
        return name
    }
}
