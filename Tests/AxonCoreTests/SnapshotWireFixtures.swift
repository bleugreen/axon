import AxonClient
@testable import AxonCore

// The daemon's `look` wire shapes, built from the snapshot model so a formatter test can state its
// input as a tree instead of nested JSON. Only the fields the CLI-side formatters read are emitted,
// with handles numbered depth-first as the daemon numbers them. Redaction and semantic names are the
// daemon's work and are deliberately not reproduced here.

extension AppSnapshot {
    var wireFixture: JSONValue {
        var nextIndex = 0
        var object: [String: JSONValue] = [
            "id": .string(id.rawValue),
            "app": app.wireFixture,
            "windows": .array(windows.map { $0.wireFixture(snapshotID: id, nextIndex: &nextIndex) }),
            "screenshot": screenshot.map(\.wireFixture) ?? .null,
            "focus": focusWireFixture
        ]
        if windowCount == .counted(0) {
            object["note"] = .string(ObservationNote.noWindows)
        }
        return .object(object)
    }

    private var focusWireFixture: JSONValue {
        switch focus {
        case .none:
            return .object(["status": .string("none")])
        case let .inaccessible(error):
            return .object(["status": .string("inaccessible"), "error": .string(error)])
        case let .available(element, handle):
            var index = handle?.nodeIndex ?? 0
            var object: [String: JSONValue] = [
                "status": .string("available"),
                "element": element.wireFixture(snapshotID: id, nextIndex: &index)
            ]
            if let handle {
                object["handle"] = .string(SnapshotHandle(snapshotID: id, nodeIndex: handle.nodeIndex).rawValue)
            }
            return .object(object)
        }
    }
}

extension AppIdentity {
    var wireFixture: JSONValue {
        .object([
            "bundleIdentifier": bundleIdentifier.map(JSONValue.string) ?? .null,
            "name": .string(name),
            "processIdentifier": .int(Int(processIdentifier))
        ])
    }
}

extension AXChildrenPage {
    var wireFixture: JSONValue {
        var nextIndex = baseIndex
        return .object([
            "snapshot": .string(snapshotID.rawValue),
            "parent": .string(parentHandle),
            "offset": .int(offset),
            "limit": .int(limit),
            "total": .int(total),
            "baseIndex": .int(baseIndex),
            "nextOffset": offset + limit < total ? .int(offset + limit) : .null,
            "children": .array(children.map { $0.wireFixture(snapshotID: snapshotID, nextIndex: &nextIndex) })
        ])
    }
}

extension AXNode {
    func wireFixture(snapshotID: SnapshotID, nextIndex: inout Int) -> JSONValue {
        let index = nextIndex
        nextIndex += 1
        var object: [String: JSONValue] = [
            "index": .int(index),
            "handle": .string(SnapshotHandle(snapshotID: snapshotID, nodeIndex: index).rawValue),
            "role": .string(role),
            "actions": .array(actions.map(JSONValue.string)),
            "childCount": .int(childCount ?? children.count),
            "children": .array(children.map { $0.wireFixture(snapshotID: snapshotID, nextIndex: &nextIndex) })
        ]
        let strings: [(String, String?)] = [
            ("subrole", subrole), ("title", title), ("value", value), ("description", description),
            ("help", help), ("identifier", identifier), ("truncationReason", truncationReason)
        ]
        for case let (key, value?) in strings {
            object[key] = .string(value)
        }
        if let frame {
            object["frame"] = frame.wireFixture
        }
        return .object(object)
    }
}

extension AXFrame {
    var wireFixture: JSONValue {
        .object(["x": .double(x), "y": .double(y), "width": .double(width), "height": .double(height)])
    }
}

extension EncodedScreenshot {
    var wireFixture: JSONValue {
        var object: [String: JSONValue] = [
            "mediaType": .string(mediaType),
            "base64Data": .string(base64Data),
            "width": .int(width),
            "height": .int(height)
        ]
        if let sourceWindowFrame {
            object["sourceWindowFrame"] = sourceWindowFrame.wireFixture
        }
        return .object(object)
    }
}
