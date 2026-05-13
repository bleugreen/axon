import Foundation
import Yams

public enum ActionBatchError: Error, CustomStringConvertible {
    case invalidParams(String)

    public var description: String {
        switch self {
        case let .invalidParams(message):
            return message
        }
    }
}

public struct ActionBatchExecutor {
    public typealias CommandHandler = (JSONRPCRequest) -> JSONRPCResponse

    private let commandHandler: CommandHandler

    public init(commandHandler: @escaping CommandHandler) {
        self.commandHandler = commandHandler
    }

    public func run(params: [String: JSONValue]) throws -> JSONValue {
        let batch = try batchValue(from: params)
        guard case let .object(batchObject) = batch else {
            throw ActionBatchError.invalidParams("batch must be an object")
        }

        let actions = try actionArray(in: batchObject)
        let dryRun = bool("dryRun", in: params) ?? bool("dryRun", in: batchObject) ?? false
        let continueOnError = bool("continueOnError", in: params) ?? bool("continueOnError", in: batchObject) ?? false

        var trace: [JSONValue] = []
        var success = true

        for (index, action) in actions.enumerated() {
            let record = runAction(action, index: index, dryRun: dryRun)
            trace.append(record)
            if record["success"] == .bool(false) {
                success = false
                if !continueOnError {
                    break
                }
            }
        }

        return .object([
            "success": .bool(success),
            "dryRun": .bool(dryRun),
            "continueOnError": .bool(continueOnError),
            "trace": .array(trace)
        ])
    }

    private func batchValue(from params: [String: JSONValue]) throws -> JSONValue {
        if params["actions"] != nil {
            return .object(params)
        }
        if let batch = params["batch"] {
            return batch
        }
        if case let .string(source)? = params["source"] {
            return try ActionBatchExecutor.parseSource(source)
        }
        if case let .string(path)? = params["path"] {
            return try ActionBatchExecutor.parseSource(String(contentsOfFile: path, encoding: .utf8))
        }
        throw ActionBatchError.invalidParams("run_batch requires actions, batch, source, or path")
    }

    public static func parseSource(_ source: String) throws -> JSONValue {
        if let data = source.data(using: .utf8),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return json
        }
        let loaded = try Yams.load(yaml: source)
        return try jsonValue(from: loaded)
    }

    private static func jsonValue(from value: Any?) throws -> JSONValue {
        guard let value else {
            return .null
        }
        switch value {
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .int(value)
        case let value as Double:
            return .double(value)
        case let value as [Any?]:
            return .array(try value.map(jsonValue(from:)))
        case let value as [Any]:
            return .array(try value.map { try jsonValue(from: $0) })
        case let value as [String: Any?]:
            return .object(try value.mapValues { try jsonValue(from: $0) })
        case let value as [String: Any]:
            return .object(try value.mapValues { try jsonValue(from: $0) })
        default:
            throw ActionBatchError.invalidParams("unsupported YAML value: \(type(of: value))")
        }
    }

    private func actionArray(in object: [String: JSONValue]) throws -> [JSONValue] {
        guard let value = object["actions"] else {
            throw ActionBatchError.invalidParams("batch requires actions")
        }
        guard case let .array(actions) = value else {
            throw ActionBatchError.invalidParams("actions must be an array")
        }
        return actions
    }

    private func runAction(_ action: JSONValue, index: Int, dryRun: Bool) -> JSONValue {
        do {
            guard case var .object(object) = action else {
                throw ActionBatchError.invalidParams("actions[\(index)] must be an object")
            }
            guard case let .string(tool)? = object.removeValue(forKey: "tool"), !tool.isEmpty else {
                throw ActionBatchError.invalidParams("actions[\(index)] requires tool")
            }
            let method = try commandMethod(for: tool)

            var record: [String: JSONValue] = [
                "index": .int(index),
                "tool": .string(tool),
                "success": .bool(true)
            ]

            if dryRun {
                record["dryRun"] = .bool(true)
                record["params"] = .object(object)
                return .object(record)
            }

            let response = commandHandler(JSONRPCRequest(
                id: .string("batch.\(index).\(tool)"),
                method: method,
                params: .object(object)
            ))
            if let error = response.error {
                throw ActionBatchError.invalidParams(error.message)
            }
            record["result"] = resultSummary(method: method, result: response.result ?? [:])
            return .object(record)
        } catch {
            return .object([
                "index": .int(index),
                "success": .bool(false),
                "error": .string(String(describing: error))
            ])
        }
    }

    private func commandMethod(for tool: String) throws -> String {
        switch tool {
        case "list_apps":
            return "list_apps"
        case "get_app_state":
            return "snapshot"
        case "get_children":
            return "get_children"
        case "get_screenshot":
            return "screenshot"
        case "resolve":
            return "resolve"
        case "changed_since":
            return "changed_since"
        case "click", "scroll", "drag", "perform_action", "set_value", "type_text", "press_key":
            return tool
        default:
            throw ActionBatchError.invalidParams("unknown batch tool: \(tool)")
        }
    }

    private func resultSummary(method: String, result: [String: JSONValue]) -> JSONValue {
        switch method {
        case "list_apps":
            let count = result["apps"]?.arrayValue?.count ?? 0
            return .object(["count": .int(count)])
        case "snapshot":
            guard case let .object(snapshot)? = result["snapshot"] else {
                return .object([:])
            }
            return .object([
                "snapshot": snapshot["id"] ?? .null,
                "app": snapshot["app"]?["name"] ?? .null
            ])
        case "screenshot":
            return .object([
                "width": result["screenshot"]?["width"] ?? .null,
                "height": result["screenshot"]?["height"] ?? .null
            ])
        case "get_children":
            return .object([
                "parent": result["children"]?["parent"] ?? .null,
                "offset": result["children"]?["offset"] ?? .null,
                "nextOffset": result["children"]?["nextOffset"] ?? .null
            ])
        case "resolve":
            return result["resolution"] ?? .object([:])
        case "changed_since":
            return .object([
                "changed": result["changed"] ?? .null,
                "reason": result["reason"] ?? .null
            ])
        default:
            return result["action"] ?? .object(result)
        }
    }

    private func bool(_ key: String, in object: [String: JSONValue]) -> Bool? {
        guard case let .bool(value)? = object[key] else {
            return nil
        }
        return value
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else {
            return nil
        }
        return values
    }
}
