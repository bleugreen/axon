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
    public typealias SnapshotProvider = RecordedFactEvaluator.SnapshotProvider

    private let commandHandler: CommandHandler
    private let factEvaluator: RecordedFactEvaluator?
    private let snapshotProvider: SnapshotProvider?
    private let changePollIntervalMs: Int
    private let changeTimeoutMs: Int

    public init(
        commandHandler: @escaping CommandHandler,
        snapshotProvider: SnapshotProvider? = nil,
        changePollIntervalMs: Int = 100,
        changeTimeoutMs: Int = 5_000
    ) {
        self.commandHandler = commandHandler
        self.snapshotProvider = snapshotProvider
        self.factEvaluator = snapshotProvider.map(RecordedFactEvaluator.init(snapshotProvider:))
        self.changePollIntervalMs = max(0, changePollIntervalMs)
        self.changeTimeoutMs = max(0, changeTimeoutMs)
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
        var facts: [String: RecordedFact] = [:]
        var success = true

        for (index, action) in actions.enumerated() {
            let record = runAction(action, index: index, dryRun: dryRun, facts: &facts)
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
        if case let .string(path)? = params["path"] {
            var batch = try ActionBatchExecutor.parseSource(String(contentsOfFile: path, encoding: .utf8))
            if let appendedActions = params["actions"] {
                batch = try batch.appendingActions(appendedActions)
            }
            return batch
        }
        if params["actions"] != nil {
            return .object(params)
        }
        throw ActionBatchError.invalidParams("run requires actions or path")
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

    private func runAction(_ action: JSONValue, index: Int, dryRun: Bool, facts: inout [String: RecordedFact]) -> JSONValue {
        do {
            guard case var .object(object) = action else {
                throw ActionBatchError.invalidParams("actions[\(index)] must be an object")
            }
            let actionID = optionalString("id", in: object)
            let requiredFactIDs = try requiredFacts(in: object)
            let expectedFacts = try expectedFacts(in: object)
            let changeBaselines = try changedBaselines(for: expectedFacts)

            try verifyRequiredFacts(requiredFactIDs, facts: facts)

            guard case let .string(tool)? = object.removeValue(forKey: "tool"), !tool.isEmpty else {
                throw ActionBatchError.invalidParams("actions[\(index)] requires tool")
            }
            let method = try commandMethod(for: tool)
            stripMetadata(from: &object)

            var record: [String: JSONValue] = [
                "index": .int(index),
                "tool": .string(tool),
                "success": .bool(true)
            ]
            if let actionID {
                record["actionId"] = .string(actionID)
            }

            if dryRun {
                record["dryRun"] = .bool(true)
                record["params"] = .object(object)
                return .object(record)
            }

            let response = dispatchPrimitive(object, index: index, tool: tool, method: method)
            if let error = response.error {
                throw ActionBatchError.invalidParams(error.message)
            }
            if primitiveActionSucceeded(in: response.result) == false {
                record["success"] = .bool(false)
                record["result"] = resultSummary(method: method, result: response.result ?? [:])
                record["error"] = .string(primitiveActionFailureMessage(in: response.result) ?? "primitive action reported failure")
                return .object(record)
            }
            try verifyExpectedFacts(expectedFacts, changeBaselines: changeBaselines, facts: &facts)
            record["result"] = resultSummary(method: method, result: response.result ?? [:])
            return .object(record)
        } catch let error as RecordedFactError {
            var record: [String: JSONValue] = [
                "index": .int(index),
                "success": .bool(false),
                "error": .string(error.description)
            ]
            if case let .object(object) = action, let actionID = optionalString("id", in: object) {
                record["actionId"] = .string(actionID)
            }
            if let factID = error.factID {
                record["factId"] = .string(factID)
            }
            return .object(record)
        } catch {
            return .object([
                "index": .int(index),
                "success": .bool(false),
                "error": .string(String(describing: error))
            ])
        }
    }

    private func dispatchPrimitive(
        _ object: [String: JSONValue],
        index: Int,
        tool: String,
        method: String
    ) -> JSONRPCResponse {
        commandHandler(JSONRPCRequest(
            id: .string("batch.\(index).\(tool)"),
            method: method,
            params: .object(object)
        ))
    }

    private func verifyRequiredFacts(_ requiredFactIDs: [String], facts: [String: RecordedFact]) throws {
        guard !requiredFactIDs.isEmpty else {
            return
        }
        guard let factEvaluator else {
            throw RecordedFactError.unsupported(factID: requiredFactIDs[0], message: "fact verification is unavailable")
        }
        for factID in requiredFactIDs {
            guard let fact = facts[factID] else {
                throw RecordedFactError.missingDependency(factID)
            }
            try factEvaluator.verify(fact)
        }
    }

    private func verifyExpectedFacts(
        _ expectedFacts: [RecordedFact],
        changeBaselines: [String: SnapshotSummary],
        facts: inout [String: RecordedFact]
    ) throws {
        guard !expectedFacts.isEmpty else {
            return
        }
        guard let factEvaluator else {
            throw RecordedFactError.unsupported(factID: expectedFacts[0].id, message: "fact verification is unavailable")
        }
        for fact in expectedFacts {
            if fact.kind == "changed", let baseline = changeBaselines[fact.id] {
                try verifyChangedFact(fact, baseline: baseline)
            } else {
                try factEvaluator.verify(fact)
            }
            facts[fact.id] = fact
        }
    }

    private func changedBaselines(for facts: [RecordedFact]) throws -> [String: SnapshotSummary] {
        guard facts.contains(where: { $0.kind == "changed" }) else {
            return [:]
        }
        guard let snapshotProvider else {
            throw RecordedFactError.unsupported(factID: facts.first(where: { $0.kind == "changed" })?.id ?? "changed", message: "changed fact verification is unavailable")
        }
        var baselines: [String: SnapshotSummary] = [:]
        for fact in facts where fact.kind == "changed" {
            let app = try changedFactApp(fact)
            baselines[fact.id] = try SnapshotSummary(snapshot: snapshotProvider(app))
        }
        return baselines
    }

    private func verifyChangedFact(_ fact: RecordedFact, baseline: SnapshotSummary) throws {
        guard let snapshotProvider else {
            throw RecordedFactError.unsupported(factID: fact.id, message: "changed fact verification is unavailable")
        }
        let app = try changedFactApp(fact)
        let deadline = Date().addingTimeInterval(Double(changeTimeoutMs) / 1_000)
        repeat {
            let current = try SnapshotSummary(snapshot: snapshotProvider(app))
            if baseline.change(comparedTo: current).changed {
                return
            }
            if changePollIntervalMs > 0 {
                Thread.sleep(forTimeInterval: Double(changePollIntervalMs) / 1_000)
            }
        } while Date() <= deadline
        throw RecordedFactError.mismatch(factID: fact.id, message: "app did not change")
    }

    private func changedFactApp(_ fact: RecordedFact) throws -> String {
        guard case let .object(object) = fact.target,
              case let .string(app)? = object["app"],
              !app.isEmpty
        else {
            throw RecordedFactError.invalidFact("fact \(fact.id) target requires app")
        }
        return app
    }

    private func requiredFacts(in object: [String: JSONValue]) throws -> [String] {
        guard let value = object["requires"], value != .null else {
            return []
        }
        guard case let .array(values) = value else {
            throw ActionBatchError.invalidParams("requires must be an array of fact ids")
        }
        return try values.map { value in
            guard case let .string(id) = value, !id.isEmpty else {
                throw ActionBatchError.invalidParams("requires must be an array of fact ids")
            }
            return id
        }
    }

    private func expectedFacts(in object: [String: JSONValue]) throws -> [RecordedFact] {
        guard let value = object["expects"], value != .null else {
            return []
        }
        guard case let .array(values) = value else {
            throw ActionBatchError.invalidParams("expects must be an array of facts")
        }
        return try values.map(RecordedFact.init(jsonValue:))
    }

    private func stripMetadata(from object: inout [String: JSONValue]) {
        for key in ["id", "label", "requires", "expects", "observed", "warnings", "resolve"] {
            object.removeValue(forKey: key)
        }
    }

    private func optionalString(_ key: String, in object: [String: JSONValue]) -> String? {
        guard case let .string(value)? = object[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    private func commandMethod(for tool: String) throws -> String {
        switch tool {
        case "look", "find", "click", "scroll", "drag", "invoke", "type", "keyboard":
            return tool
        default:
            throw ActionBatchError.invalidParams("unknown batch tool: \(tool)")
        }
    }

    private func resultSummary(method: String, result: [String: JSONValue]) -> JSONValue {
        switch method {
        case "look":
            if let apps = result["apps"]?.arrayValue {
                return .object(["count": .int(apps.count)])
            }
            if case let .object(snapshot)? = result["snapshot"] {
                return .object([
                    "snapshot": snapshot["id"] ?? .null,
                    "app": snapshot["app"]?["name"] ?? .null
                ])
            }
            if result["children"] != nil {
                return .object([
                    "parent": result["children"]?["parent"] ?? .null,
                    "offset": result["children"]?["offset"] ?? .null,
                    "nextOffset": result["children"]?["nextOffset"] ?? .null
                ])
            }
            if result["changed"] != nil {
                return .object([
                    "changed": result["changed"] ?? .null,
                    "reason": result["reason"] ?? .null
                ])
            }
            return .object([:])
        case "find":
            return result["resolution"] ?? .object([:])
        default:
            return result["action"] ?? .object(result)
        }
    }

    private func primitiveActionSucceeded(in result: [String: JSONValue]?) -> Bool? {
        guard let result else {
            return nil
        }
        return bool("success", in: objectValue(result["action"]) ?? result)
    }

    private func primitiveActionFailureMessage(in result: [String: JSONValue]?) -> String? {
        guard let result else {
            return nil
        }
        let action = objectValue(result["action"]) ?? result
        return optionalString("message", in: action)
    }

    private func objectValue(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case let .object(object)? = value else {
            return nil
        }
        return object
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

    func appendingActions(_ appendedActions: JSONValue) throws -> JSONValue {
        guard case var .object(object) = self else {
            throw ActionBatchError.invalidParams("batch must be an object")
        }
        guard case var .array(actions)? = object["actions"] else {
            throw ActionBatchError.invalidParams("batch requires actions")
        }
        guard case let .array(appended) = appendedActions else {
            throw ActionBatchError.invalidParams("actions must be an array")
        }
        actions.append(contentsOf: appended)
        object["actions"] = .array(actions)
        return .object(object)
    }
}
