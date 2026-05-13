import Foundation

public struct MCPRouter {
    public static let protocolVersion = "2025-11-25"

    private let commandHandler: any JSONRPCCommandHandling

    public init(commandHandler: any JSONRPCCommandHandling = SocketCommandRouter()) {
        self.commandHandler = commandHandler
    }

    public init(commandRouter: CommandRouter) {
        self.commandHandler = commandRouter
    }

    public func handle(_ request: JSONRPCRequest) -> JSONRPCResponse? {
        if request.id == nil, request.method.hasPrefix("notifications/") {
            return nil
        }

        switch request.method {
        case "initialize":
            return JSONRPCResponse(id: request.id, result: [
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object([
                    "tools": .object([:])
                ]),
                "serverInfo": .object([
                    "name": .string("axon"),
                    "version": .string("0.1.0")
                ]),
                "instructions": .string("Use plain Axon tool names. Targets may be snapshot handles or locator objects.")
            ])
        case "ping":
            return JSONRPCResponse(id: request.id, result: [:])
        case "tools/list":
            return JSONRPCResponse(id: request.id, result: [
                "tools": .array(Self.tools.map(\.jsonValue))
            ])
        case "tools/call":
            return callTool(request)
        default:
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }
    }

    private func callTool(_ request: JSONRPCRequest) -> JSONRPCResponse {
        do {
            let params = try objectParams(in: request)
            guard case let .string(name) = params["name"] else {
                throw JSONRPCError.invalidParams("tools/call requires string name")
            }
            guard let method = Self.commandMethod(for: name) else {
                throw JSONRPCError.invalidParams("Unknown tool: \(name)")
            }

            let arguments: [String: JSONValue]
            if let rawArguments = params["arguments"], rawArguments != .null {
                guard case let .object(object) = rawArguments else {
                    throw JSONRPCError.invalidParams("tools/call arguments must be an object")
                }
                arguments = Self.argumentsWithMCPDefaults(for: name, arguments: object)
            } else {
                arguments = Self.argumentsWithMCPDefaults(for: name, arguments: [:])
            }

            let commandResponse = commandHandler.handle(JSONRPCRequest(
                id: request.id,
                method: method,
                params: .object(arguments)
            ))
            if let error = commandResponse.error {
                return toolResult(id: request.id, structuredContent: [
                    "error": error.jsonValue
                ], isError: true)
            }
            return toolResult(id: request.id, structuredContent: commandResponse.result ?? [:], isError: false)
        } catch let error as JSONRPCError {
            return JSONRPCResponse(id: request.id, error: error)
        } catch {
            return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
        }
    }

    private func toolResult(id: JSONRPCID?, structuredContent: [String: JSONValue], isError: Bool) -> JSONRPCResponse {
        let content = MCPContent.normalize(JSONValue.object(structuredContent))
        return JSONRPCResponse(id: id, result: [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(content.structured.compactJSONString)
                ])
            ] + content.images),
            "structuredContent": content.structured,
            "isError": .bool(isError)
        ])
    }

    private func objectParams(in request: JSONRPCRequest) throws -> [String: JSONValue] {
        guard case let .object(params) = request.params else {
            throw JSONRPCError.invalidParams("params must be an object")
        }
        return params
    }

    private static func commandMethod(for toolName: String) -> String? {
        switch toolName {
        case "list_apps":
            return "list_apps"
        case "request_accessibility":
            return "request_accessibility"
        case "get_app_state":
            return "snapshot"
        case "get_screenshot":
            return "screenshot"
        case "resolve":
            return "resolve"
        case "changed_since":
            return "changed_since"
        case "run_plan":
            return "run_plan"
        case "click":
            return "click"
        case "scroll":
            return "scroll"
        case "drag":
            return "drag"
        case "perform_action":
            return "perform_action"
        case "set_value":
            return "set_value"
        case "type_text":
            return "type_text"
        case "press_key":
            return "press_key"
        default:
            return nil
        }
    }

    private static func argumentsWithMCPDefaults(
        for toolName: String,
        arguments: [String: JSONValue]
    ) -> [String: JSONValue] {
        guard toolName == "get_app_state" else {
            return arguments
        }
        var updated = arguments
        if updated["screenshot"] == nil {
            updated["screenshot"] = .bool(false)
        }
        if updated["includeTree"] == nil {
            updated["includeTree"] = .bool(false)
        }
        return updated
    }

    private static let tools: [MCPTool] = [
        MCPTool(
            name: "list_apps",
            description: "List currently running macOS applications visible to Axon.",
            inputSchema: objectSchema()
        ),
        MCPTool(
            name: "request_accessibility",
            description: "Ask macOS to show the Accessibility permission prompt for the running Axon daemon identity.",
            inputSchema: objectSchema()
        ),
        MCPTool(
            name: "get_app_state",
            description: "Capture an accessibility snapshot for a running app, optionally including an embedded screenshot.",
            inputSchema: objectSchema(properties: [
                "app": stringSchema("Bundle id, pid, exact app name, or partial app name."),
                "screenshot": boolSchema("Whether to include embedded ScreenCaptureKit screenshot data. Defaults to false for MCP."),
                "includeTree": boolSchema("Whether to include the full nested AX tree. Defaults to false for MCP; indexedNodes are always returned.")
            ], required: ["app"])
        ),
        MCPTool(
            name: "get_screenshot",
            description: "Capture an embedded ScreenCaptureKit screenshot for a running app window.",
            inputSchema: objectSchema(properties: [
                "app": stringSchema("Bundle id, pid, exact app name, or partial app name.")
            ], required: ["app"])
        ),
        MCPTool(
            name: "resolve",
            description: "Resolve an AX locator against a fresh app snapshot.",
            inputSchema: objectSchema(properties: [
                "app": stringSchema("Bundle id, pid, exact app name, or partial app name."),
                "locator": locatorSchema()
            ], required: ["app", "locator"])
        ),
        MCPTool(
            name: "changed_since",
            description: "Recapture the app for a retained snapshot and report whether coarse app/window state changed.",
            inputSchema: objectSchema(properties: [
                "snapshotId": stringSchema("Snapshot id returned by get_app_state.")
            ], required: ["snapshotId"])
        ),
        MCPTool(
            name: "run_plan",
            description: "Execute an invocation-scoped Axon automation plan. YAML source is the preferred compact format; JSON plan objects are also accepted.",
            inputSchema: objectSchema(properties: [
                "source": stringSchema("YAML or JSON automation plan source."),
                "path": stringSchema("Local plan file path for the Axon daemon to read."),
                "plan": .object([
                    "type": .string("object"),
                    "description": .string("Automation plan object when not using source."),
                    "additionalProperties": .bool(true)
                ]),
                "args": .object([
                    "type": .string("object"),
                    "description": .string("Invocation arguments available as $args.* in the plan."),
                    "additionalProperties": .bool(true)
                ]),
                "dryRun": boolSchema("Resolve and trace the plan without dispatching mutating actions.")
            ])
        ),
        MCPTool(
            name: "click",
            description: "Click a target specified by snapshot handle, locator object, or point.",
            inputSchema: objectSchema(properties: [
                "target": targetSchema()
            ], required: ["target"])
        ),
        MCPTool(
            name: "scroll",
            description: "Scroll an accessibility surface by resolving an offscreen descendant and requesting AXScrollToVisible.",
            inputSchema: objectSchema(properties: [
                "app": stringSchema("Optional app used to resolve a scroll surface without activating it."),
                "target": targetSchema(),
                "deltaX": numberSchema("Horizontal scroll delta in pixels. Defaults to 0."),
                "deltaY": numberSchema("Vertical scroll delta in pixels. Defaults to -120.")
            ])
        ),
        MCPTool(
            name: "drag",
            description: "Drag from one point, snapshot handle, or locator target to another.",
            inputSchema: objectSchema(properties: [
                "app": stringSchema("Optional app to activate before dragging."),
                "from": targetSchema(),
                "to": targetSchema(),
                "durationMs": numberSchema("Optional drag hold duration in milliseconds.")
            ], required: ["from", "to"])
        ),
        MCPTool(
            name: "perform_action",
            description: "Perform a named AX action on a target specified by snapshot handle or locator object.",
            inputSchema: objectSchema(properties: [
                "target": targetSchema(),
                "action": stringSchema("Accessibility action name, for example AXPress or AXShowMenu.")
            ], required: ["target", "action"])
        ),
        MCPTool(
            name: "set_value",
            description: "Set an accessibility value on a target specified by snapshot handle or locator object.",
            inputSchema: objectSchema(properties: [
                "target": targetSchema(),
                "value": stringSchema("New string value.")
            ], required: ["target", "value"])
        ),
        MCPTool(
            name: "type_text",
            description: "Activate an app and type text with CoreGraphics keyboard events.",
            inputSchema: objectSchema(properties: [
                "app": stringSchema("Bundle id, pid, exact app name, or partial app name."),
                "text": stringSchema("Text to type.")
            ], required: ["app", "text"])
        ),
        MCPTool(
            name: "press_key",
            description: "Activate an app and press a key or key combination.",
            inputSchema: objectSchema(properties: [
                "app": stringSchema("Bundle id, pid, exact app name, or partial app name."),
                "key": stringSchema("Key or combo, for example Return or cmd+shift+p.")
            ], required: ["app", "key"])
        )
    ]
}

private struct MCPTool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue

    var jsonValue: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema
        ])
    }
}

private func objectSchema(properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object(properties),
        "additionalProperties": .bool(false)
    ]
    if !required.isEmpty {
        object["required"] = .array(required.map(JSONValue.string))
    }
    return .object(object)
}

private func stringSchema(_ description: String) -> JSONValue {
    .object([
        "type": .string("string"),
        "description": .string(description)
    ])
}

private func boolSchema(_ description: String) -> JSONValue {
    .object([
        "type": .string("boolean"),
        "description": .string(description)
    ])
}

private func numberSchema(_ description: String) -> JSONValue {
    .object([
        "type": .string("number"),
        "description": .string(description)
    ])
}

private func locatorSchema() -> JSONValue {
    .object([
        "type": .string("object"),
        "description": .string("AX locator with role, subrole, title, value, description, identifier, actions, and ancestors."),
        "additionalProperties": .bool(true)
    ])
}

private func targetSchema() -> JSONValue {
    .object([
        "anyOf": .array([
            .object([
                "type": .string("string"),
                "description": .string("Snapshot handle like snapshot:<id>:<index>.")
            ]),
            .object([
                "type": .string("object"),
                "description": .string("Locator target object with app and locator fields."),
                "additionalProperties": .bool(true)
            ]),
            .object([
                "type": .string("object"),
                "description": .string("Point target object: { point: { x, y } } or { x, y } in screen coordinates."),
                "additionalProperties": .bool(true)
            ])
        ])
    ])
}

private extension JSONRPCError {
    var jsonValue: JSONValue {
        .object([
            "code": .int(code),
            "message": .string(message)
        ])
    }
}

private struct MCPContent {
    let structured: JSONValue
    let images: [JSONValue]

    static func normalize(_ value: JSONValue) -> MCPContent {
        var images: [JSONValue] = []
        let structured = value.redactingMCPImagePayloads(into: &images)
        return MCPContent(structured: structured, images: images)
    }
}

private extension JSONValue {
    var compactJSONString: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func redactingMCPImagePayloads(into images: inout [JSONValue]) -> JSONValue {
        switch self {
        case var .object(object):
            if case let .string(base64Data)? = object["base64Data"],
               case let .string(mediaType)? = object["mediaType"] {
                images.append(.object([
                    "type": .string("image"),
                    "data": .string(base64Data),
                    "mimeType": .string(mediaType)
                ]))
                object.removeValue(forKey: "base64Data")
                object["contentTransport"] = .string("mcp_image")
            }

            var redacted: [String: JSONValue] = [:]
            redacted.reserveCapacity(object.count)
            for (key, value) in object {
                redacted[key] = value.redactingMCPImagePayloads(into: &images)
            }
            return .object(redacted)
        case let .array(values):
            return .array(values.map { $0.redactingMCPImagePayloads(into: &images) })
        case .string, .int, .double, .bool, .null:
            return self
        }
    }
}
