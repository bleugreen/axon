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
                    "version": .string(AxonVersion.current)
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
            let result = commandResponse.result ?? [:]
            if name == "look", result["apps"] != nil, Self.outputFormat(in: arguments) != "debug" {
                return appListObservationResult(id: request.id, result: result)
            }
            if name == "look", result["snapshot"] != nil, Self.outputFormat(in: arguments) != "debug" {
                return appStateObservationResult(id: request.id, result: result, arguments: arguments)
            }
            if name == "look", result["children"] != nil, Self.outputFormat(in: arguments) != "debug" {
                return childrenObservationResult(id: request.id, result: result, arguments: arguments)
            }
            return toolResult(id: request.id, structuredContent: result, isError: false)
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

    private func appStateObservationResult(
        id: JSONRPCID?,
        result: [String: JSONValue],
        arguments: [String: JSONValue]
    ) -> JSONRPCResponse {
        guard let snapshot = result["snapshot"] else {
            return toolResult(id: id, structuredContent: result, isError: false)
        }

        let formatter = SnapshotObservationFormatter()
        let observation = formatter.observation(from: snapshot, frames: Self.bool("frames", in: arguments) ?? false)
        let content = MCPContent.normalize(.object(["snapshot": observation]))
        return JSONRPCResponse(id: id, result: [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(formatter.text(from: content.structured["snapshot"] ?? observation))
                ])
            ] + content.images),
            "structuredContent": content.structured,
            "isError": .bool(false)
        ])
    }

    private func appListObservationResult(
        id: JSONRPCID?,
        result: [String: JSONValue]
    ) -> JSONRPCResponse {
        let formatter = AppListFormatter()
        let observation = formatter.observation(from: result)
        return JSONRPCResponse(id: id, result: [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(formatter.text(from: observation))
                ])
            ]),
            "structuredContent": .object(["apps": observation]),
            "isError": .bool(false)
        ])
    }

    private func childrenObservationResult(
        id: JSONRPCID?,
        result: [String: JSONValue],
        arguments: [String: JSONValue]
    ) -> JSONRPCResponse {
        guard let children = result["children"] else {
            return toolResult(id: id, structuredContent: result, isError: false)
        }

        let formatter = SnapshotObservationFormatter()
        let observation = formatter.children(from: children, frames: Self.bool("frames", in: arguments) ?? false)
        let content = MCPContent.normalize(.object(["children": observation]))
        return JSONRPCResponse(id: id, result: [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(formatter.text(from: content.structured["children"] ?? observation))
                ])
            ] + content.images),
            "structuredContent": content.structured,
            "isError": .bool(false)
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
        case "look", "find", "click", "type", "keyboard", "scroll", "drag", "invoke", "save", "run", "permit":
            return toolName
        default:
            return nil
        }
    }

    private static func argumentsWithMCPDefaults(
        for toolName: String,
        arguments: [String: JSONValue]
    ) -> [String: JSONValue] {
        guard toolName == "look" else {
            return arguments
        }
        if arguments["since"] != nil {
            return arguments
        }
        guard case let .string(target)? = arguments["target"] ?? arguments["app"],
              (try? SnapshotHandle(target)) == nil
        else {
            return arguments
        }
        var updated = arguments
        let format = outputFormat(in: arguments)
        if updated["screenshot"] == nil {
            updated["screenshot"] = .bool(false)
        }
        if updated["tree"] == nil {
            updated["tree"] = .bool(format != "debug")
        }
        if updated["sensitive"] == nil {
            updated["sensitive"] = .bool(false)
        }
        return updated
    }

    private static func outputFormat(in arguments: [String: JSONValue]) -> String {
        guard case let .string(format)? = arguments["format"] else {
            return "observation"
        }
        return format == "debug" ? "debug" : "observation"
    }

    private static func bool(_ key: String, in object: [String: JSONValue]) -> Bool? {
        guard case let .bool(value)? = object[key] else {
            return nil
        }
        return value
    }

    private static let tools: [MCPTool] = [
        MCPTool(
            name: "look",
            description: "Observe Axon's current surface: no target lists apps, an app target captures state, a handle target pages children, and since returns a change check.",
            inputSchema: objectSchema(properties: [
                "target": stringSchema("Bundle id, pid, app name, partial app name, or retained snapshot handle such as s12:4. Omit to list apps."),
                "since": stringSchema("Snapshot id from a prior look response. Returns a coarse change check instead of a tree."),
                "screenshot": boolSchema("Include embedded ScreenCaptureKit screenshot data with an app observation. Defaults to false for MCP."),
                "screenText": boolSchema("OCR visible text from the app window screenshot and include it as organized screenText. Defaults to false."),
                "tree": boolSchema("Include the nested AX tree for app observations. Defaults to true for observation format and false for debug format."),
                "sensitive": boolSchema("Redact values and secret-like text while preserving short safe prefixes. Sensitive snapshots cannot include screenshots or screenText."),
                "offset": numberSchema("Zero-based child offset when target is a retained handle. Defaults to 0."),
                "limit": numberSchema("Maximum children when target is a retained handle. Defaults to Axon's sibling page size."),
                "depth": numberSchema("Maximum tree depth to return for app observations, with windows at depth 0."),
                "format": stringSchema("Defaults to observation. Use debug only when diagnosing Axon internals."),
                "frames": boolSchema("Include frames in observation output. Defaults to false.")
            ])
        ),
        MCPTool(
            name: "find",
            description: "Resolve an AX locator against a fresh app snapshot.",
            inputSchema: objectSchema(properties: [
                "app": stringSchema("Bundle id, pid, exact app name, or partial app name."),
                "locator": locatorSchema()
            ], required: ["app", "locator"])
        ),
        MCPTool(
            name: "run",
            description: "Run a sequence of Axon actions from inline actions, a .axn path, or a path loaded first with inline actions appended.",
            inputSchema: objectSchema(properties: [
                "actions": .object([
                    "type": .string("array"),
                    "description": .string("Ordered action objects, each with a tool field and that tool's normal arguments."),
                    "items": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(true)
                    ])
                ]),
                "path": stringSchema("Local .axn batch file path for the Axon daemon to read."),
                "argValues": .object([
                    "type": .string("object"),
                    "description": .string("Caller-supplied .axn argument values keyed by declared arg name. Valid only for args without a declared source."),
                    "additionalProperties": .bool(true)
                ]),
                "continueOnError": boolSchema("Continue after an action fails. Defaults to false."),
                "dryRun": boolSchema("Trace the batch without dispatching actions.")
            ])
        ),
        MCPTool(
            name: "save",
            description: "Save recent recorded Axon calls as an editable .axn action batch. Read calls are omitted unless includeReads is true.",
            inputSchema: objectSchema(properties: [
                "sessionId": stringSchema("History session to export. Defaults to the daemon's default session."),
                "from": stringSchema("Optional starting call id, inclusive."),
                "to": stringSchema("Optional ending call id, inclusive."),
                "path": stringSchema("Optional local path to write the .axn file."),
                "includeReads": boolSchema("Include read/context tools such as look and find. Defaults to false.")
            ])
        ),
        MCPTool(
            name: "click",
            description: "Click a target specified by snapshot handle, locator object, point, or text location.",
            inputSchema: objectSchema(properties: [
                "target": pointerTargetSchema()
            ], required: ["target"])
        ),
        MCPTool(
            name: "scroll",
            description: "Scroll an accessibility surface by resolving an offscreen descendant and requesting AXScrollToVisible.",
            inputSchema: objectSchema(properties: [
                "app": stringSchema("Optional app used to resolve a scroll surface without activating it."),
                "target": pointerTargetSchema(),
                "deltaX": numberSchema("Horizontal scroll delta in pixels. Defaults to 0."),
                "deltaY": numberSchema("Vertical scroll delta in pixels. Defaults to -120.")
            ])
        ),
        MCPTool(
            name: "drag",
            description: "Drag from one point, snapshot handle, or locator target to another.",
            inputSchema: objectSchema(properties: [
                "app": stringSchema("Optional app to activate before dragging."),
                "from": pointerTargetSchema(),
                "to": pointerTargetSchema(),
                "durationMs": numberSchema("Optional drag hold duration in milliseconds.")
            ], required: ["from", "to"])
        ),
        MCPTool(
            name: "invoke",
            description: "Invoke a named AX action on a target specified by snapshot handle or locator object.",
            inputSchema: objectSchema(properties: [
                "target": elementTargetSchema(),
                "name": stringSchema("Accessibility action name, for example AXPress or AXShowMenu.")
            ], required: ["target", "name"])
        ),
        MCPTool(
            name: "type",
            description: "Fill a writable field by setting AXValue directly on a target, avoiding focus and keystroke timing races.",
            inputSchema: objectSchema(properties: [
                "target": elementTargetSchema(),
                "value": stringSchema("New string value.")
            ], required: ["target", "value"])
        ),
        MCPTool(
            name: "keyboard",
            description: "Post keyboard input for shortcuts, special keys, or raw text when field-level type is not the right intent.",
            inputSchema: objectSchema(properties: [
                "app": stringSchema("Optional app to activate before posting keyboard input."),
                "keys": stringSchema("Text, special key, or combo, for example Return or cmd+shift+p.")
            ], required: ["keys"])
        ),
        MCPTool(
            name: "permit",
            description: "Ask macOS to show the Accessibility permission prompt for the running Axon daemon identity.",
            inputSchema: objectSchema()
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
        "description": .string("AX locator with role, subrole, label, title, value, description, identifier, actions, and ancestors."),
        "additionalProperties": .bool(true)
    ])
}

private func elementTargetSchema() -> JSONValue {
    .object([
        "anyOf": .array([
            .object([
                "type": .string("string"),
                "description": .string("Snapshot handle like s12:19.")
            ]),
            .object([
                "type": .string("object"),
                "description": .string("Locator target object with app and locator fields. Locator may use label, title, value, description, identifier, actions, and ancestors."),
                "additionalProperties": .bool(true)
            ])
        ])
    ])
}

private func pointerTargetSchema() -> JSONValue {
    .object([
        "anyOf": .array([
            .object([
                "type": .string("string"),
                "description": .string("Snapshot handle like s12:19.")
            ]),
            .object([
                "type": .string("object"),
                "description": .string("Locator target object with app and locator fields. Locator may use label, title, value, description, identifier, actions, and ancestors."),
                "additionalProperties": .bool(true)
            ]),
            .object([
                "type": .string("object"),
                "description": .string("Point target object: { point: { x, y } } or { x, y } in screen coordinates."),
                "additionalProperties": .bool(true)
            ]),
            .object([
                "type": .string("object"),
                "description": .string("Text location target object: { location: { app, text, source? } }. Resolves visible text to a click/drag/scroll point using AX text or screenshot OCR without callers providing coordinates."),
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
