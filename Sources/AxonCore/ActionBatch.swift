import Foundation

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
    public typealias ActionRecorder = (JSONRPCRequest, JSONRPCResponse) -> Void
    public typealias SnapshotProvider = RecordedFactEvaluator.SnapshotProvider
    public typealias ParameterSourceResolver = (URL) throws -> String?
    public typealias ActiveSecretRedactorProvider = @Sendable () -> ActiveSecretRedactor

    private static let redactedSecretValue = "<redacted: contains-secret>"
    private static let substitutableStringFields: Set<String> = ["value", "keys"]
    private static let parameterReferenceRegex = try! NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}"#
    )
    private static let anyParameterReferenceRegex = try! NSRegularExpression(
        pattern: #"\{\{[^}]*\}\}"#
    )

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
        parameterSourceResolvers: [String: ParameterSourceResolver] = ActionBatchExecutor.defaultParameterSourceResolvers(),
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
        let batch = try batchValue(from: params)
        guard case let .object(batchObject) = batch else {
            throw ActionBatchError.invalidParams("batch must be an object")
        }

        let preparedBatch = try prepareBatch(batchObject, callerArgValues: callerArgValues(in: params))
        let actions = try actionArray(in: preparedBatch.object)
        let dryRun = bool("dryRun", in: params) ?? bool("dryRun", in: batchObject) ?? false
        let continueOnError = bool("continueOnError", in: params) ?? bool("continueOnError", in: batchObject) ?? false

        var trace: [JSONValue] = []
        var facts: [String: RecordedFact] = [:]
        var success = true

        for (index, action) in actions.enumerated() {
            if isNoteBlock(action) {
                continue
            }
            let record = runAction(
                action,
                index: index,
                dryRun: dryRun,
                secretTaintedFields: preparedBatch.secretTaintedFieldsByAction[index] ?? [],
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
    ) throws -> ActionBatchDebugSession {
        let batch = try batchValue(from: params)
        guard case let .object(batchObject) = batch else {
            throw ActionBatchError.invalidParams("batch must be an object")
        }

        let preparedBatch = try prepareBatch(batchObject, callerArgValues: callerArgValues(in: params))
        let actions = try actionArray(in: preparedBatch.object)
        let dryRun = bool("dryRun", in: params) ?? bool("dryRun", in: batchObject) ?? false
        return ActionBatchDebugSession(
            executor: self,
            actions: actions,
            secretTaintedFieldsByAction: preparedBatch.secretTaintedFieldsByAction,
            dryRun: dryRun,
            breakpoints: breakpoints,
            documentID: optionalString("documentId", in: params),
            label: optionalString("label", in: params)
        )
    }

    func debugRunAction(
        _ action: JSONValue,
        index: Int,
        dryRun: Bool,
        secretTaintedFields: Set<String>,
        facts: inout [String: RecordedFact]
    ) -> JSONValue {
        runAction(
            action,
            index: index,
            dryRun: dryRun,
            secretTaintedFields: secretTaintedFields,
            facts: &facts
        )
    }

    func isExecutableDebugAction(_ action: JSONValue) -> Bool {
        !isNoteBlock(action)
    }

    func debugPauseSnapshot(for action: JSONValue, reason: String) -> JSONValue? {
        guard let snapshotProvider,
              let app = debugSnapshotApp(in: action)
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
                guard let name = envName(from: source), !name.isEmpty else {
                    throw ActionBatchError.invalidParams("env source requires a variable name")
                }
                return ProcessInfo.processInfo.environment[name]
            },
            "op": { source in
                try OnePasswordCLI().read(reference: source.absoluteString)
            }
        ]
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
        do {
            return try AxnDocumentCodec.parseSource(source)
        } catch let error as AxonRecipeError {
            throw ActionBatchError.invalidParams(error.description)
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

    private func prepareBatch(
        _ object: [String: JSONValue],
        callerArgValues: [String: JSONValue]
    ) throws -> PreparedActionBatch {
        let declarations = try ActionParameterDeclaration.parseList(object["args"])
        guard !declarations.isEmpty else {
            if let unknown = callerArgValues.keys.sorted().first {
                throw ActionBatchError.invalidParams("unknown arg: \(unknown)")
            }
            _ = try substituteParameters(in: actionArray(in: object), resolved: [:])
            return PreparedActionBatch(object: object, secretTaintedFieldsByAction: [:])
        }

        let resolved = try resolveParameters(declarations, callerArgValues: callerArgValues)
        let actions = try actionArray(in: object)
        let substituted = try substituteParameters(in: actions, resolved: resolved)

        var prepared = object
        prepared["actions"] = .array(substituted.actions)
        return PreparedActionBatch(object: prepared, secretTaintedFieldsByAction: substituted.secretTaintedFieldsByAction)
    }

    private func callerArgValues(in params: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let value = params["argValues"], value != .null else {
            return [:]
        }
        guard case let .object(object) = value else {
            throw ActionBatchError.invalidParams("argValues must be an object")
        }
        return object
    }

    private func resolveParameters(
        _ declarations: [ActionParameterDeclaration],
        callerArgValues: [String: JSONValue]
    ) throws -> [String: ResolvedActionParameter] {
        let declaredNames = Set(declarations.map(\.name))
        if let unknown = callerArgValues.keys.sorted().first(where: { !declaredNames.contains($0) }) {
            throw ActionBatchError.invalidParams("unknown arg: \(unknown)")
        }

        var resolved: [String: ResolvedActionParameter] = [:]
        for declaration in declarations {
            if declaration.source != nil, callerArgValues[declaration.name] != nil {
                throw ActionBatchError.invalidParams("caller arg cannot override sourced arg: \(declaration.name)")
            }

            let rawValue: JSONValue?
            if let callerValue = callerArgValues[declaration.name] {
                rawValue = callerValue
            } else if let source = declaration.source {
                rawValue = try resolveSource(source, for: declaration).map(JSONValue.string)
                    ?? declaration.defaultValue
            } else {
                rawValue = declaration.defaultValue
            }

            guard let rawValue else {
                throw ActionBatchError.invalidParams("missing required arg: \(declaration.name)")
            }

            resolved[declaration.name] = ResolvedActionParameter(
                value: try ActionParameterValueCoercer.stringValue(rawValue, type: declaration.type, name: declaration.name),
                isSecret: declaration.type == .secret
            )
        }
        return resolved
    }

    private func resolveSource(_ source: URL, for declaration: ActionParameterDeclaration) throws -> String? {
        guard let scheme = source.scheme, !scheme.isEmpty else {
            throw ActionBatchError.invalidParams("arg \(declaration.name) source requires a scheme")
        }
        guard let resolver = parameterSourceResolvers[scheme] else {
            throw ActionBatchError.invalidParams("unsupported source scheme for arg \(declaration.name): \(scheme)")
        }
        return try resolver(source)
    }

    private func substituteParameters(
        in actions: [JSONValue],
        resolved: [String: ResolvedActionParameter]
    ) throws -> (actions: [JSONValue], secretTaintedFieldsByAction: [Int: Set<String>]) {
        var substitutedActions: [JSONValue] = []
        var taintByAction: [Int: Set<String>] = [:]

        for (index, action) in actions.enumerated() {
            guard case var .object(object) = action else {
                substitutedActions.append(action)
                continue
            }

            if isNoteBlock(action) {
                substitutedActions.append(action)
                continue
            }

            try rejectUnsupportedReferences(in: object, actionIndex: index)

            var secretTaintedFields: Set<String> = []
            for field in Self.substitutableStringFields {
                guard let fieldValue = object[field] else {
                    continue
                }
                guard case let .string(template) = fieldValue else {
                    if containsReferenceSyntax(fieldValue) {
                        throw ActionBatchError.invalidParams("parameter references are only supported in string value fields: actions[\(index)].\(field)")
                    }
                    continue
                }
                let result = try substituteReferences(in: template, resolved: resolved)
                object[field] = .string(result.value)
                if result.containsSecret {
                    secretTaintedFields.insert(field)
                }
            }

            if !secretTaintedFields.isEmpty {
                taintByAction[index] = secretTaintedFields
            }
            substitutedActions.append(.object(object))
        }

        return (substitutedActions, taintByAction)
    }

    private func rejectUnsupportedReferences(in object: [String: JSONValue], actionIndex: Int) throws {
        for (key, value) in object where !Self.substitutableStringFields.contains(key) {
            if containsReferenceSyntax(value) {
                throw ActionBatchError.invalidParams("parameter references are only supported in string value fields: actions[\(actionIndex)].\(key)")
            }
        }
    }

    private func isNoteBlock(_ value: JSONValue) -> Bool {
        guard case let .object(object) = value, object["tool"] == nil else {
            return false
        }
        return object["note"] != nil
    }

    private func containsReferenceSyntax(_ value: JSONValue) -> Bool {
        switch value {
        case let .string(value):
            return value.contains("{{")
                || value.contains("}}")
                || Self.anyParameterReferenceRegex.firstMatch(
                    in: value,
                    range: NSRange(value.startIndex..<value.endIndex, in: value)
                ) != nil
        case let .array(values):
            return values.contains(where: containsReferenceSyntax)
        case let .object(object):
            return object.values.contains(where: containsReferenceSyntax)
        default:
            return false
        }
    }

    private func substituteReferences(
        in template: String,
        resolved: [String: ResolvedActionParameter]
    ) throws -> (value: String, containsSecret: Bool) {
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        let matches = Self.anyParameterReferenceRegex.matches(in: template, range: range)
        guard !matches.isEmpty else {
            if template.contains("{{") || template.contains("}}") {
                throw ActionBatchError.invalidParams("invalid arg reference syntax: \(template)")
            }
            return (template, false)
        }

        var output = ""
        var currentIndex = template.startIndex
        var containsSecret = false

        for match in matches {
            guard let matchRange = Range(match.range, in: template),
                  let name = parameterReferenceName(in: String(template[matchRange]))
            else {
                throw ActionBatchError.invalidParams("invalid arg reference syntax: \(template)")
            }
            let prefix = template[currentIndex..<matchRange.lowerBound]
            if prefix.contains("{{") || prefix.contains("}}") {
                throw ActionBatchError.invalidParams("invalid arg reference syntax: \(template)")
            }
            output += prefix
            guard let parameter = resolved[name] else {
                throw ActionBatchError.invalidParams("undeclared arg reference: \(name)")
            }
            output += parameter.value
            containsSecret = containsSecret || parameter.isSecret
            currentIndex = matchRange.upperBound
        }

        let suffix = template[currentIndex..<template.endIndex]
        if suffix.contains("{{") || suffix.contains("}}") {
            throw ActionBatchError.invalidParams("invalid arg reference syntax: \(template)")
        }
        output += suffix
        return (output, containsSecret)
    }

    private func parameterReferenceName(in token: String) -> String? {
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        guard let match = Self.parameterReferenceRegex.firstMatch(in: token, range: range),
              match.range == range,
              let nameRange = Range(match.range(at: 1), in: token)
        else {
            return nil
        }
        return String(token[nameRange])
    }

    private func runAction(
        _ action: JSONValue,
        index: Int,
        dryRun: Bool,
        secretTaintedFields: Set<String>,
        facts: inout [String: RecordedFact]
    ) -> JSONValue {
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
        method: String,
        secretTaintedFields: Set<String>
    ) -> JSONRPCResponse {
        let request = JSONRPCRequest(
            id: .string("batch.\(index).\(tool)"),
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
        case "look", "find", "click", "scroll", "drag", "invoke", "type", "keyboard":
            return tool
        default:
            throw ActionBatchError.invalidParams("unknown batch tool: \(tool)")
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

public final class ActionBatchDebugSession {
    public let id: String

    private let lock = NSRecursiveLock()
    private let executor: ActionBatchExecutor
    private let actions: [JSONValue]
    private let secretTaintedFieldsByAction: [Int: Set<String>]
    private let dryRun: Bool
    private var breakpoints: Set<String>
    private let documentID: String?
    private let label: String?
    private var facts: [String: RecordedFact] = [:]
    private var trace: [JSONValue] = []
    private var currentIndex: Int?
    private var lastActionID: String?
    private var pauseReason: String?
    private var pauseSnapshot: JSONValue?
    private var state: State

    public init(
        id: String = UUID().uuidString,
        executor: ActionBatchExecutor,
        actions: [JSONValue],
        secretTaintedFieldsByAction: [Int: Set<String>],
        dryRun: Bool,
        breakpoints: Set<String>,
        documentID: String? = nil,
        label: String? = nil
    ) {
        self.id = id
        self.executor = executor
        self.actions = actions
        self.secretTaintedFieldsByAction = secretTaintedFieldsByAction
        self.dryRun = dryRun
        self.breakpoints = breakpoints
        self.documentID = documentID
        self.label = label
        self.currentIndex = Self.nextExecutableIndex(in: actions, startingAt: 0, executor: executor)
        self.state = self.currentIndex == nil ? .completed : .paused
        self.pauseReason = self.currentIndex == nil ? nil : "start"
    }

    public func runUntilPause(before blockID: String?) {
        _ = runToBlock(blockID, reason: "pauseBefore")
    }

    @discardableResult
    public func runToBlock(_ blockID: String?) -> JSONValue {
        runToBlock(blockID, reason: "runTo")
    }

    @discardableResult
    private func runToBlock(_ blockID: String?, reason: String) -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        guard let blockID else {
            return status
        }
        while state == .paused, currentActionID != blockID {
            _ = step()
        }
        if state == .paused, currentActionID == blockID {
            capturePauseSnapshot(reason: reason)
        }
        return status
    }

    @discardableResult
    public func setBreakpoints(_ breakpoints: Set<String>) -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        self.breakpoints = breakpoints
        return status
    }

    @discardableResult
    public func step() -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        guard state == .paused, let index = currentIndex else {
            return status
        }
        pauseSnapshot = nil
        pauseReason = nil
        let record = executor.debugRunAction(
            actions[index],
            index: index,
            dryRun: dryRun,
            secretTaintedFields: secretTaintedFieldsByAction[index] ?? [],
            facts: &facts
        )
        trace.append(record)
        lastActionID = Self.actionID(in: actions[index])
        if record["success"] == .bool(false) {
            state = .failed
            capturePauseSnapshot(reason: "failure")
            return status
        }

        currentIndex = Self.nextExecutableIndex(in: actions, startingAt: index + 1, executor: executor)
        state = currentIndex == nil ? .completed : .paused
        pauseReason = state == .paused ? "step" : nil
        return status
    }

    @discardableResult
    public func continueUntilBreakpoint() -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        pauseSnapshot = nil
        pauseReason = nil
        while state == .paused {
            _ = step()
            guard state == .paused else {
                break
            }
            if let currentActionID, breakpoints.contains(currentActionID) {
                capturePauseSnapshot(reason: "breakpoint")
                break
            }
        }
        return status
    }

    @discardableResult
    public func retryFailedAction() -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        guard state == .failed, currentIndex != nil else {
            return status
        }
        state = .paused
        pauseReason = nil
        return step()
    }

    @discardableResult
    public func stop() -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        pauseSnapshot = nil
        state = .stopped
        return status
    }

    public var status: JSONValue {
        lock.lock()
        defer { lock.unlock() }
        var object: [String: JSONValue] = [
            "sessionId": .string(id),
            "state": .string(state.rawValue),
            "dryRun": .bool(dryRun),
            "trace": .array(trace),
            "breakpoints": .array(breakpoints.sorted().map(JSONValue.string)),
            "availableActions": .array(availableActions.map(JSONValue.string))
        ]
        if let currentIndex {
            object["currentIndex"] = .int(currentIndex)
        } else {
            object["currentIndex"] = .null
        }
        if let currentActionID {
            object["currentActionId"] = .string(currentActionID)
            object["cursorBlockId"] = .string(currentActionID)
        } else {
            object["currentActionId"] = .null
            object["cursorBlockId"] = .null
        }
        if let lastActionID {
            object["lastActionId"] = .string(lastActionID)
        } else {
            object["lastActionId"] = .null
        }
        if let pauseReason {
            object["pauseReason"] = .string(pauseReason)
        } else {
            object["pauseReason"] = .null
        }
        if let documentID {
            object["documentId"] = .string(documentID)
        }
        if let label {
            object["label"] = .string(label)
        }
        if let pauseSnapshot {
            object["pauseSnapshot"] = pauseSnapshot
        }
        return .object(object)
    }

    private var availableActions: [String] {
        switch state {
        case .paused:
            return ["resume", "runTo", "step", "setBreakpoints", "stop"]
        case .failed:
            return ["retry", "setBreakpoints", "stop"]
        case .completed, .stopped:
            return []
        }
    }

    private var currentActionID: String? {
        guard let currentIndex else {
            return nil
        }
        return Self.actionID(in: actions[currentIndex])
    }

    private func capturePauseSnapshot(reason: String) {
        pauseReason = reason
        guard let currentIndex else {
            pauseSnapshot = nil
            return
        }
        pauseSnapshot = executor.debugPauseSnapshot(for: actions[currentIndex], reason: reason)
    }

    private static func nextExecutableIndex(
        in actions: [JSONValue],
        startingAt start: Int,
        executor: ActionBatchExecutor
    ) -> Int? {
        var index = start
        while index < actions.count {
            if executor.isExecutableDebugAction(actions[index]) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func actionID(in action: JSONValue) -> String? {
        guard case let .object(object) = action,
              case let .string(id)? = object["id"],
              !id.isEmpty
        else {
            return nil
        }
        return id
    }

    private enum State: String {
        case paused
        case completed
        case failed
        case stopped
    }
}

private struct PreparedActionBatch {
    let object: [String: JSONValue]
    let secretTaintedFieldsByAction: [Int: Set<String>]
}

private enum ActionParameterType: String {
    case string
    case secret
    case number
    case date
    case email
    case path
}

private struct ActionParameterDeclaration {
    let name: String
    let type: ActionParameterType
    let defaultValue: JSONValue?
    let source: URL?

    static func parseList(_ value: JSONValue?) throws -> [ActionParameterDeclaration] {
        guard let value, value != .null else {
            return []
        }
        guard case let .array(values) = value else {
            throw ActionBatchError.invalidParams("args must be an array")
        }

        var seenNames: Set<String> = []
        return try values.enumerated().map { index, value in
            guard case let .object(object) = value else {
                throw ActionBatchError.invalidParams("args[\(index)] must be an object")
            }
            guard case let .string(name)? = object["name"], isValidName(name) else {
                throw ActionBatchError.invalidParams("args[\(index)] requires snake_case name")
            }
            guard seenNames.insert(name).inserted else {
                throw ActionBatchError.invalidParams("duplicate arg: \(name)")
            }
            guard case let .string(rawType)? = object["type"],
                  let type = ActionParameterType(rawValue: rawType)
            else {
                throw ActionBatchError.invalidParams("args[\(index)] requires type")
            }
            let defaultValue = object["default"]
            if type == .secret, defaultValue != nil, defaultValue != .null {
                throw ActionBatchError.invalidParams("secret arg cannot have default: \(name)")
            }
            let source: URL?
            if let sourceValue = object["source"], sourceValue != .null {
                guard case let .string(rawSource) = sourceValue,
                      let url = URL(string: rawSource),
                      url.scheme != nil
                else {
                    throw ActionBatchError.invalidParams("arg \(name) source must be a URL")
                }
                source = url
            } else {
                source = nil
            }
            return ActionParameterDeclaration(
                name: name,
                type: type,
                defaultValue: defaultValue == .null ? nil : defaultValue,
                source: source
            )
        }
    }

    private static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first >= "a",
              first <= "z"
        else {
            return false
        }
        return name.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "_"
        }
    }
}

private struct ResolvedActionParameter {
    let value: String
    let isSecret: Bool
}

private enum ActionParameterValueCoercer {
    static func stringValue(_ value: JSONValue, type: ActionParameterType, name: String) throws -> String {
        switch type {
        case .string, .secret, .path:
            return try scalarString(value, name: name)
        case .email:
            let string = try scalarString(value, name: name)
            guard isValidEmail(string) else {
                throw ActionBatchError.invalidParams("arg \(name) must be an email")
            }
            return string
        case .number:
            return try numberString(value, name: name)
        case .date:
            return try dateString(value, name: name)
        }
    }

    private static func scalarString(_ value: JSONValue, name: String) throws -> String {
        switch value {
        case let .string(value):
            return value
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .bool(value):
            return String(value)
        default:
            throw ActionBatchError.invalidParams("arg \(name) must be a scalar")
        }
    }

    private static func numberString(_ value: JSONValue, name: String) throws -> String {
        switch value {
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .string(value):
            guard Double(value) != nil else {
                throw ActionBatchError.invalidParams("arg \(name) must be a number")
            }
            return value
        default:
            throw ActionBatchError.invalidParams("arg \(name) must be a number")
        }
    }

    private static func dateString(_ value: JSONValue, name: String) throws -> String {
        let string = try scalarString(value, name: name)
        switch string {
        case "today":
            return isoDateString(Date())
        case "yesterday":
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            return isoDateString(yesterday)
        default:
            guard isISODate(string) else {
                throw ActionBatchError.invalidParams("arg \(name) must be an ISO date, today, or yesterday")
            }
            return string
        }
    }

    private static func isValidEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2
            && !parts[0].isEmpty
            && parts[1].contains(".")
            && !parts[1].hasPrefix(".")
            && !parts[1].hasSuffix(".")
    }

    private static func isISODate(_ value: String) -> Bool {
        guard value.count == 10 else {
            return false
        }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else {
            return false
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }

    private static func isoDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private func envName(from source: URL) -> String? {
    if let host = source.host, !host.isEmpty {
        return host
    }
    let path = source.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return path.isEmpty ? nil : path
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
