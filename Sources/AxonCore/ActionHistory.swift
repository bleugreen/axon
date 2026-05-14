import Foundation
import Yams

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

    public func record(request: JSONRPCRequest, response: JSONRPCResponse, sessionID: String) {
        guard shouldRecord(method: request.method) else {
            return
        }
        let historyRequest = request.withParams(strippingSensitiveHistoryKeysFrom: request.params)
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
        let records = slicedRecords(sessionID: sessionID, from: from, to: to)
        let actions = records.compactMap { actionObject(for: $0, includeReads: includeReads) }
        let script = try Yams.serialize(node: scriptNode(actions: actions), sortKeys: false)
        return ActionHistoryExport(script: script, actionCount: actions.count, recordCount: records.count)
    }

    private func slicedRecords(sessionID: String, from: String?, to: String?) -> [ActionHistoryRecord] {
        let records = self.records(sessionID: sessionID)
        guard !records.isEmpty else {
            return []
        }
        let start = from.flatMap { id in records.firstIndex { $0.id == id } } ?? records.startIndex
        let end = to.flatMap { id in records.firstIndex { $0.id == id } } ?? records.index(before: records.endIndex)
        guard start <= end else {
            return []
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

    private func scriptNode(actions: [[String: JSONValue]]) -> Node {
        Node([
            (Node("version"), Node("1", Tag(.int))),
            (Node("actions"), Node(actions.map(yamlNode(from:)), Tag(.seq)))
        ], Tag(.map))
    }

    private func yamlNode(from object: [String: JSONValue]) -> Node {
        Node(orderedKeys(for: object).map { key in
            (Node(key), yamlNode(from: object[key] ?? .null))
        }, Tag(.map))
    }

    private func yamlNode(from value: JSONValue) -> Node {
        switch value {
        case let .string(value):
            return .scalar(value.represented())
        case let .int(value):
            return .scalar(value.represented())
        case let .double(value):
            return .scalar(value.represented())
        case let .bool(value):
            return .scalar(value.represented())
        case .null:
            return .scalar(NSNull().represented())
        case let .array(values):
            return Node(values.map(yamlNode(from:)), Tag(.seq))
        case let .object(object):
            return yamlNode(from: object)
        }
    }

    private func orderedKeys(for object: [String: JSONValue]) -> [String] {
        object.keys.sorted { lhs, rhs in
            let lhsPriority = keyPriority(lhs)
            let rhsPriority = keyPriority(rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs < rhs
        }
    }

    private func keyPriority(_ key: String) -> Int {
        switch key {
        case "tool":
            return 0
        case "app":
            return 1
        case "target":
            return 2
        case "locator":
            return 3
        case "name", "value", "keys":
            return 4
        default:
            return 100
        }
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
}
