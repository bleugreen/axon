import Foundation

public struct SnapshotObservationFormatter {
    private static let maxObservedChildren = 24
    private static let maxCoalescedLabelLength = 240
    private static let maxScreenTextItems = 100

    public init() {}

    public func observation(from snapshot: JSONValue, frames: Bool) -> JSONValue {
        observation(from: snapshot, frames: frames, maxDepth: nil)
    }

    public func observation(from snapshot: JSONValue, frames: Bool, maxDepth: Int?) -> JSONValue {
        guard case let .object(object) = snapshot else {
            return snapshot
        }

        let snapshotID = string("id", in: object) ?? "unknown"
        let app = object["app"]?.objectValue ?? [:]
        let compactTree = compactForest(
            from: object["windows"],
            snapshotID: snapshotID,
            frames: frames,
            maxDepth: maxDepth
        )
        var observation: [String: JSONValue] = [
            "format": .string("observation"),
            "snapshot": .string(snapshotID),
            "app": .string(string("name", in: app) ?? "unknown"),
            "pid": app["processIdentifier"] ?? .null,
            "tree": .string(dsl(from: compactTree))
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
        if let redaction = mergedRedaction(topLevel: object["redaction"], nodes: compactTree) {
            observation["redaction"] = redaction
        }
        if let warnings = object["warnings"] {
            observation["warnings"] = warnings
        }
        return .object(observation)
    }

    public func children(from childrenPage: JSONValue, frames: Bool) -> JSONValue {
        guard case let .object(object) = childrenPage else {
            return childrenPage
        }

        let snapshotID = string("snapshot", in: object) ?? "unknown"
        let baseIndex = object["baseIndex"]?.intValue ?? 0
        let compactTree = compactForest(
            from: object["children"],
            snapshotID: snapshotID,
            frames: frames,
            baseIndex: baseIndex
        )
        var observation: [String: JSONValue] = [
            "format": .string("children"),
            "snapshot": .string(snapshotID),
            "parent": object["parent"] ?? .null,
            "offset": object["offset"] ?? .int(0),
            "limit": object["limit"] ?? .int(0),
            "total": object["total"] ?? .int(0),
            "nextOffset": object["nextOffset"] ?? .null,
            "tree": .string(dsl(from: compactTree))
        ]
        if let redaction = mergedRedaction(topLevel: nil, nodes: compactTree) {
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
        if case let .array(items)? = object["screenText"], !items.isEmpty {
            lines.append("screenText:")
            for item in items {
                appendScreenText(item, lines: &lines)
            }
        }
        if case let .string(tree)? = object["tree"], string("format", in: object) == "observation" {
            lines.append("tree:")
            appendIndentedTree(tree, lines: &lines)
        } else if case let .array(nodes)? = object["tree"] {
            lines.append("tree:")
            for node in nodes {
                appendDSL(node, depth: 1, lines: &lines)
            }
        } else if string("format", in: object) == "children" {
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
            if case let .string(tree)? = object["tree"] {
                appendIndentedTree(tree, lines: &lines)
            } else if case let .array(nodes)? = object["items"] {
                for node in nodes {
                    appendDSL(node, depth: 1, lines: &lines)
                }
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

    private func compactForest(
        from value: JSONValue?,
        snapshotID: String,
        frames: Bool,
        maxDepth: Int? = nil
    ) -> [JSONValue] {
        compactForest(from: value, snapshotID: snapshotID, frames: frames, baseIndex: 0, maxDepth: maxDepth)
    }

    private func compactForest(
        from value: JSONValue?,
        snapshotID: String,
        frames: Bool,
        baseIndex: Int,
        maxDepth: Int? = nil
    ) -> [JSONValue] {
        guard case let .array(nodes)? = value else {
            return []
        }
        var nextIndex = baseIndex
        return nodes.flatMap {
            compactNodes(
                from: $0,
                snapshotID: snapshotID,
                frames: frames,
                nextIndex: &nextIndex,
                depth: 0,
                maxDepth: maxDepth
            )
        }
    }

    private func compactNodes(
        from value: JSONValue,
        snapshotID: String,
        frames: Bool,
        nextIndex: inout Int,
        depth: Int,
        maxDepth: Int?
    ) -> [JSONValue] {
        guard case let .object(object) = value else {
            return []
        }

        let index = nextIndex
        nextIndex += 1

        let role = normalizedRole(string("role", in: object))
        let rawChildren = object["children"]?.arrayValue ?? []
        var compactChildren: [JSONValue] = []
        var truncationReasons: [String] = []
        if let maxDepth, depth >= maxDepth, !rawChildren.isEmpty {
            truncationReasons.append("depth limit hides \(childCountDescription(rawChildren.count))")
            nextIndex += descendantCount(in: rawChildren)
        } else {
            for (childOffset, rawChild) in rawChildren.enumerated() {
                let childNodes = compactNodes(
                    from: rawChild,
                    snapshotID: snapshotID,
                    frames: frames,
                    nextIndex: &nextIndex,
                    depth: depth + 1,
                    maxDepth: maxDepth
                )
                compactChildren.append(contentsOf: childNodes.map {
                    withSourceEnd(childOffset + 1, in: $0)
                })
            }
        }

        var label = label(in: object)
        let actions = exposedActions(compactActions(from: object["actions"]), role: role)
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
        let handle = string("handle", in: object) ?? "\(snapshotID):\(index)"
        var more = continuation(from: truncationReasons, handle: handle)
        let rawChildTotal = object["childCount"]?.intValue ?? rawChildren.count
        if rawChildTotal > Self.maxObservedChildren, compactChildren.count > Self.maxObservedChildren {
            let visibleChildren = Array(compactChildren.prefix(Self.maxObservedChildren))
            let sourceOffset = sourceEnd(in: visibleChildren.last) ?? Self.maxObservedChildren
            if var continuation = more {
                continuation.offset = sourceOffset
                more = continuation
                truncationReasons = truncationReasons.map {
                    normalizedChildLimitReason($0, visibleLimit: Self.maxObservedChildren)
                }
            } else {
                more = Continuation(
                    handle: handle,
                    offset: sourceOffset,
                    limit: Self.maxObservedChildren,
                    total: rawChildTotal
                )
                truncationReasons.append("children display limited to \(Self.maxObservedChildren) of \(rawChildTotal)")
            }
            compactChildren = visibleChildren
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
        if let redaction = object["redaction"] {
            compact["redaction"] = redaction
        }
        if let more {
            compact["more"] = more.jsonValue
        }
        if frames, let frame = object["frame"], frame != .null {
            compact["frame"] = frame
        }
        if compactChildren.isEmpty {
            compact.removeValue(forKey: "children")
        }
        return [.object(compact)]
    }

    private func descendantCount(in values: [JSONValue]) -> Int {
        values.reduce(0) { total, value in
            guard case let .object(object) = value else {
                return total
            }
            return total + 1 + descendantCount(in: object["children"]?.arrayValue ?? [])
        }
    }

    private func childCountDescription(_ count: Int) -> String {
        "\(count) \(count == 1 ? "child" : "children")"
    }

    private func withSourceEnd(_ sourceEnd: Int, in value: JSONValue) -> JSONValue {
        guard case var .object(object) = value else {
            return value
        }
        object["_sourceEnd"] = .int(sourceEnd)
        return .object(object)
    }

    private func sourceEnd(in value: JSONValue?) -> Int? {
        guard case let .object(object)? = value else {
            return nil
        }
        return object["_sourceEnd"]?.intValue
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
        if isLowInformationPagingControl(role: role, label: label, actions: actions, hasChildren: hasChildren) {
            return false
        }
        if isFarOffscreen(object["frame"]) && !hasSemanticSubrole(object) {
            return false
        }
        return isContentful(
            role: role,
            label: label,
            actions: actions,
            truncationReasons: truncationReasons,
            hasChildren: hasChildren,
            childCount: childCount
        )
    }

    private func isContentful(
        role: String,
        label: String?,
        actions: [String],
        truncationReasons: [String],
        hasChildren: Bool,
        childCount: Int
    ) -> Bool {
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

    private func isLowInformationPagingControl(
        role: String,
        label: String?,
        actions: [String],
        hasChildren: Bool
    ) -> Bool {
        guard role == "button",
              let label,
              actions == ["click"],
              !hasChildren
        else {
            return false
        }
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "scroll backwards", "scroll forwards":
            return true
        default:
            return false
        }
    }

    private func hasSemanticSubrole(_ object: [String: JSONValue]) -> Bool {
        guard let subrole = string("subrole", in: object) else {
            return false
        }
        return !subrole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private struct Continuation {
        let handle: String
        var offset: Int
        let limit: Int
        let total: Int

        var jsonValue: JSONValue {
            .object([
                "tool": .string("look"),
                "target": .string(handle),
                "offset": .int(offset),
                "limit": .int(limit),
                "total": .int(total)
            ])
        }
    }

    private func continuation(from truncationReasons: [String], handle: String) -> Continuation? {
        for reason in truncationReasons {
            if let range = reason.range(of: #"children limited to ([0-9]+) of ([0-9]+)"#, options: .regularExpression) {
                let match = String(reason[range])
                let values = match
                    .split(whereSeparator: { !$0.isNumber })
                    .compactMap { Int($0) }
                guard values.count >= 2 else {
                    continue
                }
                return Continuation(
                    handle: handle,
                    offset: values[0],
                    limit: Self.maxObservedChildren,
                    total: values[1]
                )
            }
        }
        return nil
    }

    private func normalizedChildLimitReason(_ reason: String, visibleLimit: Int) -> String {
        guard let range = reason.range(of: #"children limited to ([0-9]+) of ([0-9]+)"#, options: .regularExpression) else {
            return reason
        }
        let match = String(reason[range])
        let values = match
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        guard values.count >= 2 else {
            return reason
        }
        return reason.replacingCharacters(in: range, with: "children limited to \(visibleLimit) of \(values[1])")
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

    private func dsl(from nodes: [JSONValue]) -> String {
        var lines: [String] = []
        for node in nodes {
            appendDSL(node, depth: 0, lines: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private func appendIndentedTree(_ tree: String, lines: inout [String]) {
        for line in tree.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append("  \(line)")
        }
    }

    private func appendDSL(_ value: JSONValue, depth: Int, lines: inout [String]) {
        guard case let .object(object) = value else {
            return
        }
        let indent = String(repeating: "  ", count: depth)
        let handle = string("handle", in: object) ?? "?:?"
        let role = string("role", in: object) ?? "node"
        var line = "\(indent)\(handle): \(role)"
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
        if let redaction = firstRedactionLabel(in: object["redaction"]) {
            line += " redaction=\(redaction)"
        }
        if let truncated = string("truncated", in: object) {
            line += " <truncated: \(truncated)>"
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
                appendDSL(child, depth: depth + 1, lines: &lines)
            }
        }
    }

    private func mergedRedaction(topLevel: JSONValue?, nodes: [JSONValue]) -> JSONValue? {
        var merged: [String: JSONValue] = [:]
        if case let .object(redaction)? = topLevel {
            merge(redaction: redaction, into: &merged)
        }
        mergeRedactions(in: nodes, into: &merged)
        return merged.isEmpty ? nil : .object(merged)
    }

    private func mergeRedactions(in nodes: [JSONValue], into merged: inout [String: JSONValue]) {
        for node in nodes {
            guard case let .object(object) = node else {
                continue
            }
            if case let .object(redaction)? = object["redaction"] {
                merge(redaction: redaction, into: &merged)
            }
            if case let .array(children)? = object["children"] {
                mergeRedactions(in: children, into: &merged)
            }
        }
    }

    private func merge(redaction: [String: JSONValue], into merged: inout [String: JSONValue]) {
        for (key, value) in redaction {
            switch (key, value) {
            case let ("fields", .array(values)):
                merged[key] = .array(appendingUnique(values, to: merged[key]?.arrayValue ?? []))
            case let ("references", .object(fields)),
                 let ("matched", .object(fields)):
                merged[key] = .object(mergingArrayFields(fields, into: merged[key]?.objectValue ?? [:]))
            case let ("reasons", .object(fields)),
                 let ("providers", .object(fields)):
                merged[key] = .object(mergingObjectFields(fields, into: merged[key]?.objectValue ?? [:]))
            default:
                if merged[key] == nil {
                    merged[key] = value
                }
            }
        }
    }

    private func mergingArrayFields(
        _ fields: [String: JSONValue],
        into existing: [String: JSONValue]
    ) -> [String: JSONValue] {
        var merged = existing
        for (field, value) in fields {
            guard case let .array(values) = value else {
                if merged[field] == nil {
                    merged[field] = value
                }
                continue
            }
            merged[field] = .array(appendingUnique(values, to: merged[field]?.arrayValue ?? []))
        }
        return merged
    }

    private func mergingObjectFields(
        _ fields: [String: JSONValue],
        into existing: [String: JSONValue]
    ) -> [String: JSONValue] {
        var merged = existing
        for (field, value) in fields where merged[field] == nil {
            merged[field] = value
        }
        return merged
    }

    private func appendingUnique(_ values: [JSONValue], to existing: [JSONValue]) -> [JSONValue] {
        var merged = existing
        for value in values where !merged.contains(value) {
            merged.append(value)
        }
        return merged
    }

    private func string(_ key: String, in object: [String: JSONValue]) -> String? {
        guard case let .string(value)? = object[key] else {
            return nil
        }
        return value
    }

    private func firstRedactionLabel(in value: JSONValue?) -> String? {
        guard case let .object(redaction)? = value else {
            return nil
        }
        if case let .object(references)? = redaction["references"] {
            let labels = references.values.flatMap { value -> [String] in
                guard case let .array(items) = value else {
                    return []
                }
                return items.compactMap(\.scalarText)
            }
            if let first = labels.sorted().first {
                return first
            }
        }
        if case let .object(reasons)? = redaction["reasons"],
           reasons.values.contains(.string("active-credential")) {
            return "active-credential"
        }
        return nil
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
