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
                    indexed.node.subrole.presentationString,
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
                    redactionContext: redactionContext
                )
                node.addRedactedString(
                    "title",
                    indexed.node.title.presentationString,
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
                    redactionContext: redactionContext
                )
                node.addRedactedString(
                    "value",
                    indexed.node.value.presentationString,
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
                    redactionContext: redactionContext
                )
                node.addRedactedString(
                    "description",
                    indexed.node.description.presentationString,
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
                    redactionContext: redactionContext
                )
                return .object(node)
            }),
            "screenshot": screenshot.map(\.jsonValue) ?? .null
        ]
        object["focus"] = focus.jsonValue(snapshotID: id, app: app, activeSecretRedactor: activeSecretRedactor)
        if includeTree {
            var nextIndex = 0
            object["windows"] = .array(windows.map {
                $0.jsonValue(
                    snapshotID: id,
                    nextIndex: &nextIndex,
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor,
                    includeHandle: true
                )
            })
        }
        return .object(object)
    }
}

private extension FocusObservation {
    func jsonValue(snapshotID: SnapshotID, app: AppIdentity, activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        switch self {
        case .none:
            return .object(["status": .string("none")])
        case let .inaccessible(error):
            return .object(["status": .string("inaccessible"), "error": .string(error)])
        case let .available(element, pendingHandle):
            var index = pendingHandle?.nodeIndex ?? 0
            let elementJSON = element.jsonValue(
                snapshotID: snapshotID,
                nextIndex: &index,
                activeSecretRedactor: activeSecretRedactor,
                deterministicRedactor: .standard,
                includeHandle: pendingHandle != nil
            )
            var object: [String: JSONValue] = [
                "status": .string("available"),
                "target": locatorTarget(element: elementJSON, app: app),
                "element": elementJSON
            ]
            if let pendingHandle {
                object["handle"] = .string(SnapshotHandle(snapshotID: snapshotID, nodeIndex: pendingHandle.nodeIndex).rawValue)
            }
            return .object(object)
        }
    }

    private func locatorTarget(element: JSONValue, app: AppIdentity) -> JSONValue {
        guard case let .object(fields) = element else {
            return .null
        }
        var locator: [String: JSONValue] = ["role": fields["role"] ?? .string("AXUnknown")]
        for key in ["subrole", "identifier", "title", "description"] where fields[key] != nil && fields[key] != JSONValue.null {
            locator[key] = fields[key]
        }
        if locator["title"] == nil, locator["description"] == nil, let value = fields["value"], value != JSONValue.null {
            locator["value"] = value
        }
        return .object([
            "app": .string(app.bundleIdentifier ?? "pid:\(app.processIdentifier)"),
            "locator": .object(locator)
        ])
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
        let redactionContext = DeterministicRedactionContext(node: self)
        var object: [String: JSONValue] = [
            "role": .string(role),
            "enabled": enabled.map(JSONValue.bool) ?? .null,
            "focused": focused.map(JSONValue.bool) ?? .null,
            "actions": .array(actions.map(JSONValue.string)),
            "childCount": .int(childCount ?? children.count),
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
            subrole.presentationString,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: redactionContext
        )
        object.addRedactedString(
            "title",
            title.presentationString,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: redactionContext
        )
        object.addRedactedString(
            "value",
            value.presentationString,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: redactionContext
        )
        object.addRedactedString(
            "description",
            description.presentationString,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: redactionContext
        )
        object.addRedactedString(
            "help",
            help.presentationString,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: redactionContext
        )
        object.addRedactedString(
            "identifier",
            identifier.presentationString,
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            redactionContext: redactionContext
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

private extension Optional where Wrapped == String {
    var presentationString: String? {
        guard let value = self else {
            return nil
        }
        return value.isAXUIElementPointerLabel ? nil : value
    }
}

private extension String {
    var isAXUIElementPointerLabel: Bool {
        hasPrefix("<AXUIElement ") && contains(">")
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
            "windows": .array(windows.map { window in
                window.jsonValue(
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: DeterministicRedactor.standard
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
        deterministicRedactor: DeterministicRedactor = DeterministicRedactor.standard
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
            redactionContext: DeterministicRedactionContext(role: role, title: title)
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


public extension JSONValue {
    /// Replaces internal snapshot identity with canonical semantic names for public observations.
    /// Debug observations retain handles for diagnostics, but names remain the primary vocabulary.
    func renderingSemanticNames(_ study: SemanticNameStudy, includeDebugHandles: Bool) -> JSONValue {
        guard case var .object(root) = self else { return self }
        let names = Dictionary(uniqueKeysWithValues: study.elements.map { ($0.sourceIndex, $0.name) })
        var nextIndex = 0
        func renderNode(_ value: JSONValue) -> JSONValue {
            guard case var .object(node) = value else { return value }
            let index = nextIndex
            nextIndex += 1
            if let name = names[index] { node["name"] = .string(name) }
            if !includeDebugHandles {
                node.removeValue(forKey: "handle")
                node.removeValue(forKey: "index")
            }
            if case let .array(children)? = node["children"] {
                node["children"] = .array(children.map(renderNode))
            }
            return .object(node)
        }
        if case let .array(windows)? = root["windows"] {
            root["windows"] = .array(windows.map(renderNode))
        }
        if case let .array(indexed)? = root["indexedNodes"] {
            root["indexedNodes"] = .array(indexed.map { value in
                guard case var .object(node) = value,
                      case let .int(index)? = node["index"] else { return value }
                if let name = names[index] { node["name"] = .string(name) }
                if !includeDebugHandles {
                    node.removeValue(forKey: "handle")
                    node.removeValue(forKey: "index")
                }
                return .object(node)
            })
        }
        if !includeDebugHandles, case var .object(focus)? = root["focus"] {
            focus.removeValue(forKey: "handle")
            root["focus"] = .object(focus)
        }
        return .object(root)
    }
}
