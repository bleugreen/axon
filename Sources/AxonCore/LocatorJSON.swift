public extension LocatorResolution {
    var jsonValue: JSONValue {
        jsonValue(activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        .object([
            "status": .string(status.rawValue),
            "snapshotID": .string(snapshotID.rawValue),
            "confidence": .string(confidence.rawValue),
            "path": .string(path.rawValue),
            "context": .string(context.rawValue),
            "best": best.map { $0.jsonValue(activeSecretRedactor: activeSecretRedactor) } ?? .null,
            "candidates": .array(candidates.map { $0.jsonValue(activeSecretRedactor: activeSecretRedactor) })
        ])
    }
}

private extension TextMatch {
    var jsonValue: JSONValue {
        switch self {
        case let .exact(value, false): return .string(value)
        case let .exact(value, true): return .object(["exact": .string(value), "caseSensitive": .bool(true)])
        case let .contains(value, caseSensitive):
            var object: [String: JSONValue] = ["contains": .string(value)]
            if caseSensitive { object["caseSensitive"] = .bool(true) }
            return .object(object)
        }
    }
}

private extension AXAncestorLocator {
    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [:]
        if let role { object["role"] = .string(role) }
        if let subrole { object["subrole"] = .string(subrole) }
        if let identifier { object["identifier"] = identifier.jsonValue }
        if let title { object["title"] = title.jsonValue }
        if let label { object["label"] = label.jsonValue }
        return .object(object)
    }
}

private extension LocatorEvidenceItem {
    var jsonValue: JSONValue {
        .object([
            "field": .string(field.rawValue),
            "outcome": .string(outcome.rawValue),
            "expected": expected.map(JSONValue.string) ?? .null,
            "actual": actual.map(JSONValue.string) ?? .null
        ])
    }
}

public extension LocatorCandidate {
    var jsonValue: JSONValue {
        jsonValue(activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        var object: [String: JSONValue] = [
            "index": .int(index),
            "handle": handle.map { .string($0.rawValue) } ?? .null,
            "role": .string(role),
            "frame": frame.map(\.jsonValue) ?? .null,
            "score": .int(score)
        ]
        let titleWasRedacted = object.addRedactedString(
            "title",
            title,
            activeSecretRedactor: activeSecretRedactor,
            redactionContext: DeterministicRedactionContext(role: role, title: title)
        )
        let renderedReasons: [String]
        if titleWasRedacted,
           let title,
           case let .string(replacement)? = object["title"] {
            renderedReasons = reasons.map { $0.replacingOccurrences(of: title, with: replacement) }
        } else {
            renderedReasons = reasons
        }
        object["reasons"] = .array(renderedReasons.redactedReasonValues(
            activeSecretRedactor: activeSecretRedactor
        ))
        object["evidence"] = .array(evidence.map(\.jsonValue))
        object["observedLocator"] = observedLocator?.jsonValue ?? .null
        return .object(object)
    }
}

public extension AXLocator {
    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [:]
        if let role { object["role"] = .string(role) }
        if let subrole { object["subrole"] = .string(subrole) }
        if let title { object["title"] = title.jsonValue }
        if let label { object["label"] = label.jsonValue }
        if let value { object["value"] = value.jsonValue }
        if let description { object["description"] = description.jsonValue }
        if let identifier { object["identifier"] = identifier.jsonValue }
        if !actions.isEmpty { object["actions"] = .array(actions.map(JSONValue.string)) }
        if !ancestors.isEmpty { object["ancestors"] = .array(ancestors.map(\.jsonValue)) }
        if let window { object["window"] = window.jsonValue }
        if !nearbyText.isEmpty { object["nearbyText"] = .array(nearbyText.map(\.jsonValue)) }
        if let frame { object["frame"] = frame.jsonValue }
        return .object(object)
    }

    init(jsonValue: JSONValue) throws {
        guard case let .object(object) = jsonValue else {
            throw JSONRPCError.invalidParams("locator must be an object")
        }

        self.init(
            role: try optionalString("role", in: object),
            subrole: try optionalString("subrole", in: object),
            title: try optionalTextMatch("title", in: object),
            label: try optionalTextMatch("label", in: object),
            value: try optionalTextMatch("value", in: object),
            description: try optionalTextMatch("description", in: object),
            identifier: try optionalTextMatch("identifier", in: object),
            actions: try stringArray("actions", in: object),
            ancestors: try ancestorArray("ancestors", in: object),
            window: try optionalAncestor("window", in: object),
            nearbyText: try textMatchArray("nearbyText", in: object),
            frame: try optionalFrame("frame", in: object)
        )
    }
}

private func optionalString(_ key: String, in object: [String: JSONValue]) throws -> String? {
    guard let value = object[key], value != .null else {
        return nil
    }
    guard case let .string(string) = value else {
        throw JSONRPCError.invalidParams("\(key) must be a string")
    }
    return string
}

private func optionalTextMatch(_ key: String, in object: [String: JSONValue]) throws -> TextMatch? {
    guard let value = object[key], value != .null else {
        return nil
    }
    return try TextMatch(jsonValue: value, field: key)
}

private func stringArray(_ key: String, in object: [String: JSONValue]) throws -> [String] {
    guard let value = object[key], value != .null else {
        return []
    }
    guard case let .array(values) = value else {
        throw JSONRPCError.invalidParams("\(key) must be an array of strings")
    }
    return try values.map { value in
        guard case let .string(string) = value else {
            throw JSONRPCError.invalidParams("\(key) must be an array of strings")
        }
        return string
    }
}

private func ancestorArray(_ key: String, in object: [String: JSONValue]) throws -> [AXAncestorLocator] {
    guard let value = object[key], value != .null else {
        return []
    }
    guard case let .array(values) = value else {
        throw JSONRPCError.invalidParams("\(key) must be an array of objects")
    }
    return try values.map { value in
        guard case let .object(ancestor) = value else {
            throw JSONRPCError.invalidParams("\(key) must be an array of objects")
        }
        return try ancestorLocator(from: ancestor)
    }
}

private func optionalAncestor(_ key: String, in object: [String: JSONValue]) throws -> AXAncestorLocator? {
    guard let value = object[key], value != .null else {
        return nil
    }
    guard case let .object(ancestor) = value else {
        throw JSONRPCError.invalidParams("\(key) must be an object")
    }
    return try ancestorLocator(from: ancestor)
}

private func ancestorLocator(from object: [String: JSONValue]) throws -> AXAncestorLocator {
    AXAncestorLocator(
        role: try optionalString("role", in: object),
        subrole: try optionalString("subrole", in: object),
        identifier: try optionalTextMatch("identifier", in: object),
        title: try optionalTextMatch("title", in: object),
        label: try optionalTextMatch("label", in: object)
    )
}

private func textMatchArray(_ key: String, in object: [String: JSONValue]) throws -> [TextMatch] {
    guard let value = object[key], value != .null else {
        return []
    }
    guard case let .array(values) = value else {
        throw JSONRPCError.invalidParams("\(key) must be an array of strings or matcher objects")
    }
    return try values.map { try TextMatch(jsonValue: $0, field: key) }
}

private func optionalFrame(_ key: String, in object: [String: JSONValue]) throws -> AXFrame? {
    guard let value = object[key], value != .null else {
        return nil
    }
    guard case let .object(frame) = value else {
        throw JSONRPCError.invalidParams("\(key) must be an object")
    }
    return AXFrame(
        x: try requiredDouble("x", in: frame, parent: key),
        y: try requiredDouble("y", in: frame, parent: key),
        width: try requiredDouble("width", in: frame, parent: key),
        height: try requiredDouble("height", in: frame, parent: key)
    )
}

private func requiredDouble(_ key: String, in object: [String: JSONValue], parent: String) throws -> Double {
    guard let value = object[key] else {
        throw JSONRPCError.invalidParams("\(parent).\(key) is required")
    }
    switch value {
    case let .double(double):
        return double
    case let .int(int):
        return Double(int)
    default:
        throw JSONRPCError.invalidParams("\(parent).\(key) must be a number")
    }
}

private extension TextMatch {
    init(jsonValue: JSONValue, field: String) throws {
        if case let .string(value) = jsonValue {
            self = .exact(value)
            return
        }

        guard case let .object(object) = jsonValue else {
            throw JSONRPCError.invalidParams("\(field) must be a string or matcher object")
        }

        let caseSensitive = boolValue("caseSensitive", in: object) ?? false
        if case let .string(value) = object["exact"] {
            self = .exact(value, caseSensitive: caseSensitive)
            return
        }
        if case let .string(value) = object["contains"] {
            self = .contains(value, caseSensitive: caseSensitive)
            return
        }

        throw JSONRPCError.invalidParams("\(field) matcher must contain exact or contains")
    }
}

private func boolValue(_ key: String, in object: [String: JSONValue]) -> Bool? {
    guard case let .bool(value) = object[key] else {
        return nil
    }
    return value
}
