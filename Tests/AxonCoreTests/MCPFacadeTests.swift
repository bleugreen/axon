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
    #expect(toolNames(in: tools).contains("request_accessibility"))
    #expect(toolNames(in: tools).contains("get_app_state"))
    #expect(toolNames(in: tools).contains("changed_since"))
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

@Test func mcpGetAppStateDefaultsToCompactStateWithoutScreenshot() {
    let commandRouter = CommandRouter(
        captureSnapshot: { app, includeScreenshot in
            #expect(app == "com.example.App")
            #expect(includeScreenshot == false)
            return AppSnapshot(
                id: SnapshotID("mcp-compact"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [
                    AXNode(role: "AXWindow", title: "Main", children: [
                        AXNode(role: "AXButton", title: "Run", actions: ["AXPress"])
                    ])
                ],
                screenshot: nil
            )
        }
    )

    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("compact-state"),
        method: "tools/call",
        params: .object([
            "name": .string("get_app_state"),
            "arguments": .object(["app": .string("com.example.App")])
        ])
    ))

    let snapshot = response?.result?["structuredContent"]?["snapshot"]
    #expect(response?.error == nil)
    #expect(snapshot?["windows"] == nil)
    #expect(snapshot?["indexedNodes"]?[1]?["title"] == .string("Run"))
    #expect(snapshot?["indexedNodes"]?[1]?["actions"]?[0] == .string("AXPress"))
}

@Test func mcpScreenshotUsesImageContentInsteadOfTextualBase64() {
    let commandRouter = CommandRouter(
        captureScreenshot: { app in
            #expect(app == "com.example.App")
            return EncodedScreenshot(
                mediaType: "image/png",
                base64Data: "raw-image-payload",
                width: 1600,
                height: 990
            )
        }
    )
    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("shot"),
        method: "tools/call",
        params: .object([
            "name": .string("get_screenshot"),
            "arguments": .object(["app": .string("com.example.App")])
        ])
    ))

    let result = response?.result
    let screenshot = result?["structuredContent"]?["screenshot"]
    let text = textContent(in: result)
    let image = imageContent(in: result)

    #expect(response?.error == nil)
    #expect(screenshot?["mediaType"] == .string("image/png"))
    #expect(screenshot?["width"] == .int(1600))
    #expect(screenshot?["height"] == .int(990))
    #expect(screenshot?["contentTransport"] == .string("mcp_image"))
    #expect(screenshot?["base64Data"] == nil)
    #expect(text?.contains("base64Data") == false)
    #expect(text?.contains("raw-image-payload") == false)
    #expect(image?["type"] == .string("image"))
    #expect(image?["mimeType"] == .string("image/png"))
    #expect(image?["data"] == .string("raw-image-payload"))
}

@Test func mcpAppStateScreenshotUsesImageContentInsteadOfStructuredBase64() {
    let commandRouter = CommandRouter(
        captureSnapshot: { app, includeScreenshot in
            #expect(app == "com.example.App")
            #expect(includeScreenshot == true)
            return AppSnapshot(
                id: SnapshotID("with-image"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [AXNode(role: "AXWindow", title: "Main")],
                screenshot: EncodedScreenshot(
                    mediaType: "image/png",
                    base64Data: "nested-image-payload",
                    width: 1200,
                    height: 800
                )
            )
        }
    )
    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("state-shot"),
        method: "tools/call",
        params: .object([
            "name": .string("get_app_state"),
            "arguments": .object([
                "app": .string("com.example.App"),
                "includeScreenshot": .bool(true)
            ])
        ])
    ))

    let result = response?.result
    let screenshot = result?["structuredContent"]?["snapshot"]?["screenshot"]
    let text = textContent(in: result)
    let image = imageContent(in: result)

    #expect(response?.error == nil)
    #expect(screenshot?["mediaType"] == .string("image/png"))
    #expect(screenshot?["width"] == .int(1200))
    #expect(screenshot?["height"] == .int(800))
    #expect(screenshot?["contentTransport"] == .string("mcp_image"))
    #expect(screenshot?["base64Data"] == nil)
    #expect(text?.contains("base64Data") == false)
    #expect(text?.contains("nested-image-payload") == false)
    #expect(image?["type"] == .string("image"))
    #expect(image?["mimeType"] == .string("image/png"))
    #expect(image?["data"] == .string("nested-image-payload"))
}

@Test func mcpNotificationDoesNotProduceResponse() {
    let response = MCPRouter(commandRouter: CommandRouter()).handle(JSONRPCRequest(
        id: nil,
        method: "notifications/initialized"
    ))

    #expect(response == nil)
}

private func textContent(in result: [String: JSONValue]?) -> String? {
    guard case let .string(text)? = result?["content"]?[0]?["text"] else {
        return nil
    }
    return text
}

private func imageContent(in result: [String: JSONValue]?) -> JSONValue? {
    guard case let .array(content)? = result?["content"] else {
        return nil
    }
    return content.first { item in
        item["type"] == .string("image")
    }
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
