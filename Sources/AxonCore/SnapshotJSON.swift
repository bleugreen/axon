import Foundation

public extension AppSnapshot {
    var jsonValue: JSONValue {
        jsonValue(includeTree: true)
    }

    func jsonValue(includeTree: Bool) -> JSONValue {
        jsonValue(includeTree: includeTree, sensitive: false)
    }

    func jsonValue(includeTree: Bool, activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        jsonValue(includeTree: includeTree, sensitive: false, activeSecretRedactor: activeSecretRedactor)
    }

    func jsonValue(
        includeTree: Bool,
        sensitive: Bool,
        activeSecretRedactor: ActiveSecretRedactor = ActiveSecretRedactor()
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id.rawValue),
            "app": app.jsonValue,
            "indexedNodes": .array(indexedNodes.map { indexed in
                let redactionScope = "\(id.rawValue)_\(indexed.index)"
                var node: [String: JSONValue] = [
                    "index": .int(indexed.index),
                    "role": .string(indexed.node.role),
                    "actions": .array(indexed.node.actions.map(JSONValue.string)),
                    "frame": indexed.node.frame.map(\.jsonValue) ?? .null,
                    "truncationReason": indexed.node.truncationReason.map(JSONValue.string) ?? .null,
                    "handle": handle(for: indexed.index).map { .string($0.rawValue) } ?? .null
                ]
                node.addRedactedString(
                    "subrole",
                    indexed.node.subrole,
                    sensitive: sensitive,
                    activeSecretRedactor: activeSecretRedactor,
                    redactionScope: redactionScope
                )
                node.addRedactedString(
                    "title",
                    indexed.node.title,
                    sensitive: sensitive,
                    activeSecretRedactor: activeSecretRedactor,
                    redactionScope: redactionScope
                )
                node.addRedactedString(
                    "value",
                    indexed.node.value,
                    sensitive: sensitive,
                    always: true,
                    activeSecretRedactor: activeSecretRedactor,
                    redactionScope: redactionScope
                )
                node.addRedactedString(
                    "description",
                    indexed.node.description,
                    sensitive: sensitive,
                    activeSecretRedactor: activeSecretRedactor,
                    redactionScope: redactionScope
                )
                return .object(node)
            }),
            "screenshot": sensitive ? .null : screenshot.map(\.jsonValue) ?? .null
        ]
        if sensitive {
            object["redaction"] = SnapshotRedactor.metadata(scope: "snapshot")
        }
        if includeTree {
            var nextIndex = 0
            object["windows"] = .array(windows.map {
                $0.jsonValue(
                    snapshotID: id,
                    nextIndex: &nextIndex,
                    sensitive: sensitive,
                    activeSecretRedactor: activeSecretRedactor,
                    includeHandle: false
                )
            })
        }
        return .object(object)
    }
}

public extension AppIdentity {
    var jsonValue: JSONValue {
        .object([
            "bundleIdentifier": bundleIdentifier.map(JSONValue.string) ?? .null,
            "name": .string(name),
            "processIdentifier": .int(Int(processIdentifier))
        ])
    }
}

public extension AXChildrenPage {
    var jsonValue: JSONValue {
        jsonValue(activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        var nextIndex = baseIndex
        return .object([
            "snapshot": .string(snapshotID.rawValue),
            "parent": .string(parentHandle),
            "offset": .int(offset),
            "limit": .int(limit),
            "total": .int(total),
            "baseIndex": .int(baseIndex),
            "nextOffset": offset + limit < total ? .int(offset + limit) : .null,
            "children": .array(children.map { child in
                child.jsonValue(
                    snapshotID: snapshotID,
                    nextIndex: &nextIndex,
                    sensitive: false,
                    activeSecretRedactor: activeSecretRedactor,
                    includeHandle: true
                )
            })
        ])
    }
}

private extension AXNode {
    func jsonValue(
        snapshotID: SnapshotID,
        nextIndex: inout Int,
        sensitive: Bool,
        activeSecretRedactor: ActiveSecretRedactor,
        includeHandle: Bool
    ) -> JSONValue {
        let index = nextIndex
        nextIndex += 1
        let redactionScope = "\(snapshotID.rawValue)_\(index)"
        var object: [String: JSONValue] = [
            "role": .string(role),
            "enabled": enabled.map(JSONValue.bool) ?? .null,
            "focused": focused.map(JSONValue.bool) ?? .null,
            "actions": .array(actions.map(JSONValue.string)),
            "truncationReason": truncationReason.map(JSONValue.string) ?? .null,
            "children": .array(children.map {
                $0.jsonValue(
                    snapshotID: snapshotID,
                    nextIndex: &nextIndex,
                    sensitive: sensitive,
                    activeSecretRedactor: activeSecretRedactor,
                    includeHandle: includeHandle
                )
            })
        ]
        if includeHandle {
            object["index"] = .int(index)
            object["handle"] = .string(SnapshotHandle(snapshotID: snapshotID, nodeIndex: index).rawValue)
        }
        object.addRedactedString(
            "subrole",
            subrole,
            sensitive: sensitive,
            activeSecretRedactor: activeSecretRedactor,
            redactionScope: redactionScope
        )
        object.addRedactedString(
            "title",
            title,
            sensitive: sensitive,
            activeSecretRedactor: activeSecretRedactor,
            redactionScope: redactionScope
        )
        object.addRedactedString(
            "value",
            value,
            sensitive: sensitive,
            always: true,
            activeSecretRedactor: activeSecretRedactor,
            redactionScope: redactionScope
        )
        object.addRedactedString(
            "description",
            description,
            sensitive: sensitive,
            activeSecretRedactor: activeSecretRedactor,
            redactionScope: redactionScope
        )
        object.addRedactedString(
            "help",
            help,
            sensitive: sensitive,
            activeSecretRedactor: activeSecretRedactor,
            redactionScope: redactionScope
        )
        object.addRedactedString(
            "identifier",
            identifier,
            sensitive: sensitive,
            activeSecretRedactor: activeSecretRedactor,
            redactionScope: redactionScope
        )
        object["frame"] = frame.map(\.jsonValue) ?? .null
        return .object(object)
    }
}

public extension EncodedScreenshot {
    var jsonValue: JSONValue {
        .object([
            "mediaType": .string(mediaType),
            "base64Data": .string(base64Data),
            "width": .int(width),
            "height": .int(height)
        ])
    }
}

public extension AXNode {
    var jsonValue: JSONValue {
        jsonValue(sensitive: false)
    }

    func jsonValue(sensitive: Bool) -> JSONValue {
        jsonValue(sensitive: sensitive, activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(sensitive: Bool, activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        var nextIndex = 0
        return jsonValue(
            snapshotID: SnapshotID("node"),
            nextIndex: &nextIndex,
            sensitive: sensitive,
            activeSecretRedactor: activeSecretRedactor,
            includeHandle: false
        )
    }
}

public extension AXFrame {
    var jsonValue: JSONValue {
        .object([
            "x": .double(x),
            "y": .double(y),
            "width": .double(width),
            "height": .double(height)
        ])
    }
}

public extension SnapshotSummary {
    var jsonValue: JSONValue {
        jsonValue(sensitive: false)
    }

    func jsonValue(sensitive: Bool) -> JSONValue {
        jsonValue(sensitive: sensitive, activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        jsonValue(sensitive: false, activeSecretRedactor: activeSecretRedactor)
    }

    func jsonValue(sensitive: Bool, activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id.rawValue),
            "app": app.jsonValue,
            "windows": .array(windows.enumerated().map { index, window in
                window.jsonValue(
                    sensitive: sensitive,
                    activeSecretRedactor: activeSecretRedactor,
                    redactionScope: "\(id.rawValue)_window_\(index)"
                )
            }),
            "observationToken": observationToken.map(JSONValue.int) ?? .null
        ]
        if sensitive {
            object["redaction"] = SnapshotRedactor.metadata(scope: "snapshotSummary")
        }
        return .object(object)
    }
}

public extension WindowSignature {
    var jsonValue: JSONValue {
        jsonValue(sensitive: false)
    }

    func jsonValue(sensitive: Bool) -> JSONValue {
        jsonValue(sensitive: sensitive, activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(
        sensitive: Bool,
        activeSecretRedactor: ActiveSecretRedactor,
        redactionScope: String = "window"
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "role": .string(role),
            "subrole": subrole.map(JSONValue.string) ?? .null,
            "frame": frame.map(\.jsonValue) ?? .null,
            "childCount": .int(childCount)
        ]
        object.addRedactedString(
            "title",
            title,
            sensitive: sensitive,
            activeSecretRedactor: activeSecretRedactor,
            redactionScope: redactionScope
        )
        return .object(object)
    }
}

public extension FrameSignature {
    var jsonValue: JSONValue {
        .object([
            "x": .int(x),
            "y": .int(y),
            "width": .int(width),
            "height": .int(height)
        ])
    }
}

public extension SnapshotChange {
    var jsonValue: JSONValue {
        .object([
            "changed": .bool(changed),
            "reason": .string(reason)
        ])
    }
}

public extension ObservedAppChange {
    var jsonValue: JSONValue {
        .object([
            "sequence": .int(sequence),
            "reason": .string(reason)
        ])
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    mutating func addRedactedString(
        _ key: String,
        _ value: String?,
        sensitive: Bool,
        always: Bool = false,
        activeSecretRedactor: ActiveSecretRedactor = ActiveSecretRedactor(),
        redactionScope: String? = nil
    ) {
        guard let value else {
            self[key] = .null
            return
        }
        if redactionScope != nil,
           addActiveSecretRedactedString(
               key,
               value,
               activeSecretRedactor: activeSecretRedactor
           ) {
            return
        }
        guard sensitive else {
            self[key] = .string(value)
            return
        }
        let redaction = SnapshotRedactor.redact(value, always: always)
        self[key] = .string(redaction.value)
        if let reason = redaction.reason {
            addRedactionMetadata(field: key, reason: reason)
        }
    }

    private mutating func addRedactionMetadata(field: String, reason: String) {
        var fields: [JSONValue] = []
        var reasons: [String: JSONValue] = [:]
        var metadata: [String: JSONValue] = [:]
        if case let .object(existing)? = self["redaction"] {
            metadata = existing
            if case let .array(existingFields)? = existing["fields"] {
                fields = existingFields
            }
            if case let .object(existingReasons)? = existing["reasons"] {
                reasons = existingReasons
            }
        }
        if !fields.contains(.string(field)) {
            fields.append(.string(field))
        }
        reasons[field] = .string(reason)
        metadata["fields"] = .array(fields)
        metadata["reasons"] = .object(reasons)
        self["redaction"] = .object(metadata)
    }
}

private enum SnapshotRedactor {
    private struct Match {
        let range: Range<String.Index>
        let reason: String
    }

    static func metadata(scope: String) -> JSONValue {
        .object([
            "sensitive": .bool(true),
            "scope": .string(scope),
            "style": .string("prefix_preserving"),
            "screenshots": .string("disabled")
        ])
    }

    static func redact(_ value: String, always: Bool) -> (value: String, reason: String?) {
        if value.isEmpty {
            return (value, nil)
        }
        if let match = secretMatch(in: value) {
            return (redacted(value, matchRange: match.range), match.reason)
        }
        if always {
            return (redacted(value, matchRange: value.startIndex..<value.endIndex), "sensitive_value")
        }
        return (value, nil)
    }

    private static func secretMatch(in value: String) -> Match? {
        if let match = firstRegexMatch(#"github_pat_[A-Za-z0-9_]{20,}"#, in: value) {
            return Match(range: match, reason: "github_token")
        }
        if let match = firstRegexMatch(#"gh[pousr]_[A-Za-z0-9_]{20,}"#, in: value) {
            return Match(range: match, reason: "github_token")
        }
        if let match = firstRegexMatch(#"sk-(?:proj-)?[A-Za-z0-9_-]{16,}"#, in: value) {
            return Match(range: match, reason: "api_key")
        }
        if let match = firstRegexMatch(#"xox[baprs]-[A-Za-z0-9-]{20,}"#, in: value) {
            return Match(range: match, reason: "slack_token")
        }
        if let match = firstRegexMatch(#"AKIA[0-9A-Z]{16}"#, in: value) {
            return Match(range: match, reason: "aws_access_key")
        }
        if let match = firstRegexMatch(#"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, in: value) {
            return Match(range: match, reason: "jwt")
        }
        if let match = firstRegexMatch(#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, in: value) {
            return Match(range: match, reason: "private_key")
        }
        if let match = firstRegexMatch(#"\b[A-Fa-f0-9]{32,}\b"#, in: value) {
            return Match(range: match, reason: "long_hex_secret")
        }
        if let match = firstRegexMatch(#"\b[A-Za-z0-9_+/=-]{40,}\b"#, in: value), hasMixedSecretAlphabet(String(value[match])) {
            return Match(range: match, reason: "long_token")
        }
        return nil
    }

    private static func redacted(_ value: String, matchRange: Range<String.Index>) -> String {
        let matchLength = value.distance(from: matchRange.lowerBound, to: matchRange.upperBound)
        let visibleSecretCharacters = matchLength <= 8 ? min(matchLength, 2) : min(matchLength, 12)
        let visibleEnd = value.index(matchRange.lowerBound, offsetBy: visibleSecretCharacters)
        let prefixEnd = matchRange.lowerBound == value.startIndex
            ? visibleEnd
            : max(visibleEnd, value.index(value.startIndex, offsetBy: min(8, value.count)))
        let prefix = String(value[..<prefixEnd])
        return "\(prefix)...[redacted]"
    }

    private static func firstRegexMatch(_ pattern: String, in value: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let stringRange = Range(match.range, in: value) else {
            return nil
        }
        return stringRange
    }

    private static func hasMixedSecretAlphabet(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        let hasLetter = scalars.contains { CharacterSet.letters.contains($0) }
        let hasNumber = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let hasSymbol = scalars.contains { CharacterSet(charactersIn: "_+/=-").contains($0) }
        return hasLetter && hasNumber && (hasSymbol || value.count >= 48)
    }
}
