public extension LocatorResolution {
    var jsonValue: JSONValue {
        jsonValue(activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        .object([
            "status": .string(status.rawValue),
            "snapshotID": .string(snapshotID.rawValue),
            "confidence": .string(confidence.rawValue),
            "best": best.map { $0.jsonValue(activeSecretRedactor: activeSecretRedactor) } ?? .null,
            "candidates": .array(candidates.map { $0.jsonValue(activeSecretRedactor: activeSecretRedactor) })
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
        return .object(object)
    }
}

public extension AXLocator {
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
