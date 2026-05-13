import Foundation

public struct SnapshotObservationFormatter {
    public init() {}

    public func observation(from snapshot: JSONValue, frames: Bool) -> JSONValue {
        guard case let .object(object) = snapshot else {
            return snapshot
        }

        let snapshotID = string("id", in: object) ?? "unknown"
        let app = object["app"]?.objectValue ?? [:]
        var observation: [String: JSONValue] = [
            "format": .string("observation"),
            "snapshot": .string(snapshotID),
            "app": .string(string("name", in: app) ?? "unknown"),
            "pid": app["processIdentifier"] ?? .null,
            "tree": .array(compactForest(from: object["windows"], snapshotID: snapshotID, frames: frames))
        ]
        if let bundle = string("bundleIdentifier", in: app) {
            observation["bundle"] = .string(bundle)
        }
        if let screenshot = object["screenshot"], screenshot != .null {
            observation["screenshot"] = screenshot
        }
        if let redaction = object["redaction"] {
            observation["redaction"] = redaction
        }
        return .object(observation)
    }

    public func text(from observation: JSONValue) -> String {
        guard case let .object(object) = observation else {
            let data = (try? JSONEncoder().encode(observation)) ?? Data("null".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        var lines: [String] = []
        if let app = string("app", in: object) {
            if let pid = object["pid"]?.scalarText {
                lines.append("app: \(yamlString(app))")
                lines.append("pid: \(pid)")
            } else {
                lines.append("app: \(yamlString(app))")
            }
        }
        if let bundle = string("bundle", in: object) {
            lines.append("bundle: \(yamlString(bundle))")
        }
        if let snapshot = string("snapshot", in: object) {
            lines.append("snapshot: \(snapshot)")
        }
        if let screenshot = object["screenshot"]?.objectValue {
            let width = screenshot["width"]?.scalarText ?? "?"
            let height = screenshot["height"]?.scalarText ?? "?"
            lines.append("screenshot: \(width)x\(height)")
        }
        lines.append("tree:")
        if case let .array(nodes)? = object["tree"] {
            for node in nodes {
                appendText(node, depth: 1, lines: &lines)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func compactForest(from value: JSONValue?, snapshotID: String, frames: Bool) -> [JSONValue] {
        guard case let .array(nodes)? = value else {
            return []
        }
        var nextIndex = 0
        return nodes.flatMap { compactNodes(from: $0, snapshotID: snapshotID, frames: frames, nextIndex: &nextIndex) }
    }

    private func compactNodes(
        from value: JSONValue,
        snapshotID: String,
        frames: Bool,
        nextIndex: inout Int
    ) -> [JSONValue] {
        guard case let .object(object) = value else {
            return []
        }

        let index = nextIndex
        nextIndex += 1

        let children = object["children"]?.arrayValue ?? []
        let compactChildren = children.flatMap {
            compactNodes(from: $0, snapshotID: snapshotID, frames: frames, nextIndex: &nextIndex)
        }

        guard shouldInclude(object) else {
            return compactChildren
        }

        var compact: [String: JSONValue] = [
            "handle": .string("\(snapshotID):\(index)"),
            "role": .string(normalizedRole(string("role", in: object))),
            "children": .array(compactChildren)
        ]
        if let label = label(in: object) {
            compact["label"] = .string(label)
        }
        let actions = compactActions(from: object["actions"])
        if !actions.isEmpty {
            compact["actions"] = .array(actions.map(JSONValue.string))
        }
        if let truncation = string("truncationReason", in: object) {
            compact["truncated"] = .string(truncation)
        }
        if frames, let frame = object["frame"], frame != .null {
            compact["frame"] = frame
        }
        if compactChildren.isEmpty {
            compact.removeValue(forKey: "children")
        }
        return [.object(compact)]
    }

    private func shouldInclude(_ object: [String: JSONValue]) -> Bool {
        if isFarOffscreen(object["frame"]) {
            return false
        }
        if string("truncationReason", in: object) != nil {
            return true
        }
        if label(in: object) != nil {
            return true
        }
        switch normalizedRole(string("role", in: object)) {
        case "window", "web", "field", "button", "link", "menu", "list", "row", "cell":
            return true
        default:
            return !compactActions(from: object["actions"]).isEmpty
        }
    }

    private func isFarOffscreen(_ value: JSONValue?) -> Bool {
        guard case let .object(frame)? = value else {
            return false
        }
        let x = frame["x"]?.doubleValue
        let y = frame["y"]?.doubleValue
        return (x != nil && x! < -100) || (y != nil && y! < -100)
    }

    private func label(in object: [String: JSONValue]) -> String? {
        for key in ["title", "value", "description", "identifier", "help"] {
            if let value = string(key, in: object), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func normalizedRole(_ role: String?) -> String {
        switch role {
        case "AXWindow":
            return "window"
        case "AXButton":
            return "button"
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
            return "field"
        case "AXStaticText":
            return "text"
        case "AXHeading":
            return "heading"
        case "AXLink":
            return "link"
        case "AXMenu", "AXMenuBar", "AXMenuItem":
            return "menu"
        case "AXList", "AXOutline", "AXTable":
            return "list"
        case "AXRow":
            return "row"
        case "AXCell":
            return "cell"
        case "AXWebArea":
            return "web"
        case "AXScrollArea":
            return "scroll"
        case "AXGroup":
            return "group"
        default:
            return role?.replacingOccurrences(of: "AX", with: "").lowercased() ?? "node"
        }
    }

    private func compactActions(from value: JSONValue?) -> [String] {
        guard case let .array(values)? = value else {
            return []
        }
        var actions: [String] = []
        for value in values {
            guard case let .string(action) = value else {
                continue
            }
            let compact: String?
            switch action {
            case "AXPress":
                compact = "click"
            case "AXSetValue":
                compact = "set_value"
            case "AXShowMenu":
                compact = "menu"
            case "AXScrollToVisible":
                compact = "scroll_to_visible"
            default:
                compact = nil
            }
            if let compact, !actions.contains(compact) {
                actions.append(compact)
            }
        }
        return actions
    }

    private func appendText(_ value: JSONValue, depth: Int, lines: inout [String]) {
        guard case let .object(object) = value else {
            return
        }
        let indent = String(repeating: "  ", count: depth)
        let handle = string("handle", in: object) ?? "?:?"
        let role = string("role", in: object) ?? "node"
        var line = "\(indent)\(handle) \(role)"
        if let label = string("label", in: object) {
            line += " \(yamlString(label))"
        }
        if case let .array(actions)? = object["actions"], !actions.isEmpty {
            let actionText = actions.compactMap { value -> String? in
                guard case let .string(action) = value else {
                    return nil
                }
                return action
            }.joined(separator: ",")
            if !actionText.isEmpty {
                line += " [\(actionText)]"
            }
        }
        if let truncated = string("truncated", in: object) {
            line += " # \(truncated)"
        }
        lines.append(line)

        if case let .array(children)? = object["children"] {
            for child in children {
                appendText(child, depth: depth + 1, lines: &lines)
            }
        }
    }

    private func string(_ key: String, in object: [String: JSONValue]) -> String? {
        guard case let .string(value)? = object[key] else {
            return nil
        }
        return value
    }

    private func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(object) = self else {
            return nil
        }
        return object
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else {
            return nil
        }
        return values
    }

    var scalarText: String? {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case .object, .array, .null:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .double(value):
            return value
        case let .int(value):
            return Double(value)
        case .string, .bool, .object, .array, .null:
            return nil
        }
    }
}
