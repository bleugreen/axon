import Foundation

public enum RecordedFactError: Error, CustomStringConvertible, Equatable {
    case invalidFact(String)
    case missingDependency(String)
    case unresolvedLocator(factID: String, status: LocatorResolutionStatus)
    case mismatch(factID: String, message: String)
    case unsupported(factID: String, message: String)

    public var description: String {
        switch self {
        case let .invalidFact(message):
            return message
        case let .missingDependency(id):
            return "Missing required fact: \(id)"
        case let .unresolvedLocator(factID, status):
            return "Fact \(factID) locator did not resolve uniquely: \(status.rawValue)"
        case let .mismatch(factID, message):
            return "Fact \(factID) did not verify: \(message)"
        case let .unsupported(factID, message):
            return "Fact \(factID) is unsupported: \(message)"
        }
    }

    public var factID: String? {
        switch self {
        case let .missingDependency(id):
            return id
        case let .unresolvedLocator(factID, _), let .mismatch(factID, _), let .unsupported(factID, _):
            return factID
        case .invalidFact:
            return nil
        }
    }
}

public struct RecordedFact: Equatable, Sendable {
    public let id: String
    public let kind: String
    public let target: JSONValue
    public let state: [String: JSONValue]
    public let raw: JSONValue

    public init(jsonValue: JSONValue) throws {
        guard case let .object(object) = jsonValue else {
            throw RecordedFactError.invalidFact("fact must be an object")
        }
        guard case let .string(id)? = object["id"], !id.isEmpty else {
            throw RecordedFactError.invalidFact("fact requires id")
        }
        guard case let .string(kind)? = object["kind"], !kind.isEmpty else {
            throw RecordedFactError.invalidFact("fact \(id) requires kind")
        }
        guard let target = object["target"] else {
            throw RecordedFactError.invalidFact("fact \(id) requires target")
        }
        let state: [String: JSONValue]
        if case let .object(object)? = object["state"] {
            state = object
        } else {
            state = [:]
        }

        self.id = id
        self.kind = kind
        self.target = target
        self.state = state
        self.raw = jsonValue
    }
}

public struct RecordedFactEvaluator {
    public typealias SnapshotProvider = (String) throws -> AppSnapshot

    private let snapshotProvider: SnapshotProvider

    public init(snapshotProvider: @escaping SnapshotProvider) {
        self.snapshotProvider = snapshotProvider
    }

    public func verify(_ fact: RecordedFact) throws {
        let target = try locatorTarget(for: fact)
        let snapshot = try snapshotProvider(target.app)
        let resolution = LocatorResolver().resolve(target.locator, in: snapshot)
        guard resolution.status == .unique, let index = resolution.best?.index else {
            throw RecordedFactError.unresolvedLocator(factID: fact.id, status: resolution.status)
        }
        let node = snapshot.indexedNodes[index].node

        switch fact.kind {
        case "exists", "window", "menu-selection", "changed":
            return
        case "focused":
            try verifyBool(fact, key: "focused", actual: node.focused)
        case "enabled":
            try verifyBool(fact, key: "enabled", actual: node.enabled)
        case "value":
            try verifyString(fact, key: "value", actual: node.value)
        case "selected":
            try verifyString(fact, key: "selected", actual: node.value)
        default:
            throw RecordedFactError.unsupported(factID: fact.id, message: "unknown kind \(fact.kind)")
        }
    }

    private func locatorTarget(for fact: RecordedFact) throws -> (app: String, locator: AXLocator) {
        guard case let .object(object) = fact.target else {
            throw RecordedFactError.invalidFact("fact \(fact.id) target must be an object")
        }
        guard case let .string(app)? = object["app"], !app.isEmpty else {
            throw RecordedFactError.invalidFact("fact \(fact.id) target requires app")
        }
        guard let locatorValue = object["locator"] else {
            throw RecordedFactError.invalidFact("fact \(fact.id) target requires locator")
        }
        return try (app, AXLocator(jsonValue: locatorValue))
    }

    private func verifyBool(_ fact: RecordedFact, key: String, actual: Bool?) throws {
        let expected = boolExpectation(key, in: fact.state)
        guard let expected else {
            if actual == true {
                return
            }
            throw RecordedFactError.mismatch(factID: fact.id, message: "\(key) was not true")
        }
        guard actual == expected else {
            throw RecordedFactError.mismatch(factID: fact.id, message: "\(key) expected \(expected), got \(actual.map(String.init) ?? "nil")")
        }
    }

    private func verifyString(_ fact: RecordedFact, key: String, actual: String?) throws {
        guard let matcher = try stringMatcher(key, in: fact.state) else {
            guard actual != nil else {
                throw RecordedFactError.mismatch(factID: fact.id, message: "\(key) was nil")
            }
            return
        }
        guard matcher.matches(actual) else {
            throw RecordedFactError.mismatch(factID: fact.id, message: "\(key) \(matcher.reasonFragment), got \(actual ?? "nil")")
        }
    }

    private func boolExpectation(_ key: String, in state: [String: JSONValue]) -> Bool? {
        switch state[key] {
        case let .bool(value):
            return value
        case let .object(object):
            if case let .bool(value)? = object["equals"] {
                return value
            }
            return nil
        default:
            return nil
        }
    }

    private func stringMatcher(_ key: String, in state: [String: JSONValue]) throws -> TextMatch? {
        guard let value = state[key], value != .null else {
            return nil
        }
        if case let .string(expected) = value {
            return .exact(expected)
        }
        guard case let .object(object) = value else {
            throw RecordedFactError.invalidFact("\(key) expectation must be a string or object")
        }
        let caseSensitive = boolValue("caseSensitive", in: object) ?? false
        if case let .string(expected)? = object["equals"] {
            return .exact(expected, caseSensitive: caseSensitive)
        }
        if case let .string(expected)? = object["exact"] {
            return .exact(expected, caseSensitive: caseSensitive)
        }
        if case let .string(expected)? = object["contains"] {
            return .contains(expected, caseSensitive: caseSensitive)
        }
        throw RecordedFactError.invalidFact("\(key) expectation must include equals, exact, or contains")
    }

    private func boolValue(_ key: String, in object: [String: JSONValue]) -> Bool? {
        guard case let .bool(value)? = object[key] else {
            return nil
        }
        return value
    }
}
