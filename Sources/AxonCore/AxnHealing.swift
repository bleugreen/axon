
import Foundation

public enum LocatorHealStatus: String, Codable, Sendable {
    case proposed
    case halted
    case clean
}

public struct LocatorHealEvent: Equatable, Sendable {
    public let actionID: String?
    public let actionIndex: Int
    public let status: LocatorHealStatus
    public let confidence: String
    public let path: String
    public let evidence: [JSONValue]
    public let proposal: JSONValue?
    public let diff: String
    public let reason: String?

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "actionIndex": .int(actionIndex),
            "status": .string(status.rawValue),
            "confidence": .string(confidence),
            "path": .string(path),
            "evidence": .array(evidence),
            "diff": .string(diff)
        ]
        if let actionID { object["actionId"] = .string(actionID) }
        if let proposal { object["proposal"] = proposal }
        if let reason { object["reason"] = .string(reason) }
        return .object(object)
    }
}

public enum AxnHealing {
    public static func event(
        action: AxnAction,
        index: Int,
        resolution: JSONValue,
        verify: (JSONValue, String) -> Bool,
        activeSecretRedactor: ActiveSecretRedactor
    ) -> LocatorHealEvent? {
        guard case let .object(record) = resolution else { return nil }
        let status = string("status", in: record) ?? "missing"
        let confidence = string("confidence", in: record) ?? "none"
        let path = string("path", in: record) ?? "fullSnapshot"
        let evidence = record["evidence"]?.arrayValue ?? []
        let drift = evidence.filter { item in
            guard case let .object(object) = item else { return false }
            let outcome = string("outcome", in: object)
            let field = string("field", in: object)
            return outcome != "matched" && outcome != "unevaluated" && field != "frame"
        }
        guard !drift.isEmpty || status != "unique" else { return nil }

        let identity = action.id ?? "actions[\(index)]"
        guard status == "unique" else {
            return LocatorHealEvent(
                actionID: action.id, actionIndex: index, status: .halted,
                confidence: confidence, path: path, evidence: evidence, proposal: nil,
                diff: "\(identity)  target.locator  healing halted: resolution \(status)",
                reason: "locator resolution was not unique"
            )
        }
        guard let recorded = recordedLocator(in: action.fields),
              case let .object(observed)? = record["observedLocator"]
        else {
            return LocatorHealEvent(
                actionID: action.id, actionIndex: index, status: .halted,
                confidence: confidence, path: path, evidence: evidence, proposal: nil,
                diff: "\(identity)  target.locator  healing halted: observed locator unavailable",
                reason: "the resolver did not return an observed locator"
            )
        }

        var proposal = observed
        if let frame = recorded["frame"], !drift.isEmpty { proposal["frame"] = frame }
        for item in evidence {
            guard case let .object(object) = item,
                  string("outcome", in: object) == "unevaluated",
                  let field = string("field", in: object),
                  let original = recorded[field]
            else { continue }
            proposal[field] = original
        }
        let proposalValue = JSONValue.object(proposal)
        if containsSecret(proposalValue, redactor: activeSecretRedactor) {
            return LocatorHealEvent(
                actionID: action.id, actionIndex: index, status: .halted,
                confidence: confidence, path: path, evidence: evidence, proposal: nil,
                diff: "\(identity)  target.locator  healing halted: proposal contains an active secret",
                reason: "proposal contains an active secret"
            )
        }
        guard targetApp(in: action.fields) != nil else {
            return LocatorHealEvent(
                actionID: action.id, actionIndex: index, status: .halted,
                confidence: confidence, path: path, evidence: evidence, proposal: nil,
                diff: "\(identity)  target.locator  healing halted: locator target has no app",
                reason: "locator target has no app"
            )
        }
        guard verify(proposalValue, confidence) else {
            return LocatorHealEvent(
                actionID: action.id, actionIndex: index, status: .halted,
                confidence: confidence, path: path, evidence: evidence, proposal: nil,
                diff: "\(identity)  target.locator  healing halted: proposal verification failed",
                reason: "proposal did not resolve uniquely at equal or higher confidence"
            )
        }

        let rendered = renderDiff(identity: identity, before: recorded, after: proposal)
        return LocatorHealEvent(
            actionID: action.id, actionIndex: index, status: .proposed,
            confidence: confidence, path: path, evidence: evidence,
            proposal: proposalValue, diff: rendered, reason: nil
        )
    }

    public static func revise(_ axn: Axn, with events: [LocatorHealEvent]) -> Axn {
        var revised = axn
        let proposals = Dictionary(uniqueKeysWithValues: events.compactMap { event -> (Int, JSONValue)? in
            guard event.status == .proposed, let proposal = event.proposal else { return nil }
            return (event.actionIndex, proposal)
        })
        for index in revised.blocks.indices {
            guard let proposal = proposals[index], case var .action(action) = revised.blocks[index] else { continue }
            if case var .object(target)? = action.fields["target"] {
                target["locator"] = proposal
                action.fields["target"] = .object(target)
            }
            revised.blocks[index] = .action(action)
        }
        return revised
    }

    public static func header(for events: [LocatorHealEvent]) -> String {
        let proposed = events.filter { $0.status == .proposed }
        guard !proposed.isEmpty else { return "" }
        return (["# Axon healed locator proposals. Review before replaying."] +
            proposed.flatMap { $0.diff.split(separator: "\n").map { "# \($0)" } }).joined(separator: "\n") + "\n"
    }

    private static func recordedLocator(in fields: [String: JSONValue]) -> [String: JSONValue]? {
        guard case let .object(target)? = fields["target"],
              case let .object(locator)? = target["locator"] else { return nil }
        return locator
    }

    private static func targetApp(in fields: [String: JSONValue]) -> String? {
        guard case let .object(target)? = fields["target"] else { return nil }
        return string("app", in: target)
    }

    private static func containsSecret(_ value: JSONValue, redactor: ActiveSecretRedactor) -> Bool {
        switch value {
        case let .string(string): return redactor.redaction(for: string) != nil
        case let .array(values): return values.contains { containsSecret($0, redactor: redactor) }
        case let .object(object): return object.values.contains { containsSecret($0, redactor: redactor) }
        default: return false
        }
    }

    private static func renderDiff(identity: String, before: [String: JSONValue], after: [String: JSONValue]) -> String {
        var lines = ["\(identity)  target.locator"]
        for key in Set(before.keys).union(after.keys).sorted() {
            if before[key] == after[key] { continue }
            if let old = before[key] { lines.append("  - \(key): \(render(old))") }
            if let new = after[key] { lines.append("  + \(key): \(render(new))") }
        }
        return lines.joined(separator: "\n")
    }

    private static func render(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return string
    }

    private static func string(_ key: String, in object: [String: JSONValue]) -> String? {
        guard case let .string(value)? = object[key] else { return nil }
        return value
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else { return nil }
        return values
    }
}
