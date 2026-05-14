import Foundation
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
    #expect(toolNames(in: tools).contains("look"))
    #expect(toolNames(in: tools).contains("permit"))
    #expect(toolNames(in: tools).contains("look"))
    #expect(toolNames(in: tools).contains("look"))
    #expect(toolNames(in: tools).contains("run"))
    #expect(toolNames(in: tools).contains("save"))
    #expect(!toolNames(in: tools).contains("run_plan"))
    #expect(toolNames(in: tools).contains("look"))
    #expect(toolNames(in: tools).contains("click"))
    #expect(toolNames(in: tools).contains("scroll"))
    #expect(toolNames(in: tools).contains("drag"))
    #expect(toolNames(in: tools).allSatisfy { !$0.contains("mcp") })
    #expect(tool(named: "look", in: tools)?["inputSchema"]?["properties"]?["screenshot"] != nil)
    #expect(tool(named: "look", in: tools)?["inputSchema"]?["properties"]?["screenText"] != nil)
    #expect(tool(named: "look", in: tools)?["inputSchema"]?["properties"]?["sensitive"] != nil)
    #expect(tool(named: "look", in: tools)?["inputSchema"]?["properties"]?["includeScreenshot"] == nil)
    #expect(tool(named: "click", in: tools)?["inputSchema"]?["properties"]?["target"]?["anyOf"]?[2] != nil)
    #expect(tool(named: "click", in: tools)?["inputSchema"]?["properties"]?["target"]?["anyOf"]?[3] != nil)
    #expect(tool(named: "invoke", in: tools)?["inputSchema"]?["properties"]?["target"]?["anyOf"]?[2] == nil)
    #expect(tool(named: "type", in: tools)?["inputSchema"]?["properties"]?["target"]?["anyOf"]?[2] == nil)
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
    #expect(response?.result?["structuredContent"]?["children"]?["items"]?[0]?["handle"] == .string("s12:42"))
    #expect(response?.result?["structuredContent"]?["children"]?["tree"] == nil)
    #expect(textContent(in: response?.result)?.contains("children:") == true)
    #expect(textContent(in: response?.result)?.contains("s12:42 button \"Tab 25\"") == true)
}

@Test func mcpToolsCallReturnsStructuredContentFromCommandRouter() {
    let commandRouter = CommandRouter(
        listApps: {
            [
                AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                AppIdentity(bundleIdentifier: "com.example.Helper", name: "Example Helper", processIdentifier: 8),
                AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 9)
            ]
        }
    )
    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("call"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([:])
        ])
    ))

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

@Test func mcpLookAppsDebugReturnsFullAppObjects() {
    let commandRouter = CommandRouter(
        listApps: {
            [AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7)]
        }
    )
    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
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
                        "target": .string("s1:2")
                    ])
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
                        "target": .string("s1:2")
                    ])
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

@Test func mcpLookDefaultsToCompactStateWithoutScreenshot() {
    let commandRouter = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == false)
            return AppSnapshot(
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
        }
    )

    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("compact-state"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object(["target": .string("com.example.App")])
        ])
    ))

    let snapshot = response?.result?["structuredContent"]?["snapshot"]
    let text = textContent(in: response?.result)
    #expect(response?.error == nil)
    #expect(snapshot?["format"] == .string("observation"))
    #expect(snapshot?["snapshot"] == .string("mcp-compact"))
    #expect(snapshot?["tree"]?[0]?["handle"] == .string("mcp-compact:0"))
    #expect(snapshot?["tree"]?[0]?["children"]?[0]?["handle"] == .string("mcp-compact:2"))
    #expect(snapshot?["tree"]?[0]?["children"]?[0]?["role"] == .string("button"))
    #expect(snapshot?["tree"]?[0]?["children"]?[0]?["label"] == .string("Run"))
    #expect(snapshot?["tree"]?[0]?["children"]?[0]?["actions"]?[0] == .string("click"))
    #expect(snapshot?["indexedNodes"] == nil)
    #expect(snapshot?["windows"] == nil)
    #expect(text?.contains("snapshot: mcp-compact") == true)
    #expect(text?.contains("mcp-compact:2 button \"Run\"") == true)
    #expect(text?.contains("snapshot:") == true)
    #expect(text?.contains("snapshot:mcp-compact") == false)
    #expect(text?.contains("Hidden Tab") == false)
}

@Test func mcpLookScreenTextAddsOCRWithoutScreenshotPayload() {
    let commandRouter = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == true)
            return AppSnapshot(
                id: SnapshotID("mcp-ocr"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [
                    AXNode(
                        role: "AXWindow",
                        title: "Main",
                        frame: AXFrame(x: 100, y: 200, width: 800, height: 600)
                    )
                ],
                screenshot: EncodedScreenshot(
                    mediaType: "image/png",
                    base64Data: "internal-image-payload",
                    width: 800,
                    height: 600
                )
            )
        },
        recognizeText: { _ in
            [
                RecognizedTextObservation(
                    text: "Second line",
                    boundingBox: NormalizedTextBoundingBox(x: 0.20, y: 0.50, width: 0.20, height: 0.05),
                    confidence: 0.91
                ),
                RecognizedTextObservation(
                    text: "First line",
                    boundingBox: NormalizedTextBoundingBox(x: 0.10, y: 0.80, width: 0.20, height: 0.05),
                    confidence: 1
                )
            ]
        }
    )

    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("screen-text"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "target": .string("com.example.App"),
                "screenText": .bool(true)
            ])
        ])
    ))

    let result = response?.result
    let snapshot = result?["structuredContent"]?["snapshot"]
    let text = textContent(in: result)

    #expect(response?.error == nil)
    #expect(result?["isError"] == .bool(false))
    #expect(snapshot?["screenText"]?[0]?["text"] == .string("First line"))
    #expect(snapshot?["screenText"]?[0]?["confidence"] == .double(1))
    #expect(snapshot?["screenText"]?[0]?["frame"] == nil)
    #expect(snapshot?["screenText"]?[1]?["text"] == .string("Second line"))
    #expect(snapshot?["screenText"]?[1]?["confidence"] == .double(0.91))
    #expect(snapshot?["screenshot"] == nil)
    #expect(imageContent(in: result) == nil)
    #expect(text?.contains("screenText:") == true)
    #expect(text?.contains("- \"First line\"") == true)
    #expect(text?.contains("- \"First line\" confidence=1") == false)
    #expect(text?.contains("- \"Second line\" confidence=0.91") == true)
    #expect(text?.contains("internal-image-payload") == false)
}

@Test func mcpLookScreenTextCanIncludeFramesWhenRequested() {
    let commandRouter = CommandRouter(
        captureSnapshot: { _, screenshot in
            #expect(screenshot == true)
            return AppSnapshot(
                id: SnapshotID("mcp-ocr-frames"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [
                    AXNode(
                        role: "AXWindow",
                        title: "Main",
                        frame: AXFrame(x: 100, y: 200, width: 800, height: 600)
                    )
                ],
                screenshot: EncodedScreenshot(mediaType: "image/png", base64Data: "internal-image-payload", width: 800, height: 600)
            )
        },
        recognizeText: { _ in
            [
                RecognizedTextObservation(
                    text: "Framed text",
                    boundingBox: NormalizedTextBoundingBox(x: 0.25, y: 0.60, width: 0.20, height: 0.10),
                    confidence: nil
                )
            ]
        }
    )

    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("screen-text-frames"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "target": .string("com.example.App"),
                "screenText": .bool(true),
                "frames": .bool(true)
            ])
        ])
    ))

    let snapshot = response?.result?["structuredContent"]?["snapshot"]

    #expect(response?.error == nil)
    #expect(snapshot?["screenText"]?[0]?["text"] == .string("Framed text"))
    #expect(snapshot?["screenText"]?[0]?["frame"]?["x"] == .double(300))
    #expect(snapshot?["screenText"]?[0]?["frame"]?["y"] == .double(380))
    #expect(snapshot?["screenText"]?[0]?["frame"]?["width"] == .double(160))
    #expect(snapshot?["screenText"]?[0]?["frame"]?["height"] == .double(60))
}

@Test func mcpSensitiveAppStateDoesNotLeakSecretsInTextOrStructuredContent() throws {
    let secret = "sk-proj-abcdef1234567890SECRET"
    let commandRouter = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == false)
            return AppSnapshot(
                id: SnapshotID("mcp-sensitive"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [
                    AXNode(role: "AXWindow", title: "Main", children: [
                        AXNode(role: "AXTextField", value: secret)
                    ])
                ],
                screenshot: nil
            )
        }
    )

    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("sensitive-state"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "target": .string("com.example.App"),
                "sensitive": .bool(true)
            ])
        ])
    ))

    let result = response?.result
    let snapshot = result?["structuredContent"]?["snapshot"]
    let encoded = try encodedJSONString(.object(result ?? [:]))

    #expect(response?.error == nil)
    #expect(result?["isError"] == .bool(false))
    #expect(snapshot?["redaction"]?["sensitive"] == .bool(true))
    #expect(snapshot?["indexedNodes"] == nil)
    #expect(snapshot?["tree"]?[0]?["children"]?[0]?["label"] == .string("sk-proj-abcd...[redacted]"))
    #expect(textContent(in: result)?.contains("SECRET") == false)
    #expect(encoded.contains("SECRET") == false)
}

@Test func mcpLookRedactsActiveCredentialsWithoutSensitiveFlag() throws {
    let secret = "correct horse battery staple"
    let commandRouter = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == false)
            return AppSnapshot(
                id: SnapshotID("mcp-active"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [
                    AXNode(role: "AXWindow", title: "Main", children: [
                        AXNode(role: "AXTextField", value: secret)
                    ])
                ],
                screenshot: nil
            )
        },
        activeCredentialFilter: try mcpActiveCredentialFilter(values: [secret])
    )

    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("active-state"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "target": .string("com.example.App")
            ])
        ])
    ))

    let result = response?.result
    let snapshot = result?["structuredContent"]?["snapshot"]
    let encoded = try encodedJSONString(.object(result ?? [:]))

    #expect(response?.error == nil)
    #expect(result?["isError"] == .bool(false))
    #expect(snapshot?["tree"]?[0]?["children"]?[0]?["label"] == .string("<redacted: active-credential>"))
    #expect(snapshot?["tree"]?[0]?["children"]?[0]?["redaction"]?["references"]?["value"]?[0] == .string("op://MCP/Active/secret"))
    #expect(textContent(in: result)?.contains("redaction=op://MCP/Active/secret") == true)
    #expect(textContent(in: result)?.contains(secret) == false)
    #expect(encoded.contains(secret) == false)
    #expect(encoded.contains("<redacted: active-credential>"))
}

@Test func mcpLookScreenTextRedactsActiveCredentials() throws {
    let secret = "correct horse battery staple"
    let commandRouter = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == true)
            return AppSnapshot(
                id: SnapshotID("mcp-active-ocr"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [
                    AXNode(
                        role: "AXWindow",
                        title: "Main",
                        frame: AXFrame(x: 100, y: 200, width: 800, height: 600)
                    )
                ],
                screenshot: EncodedScreenshot(mediaType: "image/png", base64Data: "ocr-image-payload", width: 800, height: 600)
            )
        },
        recognizeText: { _ in
            [
                RecognizedTextObservation(
                    text: secret,
                    boundingBox: NormalizedTextBoundingBox(x: 0.10, y: 0.80, width: 0.20, height: 0.05),
                    confidence: 1
                )
            ]
        },
        activeCredentialFilter: try mcpActiveCredentialFilter(values: [secret])
    )

    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("active-screen-text"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "target": .string("com.example.App"),
                "screenText": .bool(true)
            ])
        ])
    ))

    let result = response?.result
    let snapshot = result?["structuredContent"]?["snapshot"]
    let encoded = try encodedJSONString(.object(result ?? [:]))

    #expect(response?.error == nil)
    #expect(snapshot?["screenText"]?[0]?["text"] == .string("<redacted: active-credential>"))
    #expect(textContent(in: result)?.contains(secret) == false)
    #expect(encoded.contains(secret) == false)
    #expect(imageContent(in: result) == nil)
}

@Test func mcpLookOmitsScreenshotWhenActiveCredentialIsDetected() throws {
    let secret = "correct horse battery staple"
    let commandRouter = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == true)
            return AppSnapshot(
                id: SnapshotID("mcp-active-screenshot"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [
                    AXNode(role: "AXWindow", title: "Main", children: [
                        AXNode(role: "AXTextField", title: "Password", value: secret)
                    ])
                ],
                screenshot: EncodedScreenshot(
                    mediaType: "image/png",
                    base64Data: "raw-image-payload",
                    width: 1200,
                    height: 800
                )
            )
        },
        activeCredentialFilter: try mcpActiveCredentialFilter(values: [secret])
    )

    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("active-shot"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "target": .string("com.example.App"),
                "screenshot": .bool(true)
            ])
        ])
    ))

    let result = response?.result
    let snapshot = result?["structuredContent"]?["snapshot"]
    let encoded = try encodedJSONString(.object(result ?? [:]))

    #expect(response?.error == nil)
    #expect(snapshot?["screenshot"] == nil)
    #expect(snapshot?["warnings"]?[0] == .string("screenshot omitted because active credential text was redacted"))
    #expect(imageContent(in: result) == nil)
    #expect(textContent(in: result)?.contains(secret) == false)
    #expect(encoded.contains(secret) == false)
    #expect(encoded.contains("raw-image-payload") == false)
}

@Test func mcpLookScreenshotOnlyRunsOCRGuardBeforeReturningImage() throws {
    let secret = "correct horse battery staple"
    let commandRouter = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == true)
            return AppSnapshot(
                id: SnapshotID("mcp-active-shot-ocr"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [
                    AXNode(
                        role: "AXWindow",
                        title: "Main",
                        frame: AXFrame(x: 100, y: 200, width: 1200, height: 800)
                    )
                ],
                screenshot: EncodedScreenshot(
                    mediaType: "image/png",
                    base64Data: "raw-image-payload",
                    width: 1200,
                    height: 800
                )
            )
        },
        recognizeText: { _ in
            [
                RecognizedTextObservation(
                    text: secret,
                    boundingBox: NormalizedTextBoundingBox(x: 0.10, y: 0.80, width: 0.20, height: 0.05),
                    confidence: 1
                )
            ]
        },
        activeCredentialFilter: try mcpActiveCredentialFilter(values: [secret])
    )

    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("active-shot-ocr"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "target": .string("com.example.App"),
                "screenshot": .bool(true),
                "tree": .bool(false)
            ])
        ])
    ))

    let result = response?.result
    let snapshot = result?["structuredContent"]?["snapshot"]
    let encoded = try encodedJSONString(.object(result ?? [:]))

    #expect(response?.error == nil)
    #expect(snapshot?["screenshot"] == nil)
    #expect(snapshot?["screenText"] == nil)
    #expect(snapshot?["warnings"]?[0] == .string("screenshot omitted because active credential text was redacted"))
    #expect(imageContent(in: result) == nil)
    #expect(encoded.contains(secret) == false)
    #expect(encoded.contains("raw-image-payload") == false)
}

@Test func mcpLookUsesCurrentActiveCredentialFilterProvider() throws {
    let secret = "correct horse battery staple"
    let provider = RotatingActiveCredentialFilterProvider(
        filters: [
            EmptyActiveCredentialFilter(),
            try mcpActiveCredentialFilter(values: [secret])
        ]
    )
    let commandRouter = CommandRouter(
        captureSnapshot: { _, _ in
            AppSnapshot(
                id: SnapshotID("mcp-rotating-filter"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [
                    AXNode(role: "AXWindow", title: "Main", children: [
                        AXNode(role: "AXTextField", value: secret)
                    ])
                ],
                screenshot: nil
            )
        },
        activeCredentialFilterProvider: provider.current
    )

    let first = MCPRouter(commandRouter: commandRouter).handle(lookCall(id: "first-current-filter"))
    let second = MCPRouter(commandRouter: commandRouter).handle(lookCall(id: "second-current-filter"))

    #expect(textContent(in: first?.result)?.contains(secret) == true)
    #expect(textContent(in: second?.result)?.contains(secret) == false)
    #expect(textContent(in: second?.result)?.contains("<redacted: active-credential>") == true)
}

@Test func mcpSensitiveAppStateRejectsScreenshots() {
    let response = MCPRouter(commandRouter: CommandRouter()).handle(JSONRPCRequest(
        id: .string("sensitive-shot"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "target": .string("com.example.App"),
                "sensitive": .bool(true),
                "screenshot": .bool(true)
            ])
        ])
    ))

    #expect(response?.error == nil)
    #expect(response?.result?["isError"] == .bool(true))
    #expect(response?.result?["structuredContent"]?["error"]?["message"] == .string("sensitive snapshots cannot include screenshots"))
}

@Test func mcpSensitiveAppStateRejectsScreenText() {
    let response = MCPRouter(commandRouter: CommandRouter()).handle(JSONRPCRequest(
        id: .string("sensitive-screen-text"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "target": .string("com.example.App"),
                "sensitive": .bool(true),
                "screenText": .bool(true)
            ])
        ])
    ))

    #expect(response?.error == nil)
    #expect(response?.result?["isError"] == .bool(true))
    #expect(response?.result?["structuredContent"]?["error"]?["message"] == .string("sensitive snapshots cannot include screenText"))
}

@Test func mcpScreenshotUsesImageContentInsteadOfTextualBase64() {
    let commandRouter = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == true)
            return AppSnapshot(
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
        }
    )
    let response = MCPRouter(commandRouter: commandRouter).handle(JSONRPCRequest(
        id: .string("shot"),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object([
                "target": .string("com.example.App"),
                "screenshot": .bool(true),
                "tree": .bool(false)
            ])
        ])
    ))

    let result = response?.result
    let screenshot = result?["structuredContent"]?["snapshot"]?["screenshot"]
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
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == true)
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
            "name": .string("look"),
            "arguments": .object([
                "target": .string("com.example.App"),
                "screenshot": .bool(true)
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

private func lookCall(id: String) -> JSONRPCRequest {
    JSONRPCRequest(
        id: .string(id),
        method: "tools/call",
        params: .object([
            "name": .string("look"),
            "arguments": .object(["target": .string("com.example.App")])
        ])
    )
}

private func encodedJSONString(_ value: JSONValue) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

private final class RotatingActiveCredentialFilterProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let filters: [any ActiveCredentialFilter]
    private var index = 0

    init(filters: [any ActiveCredentialFilter]) {
        self.filters = filters
    }

    func current() -> any ActiveCredentialFilter {
        lock.lock()
        defer { lock.unlock() }
        let filter = filters[min(index, filters.count - 1)]
        index += 1
        return filter
    }
}

private func mcpActiveCredentialFilter(values: [String]) throws -> ActiveCredentialIndex {
    try ActiveCredentialIndex(
        secrets: values.map {
            ActiveCredentialSecret(value: $0, provider: "test", reference: "op://MCP/Active/secret")
        },
        hmacKey: Data(repeating: 0xC3, count: 32),
        provider: "test",
        createdAt: Date(timeIntervalSince1970: 1_775_000_000)
    )
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

private final class MCPRecordingCommandHandler: JSONRPCCommandHandling {
    private let response: JSONRPCResponse
    private(set) var requests: [JSONRPCRequest] = []

    init(result: [String: JSONValue]) {
        self.response = JSONRPCResponse(id: .string("recorded"), result: result)
    }

    func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: response.result ?? [:])
    }
}
