import Foundation

public enum AxnRunError: Error, CustomStringConvertible {
    case invalidParams(String)

    public var description: String {
        switch self {
        case let .invalidParams(message):
            return message
        }
    }
}

public struct AxnRunner {
    public typealias CommandHandler = (JSONRPCRequest) -> JSONRPCResponse
    public typealias ActionRecorder = (JSONRPCRequest, JSONRPCResponse) -> Void
    public typealias SnapshotProvider = RecordedFactEvaluator.SnapshotProvider
    public typealias ParameterSourceResolver = (URL) throws -> String?
    public typealias ActiveSecretRedactorProvider = @Sendable () -> ActiveSecretRedactor

    private static let redactedSecretValue = "<redacted: contains-secret>"
    private let commandHandler: CommandHandler
    private let factEvaluator: RecordedFactEvaluator?
    private let snapshotProvider: SnapshotProvider?
    private let changePollIntervalMs: Int
    private let changeTimeoutMs: Int
    private let parameterSourceResolvers: [String: ParameterSourceResolver]
    private let actionRecorder: ActionRecorder?
    private let activeSecretRedactorProvider: ActiveSecretRedactorProvider

    public init(
        commandHandler: @escaping CommandHandler,
        snapshotProvider: SnapshotProvider? = nil,
        changePollIntervalMs: Int = 100,
        changeTimeoutMs: Int = 5_000,
        parameterSourceResolvers: [String: ParameterSourceResolver] = AxnRunner.defaultParameterSourceResolvers(),
        actionRecorder: ActionRecorder? = nil,
        activeSecretRedactorProvider: @escaping ActiveSecretRedactorProvider = { ActiveSecretRedactor() }
    ) {
        self.commandHandler = commandHandler
        self.snapshotProvider = snapshotProvider
        self.factEvaluator = snapshotProvider.map(RecordedFactEvaluator.init(snapshotProvider:))
        self.changePollIntervalMs = max(0, changePollIntervalMs)
        self.changeTimeoutMs = max(0, changeTimeoutMs)
        self.parameterSourceResolvers = parameterSourceResolvers
        self.actionRecorder = actionRecorder
        self.activeSecretRedactorProvider = activeSecretRedactorProvider
    }

    public func run(params: [String: JSONValue]) throws -> JSONValue {
        let axn = try axnValue(from: params)
        let preparedRun = try prepareRun(axn, callerArgValues: callerArgValues(in: params))
        let dryRun = bool("dryRun", in: params) ?? bool("dryRun", in: axn.unknownTopLevelFields) ?? false
        let continueOnError = bool("continueOnError", in: params) ?? bool("continueOnError", in: axn.unknownTopLevelFields) ?? false

        var trace: [JSONValue] = []
        var facts: [String: RecordedFact] = [:]
        var success = true

        for action in preparedRun.actions {
            let record = runAction(
                action.action,
                index: action.index,
                dryRun: dryRun,
                secretTaintedFields: action.secretTaintedFields,
                facts: &facts
            )
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

    public func debugSession(
        params: [String: JSONValue],
        breakpoints: Set<String> = []
    ) throws -> AxnDebugSession {
        let axn = try axnValue(from: params)
        let preparedRun = try prepareRun(axn, callerArgValues: callerArgValues(in: params))
        let dryRun = bool("dryRun", in: params) ?? bool("dryRun", in: axn.unknownTopLevelFields) ?? false
        return AxnDebugSession(
            executor: self,
            actions: preparedRun.actions,
            dryRun: dryRun,
            breakpoints: breakpoints,
            documentID: optionalString("documentId", in: params),
            label: optionalString("label", in: params)
        )
    }

    func debugRunAction(
        _ action: PreparedAxnAction,
        dryRun: Bool,
        facts: inout [String: RecordedFact]
    ) -> JSONValue {
        runAction(
            action.action,
            index: action.index,
            dryRun: dryRun,
            secretTaintedFields: action.secretTaintedFields,
            facts: &facts
        )
    }

    func debugPauseSnapshot(for action: AxnAction, reason: String) -> JSONValue? {
        guard let snapshotProvider,
              let app = debugSnapshotApp(in: action.jsonValue)
        else {
            return nil
        }

        do {
            let snapshot = try snapshotProvider(app)
            let snapshotJSON = snapshot.jsonValue(
                includeTree: true,
                activeSecretRedactor: activeSecretRedactorProvider()
            )
            return .object([
                "reason": .string(reason),
                "snapshotId": .string(snapshot.id.rawValue),
                "app": snapshot.app.jsonValue,
                "observation": SnapshotObservationFormatter().observation(
                    from: snapshotJSON,
                    frames: false,
                    maxDepth: 2
                )
            ])
        } catch {
            return .object([
                "reason": .string(reason),
                "app": .string(app),
                "error": .string(String(describing: error))
            ])
        }
    }

    public static func defaultParameterSourceResolvers() -> [String: ParameterSourceResolver] {
        [
            "env": { source in
                guard let name = axnEnvironmentName(from: source), !name.isEmpty else {
                    throw AxnRunError.invalidParams("env source requires a variable name")
                }
                return ProcessInfo.processInfo.environment[name]
            },
            "op": { source in
                try OnePasswordCLI().read(reference: source.absoluteString)
            }
        ]
    }

    private func axnValue(from params: [String: JSONValue]) throws -> Axn {
        do {
            if case let .string(path)? = params["path"] {
                var axn = try Axn(source: String(contentsOfFile: path, encoding: .utf8))
                if let appendedActions = params["actions"] {
                    axn.blocks.append(contentsOf: try blocks(fromActionsValue: appendedActions))
                }
                return axn
            }
            if params["actions"] != nil {
                return try Axn(jsonValue: .object(params))
            }
            throw AxnRunError.invalidParams("run requires actions or path")
        } catch let error as AxnRunError {
            throw error
        } catch let error as AxnParseError {
            throw AxnRunError.invalidParams(error.description)
        }
    }

    public static func parseSource(_ source: String) throws -> JSONValue {
        do {
            return try Axn(source: source).jsonValue
        } catch let error as AxnParseError {
            throw AxnRunError.invalidParams(error.description)
        }
    }

    private func blocks(fromActionsValue value: JSONValue) throws -> [AxnBlock] {
        guard case let .array(actions) = value else {
            throw AxnRunError.invalidParams("actions must be an array")
        }
        return try actions.enumerated().map { index, value in
            guard case let .object(object) = value else {
                throw AxnRunError.invalidParams("actions[\(index)] must be an object")
            }
            if object["tool"] == nil, object["note"] != nil {
                return .note(AxnNote(fields: object))
            }
            return .action(AxnAction(fields: object))
        }
    }

    private func prepareRun(
        _ axn: Axn,
        callerArgValues: [String: JSONValue]
    ) throws -> PreparedAxnRun {
        let resolved = try AxnArgumentResolver(sourceResolvers: parameterSourceResolvers)
            .resolve(axn.args, callerArgValues: callerArgValues)
        let substituted = try substituteParameters(in: axn.blocks, resolved: resolved)
        return PreparedAxnRun(axn: axn, actions: substituted)
    }

    private func callerArgValues(in params: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let value = params["argValues"], value != .null else {
            return [:]
        }
        guard case let .object(object) = value else {
            throw AxnRunError.invalidParams("argValues must be an object")
        }
        return object
    }

    private func substituteParameters(
        in blocks: [AxnBlock],
        resolved: [String: ResolvedAxnArgument]
    ) throws -> [PreparedAxnAction] {
        var actions: [PreparedAxnAction] = []

        for (index, block) in blocks.enumerated() {
            guard case var .action(action) = block else {
                continue
            }

            try rejectUnsupportedReferences(in: action.fields, actionIndex: index)

            var secretTaintedFields: Set<String> = []
            for field in AxnArgumentReferenceSyntax.substitutableStringFields {
                guard let fieldValue = action.fields[field] else {
                    continue
                }
                guard case let .string(template) = fieldValue else {
                    if AxnArgumentReferenceSyntax.containsReferenceSyntax(fieldValue) {
                        throw AxnRunError.invalidParams("parameter references are only supported in string value fields: actions[\(index)].\(field)")
                    }
                    continue
                }
                let result = try AxnArgumentReferenceSyntax.substituteReferences(in: template, resolved: resolved)
                action.fields[field] = .string(result.value)
                if result.containsSecret {
                    secretTaintedFields.insert(field)
                }
            }

            actions.append(PreparedAxnAction(index: index, action: action, secretTaintedFields: secretTaintedFields))
        }

        return actions
    }

    private func rejectUnsupportedReferences(in object: [String: JSONValue], actionIndex: Int) throws {
        for (key, value) in object where !AxnArgumentReferenceSyntax.substitutableStringFields.contains(key) {
            if AxnArgumentReferenceSyntax.containsReferenceSyntax(value) {
                throw AxnRunError.invalidParams("parameter references are only supported in string value fields: actions[\(actionIndex)].\(key)")
            }
        }
    }

    private func runAction(
        _ action: AxnAction,
        index: Int,
        dryRun: Bool,
        secretTaintedFields: Set<String>,
        facts: inout [String: RecordedFact]
    ) -> JSONValue {
        do {
            var object = action.fields
            let actionID = action.id
            let requiredFactIDs = try requiredFacts(in: object)
            let expectedFacts = try expectedFacts(in: object)
            let changeBaselines = try changedBaselines(for: expectedFacts)

            try verifyRequiredFacts(requiredFactIDs, facts: facts)

            guard case let .string(tool)? = object.removeValue(forKey: "tool"), !tool.isEmpty else {
                throw AxnRunError.invalidParams("actions[\(index)] requires tool")
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
                record["params"] = .object(redactingSecrets(in: object, secretTaintedFields: secretTaintedFields))
                return .object(record)
            }

            let response = dispatchPrimitive(
                object,
                index: index,
                tool: tool,
                method: method,
                secretTaintedFields: secretTaintedFields
            )
            if let error = response.error {
                record["success"] = .bool(false)
                record["error"] = traceError(error.message, hasSecretTaint: !secretTaintedFields.isEmpty)
                return .object(record)
            }
            if primitiveActionSucceeded(in: response.result) == false {
                record["success"] = .bool(false)
                record["result"] = traceResult(method: method, result: response.result ?? [:], hasSecretTaint: !secretTaintedFields.isEmpty)
                record["error"] = traceError(
                    primitiveActionFailureMessage(in: response.result) ?? "primitive action reported failure",
                    hasSecretTaint: !secretTaintedFields.isEmpty
                )
                return .object(record)
            }
            try verifyExpectedFacts(expectedFacts, changeBaselines: changeBaselines, facts: &facts)
            record["result"] = traceResult(method: method, result: response.result ?? [:], hasSecretTaint: !secretTaintedFields.isEmpty)
            return .object(record)
        } catch let error as RecordedFactError {
            var record: [String: JSONValue] = [
                "index": .int(index),
                "success": .bool(false),
                "error": .string(error.description)
            ]
            if let actionID = action.id {
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
        method: String,
        secretTaintedFields: Set<String>
    ) -> JSONRPCResponse {
        let request = JSONRPCRequest(
            id: .string("run.\(index).\(tool)"),
            method: method,
            params: .object(object)
        )
        let response = commandHandler(request)
        if let actionRecorder {
            let recordedRequest = JSONRPCRequest(
                id: request.id,
                method: request.method,
                params: .object(redactingSecrets(in: object, secretTaintedFields: secretTaintedFields))
            )
            actionRecorder(
                recordedRequest,
                redactingSecretError(in: response, hasSecretTaint: !secretTaintedFields.isEmpty)
            )
        }
        return response
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
            throw AxnRunError.invalidParams("requires must be an array of fact ids")
        }
        return try values.map { value in
            guard case let .string(id) = value, !id.isEmpty else {
                throw AxnRunError.invalidParams("requires must be an array of fact ids")
            }
            return id
        }
    }

    private func expectedFacts(in object: [String: JSONValue]) throws -> [RecordedFact] {
        guard let value = object["expects"], value != .null else {
            return []
        }
        guard case let .array(values) = value else {
            throw AxnRunError.invalidParams("expects must be an array of facts")
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

    private func debugSnapshotApp(in action: JSONValue) -> String? {
        guard case let .object(object) = action else {
            return nil
        }
        if let app = optionalString("app", in: object) {
            return app
        }
        for key in ["target", "from", "to", "locator"] {
            if let app = debugSnapshotApp(inNestedValue: object[key]) {
                return app
            }
        }
        return nil
    }

    private func debugSnapshotApp(inNestedValue value: JSONValue?) -> String? {
        guard let value else {
            return nil
        }
        switch value {
        case let .object(object):
            if let app = optionalString("app", in: object) {
                return app
            }
            for nested in object.values {
                if let app = debugSnapshotApp(inNestedValue: nested) {
                    return app
                }
            }
            return nil
        case let .array(values):
            for nested in values {
                if let app = debugSnapshotApp(inNestedValue: nested) {
                    return app
                }
            }
            return nil
        case .string, .int, .double, .bool, .null:
            return nil
        }
    }

    private func commandMethod(for tool: String) throws -> String {
        switch tool {
        case "look", "find", "wait_for_value", "click", "scroll", "drag", "invoke", "type", "keyboard":
            return tool
        default:
            throw AxnRunError.invalidParams("unknown axn tool: \(tool)")
        }
    }

    private func redactingSecrets(
        in object: [String: JSONValue],
        secretTaintedFields: Set<String>
    ) -> [String: JSONValue] {
        guard !secretTaintedFields.isEmpty else {
            return object
        }
        var redacted = object
        for field in secretTaintedFields {
            redacted[field] = .string(Self.redactedSecretValue)
        }
        return redacted
    }

    private func traceResult(
        method: String,
        result: [String: JSONValue],
        hasSecretTaint: Bool
    ) -> JSONValue {
        hasSecretTaint ? .string(Self.redactedSecretValue) : resultSummary(method: method, result: result)
    }

    private func traceError(_ message: String, hasSecretTaint: Bool) -> JSONValue {
        .string(hasSecretTaint ? Self.redactedSecretValue : message)
    }

    private func redactingSecretError(
        in response: JSONRPCResponse,
        hasSecretTaint: Bool
    ) -> JSONRPCResponse {
        guard hasSecretTaint, response.error != nil else {
            return response
        }
        return JSONRPCResponse(id: response.id, error: .invalidParams(Self.redactedSecretValue))
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
        case "wait_for_value":
            return result["wait"] ?? .object(result)
        default:
            return result["action"] ?? .object(result)
        }
    }

    private func primitiveActionSucceeded(in result: [String: JSONValue]?) -> Bool? {
        guard let result else {
            return nil
        }
        return bool("success", in: objectValue(result["action"]) ?? objectValue(result["wait"]) ?? result)
    }

    private func primitiveActionFailureMessage(in result: [String: JSONValue]?) -> String? {
        guard let result else {
            return nil
        }
        let action = objectValue(result["action"]) ?? objectValue(result["wait"]) ?? result
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
}
