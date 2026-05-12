public extension AppSnapshot {
    var jsonValue: JSONValue {
        jsonValue(includeTree: true)
    }

    func jsonValue(includeTree: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id.rawValue),
            "app": app.jsonValue,
            "indexedNodes": .array(indexedNodes.map { indexed in
                .object([
                    "index": .int(indexed.index),
                    "role": .string(indexed.node.role),
                    "subrole": indexed.node.subrole.map(JSONValue.string) ?? .null,
                    "title": indexed.node.title.map(JSONValue.string) ?? .null,
                    "value": indexed.node.value.map(JSONValue.string) ?? .null,
                    "description": indexed.node.description.map(JSONValue.string) ?? .null,
                    "actions": .array(indexed.node.actions.map(JSONValue.string)),
                    "frame": indexed.node.frame.map(\.jsonValue) ?? .null,
                    "truncationReason": indexed.node.truncationReason.map(JSONValue.string) ?? .null,
                    "handle": handle(for: indexed.index).map { .string($0.rawValue) } ?? .null
                ])
            }),
            "screenshot": screenshot.map(\.jsonValue) ?? .null
        ]
        if includeTree {
            object["windows"] = .array(windows.map(\.jsonValue))
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
        var object: [String: JSONValue] = [
            "role": .string(role),
            "subrole": subrole.map(JSONValue.string) ?? .null,
            "title": title.map(JSONValue.string) ?? .null,
            "value": value.map(JSONValue.string) ?? .null,
            "description": description.map(JSONValue.string) ?? .null,
            "help": help.map(JSONValue.string) ?? .null,
            "identifier": identifier.map(JSONValue.string) ?? .null,
            "enabled": enabled.map(JSONValue.bool) ?? .null,
            "focused": focused.map(JSONValue.bool) ?? .null,
            "actions": .array(actions.map(JSONValue.string)),
            "truncationReason": truncationReason.map(JSONValue.string) ?? .null,
            "children": .array(children.map(\.jsonValue))
        ]
        object["frame"] = frame.map(\.jsonValue) ?? .null
        return .object(object)
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
