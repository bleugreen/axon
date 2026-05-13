import Foundation

public struct SnapshotObservationFormatter {
    private static let maxObservedChildren = 24
    private static let maxCoalescedLabelLength = 240

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

        let rawChildren = object["children"]?.arrayValue ?? []
        var compactChildren = rawChildren.flatMap {
            compactNodes(from: $0, snapshotID: snapshotID, frames: frames, nextIndex: &nextIndex)
        }

        let role = normalizedRole(string("role", in: object))
        var label = label(in: object)
        let actions = exposedActions(compactActions(from: object["actions"]), role: role)
        var truncationReasons: [String] = []
        if let truncation = string("truncationReason", in: object) {
            truncationReasons.append(truncation)
        }
        coalesceTextChildren(&compactChildren, parentRole: role, parentLabel: &label)

        guard shouldInclude(object, role: role, label: label, actions: actions, truncationReasons: truncationReasons) else {
            return compactChildren
        }

        if compactChildren.count > Self.maxObservedChildren {
            truncationReasons.append("showing \(Self.maxObservedChildren) of \(compactChildren.count) children")
            compactChildren = Array(compactChildren.prefix(Self.maxObservedChildren))
        }

        var compact: [String: JSONValue] = [
            "handle": .string("\(snapshotID):\(index)"),
            "role": .string(role),
            "children": .array(compactChildren)
        ]
        if let label {
            compact["label"] = .string(label)
        }
        if !actions.isEmpty {
            compact["actions"] = .array(actions.map(JSONValue.string))
        }
        if !truncationReasons.isEmpty {
            compact["truncated"] = .string(truncationReasons.joined(separator: "; "))
        }
        if frames, let frame = object["frame"], frame != .null {
            compact["frame"] = frame
        }
        if compactChildren.isEmpty {
            compact.removeValue(forKey: "children")
        }
        return [.object(compact)]
    }

    private func shouldInclude(
        _ object: [String: JSONValue],
        role: String,
        label: String?,
        actions: [String],
        truncationReasons: [String]
    ) -> Bool {
        if isFarOffscreen(object["frame"]) {
            return false
        }
        if !truncationReasons.isEmpty {
            return true
        }
        if label != nil {
            return true
        }
        if !isStructural(role), (actions.contains("click") || actions.contains("set_value")) {
            return true
        }
        switch role {
        case "window", "field", "button", "link", "menu", "list", "row", "cell", "heading", "text", "tabgroup", "radiobutton", "checkbox", "menubutton":
            return true
        default:
            return false
        }
    }

    private func coalesceTextChildren(
        _ children: inout [JSONValue],
        parentRole: String,
        parentLabel: inout String?
    ) {
        guard parentRole != "window" else {
            return
        }

        var remaining: [JSONValue] = []
        var textParts: [(label: String, value: JSONValue)] = []
        for child in children {
            guard case let .object(object) = child,
                  case .string("text")? = object["role"],
                  isCoalescibleTextLeaf(object),
                  let childLabel = string("label", in: object)
            else {
                remaining.append(child)
                continue
            }

            if let parentLabel, label(parentLabel, alreadyContains: childLabel) {
                continue
            }
            textParts.append((childLabel, child))
        }

        if textParts.count >= 2, parentLabel == nil {
            parentLabel = coalescedLabel(from: textParts.map(\.label))
            children = remaining
        } else {
            children = remaining + textParts.map(\.value)
        }
    }

    private func isCoalescibleTextLeaf(_ object: [String: JSONValue]) -> Bool {
        guard string("label", in: object) != nil else {
            return false
        }
        if case let .array(actions)? = object["actions"], actions.contains(where: { $0 == .string("set_value") }) {
            return false
        }
        if case let .array(children)? = object["children"], !children.isEmpty {
            return false
        }
        if object["truncated"] != nil {
            return false
        }
        return true
    }

    private func label(_ parent: String, alreadyContains child: String) -> Bool {
        let normalizedParent = parent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedChild = child.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedParent == normalizedChild || normalizedParent.contains(normalizedChild)
    }

    private func coalescedLabel(from parts: [String]) -> String {
        let joined = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard joined.count > Self.maxCoalescedLabelLength else {
            return joined
        }
        let endIndex = joined.index(joined.startIndex, offsetBy: Self.maxCoalescedLabelLength)
        return "\(joined[..<endIndex])..."
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
            if let value = string(key, in: object), !value.isEmpty, !isAXPointerDescription(value) {
                return value
            }
        }
        return nil
    }

    private func isAXPointerDescription(_ value: String) -> Bool {
        value.hasPrefix("<AXUIElement ") && value.contains("> {pid=")
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

    private func exposedActions(_ actions: [String], role: String) -> [String] {
        if isStructural(role) || role == "text" || role == "heading" {
            return []
        }

        var exposed: [String] = []
        if actions.contains("set_value") {
            exposed.append("set_value")
        }
        if actions.contains("click"), isClickAffordance(role) {
            exposed.append("click")
        }
        if (role == "menu" || role == "menubutton"), actions.contains("menu") {
            exposed.append("menu")
        }
        return exposed
    }

    private func isStructural(_ role: String) -> Bool {
        ["group", "scroll", "web", "toolbar", "splitter"].contains(role)
    }

    private func isClickAffordance(_ role: String) -> Bool {
        [
            "button",
            "link",
            "checkbox",
            "radiobutton",
            "menubutton",
            "menu",
            "field",
            "popupbutton",
            "incrementor",
            "image"
        ].contains(role)
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
