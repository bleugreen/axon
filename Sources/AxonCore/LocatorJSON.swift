public extension LocatorResolution {
    var jsonValue: JSONValue {
        jsonValue(activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        .object([
            "status": .string(status.rawValue),
            "snapshotID": .string(snapshotID.rawValue),
            "best": best.map {
                $0.jsonValue(
                    activeSecretRedactor: activeSecretRedactor,
                    redactionScope: "\(snapshotID.rawValue)_locator_best_\($0.index)"
                )
            } ?? .null,
            "candidates": .array(candidates.map {
                $0.jsonValue(
                    activeSecretRedactor: activeSecretRedactor,
                    redactionScope: "\(snapshotID.rawValue)_locator_candidate_\($0.index)"
                )
            })
        ])
    }
}

public extension LocatorCandidate {
    var jsonValue: JSONValue {
        jsonValue(activeSecretRedactor: ActiveSecretRedactor(), redactionScope: "locator_candidate_\(index)")
    }

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor, redactionScope: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "index": .int(index),
            "handle": handle.map { .string($0.rawValue) } ?? .null,
            "role": .string(role),
            "score": .int(score)
        ]
        let titleWasRedacted = object.addActiveSecretRedactedString(
            "title",
            title,
            activeSecretRedactor: activeSecretRedactor
        )
        if object["title"] == nil {
            object["title"] = title.map(JSONValue.string) ?? .null
        }
        if titleWasRedacted, let title {
            object["reasons"] = .array(reasons.map {
                JSONValue.string($0.replacingOccurrences(of: title, with: "<redacted: active-credential>"))
            })
            object.addActiveSecretRedactionMetadata(
                field: "reasons",
                redaction: activeSecretRedactor.redaction(for: title) ?? ActiveSecretRedaction()
            )
        } else {
            object["reasons"] = .array(reasons.map(JSONValue.string))
        }
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
            ancestors: try ancestorArray("ancestors", in: object)
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
        return AXAncestorLocator(
            role: try optionalString("role", in: ancestor),
            title: try optionalTextMatch("title", in: ancestor),
            label: try optionalTextMatch("label", in: ancestor)
        )
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
