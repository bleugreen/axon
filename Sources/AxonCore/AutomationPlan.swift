import Foundation
import Yams

public enum AutomationPlanError: Error, CustomStringConvertible {
    case invalidParams(String)
    case executionFailed(String)
    case detailedExecutionFailed(String, details: [String: JSONValue])

    public var description: String {
        switch self {
        case let .invalidParams(message), let .executionFailed(message), let .detailedExecutionFailed(message, _):
            return message
        }
    }

    var details: [String: JSONValue] {
        switch self {
        case .invalidParams, .executionFailed:
            return [:]
        case let .detailedExecutionFailed(_, details):
            return details
        }
    }

    func withStepContext(index: Int, path: String, op: String) -> AutomationPlanError {
        guard details["stepPath"] == nil else {
            return self
        }
        var updated = details
        updated["stepIndex"] = .int(index)
        updated["stepPath"] = .string(path)
        updated["stepOp"] = .string(op)
        return .detailedExecutionFailed(description, details: updated)
    }
}

public struct AutomationPlanExecutor {
    public typealias CommandHandler = (JSONRPCRequest) -> JSONRPCResponse

    private let commandHandler: CommandHandler

    public init(commandHandler: @escaping CommandHandler) {
        self.commandHandler = commandHandler
    }

    public func run(params: [String: JSONValue]) throws -> JSONValue {
        let plan = try planValue(from: params)
        guard case let .object(planObject) = plan else {
            throw AutomationPlanError.invalidParams("plan must be an object")
        }
        let context = AutomationPlanContext(
            app: try optionalString("app", in: planObject),
            args: params["args"] ?? .object([:]),
            dryRun: bool("dryRun", in: params) ?? bool("dryRun", in: planObject) ?? false,
            outputMode: try resultOutputMode(in: planObject)
        )
        let steps = try stepArray(in: planObject, key: "steps")
        let state = AutomationPlanState(context: context)

        do {
            try runSteps(steps, state: state)
            return state.result(success: true)
        } catch let error as AutomationPlanError {
            var errorRecord: [String: JSONValue] = [
                "op": .string("error"),
                "success": .bool(false),
                "message": .string(error.description)
            ]
            errorRecord.merge(error.details) { _, new in new }
            state.record(.object(errorRecord))
            return state.result(success: false, error: error.description)
        }
    }

    private func planValue(from params: [String: JSONValue]) throws -> JSONValue {
        if let plan = params["plan"] {
            return plan
        }
        if case let .string(source)? = params["source"] {
            return try Self.parseSource(source)
        }
        if case let .string(path)? = params["path"] {
            return try Self.parseSource(String(contentsOfFile: path, encoding: .utf8))
        }
        throw AutomationPlanError.invalidParams("run_plan requires source, path, or plan")
    }

    private func resultOutputMode(in planObject: [String: JSONValue]) throws -> AutomationPlanOutputMode {
        guard let result = planObject["result"] else {
            return .compact
        }
        guard case let .object(resultObject) = result else {
            throw AutomationPlanError.invalidParams("result must be an object")
        }
        guard let outputs = resultObject["outputs"] else {
            return .compact
        }
        guard case let .string(value) = outputs else {
            throw AutomationPlanError.invalidParams("result.outputs must be compact, full, or none")
        }
        switch value {
        case "compact":
            return .compact
        case "full":
            return .full
        case "none":
            return .none
        default:
            throw AutomationPlanError.invalidParams("result.outputs must be compact, full, or none")
        }
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
            throw AutomationPlanError.invalidParams("unsupported YAML value: \(type(of: value))")
        }
    }

    private func runSteps(
        _ steps: [JSONValue],
        state: AutomationPlanState,
        pathPrefix: String = "steps"
    ) throws {
        for (index, step) in steps.enumerated() {
            try runStep(step, state: state, index: index, path: "\(pathPrefix)[\(index)]")
        }
    }

    private func runStep(_ step: JSONValue, state: AutomationPlanState, index: Int, path: String) throws {
        guard case let .object(object) = step, object.count == 1, let (op, rawParams) = object.first else {
            throw AutomationPlanError.invalidParams("each step must be an object with one operation")
        }

        let params: [String: JSONValue]
        if case let .object(rawObject) = rawParams {
            params = state.resolved(rawObject)
        } else if rawParams == .null {
            params = [:]
        } else {
            throw AutomationPlanError.invalidParams("\(op) step must be an object")
        }

        do {
            switch op {
            case "read":
                try read(params, state: state)
            case "screenshot":
                try screenshot(params, state: state)
            case "resolve":
                try resolve(params, state: state)
            case "click":
                try action(op: "click", params: params, state: state)
            case "perform_action":
                try action(op: "perform_action", params: params, state: state)
            case "set_value":
                try action(op: "set_value", params: params, state: state)
            case "type_text":
                try action(op: "type_text", params: params, state: state)
            case "press_key":
                try action(op: "press_key", params: params, state: state)
            case "changed_since":
                try changedSince(params, state: state)
            case "if":
                try conditional(params, state: state, path: path)
            case "wait_until":
                try waitUntil(params, state: state)
            case "repeat_until":
                try repeatUntil(params, state: state, path: path)
            case "assert":
                try assertion(params, state: state)
            default:
                throw AutomationPlanError.invalidParams("unknown plan operation: \(op)")
            }
        } catch let error as AutomationPlanError {
            throw error.withStepContext(index: index, path: path, op: op)
        }
    }

    private func read(_ params: [String: JSONValue], state: AutomationPlanState) throws {
        let app = try app(in: params, state: state)
        let screenshot = bool("screenshot", in: params) ?? false
        let tree = bool("tree", in: params) ?? false
        let response = commandHandler(JSONRPCRequest(
            id: .string("plan.read"),
            method: "snapshot",
            params: .object([
                "app": .string(app),
                "screenshot": .bool(screenshot),
                "includeTree": .bool(tree)
            ])
        ))
        let snapshot = try resultValue("snapshot", in: response)
        let snapshotID = try string(at: ["id"], in: snapshot)
        bindOutput(params, value: .object([
            "snapshotId": .string(snapshotID),
            "snapshot": snapshot
        ]), state: state)
        state.record(.object([
            "op": .string("read"),
            "success": .bool(true),
            "snapshotId": .string(snapshotID)
        ]))
    }

    private func screenshot(_ params: [String: JSONValue], state: AutomationPlanState) throws {
        let app = try app(in: params, state: state)
        let response = commandHandler(JSONRPCRequest(
            id: .string("plan.screenshot"),
            method: "screenshot",
            params: .object(["app": .string(app)])
        ))
        let value = try resultValue("screenshot", in: response)
        bindOutput(params, value: value, state: state)
        state.record(.object([
            "op": .string("screenshot"),
            "success": .bool(true)
        ]))
    }

    private func resolve(_ params: [String: JSONValue], state: AutomationPlanState) throws {
        let response = try resolveResponse(params, state: state)
        let resolution = try resultValue("resolution", in: response)
        bindOutput(params, value: resolution, state: state)
        state.record(.object([
            "op": .string("resolve"),
            "success": .bool(true),
            "status": resolution["status"] ?? .null
        ]))
    }

    private func action(op: String, params: [String: JSONValue], state: AutomationPlanState) throws {
        let requestParams = try actionParams(op: op, params: params, state: state)
        let target = requestParams["target"]

        if state.context.dryRun, Self.resolvesTargetBeforeDispatch(op) {
            let resolvedTarget = try targetString(from: target, state: state)
            state.record(.object([
                "op": .string(op),
                "success": .bool(true),
                "dryRun": .bool(true),
                "target": .string(resolvedTarget)
            ]))
            return
        }

        if state.context.dryRun {
            state.record(.object([
                "op": .string(op),
                "success": .bool(true),
                "dryRun": .bool(true)
            ]))
            return
        }

        let response = commandHandler(JSONRPCRequest(
            id: .string("plan.\(op)"),
            method: op,
            params: .object(requestParams)
        ))
        let action = try resultValue("action", in: response)
        bindOutput(params, value: action, state: state)
        state.record(.object([
            "op": .string(op),
            "success": action["success"] ?? .bool(true),
            "target": action["target"] ?? target ?? .null
        ]))
    }

    private func changedSince(_ params: [String: JSONValue], state: AutomationPlanState) throws {
        let snapshotID: String
        if case let .string(value)? = params["snapshotId"] {
            snapshotID = value
        } else if case let .string(value)? = params["snapshot"] {
            snapshotID = value
        } else {
            throw AutomationPlanError.invalidParams("changed_since requires snapshotId")
        }
        let response = commandHandler(JSONRPCRequest(
            id: .string("plan.changed_since"),
            method: "changed_since",
            params: .object(["snapshotId": .string(snapshotID)])
        ))
        let result = try responseResult(response)
        bindOutput(params, value: .object(result), state: state)
        state.record(.object([
            "op": .string("changed_since"),
            "success": .bool(true),
            "changed": result["changed"] ?? .null
        ]))
    }

    private static func resolvesTargetBeforeDispatch(_ op: String) -> Bool {
        op == "click" || op == "perform_action" || op == "set_value"
    }

    private func conditional(_ params: [String: JSONValue], state: AutomationPlanState, path: String) throws {
        let condition = try conditionValue(in: params)
        let matches = try evaluate(condition: condition, state: state)
        let branch = matches ? "then" : "else"
        state.record(.object([
            "op": .string("if"),
            "success": .bool(true),
            "branch": .string(branch)
        ]))
        let steps = try stepArray(in: params, key: branch, allowMissing: true)
        try runSteps(steps, state: state, pathPrefix: "\(path).\(branch)")
    }

    private func waitUntil(_ params: [String: JSONValue], state: AutomationPlanState) throws {
        let condition = try conditionValue(in: params)
        let timeoutMs = int("timeoutMs", in: params) ?? 5_000
        let intervalMs = int("intervalMs", in: params) ?? 150
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
        var attempts = 0
        while true {
            attempts += 1
            if try evaluate(condition: condition, state: state) {
                state.record(.object([
                    "op": .string("wait_until"),
                    "success": .bool(true),
                    "attempts": .int(attempts)
                ]))
                return
            }
            if Date() >= deadline {
                throw AutomationPlanError.executionFailed("wait_until timed out after \(attempts) attempts")
            }
            sleep(milliseconds: intervalMs)
        }
    }

    private func repeatUntil(_ params: [String: JSONValue], state: AutomationPlanState, path: String) throws {
        let condition = try conditionValue(in: params)
        let maxIterations = int("maxIterations", in: params)
        let timeoutMs = int("timeoutMs", in: params)
        guard maxIterations != nil || timeoutMs != nil else {
            throw AutomationPlanError.invalidParams("repeat_until requires maxIterations or timeoutMs")
        }
        let deadline = timeoutMs.map { Date().addingTimeInterval(Double($0) / 1_000) }
        var attempts = 0
        let traceIndex = state.trace.count
        while true {
            attempts += 1
            if try evaluate(condition: condition, state: state) {
                state.record(.object([
                    "op": .string("repeat_until"),
                    "success": .bool(true),
                    "attempts": .int(attempts)
                ]), at: traceIndex)
                return
            }
            if let maxIterations, attempts >= maxIterations {
                throw AutomationPlanError.executionFailed("repeat_until exceeded maxIterations \(maxIterations)")
            }
            if let deadline, Date() >= deadline {
                throw AutomationPlanError.executionFailed("repeat_until timed out after \(attempts) attempts")
            }
            try runSteps(stepArray(in: params, key: "do"), state: state, pathPrefix: "\(path).do")
        }
    }

    private func assertion(_ params: [String: JSONValue], state: AutomationPlanState) throws {
        let condition = try conditionValue(in: params)
        guard try evaluate(condition: condition, state: state) else {
            throw AutomationPlanError.executionFailed("assertion failed")
        }
        state.record(.object([
            "op": .string("assert"),
            "success": .bool(true)
        ]))
    }

    private func evaluate(condition: JSONValue, state: AutomationPlanState) throws -> Bool {
        guard case let .object(object) = condition, object.count == 1, let (op, rawParams) = object.first else {
            throw AutomationPlanError.invalidParams("condition must be an object with one predicate")
        }
        let params: [String: JSONValue]
        if case let .object(rawObject) = rawParams {
            params = state.resolved(rawObject)
        } else {
            throw AutomationPlanError.invalidParams("\(op) condition must be an object")
        }

        switch op {
        case "exists":
            let resolution = try resolveValue(params, state: state)
            guard case let .array(candidates)? = resolution["candidates"] else {
                return false
            }
            return !candidates.isEmpty
        case "not_exists":
            let resolution = try resolveValue(params, state: state)
            guard case let .array(candidates)? = resolution["candidates"] else {
                return true
            }
            return candidates.isEmpty
        case "unique":
            return try resolveValue(params, state: state)["status"] == .string("unique")
        case "changed_since":
            let snapshotID = try string("snapshotId", in: params)
            let response = commandHandler(JSONRPCRequest(
                id: .string("plan.condition.changed_since"),
                method: "changed_since",
                params: .object(["snapshotId": .string(snapshotID)])
            ))
            let result = try responseResult(response)
            return result["changed"] == .bool(true)
        default:
            throw AutomationPlanError.invalidParams("unknown condition: \(op)")
        }
    }

    private func resolveValue(_ params: [String: JSONValue], state: AutomationPlanState) throws -> JSONValue {
        try resultValue("resolution", in: resolveResponse(params, state: state))
    }

    private func resolveResponse(_ params: [String: JSONValue], state: AutomationPlanState) throws -> JSONRPCResponse {
        let locator = try locatorValue(in: params)
        let response = commandHandler(JSONRPCRequest(
            id: .string("plan.resolve"),
            method: "resolve",
            params: .object([
                "app": .string(try app(in: params, state: state)),
                "locator": locator
            ])
        ))
        _ = try responseResult(response)
        return response
    }

    private func actionParams(
        op: String,
        params: [String: JSONValue],
        state: AutomationPlanState
    ) throws -> [String: JSONValue] {
        switch op {
        case "click":
            return ["target": try actionTargetValue(in: params, state: state)]
        case "perform_action":
            return [
                "target": try actionTargetValue(in: params, state: state),
                "action": .string(try string("action", in: params))
            ]
        case "set_value":
            return [
                "target": try actionTargetValue(in: params, state: state),
                "value": .string(try string("value", in: params))
            ]
        case "type_text":
            return [
                "app": .string(try app(in: params, state: state)),
                "text": .string(try string("text", in: params))
            ]
        case "press_key":
            return [
                "app": .string(try app(in: params, state: state)),
                "key": .string(try string("key", in: params))
            ]
        default:
            throw AutomationPlanError.invalidParams("unsupported action operation: \(op)")
        }
    }

    private func targetString(from target: JSONValue?, state: AutomationPlanState) throws -> String {
        guard let target = target else {
            throw AutomationPlanError.invalidParams("action requires target")
        }
        if case let .string(handle) = target {
            return handle
        }
        guard case let .object(targetObject) = target else {
            throw AutomationPlanError.invalidParams("target must be a handle string or object")
        }
        let response = try resolveResponse(targetObject, state: state)
        let resolution = try resultValue("resolution", in: response)
        guard resolution["status"] == .string("unique"),
              case let .string(handle)? = resolution["best"]?["handle"] else {
            throw unresolvedTargetError(target: .object(targetObject), resolution: resolution)
        }
        return handle
    }

    private func actionTargetValue(in params: [String: JSONValue], state: AutomationPlanState) throws -> JSONValue {
        let target = try targetValue(in: params, state: state)
        guard case let .object(targetObject) = target, targetObject["locator"] != nil else {
            return target
        }
        return .string(try targetString(from: target, state: state))
    }

    private func targetValue(in params: [String: JSONValue], state: AutomationPlanState) throws -> JSONValue {
        guard let rawTarget = params["target"] else {
            throw AutomationPlanError.invalidParams("action requires target")
        }
        let resolvedTarget = state.resolved(rawTarget)
        if case .string = resolvedTarget {
            return resolvedTarget
        }
        guard case var .object(object) = resolvedTarget else {
            throw AutomationPlanError.invalidParams("target must be a handle string or object")
        }
        if object["app"] == nil {
            object["app"] = .string(try app(in: params, state: state))
        }
        return .object(object)
    }

    private func unresolvedTargetError(target: JSONValue, resolution: JSONValue) -> AutomationPlanError {
        let status: String
        if case let .string(value)? = resolution["status"] {
            status = value
        } else {
            status = "unknown"
        }
        var details: [String: JSONValue] = [
            "target": target,
            "resolution": resolutionSummary(resolution)
        ]
        if case let .array(candidates)? = resolution["candidates"] {
            details["candidateCount"] = .int(candidates.count)
        }
        return .detailedExecutionFailed("Locator did not resolve uniquely: \(status)", details: details)
    }

    private func resolutionSummary(_ resolution: JSONValue) -> JSONValue {
        guard case let .object(object) = resolution else {
            return resolution
        }
        var summary = object
        if case let .array(candidates)? = object["candidates"] {
            summary["candidateCount"] = .int(candidates.count)
        } else {
            summary["candidateCount"] = .int(0)
        }
        return .object(summary)
    }

    private func locatorValue(in params: [String: JSONValue]) throws -> JSONValue {
        if let locator = params["locator"] {
            return locator
        }
        if let target = params["target"],
           case let .object(object) = target,
           let locator = object["locator"] {
            return locator
        }
        throw AutomationPlanError.invalidParams("locator is required")
    }

    private func conditionValue(in params: [String: JSONValue]) throws -> JSONValue {
        guard let condition = params["condition"] else {
            throw AutomationPlanError.invalidParams("condition is required")
        }
        return condition
    }

    private func app(in params: [String: JSONValue], state: AutomationPlanState) throws -> String {
        if let value = try optionalString("app", in: params) {
            return value
        }
        if let app = state.context.app {
            return app
        }
        throw AutomationPlanError.invalidParams("app is required")
    }

    private func bindOutput(_ params: [String: JSONValue], value: JSONValue, state: AutomationPlanState) {
        guard case let .string(name)? = params["as"], !name.isEmpty else {
            return
        }
        state.outputs[name] = value
    }

    private func resultValue(_ key: String, in response: JSONRPCResponse) throws -> JSONValue {
        try responseResult(response)[key] ?? .null
    }

    private func responseResult(_ response: JSONRPCResponse) throws -> [String: JSONValue] {
        if let error = response.error {
            throw AutomationPlanError.executionFailed(error.message)
        }
        guard let result = response.result else {
            throw AutomationPlanError.executionFailed("missing command result")
        }
        return result
    }

    private func stepArray(
        in object: [String: JSONValue],
        key: String,
        allowMissing: Bool = false
    ) throws -> [JSONValue] {
        guard let value = object[key] else {
            if allowMissing {
                return []
            }
            throw AutomationPlanError.invalidParams("\(key) is required")
        }
        guard case let .array(steps) = value else {
            throw AutomationPlanError.invalidParams("\(key) must be an array")
        }
        return steps
    }

    private func sleep(milliseconds: Int) {
        guard milliseconds > 0 else {
            return
        }
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1_000)
    }
}

private final class AutomationPlanState {
    let context: AutomationPlanContext
    var trace: [JSONValue] = []
    var outputs: [String: JSONValue] = [:]

    init(context: AutomationPlanContext) {
        self.context = context
    }

    func record(_ value: JSONValue, at index: Int? = nil) {
        if let index, trace.indices.contains(index) || index == trace.endIndex {
            trace.insert(value, at: index)
        } else {
            trace.append(value)
        }
    }

    func result(success: Bool, error: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "success": .bool(success),
            "dryRun": .bool(context.dryRun),
            "trace": .array(trace),
            "outputs": .object(resultOutputs())
        ]
        if let error {
            object["error"] = .string(error)
        }
        return .object(object)
    }

    private func resultOutputs() -> [String: JSONValue] {
        switch context.outputMode {
        case .compact:
            return outputs.mapValues(compactResultValue(_:))
        case .full:
            return outputs
        case .none:
            return [:]
        }
    }

    private func compactResultValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(object):
            if let compactSnapshot = compactSnapshotValue(object) {
                return .object(compactSnapshot)
            }
            return .object(object.mapValues(compactResultValue(_:)))
        case let .array(values):
            return .array(values.map(compactResultValue(_:)))
        case .string, .int, .double, .bool, .null:
            return value
        }
    }

    private func compactSnapshotValue(_ object: [String: JSONValue]) -> [String: JSONValue]? {
        guard let id = object["id"],
              let app = object["app"],
              case let .array(nodes)? = object["indexedNodes"] else {
            return nil
        }
        var compact: [String: JSONValue] = [
            "id": id,
            "app": app,
            "indexedNodeCount": .int(nodes.count)
        ]
        let truncatedCount = nodes.reduce(0) { count, node in
            node["truncationReason"] != nil && node["truncationReason"] != .null ? count + 1 : count
        }
        if truncatedCount > 0 {
            compact["truncatedNodeCount"] = .int(truncatedCount)
        }
        if let screenshot = object["screenshot"], screenshot != .null {
            compact["screenshot"] = compactScreenshotValue(screenshot)
        }
        return compact
    }

    private func compactScreenshotValue(_ screenshot: JSONValue) -> JSONValue {
        guard case let .object(object) = screenshot else {
            return screenshot
        }
        var compact: [String: JSONValue] = [:]
        for key in ["mediaType", "width", "height", "contentTransport"] {
            if let value = object[key] {
                compact[key] = value
            }
        }
        return .object(compact)
    }

    func resolved(_ object: [String: JSONValue]) -> [String: JSONValue] {
        object.mapValues(resolved(_:))
    }

    func resolved(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .string(string):
            guard string.hasPrefix("$") else {
                return value
            }
            return referenceValue(String(string.dropFirst())) ?? value
        case let .array(values):
            return .array(values.map(resolved(_:)))
        case let .object(object):
            return .object(object.mapValues(resolved(_:)))
        case .int, .double, .bool, .null:
            return value
        }
    }

    private func referenceValue(_ reference: String) -> JSONValue? {
        let parts = reference.split(separator: ".").map(String.init)
        guard let first = parts.first else {
            return nil
        }
        let root: JSONValue?
        if first == "args" {
            root = context.args
        } else {
            root = outputs[first]
        }
        guard var current = root else {
            return nil
        }
        for part in parts.dropFirst() {
            if let index = Int(part) {
                current = current[index] ?? .null
            } else {
                current = current[part] ?? .null
            }
        }
        return current
    }
}

private struct AutomationPlanContext {
    let app: String?
    let args: JSONValue
    let dryRun: Bool
    let outputMode: AutomationPlanOutputMode
}

private enum AutomationPlanOutputMode {
    case compact
    case full
    case none
}

private func bool(_ key: String, in object: [String: JSONValue]) -> Bool? {
    guard case let .bool(value) = object[key] else {
        return nil
    }
    return value
}

private func int(_ key: String, in object: [String: JSONValue]) -> Int? {
    guard case let .int(value) = object[key] else {
        return nil
    }
    return value
}

private func string(_ key: String, in object: [String: JSONValue]) throws -> String {
    guard case let .string(value) = object[key] else {
        throw AutomationPlanError.invalidParams("\(key) must be a string")
    }
    return value
}

private func optionalString(_ key: String, in object: [String: JSONValue]) throws -> String? {
    guard let value = object[key], value != .null else {
        return nil
    }
    guard case let .string(string) = value else {
        throw AutomationPlanError.invalidParams("\(key) must be a string")
    }
    return string
}

private func string(at path: [String], in value: JSONValue) throws -> String {
    var current = value
    for key in path {
        guard let next = current[key] else {
            throw AutomationPlanError.executionFailed("missing value at \(path.joined(separator: "."))")
        }
        current = next
    }
    guard case let .string(string) = current else {
        throw AutomationPlanError.executionFailed("\(path.joined(separator: ".")) must be a string")
    }
    return string
}
