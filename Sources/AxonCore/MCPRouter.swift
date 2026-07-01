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
                "tools": .array(ToolSurfaceSchema.mcpToolJSONValues())
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
            if name == "look",
               result["apps"] != nil,
               Self.outputFormat(in: arguments) != "debug",
               Self.bool("all", in: arguments) != true {
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
        let observation = formatter.observation(
            from: snapshot,
            frames: Self.bool("frames", in: arguments) ?? false,
            maxDepth: Self.int("depth", in: arguments).map { max(0, $0) }
        )
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
        ToolSurfaceSpec.socketMethod(for: toolName)
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

    private static func int(_ key: String, in object: [String: JSONValue]) -> Int? {
        guard case let .int(value)? = object[key] else {
            return nil
        }
        return value
    }

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
