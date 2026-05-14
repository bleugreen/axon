import Foundation

public extension AppSnapshot {
    var jsonValue: JSONValue {
        jsonValue(includeTree: true)
    }

    func jsonValue(includeTree: Bool) -> JSONValue {
        jsonValue(includeTree: includeTree, activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(includeTree: Bool, activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        let deterministicRedactor = DeterministicRedactor.standard
        var object: [String: JSONValue] = [
            "id": .string(id.rawValue),
            "app": app.jsonValue,
            "indexedNodes": .array(indexedNodes.map { indexed in
                let redactionScope = "\(id.rawValue)_\(indexed.index)"
                let redactionContext = DeterministicRedactionContext(node: indexed.node)
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
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
                    redactionContext: redactionContext,
                    redactionScope: redactionScope
                )
                node.addRedactedString(
                    "title",
                    indexed.node.title,
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
                    redactionContext: redactionContext,
                    redactionScope: redactionScope
                )
                node.addRedactedString(
                    "value",
                    indexed.node.value,
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
                    redactionContext: redactionContext,
                    redactionScope: redactionScope
                )
                node.addRedactedString(
                    "description",
                    indexed.node.description,
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
                    redactionContext: redactionContext,
                    redactionScope: redactionScope
                )
                return .object(node)
            }),
            "screenshot": screenshot.map(\.jsonValue) ?? .null
        ]
        if includeTree {
            var nextIndex = 0
            object["windows"] = .array(windows.map {
                $0.jsonValue(
                    snapshotID: id,
                    nextIndex: &nextIndex,
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
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
        let deterministicRedactor = DeterministicRedactor.standard
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
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
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
        activeSecretRedactor: ActiveSecretRedactor,
        deterministicRedactor: DeterministicRedactor,
        includeHandle: Bool
    ) -> JSONValue {
        let index = nextIndex
        nextIndex += 1
        let redactionScope = "\(snapshotID.rawValue)_\(index)"
        let redactionContext = DeterministicRedactionContext(node: self)
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
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
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
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: redactionContext,
            redactionScope: redactionScope
        )
        object.addRedactedString(
            "title",
            title,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: redactionContext,
            redactionScope: redactionScope
        )
        object.addRedactedString(
            "value",
            value,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: redactionContext,
            redactionScope: redactionScope
        )
        object.addRedactedString(
            "description",
            description,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: redactionContext,
            redactionScope: redactionScope
        )
        object.addRedactedString(
            "help",
            help,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: redactionContext,
            redactionScope: redactionScope
        )
        object.addRedactedString(
            "identifier",
            identifier,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: redactionContext,
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
        jsonValue(activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        var nextIndex = 0
        return jsonValue(
            snapshotID: SnapshotID("node"),
            nextIndex: &nextIndex,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: DeterministicRedactor.standard,
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
        jsonValue(activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        let object: [String: JSONValue] = [
            "id": .string(id.rawValue),
            "app": app.jsonValue,
            "windows": .array(windows.enumerated().map { index, window in
                window.jsonValue(
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: DeterministicRedactor.standard,
                    redactionScope: "\(id.rawValue)_window_\(index)"
                )
            }),
            "observationToken": observationToken.map(JSONValue.int) ?? .null
        ]
        return .object(object)
    }
}

public extension WindowSignature {
    var jsonValue: JSONValue {
        jsonValue(activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(
        activeSecretRedactor: ActiveSecretRedactor,
        deterministicRedactor: DeterministicRedactor = DeterministicRedactor.standard,
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
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: DeterministicRedactionContext(role: role, title: title),
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
