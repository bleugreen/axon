import Foundation

public struct SnapshotObservationFormatter {
    private static let maxObservedChildren = 24
    private static let maxCoalescedLabelLength = 240
    private static let maxScreenTextItems = 100

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
        if let screenText = compactScreenText(from: object["screenText"], frames: frames) {
            observation["screenText"] = screenText
        }
        if let redaction = object["redaction"] {
            observation["redaction"] = redaction
        }
        return .object(observation)
    }

    public func children(from childrenPage: JSONValue, frames: Bool) -> JSONValue {
        guard case let .object(object) = childrenPage else {
            return childrenPage
        }

        let snapshotID = string("snapshot", in: object) ?? "unknown"
        let baseIndex = object["baseIndex"]?.intValue ?? 0
        let observation: [String: JSONValue] = [
            "format": .string("children"),
            "snapshot": .string(snapshotID),
            "parent": object["parent"] ?? .null,
            "offset": object["offset"] ?? .int(0),
            "limit": object["limit"] ?? .int(0),
            "total": object["total"] ?? .int(0),
            "nextOffset": object["nextOffset"] ?? .null,
            "items": .array(compactForest(from: object["children"], snapshotID: snapshotID, frames: frames, baseIndex: baseIndex))
        ]
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
        if case let .array(items)? = object["screenText"], !items.isEmpty {
            lines.append("screenText:")
            for item in items {
                appendScreenText(item, lines: &lines)
            }
        }
        if case let .array(nodes)? = object["tree"] {
            lines.append("tree:")
            for node in nodes {
                appendText(node, depth: 1, lines: &lines)
            }
        } else if case let .array(nodes)? = object["items"] {
            if let parent = object["parent"]?.scalarText {
                lines.append("parent: \(parent)")
            }
            if let offset = object["offset"]?.intValue,
               let limit = object["limit"]?.intValue,
               let total = object["total"]?.intValue {
                lines.append("range: \(offset)..<\(min(offset + limit, total)) of \(total)")
            }
            if let nextOffset = object["nextOffset"]?.scalarText {
                lines.append("nextOffset: \(nextOffset)")
            }
            lines.append("children:")
            for node in nodes {
                appendText(node, depth: 1, lines: &lines)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func compactScreenText(from value: JSONValue?, frames: Bool) -> JSONValue? {
        guard case let .array(items)? = value else {
            return nil
        }
        let compactItems = items.prefix(Self.maxScreenTextItems).compactMap { item -> JSONValue? in
            guard case let .object(object) = item,
                  let text = string("text", in: object),
                  !text.isEmpty
            else {
                return nil
            }

            var compact: [String: JSONValue] = ["text": .string(text)]
            if let confidence = object["confidence"] {
                compact["confidence"] = confidence
            }
            if frames, let frame = object["frame"], frame != .null {
                compact["frame"] = frame
            }
            return .object(compact)
        }
        return .array(compactItems)
    }

    private func appendScreenText(_ value: JSONValue, lines: inout [String]) {
        guard case let .object(object) = value,
              let text = string("text", in: object)
        else {
            return
        }

        var line = "  - \(yamlString(text))"
        if let confidence = object["confidence"]?.doubleValue, confidence < 1 {
            line += " confidence=\(confidence)"
        }
        if let frame = object["frame"]?.objectValue {
            line += " frame=\(compactFrame(frame))"
        }
        lines.append(line)
    }

    private func compactForest(from value: JSONValue?, snapshotID: String, frames: Bool) -> [JSONValue] {
        compactForest(from: value, snapshotID: snapshotID, frames: frames, baseIndex: 0)
    }

    private func compactForest(from value: JSONValue?, snapshotID: String, frames: Bool, baseIndex: Int) -> [JSONValue] {
        guard case let .array(nodes)? = value else {
            return []
        }
        var nextIndex = baseIndex
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
        label = meaningfulLabel(label)

        guard shouldInclude(
            object,
            role: role,
            label: label,
            actions: actions,
            truncationReasons: truncationReasons,
            hasChildren: !compactChildren.isEmpty,
            childCount: compactChildren.count
        ) else {
            return compactChildren
        }

        let outputRole = outputRole(for: role, label: label)
        let handle = "\(snapshotID):\(index)"
        let more = continuation(from: truncationReasons, handle: handle)
        if compactChildren.count > Self.maxObservedChildren, more != nil {
            truncationReasons.append("showing \(Self.maxObservedChildren) of \(compactChildren.count) children")
            compactChildren = Array(compactChildren.prefix(Self.maxObservedChildren))
        }

        var compact: [String: JSONValue] = [
            "handle": .string(handle),
            "role": .string(outputRole),
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
        if let more {
            compact["more"] = more
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
        truncationReasons: [String],
        hasChildren: Bool,
        childCount: Int
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
        if actions.contains("type") {
            return true
        }
        if actions.contains("click"), isClickAffordance(role) {
            return role != "link" || label != nil || hasChildren
        }
        if role == "row" {
            return hasChildren
        }
        if role == "cell" {
            return childCount > 1
        }
        switch role {
        case "window", "field", "button", "link", "menu", "heading", "tabgroup", "radiobutton", "checkbox", "menubutton":
            return true
        case "list":
            return hasChildren
        default:
            return false
        }
    }

    private func outputRole(for role: String, label: String?) -> String {
        if role == "row" {
            return "item"
        }
        if (role == "row" || role == "cell"), label != nil {
            return "group"
        }
        return role
    }

    private func continuation(from truncationReasons: [String], handle: String) -> JSONValue? {
        for reason in truncationReasons {
            if let range = reason.range(of: #"children limited to ([0-9]+) of ([0-9]+)"#, options: .regularExpression) {
                let match = String(reason[range])
                let values = match
                    .split(whereSeparator: { !$0.isNumber })
                    .compactMap { Int($0) }
                guard values.count >= 2 else {
                    continue
                }
                return .object([
                    "tool": .string("look"),
                    "target": .string(handle),
                    "offset": .int(values[0]),
                    "limit": .int(values[0]),
                    "total": .int(values[1])
                ])
            }
        }
        return nil
    }

    private func meaningfulLabel(_ label: String?) -> String? {
        guard let label else {
            return nil
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.inverted.contains($0) }) {
            return nil
        }
        return trimmed
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
        if case let .array(actions)? = object["actions"], actions.contains(where: { $0 == .string("type") }) {
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
        return x != nil && x! < -1_000
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
                compact = "type"
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
        if actions.contains("type") {
            exposed.append("type")
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
        let hasContinuation = object["more"]?.objectValue != nil
        if !hasContinuation, let truncated = string("truncated", in: object) {
            line += " # \(truncated)"
        }
        lines.append(line)
        if let more = object["more"]?.objectValue {
            let target = more["target"]?.scalarText ?? handle
            let offset = more["offset"]?.scalarText ?? "?"
            let limit = more["limit"]?.scalarText ?? "?"
            let total = more["total"]?.scalarText
            var moreLine = "\(indent)  more: look target=\(target) offset=\(offset) limit=\(limit)"
            if let total {
                moreLine += " total=\(total)"
            }
            lines.append(moreLine)
        }

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

    private func compactFrame(_ frame: [String: JSONValue]) -> String {
        let x = frame["x"]?.scalarText ?? "?"
        let y = frame["y"]?.scalarText ?? "?"
        let width = frame["width"]?.scalarText ?? "?"
        let height = frame["height"]?.scalarText ?? "?"
        return "{x:\(x),y:\(y),width:\(width),height:\(height)}"
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

    var intValue: Int? {
        guard case let .int(value) = self else {
            return nil
        }
        return value
    }
}
