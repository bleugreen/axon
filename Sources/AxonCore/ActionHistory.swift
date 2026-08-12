import Foundation

public struct ActionHistoryRecord: Equatable, Sendable {
    public let id: String
    public let parentID: String?
    public let sessionID: String
    public let method: String
    public let params: [String: JSONValue]
    public let success: Bool
    public let error: String?
    /// What the action changed, as read at the dispatch seam. Absent for reads, for refused or
    /// failed dispatches, and wherever the target had no live element to observe.
    public let observation: ActionObservation?

    public init(
        id: String,
        parentID: String?,
        sessionID: String,
        method: String,
        params: [String: JSONValue],
        success: Bool,
        error: String?,
        observation: ActionObservation? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.sessionID = sessionID
        self.method = method
        self.params = params
        self.success = success
        self.error = error
        self.observation = observation
    }
}

public enum ActionHistoryError: Error, CustomStringConvertible, Equatable {
    case unknownRangeBoundary(label: String, id: String)
    case reversedRange(from: String, to: String)

    public var description: String {
        switch self {
        case let .unknownRangeBoundary(label, id):
            return "Unknown history range boundary: \(label) \(id)"
        case let .reversedRange(from, to):
            return "History range starts after it ends: from \(from) to \(to)"
        }
    }
}

public final class ActionHistoryStore: @unchecked Sendable {
    public static let shared = ActionHistoryStore()

    private let lock = NSLock()
    private var nextID = 1
    private var recordsBySession: [String: [ActionHistoryRecord]] = [:]
    private var lastRecordIDBySession: [String: String] = [:]
    private let maxRecordsPerSession: Int

    public init(maxRecordsPerSession: Int = 2_000) {
        self.maxRecordsPerSession = maxRecordsPerSession
    }

    public func context(for request: JSONRPCRequest) -> ActionHistoryContext {
        let sessionID = sessionID(in: request.params) ?? "default"
        return ActionHistoryContext(
            sessionID: sessionID,
            request: request.withParams(strippingSessionKeyFrom: request.params)
        )
    }

    public func record(
        request: JSONRPCRequest,
        response: JSONRPCResponse,
        sessionID: String,
        observation: ActionObservation? = nil,
        semanticTargetLocator: ((String, String) -> AXLocator?)? = nil,
        activeSecretRedactor: ActiveSecretRedactor = ActiveSecretRedactor(),
        deterministicRedactor: DeterministicRedactor = .standard
    ) {
        guard shouldRecord(method: request.method) else {
            return
        }
        let replayableRequest = JSONRPCRequest(
            id: request.id,
            method: request.method,
            params: attachingReplayEvidenceTo(
                request.params,
                semanticTargetLocator: semanticTargetLocator
            )
        )
        let strippedRequest = replayableRequest.withParams(strippingSensitiveHistoryKeysFrom: replayableRequest.params)
        let historyRequest = strippedRequest.withParams(
            redactingSensitiveHistoryValuesFrom: strippedRequest.params,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor
        )
        let params: [String: JSONValue]
        if case let .object(object)? = historyRequest.params {
            params = object
        } else {
            params = [:]
        }
        let success = response.error == nil
        let error = response.error?.message

        lock.lock()
        defer { lock.unlock() }

        let id = "c\(nextID)"
        nextID += 1
        let parentID = lastRecordIDBySession[sessionID]
        let record = ActionHistoryRecord(
            id: id,
            parentID: parentID,
            sessionID: sessionID,
            method: request.method,
            params: params,
            success: success,
            error: error,
            // The observation holds live UI text and is redacted exactly as params are. The
            // input-echo verdict inside it was already decided against the unredacted request,
            // so redacting here cannot weaken the exclusion it feeds.
            observation: observation?.redacted(
                activeSecretRedactor: activeSecretRedactor,
                deterministicRedactor: deterministicRedactor
            )
        )
        var records = recordsBySession[sessionID] ?? []
        records.append(record)
        if records.count > maxRecordsPerSession {
            records.removeFirst(records.count - maxRecordsPerSession)
        }
        recordsBySession[sessionID] = records
        lastRecordIDBySession[sessionID] = id
    }

    public func records(sessionID: String) -> [ActionHistoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsBySession[sessionID] ?? []
    }

    public func exportScript(
        sessionID: String,
        includeReads: Bool = false,
        from: String? = nil,
        to: String? = nil,
        arguments: [AxnArgument] = []
    ) throws -> ActionHistoryExport {
        let arguments = try AxnArgument.validated(arguments)
        let records = try slicedRecords(sessionID: sessionID, from: from, to: to)
        // Gathered across the whole export before any step is compiled: an echo of typed text can
        // surface a step or two later, and every one of these strings is a parameterization
        // candidate no step may assert.
        let workflowInputs = records.flatMap { $0.observation?.inputs ?? [] }
        var ordinal = 0
        let actions = records.compactMap { record -> [String: JSONValue]? in
            guard let object = actionObject(
                for: record,
                includeReads: includeReads,
                ordinal: ordinal + 1,
                workflowInputs: workflowInputs
            ) else {
                return nil
            }
            ordinal += 1
            return object
        }
        var document: [String: JSONValue] = [
            "version": .int(2),
            "actions": .array(actions.map(JSONValue.object))
        ]
        if !arguments.isEmpty {
            document["args"] = .array(arguments.map(\.jsonValue))
        }
        let script = try AxnDocumentCodec.yamlString(from: .object(document))
        return ActionHistoryExport(script: script, actionCount: actions.count, recordCount: records.count)
    }

    private func attachingReplayEvidenceTo(
        _ params: JSONValue?,
        semanticTargetLocator: ((String, String) -> AXLocator?)?
    ) -> JSONValue? {
        guard case var .object(object)? = params, let semanticTargetLocator else { return params }
        for key in ["target", "from", "to"] {
            guard case var .object(target)? = object[key],
                  case let .string(app)? = target["app"],
                  case let .string(name)? = target["name"],
                  target["locator"] == nil,
                  let locator = semanticTargetLocator(app, name)
            else {
                continue
            }
            target["locator"] = locator.jsonValue
            object[key] = .object(target)
        }
        return .object(object)
    }

    private func slicedRecords(sessionID: String, from: String?, to: String?) throws -> [ActionHistoryRecord] {
        let records = self.records(sessionID: sessionID)
        if records.isEmpty {
            if let from {
                throw ActionHistoryError.unknownRangeBoundary(label: "from", id: from)
            }
            if let to {
                throw ActionHistoryError.unknownRangeBoundary(label: "to", id: to)
            }
            return []
        }

        let start: Int
        if let from {
            guard let index = records.firstIndex(where: { $0.id == from }) else {
                throw ActionHistoryError.unknownRangeBoundary(label: "from", id: from)
            }
            start = index
        } else {
            start = records.startIndex
        }

        let end: Int
        if let to {
            guard let index = records.firstIndex(where: { $0.id == to }) else {
                throw ActionHistoryError.unknownRangeBoundary(label: "to", id: to)
            }
            end = index
        } else {
            end = records.index(before: records.endIndex)
        }

        guard start <= end else {
            throw ActionHistoryError.reversedRange(from: from ?? records[start].id, to: to ?? records[end].id)
        }
        return Array(records[start...end])
    }

    /// Renders one history record as a saved `.axn` step.
    ///
    /// The ordinal is the step's identity, not decoration: derived fact ids hang off it, and
    /// `requires` in a later step would name it.
    private func actionObject(
        for record: ActionHistoryRecord,
        includeReads: Bool,
        ordinal: Int,
        workflowInputs: [String]
    ) -> [String: JSONValue]? {
        guard let tool = toolName(for: record.method) else {
            return nil
        }
        if !includeReads && !isReplayableAction(record.method) {
            return nil
        }
        let actionID = String(format: "a%03d", ordinal)
        var object: [String: JSONValue] = ["tool": .string(tool), "id": .string(actionID)]
        for (key, value) in record.params where key != "tool" {
            object[key] = value
        }

        if let observation = record.observation {
            attachReplayEvidence("target", in: &object, from: observation.targetBefore)
            attachReplayEvidence("from", in: &object, from: observation.fromBefore)
            attachReplayEvidence("to", in: &object, from: observation.toBefore)

            let facts = DerivedPostconditionCompiler().facts(for: DerivedPostconditionCompiler.Input(
                actionID: actionID,
                tool: tool,
                observation: observation,
                workflowInputs: workflowInputs
            ))
            if !facts.isEmpty {
                object["expects"] = .array(facts)
            }
        }

        // A v2 file must never preserve a session-pinned handle. Public actions no longer accept
        // handles, but keeping this boundary check prevents manually constructed history records
        // from producing a file that looks replayable and is not.
        guard !["target", "from", "to"].contains(where: { key in
            guard case let .string(value)? = object[key] else { return false }
            return (try? SnapshotHandle(value)) != nil
        }) else {
            return nil
        }
        return object
    }

    /// Adds the locator evidence reserved for replay to an ordinary `{app,name}` action target.
    /// The semantic name remains the action's stable identity; the pre-action observation supplies
    /// the evidence a fresh daemon needs to resolve that identity without a prior `look`.
    private func attachReplayEvidence(
        _ key: String,
        in object: inout [String: JSONValue],
        from state: ObservedElementState?
    ) {
        guard case var .object(target)? = object[key],
              case .string? = target["app"],
              case .string? = target["name"],
              let state,
              let locator = state.locator
        else {
            return
        }
        target["locator"] = .object(locator)
        object[key] = .object(target)
    }

    private func toolName(for method: String) -> String? {
        switch method {
        case "look", "find", "click", "scroll", "drag", "invoke", "type", "keyboard":
            return method
        default:
            return nil
        }
    }

    private func isReplayableAction(_ method: String) -> Bool {
        ["click", "scroll", "drag", "invoke", "type", "keyboard"].contains(method)
    }

    private func shouldRecord(method: String) -> Bool {
        switch method {
        case "health", "permit", "save":
            return false
        default:
            return toolName(for: method) != nil || method == "run"
        }
    }

    private func sessionID(in params: JSONValue?) -> String? {
        guard case let .object(object)? = params,
              case let .string(sessionID)? = object["_session"],
              !sessionID.isEmpty
        else {
            return nil
        }
        return sessionID
    }

}

public struct ActionHistoryContext {
    public let sessionID: String
    public let request: JSONRPCRequest
}

public struct ActionHistoryExport: Equatable, Sendable {
    public let script: String
    public let actionCount: Int
    public let recordCount: Int
}

private extension JSONRPCRequest {
    func withParams(strippingSessionKeyFrom params: JSONValue?) -> JSONRPCRequest {
        guard case var .object(object)? = params else {
            return self
        }
        object.removeValue(forKey: "_session")
        return JSONRPCRequest(id: id, method: method, params: .object(object))
    }

    func withParams(strippingSensitiveHistoryKeysFrom params: JSONValue?) -> JSONRPCRequest {
        guard case var .object(object)? = params else {
            return self
        }
        if method == "run" {
            object.removeValue(forKey: "actions")
            object.removeValue(forKey: "args")
            object.removeValue(forKey: "argValues")
        }
        return JSONRPCRequest(id: id, method: method, params: .object(object))
    }

    func withParams(
        redactingSensitiveHistoryValuesFrom params: JSONValue?,
        activeSecretRedactor: ActiveSecretRedactor,
        deterministicRedactor: DeterministicRedactor
    ) -> JSONRPCRequest {
        guard let params else {
            return self
        }
        return JSONRPCRequest(
            id: id,
            method: method,
            params: params.redactingSensitiveHistoryValues(
                activeSecretRedactor: activeSecretRedactor,
                deterministicRedactor: deterministicRedactor
            )
        )
    }
}

extension JSONValue {
    func redactingSensitiveHistoryValues(
        activeSecretRedactor: ActiveSecretRedactor,
        deterministicRedactor: DeterministicRedactor,
        field: String = "value"
    ) -> JSONValue {
        switch self {
        case let .string(value):
            if let active = activeSecretRedactor.redaction(for: value) {
                return .string(active.value)
            }
            if let deterministic = deterministicRedactor.redaction(
                for: field,
                value: value,
                context: DeterministicRedactionContext(
                    title: field,
                    value: value,
                    identifier: field
                )
            ) {
                return .string(deterministic.value)
            }
            return self
        case let .array(values):
            return .array(values.map {
                $0.redactingSensitiveHistoryValues(
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
                    field: field
                )
            })
        case let .object(object):
            return .object(object.mapValuesWithKeys { key, value in
                value.redactingSensitiveHistoryValues(
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
                    field: key
                )
            })
        case .int, .double, .bool, .null:
            return self
        }
    }
}

private extension Dictionary {
    func mapValuesWithKeys<T>(_ transform: (Key, Value) throws -> T) rethrows -> [Key: T] {
        var result: [Key: T] = [:]
        result.reserveCapacity(count)
        for (key, value) in self {
            result[key] = try transform(key, value)
        }
        return result
    }
}
