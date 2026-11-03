@testable import AxonClient
import Foundation
import Testing
@testable import AxonCore

@Test func mcpInitializeReturnsServerCapabilities() {
    let handler = MCPRecordingCommandHandler()
    let response = MCPRouter(commandHandler: handler).handle(JSONRPCRequest(
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
    #expect(handler.requests.isEmpty)
}

@Test func mcpToolsListUsesPlainOperationNames() {
    let handler = MCPRecordingCommandHandler()
    let response = MCPRouter(commandHandler: handler).handle(JSONRPCRequest(
        id: .string("tools"),
        method: "tools/list"
    ))

    let tools = response?.result?["tools"]
    #expect(response?.error == nil)
    #expect(toolNames(in: tools).contains("look"))
    #expect(toolNames(in: tools).contains("permit"))
    #expect(toolNames(in: tools).contains("look"))
    #expect(toolNames(in: tools).contains("look"))
    #expect(toolNames(in: tools).contains("run"))
    #expect(toolNames(in: tools).contains("save"))
    #expect(toolNames(in: tools).contains("wait_for_value"))
    #expect(toolNames(in: tools).contains("wait_for_stability"))
    #expect(!toolNames(in: tools).contains("run_plan"))
    #expect(toolNames(in: tools).contains("look"))
    #expect(toolNames(in: tools).contains("click"))
    #expect(toolNames(in: tools).contains("scroll"))
    #expect(toolNames(in: tools).contains("drag"))
    #expect(toolNames(in: tools).allSatisfy { !$0.contains("mcp") })
    #expect(tool(named: "look", in: tools)?["inputSchema"]?["properties"]?["screenshot"] != nil)
    #expect(tool(named: "look", in: tools)?["inputSchema"]?["properties"]?["screenText"] != nil)
    #expect(tool(named: "look", in: tools)?["inputSchema"]?["properties"]?["sensitive"] == nil)
    #expect(tool(named: "look", in: tools)?["inputSchema"]?["properties"]?["includeScreenshot"] == nil)
    #expect(tool(named: "run", in: tools)?["inputSchema"]?["properties"]?["argValues"] != nil)
    let clickTarget = tool(named: "click", in: tools)?["inputSchema"]?["properties"]?["target"]
    #expect(clickTarget?["anyOf"]?[2] != nil)
    #expect(clickTarget?["anyOf"]?[3]?["required"] == .array([.string("location")]))
    #expect(clickTarget?["anyOf"]?[3]?["properties"]?["location"]?["required"] == .array([.string("app"), .string("text")]))
    #expect(tool(named: "invoke", in: tools)?["inputSchema"]?["properties"]?["target"]?["anyOf"]?[2] == nil)
    #expect(tool(named: "type", in: tools)?["inputSchema"]?["properties"]?["target"]?["anyOf"]?[2] == nil)
    #expect(tool(named: "wait_for_value", in: tools)?["inputSchema"]?["required"] == .array([.string("target")]))
    #expect(tool(named: "wait_for_value", in: tools)?["inputSchema"]?["properties"]?["target"]?["anyOf"]?[0]?["type"] == .string("object"))
    #expect(tool(named: "wait_for_value", in: tools)?["inputSchema"]?["properties"]?["target"]?["anyOf"]?[0]?["additionalProperties"] == .bool(false))
    #expect(handler.requests.isEmpty)
}

@Test func mcpLookChildrenReturnsOnlyRequestedChildListObservation() {
    let handler = MCPRecordingCommandHandler(result: [
        "children": .object([
            "snapshot": .string("s12"),
            "parent": .string("s12:4"),
            "offset": .int(24),
            "limit": .int(2),
            "total": .int(30),
            "baseIndex": .int(42),
            "nextOffset": .int(26),
            "children": .array([
                .object([
                    "index": .int(42),
                    "handle": .string("s12:42"),
                    "role": .string("AXButton"),
                    "title": .string("Tab 25"),
                    "actions": .array([.string("AXPress")]),
                    "children": .array([])
                ])
            ])
        ])
    ])
    let response = MCPRouter(commandHandler: handler).handle(JSONRPCRequest(
        id: .string("children"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "target": .string("s12:4"),
                "offset": .int(24),
                "limit": .int(2)
            ])
        ])
    ))

    #expect(response?.error == nil)
    #expect(handler.requests == [
        JSONRPCRequest(
            id: .string("children"),
            method: "look",
            params: .object([
                "target": .string("s12:4"),
                "offset": .int(24),
                "limit": .int(2)
            ])
        )
    ])
    #expect(response?.result?["structuredContent"]?["children"]?["format"] == .string("children"))
    #expect(response?.result?["structuredContent"]?["children"]?["parent"] == .string("s12:4"))
    #expect(response?.result?["structuredContent"]?["children"]?["tree"] == .string("s12:42: button \"Tab 25\" [click]"))
    #expect(textContent(in: response?.result)?.contains("children:") == true)
    #expect(textContent(in: response?.result)?.contains("s12:42: button \"Tab 25\" [click]") == true)
}

@Test func mcpLookWithoutATargetCompactsTheDaemonAppList() {
    let handler = MCPRecordingCommandHandler(result: [
        "apps": .array([
            AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7).wireFixture,
            AppIdentity(bundleIdentifier: "com.example.Helper", name: "Example Helper", processIdentifier: 8).wireFixture,
            AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 9).wireFixture
        ])
    ])
    let response = MCPRouter(commandHandler: handler).handle(JSONRPCRequest(
        id: .string("call"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([:])
        ])
    ))

    #expect(handler.requests == [JSONRPCRequest(id: .string("call"), method: "look", params: .object([:]))])
    #expect(response?.error == nil)
    #expect(response?.result?["isError"] == .bool(false))
    #expect(response?.result?["structuredContent"]?["apps"]?["format"] == .string("app_list"))
    #expect(response?.result?["structuredContent"]?["apps"]?["count"] == .int(3))
    #expect(response?.result?["structuredContent"]?["apps"]?["uniqueCount"] == .int(2))
    #expect(response?.result?["structuredContent"]?["apps"]?["apps"]?[0]?["name"] == .string("Example"))
    #expect(response?.result?["structuredContent"]?["apps"]?["apps"]?[0]?["count"] == .int(2))
    #expect(response?.result?["content"]?[0]?["type"] == .string("text"))
    #expect(textContent(in: response?.result)?.contains("apps: 3 running, 2 names") == true)
    #expect(textContent(in: response?.result)?.contains("- Example (2)") == true)
    #expect(textContent(in: response?.result)?.contains("bundleIdentifier") == false)
}

@Test func mcpLookAllReturnsTheDaemonAppListUncompacted() {
    let handler = MCPRecordingCommandHandler(result: [
        "apps": .array([
            AppIdentity(bundleIdentifier: "com.example.Editor", name: "Editor", processIdentifier: 7).wireFixture,
            AppIdentity(bundleIdentifier: "com.example.Helper", name: "Editor Helper", processIdentifier: 8).wireFixture
        ])
    ])
    let response = MCPRouter(commandHandler: handler).handle(JSONRPCRequest(
        id: .string("all-apps"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object(["all": .bool(true)])
        ])
    ))

    #expect(handler.requests.first?.params == .object(["all": .bool(true)]))
    #expect(response?.result?["structuredContent"]?["apps"]?[1]?["name"] == JSONValue.string("Editor Helper"))
    #expect(textContent(in: response?.result)?.contains("bundleIdentifier") == true)
}

@Test func mcpLookAppsDebugReturnsFullAppObjects() {
    let handler = MCPRecordingCommandHandler(result: [
        "apps": .array([
            AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7).wireFixture
        ])
    ])
    let response = MCPRouter(commandHandler: handler).handle(JSONRPCRequest(
        id: .string("call"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object(["format": .string("debug")])
        ])
    ))

    #expect(response?.error == nil)
    #expect(response?.result?["structuredContent"]?["apps"]?[0]?["name"] == .string("Example"))
    #expect(response?.result?["structuredContent"]?["apps"]?[0]?["bundleIdentifier"] == .string("com.example.App"))
    #expect(textContent(in: response?.result)?.contains("bundleIdentifier") == true)
}

@Test func mcpRunForwardsActionsAndDryRun() {
    let handler = MCPRecordingCommandHandler(result: [
        "batch": .object([
            "success": .bool(true),
            "dryRun": .bool(true),
            "trace": .array([])
        ])
    ])
    let router = MCPRouter(commandHandler: handler)
    let response = router.handle(JSONRPCRequest(
        id: .string("batch"),
        method: "tools/call",
        params: .object([
            "name": .string("run"),
            "arguments": .object([
                "actions": .array([
                    .object([
                        "tool": .string("click"),
                        "target": .object(["app": .string("Example"), "name": .string("primary-button")])
                    ])
                ]),
                "argValues": .object([
                    "recipient": .string("mitch@example.com")
                ]),
                "dryRun": .bool(true),
                "continueOnError": .bool(true)
            ])
        ])
    ))

    #expect(response?.error == nil)
    #expect(handler.requests == [
        JSONRPCRequest(
            id: .string("batch"),
            method: "run",
            params: .object([
                "actions": .array([
                    .object([
                        "tool": .string("click"),
                        "target": .object(["app": .string("Example"), "name": .string("primary-button")])
                    ])
                ]),
                "argValues": .object([
                    "recipient": .string("mitch@example.com")
                ]),
                "dryRun": .bool(true),
                "continueOnError": .bool(true)
            ])
        )
    ])
    #expect(response?.result?["structuredContent"]?["batch"]?["success"] == .bool(true))
}

@Test func mcpSaveForwardsSessionRangeAndPath() {
    let handler = MCPRecordingCommandHandler(result: [
        "script": .string("version: 1\nactions: []\n"),
        "path": .string("/tmp/example.axn"),
        "actionCount": .int(0),
        "recordCount": .int(3)
    ])
    let router = MCPRouter(commandHandler: handler)
    let response = router.handle(JSONRPCRequest(
        id: .string("export"),
        method: "tools/call",
        params: .object([
            "name": .string("save"),
            "arguments": .object([
                "sessionId": .string("thread-a"),
                "from": .string("c1"),
                "to": .string("c3"),
                "path": .string("/tmp/example.axn"),
                "includeReads": .bool(true)
            ])
        ])
    ))

    #expect(response?.error == nil)
    #expect(handler.requests == [
        JSONRPCRequest(
            id: .string("export"),
            method: "save",
            params: .object([
                "sessionId": .string("thread-a"),
                "from": .string("c1"),
                "to": .string("c3"),
                "path": .string("/tmp/example.axn"),
                "includeReads": .bool(true)
            ])
        )
    ])
    #expect(response?.result?["structuredContent"]?["script"] == .string("version: 1\nactions: []\n"))
}

@Test func mcpToolsCallReportsCommandErrorsAsToolErrors() {
    let handler = MCPRecordingCommandHandler { request in
        JSONRPCResponse(id: request.id, error: .invalidParams("click requires target"))
    }
    let response = MCPRouter(commandHandler: handler).handle(JSONRPCRequest(
        id: .string("call-error"),
        method: "tools/call",
        params: .object([
            "name": .string("click"),
            "arguments": .object([:])
        ])
    ))

    #expect(handler.requests.map(\.method) == ["click"])
    #expect(response?.error == nil)
    #expect(response?.result?["isError"] == .bool(true))
    #expect(response?.result?["structuredContent"]?["error"]?["code"] == .int(-32602))
    #expect(response?.result?["structuredContent"]?["error"]?["message"] == .string("click requires target"))
}

@Test func mcpLookDefaultsToCompactStateWithScreenshotCapture() {
    let snapshot = AppSnapshot(
        id: SnapshotID("mcp-compact"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXButton", title: "Run", actions: ["AXPress"]),
                    AXNode(role: "AXStaticText", title: "Ready")
                ]),
                AXNode(role: "AXButton", title: "Hidden Tab", frame: AXFrame(x: -5000, y: 10, width: 80, height: 30), actions: ["AXPress"])
            ])
        ],
        screenshot: nil
    )
    let handler = MCPRecordingCommandHandler(result: ["snapshot": snapshot.wireFixture])

    let response = MCPRouter(commandHandler: handler).handle(JSONRPCRequest(
        id: .string("compact-state"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object(["app": .string("com.example.App")])
        ])
    ))

    let observation = response?.result?["structuredContent"]
    let text = textContent(in: response?.result)
    #expect(handler.requests.first?.params == .object([
        "app": .string("com.example.App"),
        "screenshot": .bool(true),
        "tree": .bool(true)
    ]))
    #expect(response?.error == nil)
    #expect(observation?["format"] == .string("observation"))
    #expect(observation?["snapshot"] == .string("mcp-compact"))
    #expect(observation?["tree"]?.stringValue?.contains("mcp-compact:2: button \"Run\" [click]") == true)
    #expect(observation?["indexedNodes"] == nil)
    #expect(observation?["windows"] == nil)
    #expect(observation?["screenshot"] == nil)
    #expect(text?.contains("\"snapshot\":\"mcp-compact\"") == true)
    #expect(text?.contains("mcp-compact:2: button \\\"Run\\\" [click]") == true)
    #expect(text?.contains("\"format\":\"observation\"") == true)
    #expect(text?.contains("\"windows\"") == false)
    #expect(text?.contains("Hidden Tab") == false)
}

@Test func mcpLookDebugAsksForNoTreeAndReturnsTheDaemonSnapshotUnformatted() {
    let snapshot = AppSnapshot(
        id: SnapshotID("mcp-depth"),
        app: AppIdentity(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Firefox", children: [
                AXNode(role: "AXTabGroup", title: "Browser tabs", children: [
                    AXNode(role: "AXRadioButton", title: "Tab 1", actions: ["AXPress"]),
                    AXNode(role: "AXRadioButton", title: "Tab 2", actions: ["AXPress"]),
                    AXNode(role: "AXRadioButton", title: "Tab 3", actions: ["AXPress"])
                ]),
                AXNode(role: "AXToolbar", description: "Navigation", children: [
                    AXNode(role: "AXButton", title: "Reload", actions: ["AXPress"])
                ])
            ])
        ],
        screenshot: nil
    )
    let handler = MCPRecordingCommandHandler(result: ["snapshot": snapshot.wireFixture])

    let response = MCPRouter(commandHandler: handler).handle(JSONRPCRequest(
        id: .string("depth"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "app": .string("org.mozilla.firefox"),
                "depth": .int(1),
                "format": .string("debug")
            ])
        ])
    ))

    let toolbar = response?.result?["structuredContent"]?["snapshot"]?["windows"]?[0]?["children"]?[1]
    let text = textContent(in: response?.result)

    // Debug output is the daemon's own document, so the facade neither asks for the compact tree
    // nor rewrites what comes back.
    #expect(handler.requests.first?.params == .object([
        "app": .string("org.mozilla.firefox"),
        "depth": .int(1),
        "format": .string("debug"),
        "screenshot": .bool(true),
        "tree": .bool(false)
    ]))
    #expect(response?.error == nil)
    #expect(toolbar?["handle"] == .string("mcp-depth:5"))
    #expect(toolbar?["children"]?[0]?["handle"] == .string("mcp-depth:6"))
    #expect(text?.contains("mcp-depth:5") == true)
    #expect(text?.contains("mcp-depth:6") == true)
}

@Test func mcpScreenshotUsesImageContentInsteadOfTextualBase64() {
    let snapshot = AppSnapshot(
        id: SnapshotID("screenshot-only"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [AXNode(role: "AXWindow", title: "Main")],
        screenshot: EncodedScreenshot(
            mediaType: "image/png",
            base64Data: "raw-image-payload",
            width: 1600,
            height: 990
        )
    )
    let handler = MCPRecordingCommandHandler(result: ["snapshot": snapshot.wireFixture])
    let response = MCPRouter(commandHandler: handler).handle(JSONRPCRequest(
        id: .string("shot"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "app": .string("com.example.App"),
                "screenshot": .bool(true),
                "tree": .bool(false)
            ])
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
    let snapshot = AppSnapshot(
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
    let handler = MCPRecordingCommandHandler(result: ["snapshot": snapshot.wireFixture])
    let response = MCPRouter(commandHandler: handler).handle(JSONRPCRequest(
        id: .string("state-shot"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "app": .string("com.example.App"),
                "screenshot": .bool(true)
            ])
        ])
    ))

    let result = response?.result
    let screenshot = result?["structuredContent"]?["screenshot"]
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
    let response = MCPRouter(commandHandler: MCPRecordingCommandHandler()).handle(JSONRPCRequest(
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

private func tool(named expectedName: String, in value: JSONValue?) -> JSONValue? {
    guard case let .array(tools) = value else {
        return nil
    }
    return tools.first { tool in
        tool["name"] == .string(expectedName)
    }
}

private extension JSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }
}

/// Stands in for the daemon behind the facade: records what the facade forwarded and answers with
/// a fixed result or whatever `respond` builds.
private final class MCPRecordingCommandHandler: JSONRPCCommandHandling {
    private let respond: (JSONRPCRequest) -> JSONRPCResponse
    private(set) var requests: [JSONRPCRequest] = []

    init(result: [String: JSONValue] = [:]) {
        self.respond = { JSONRPCResponse(id: $0.id, result: result) }
    }

    init(respond: @escaping (JSONRPCRequest) -> JSONRPCResponse) {
        self.respond = respond
    }

    func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        requests.append(request)
        return respond(request)
    }
}
