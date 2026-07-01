import Foundation

public struct ActionHistoryRecord: Equatable, Sendable {
    public let id: String
    public let parentID: String?
    public let sessionID: String
    public let method: String
    public let params: [String: JSONValue]
    public let success: Bool
    public let error: String?

    public init(
        id: String,
        parentID: String?,
        sessionID: String,
        method: String,
        params: [String: JSONValue],
        success: Bool,
        error: String?
    ) {
        self.id = id
        self.parentID = parentID
        self.sessionID = sessionID
        self.method = method
        self.params = params
        self.success = success
        self.error = error
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
        activeSecretRedactor: ActiveSecretRedactor = ActiveSecretRedactor(),
        deterministicRedactor: DeterministicRedactor = .standard
    ) {
        guard shouldRecord(method: request.method) else {
            return
        }
        let strippedRequest = request.withParams(strippingSensitiveHistoryKeysFrom: request.params)
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
            error: error
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

    public func exportScript(sessionID: String, includeReads: Bool = false, from: String? = nil, to: String? = nil) throws -> ActionHistoryExport {
        let records = try slicedRecords(sessionID: sessionID, from: from, to: to)
        let actions = records.compactMap { actionObject(for: $0, includeReads: includeReads) }
        let script = try AxnDocumentCodec.yamlString(from: .object([
            "version": .int(1),
            "actions": .array(actions.map(JSONValue.object))
        ]))
        return ActionHistoryExport(script: script, actionCount: actions.count, recordCount: records.count)
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

    private func actionObject(for record: ActionHistoryRecord, includeReads: Bool) -> [String: JSONValue]? {
        guard let tool = toolName(for: record.method) else {
            return nil
        }
        if !includeReads && !isReplayableAction(record.method) {
            return nil
        }
        var object: [String: JSONValue] = ["tool": .string(tool)]
        for (key, value) in record.params where key != "tool" {
            object[key] = value
        }
        return object
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

private extension JSONValue {
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
