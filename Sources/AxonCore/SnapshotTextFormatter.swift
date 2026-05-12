public struct SnapshotTextFormatter {
    public init() {}

    public func format(_ snapshot: AppSnapshot) -> String {
        var lines: [String] = [
            "App: \(snapshot.app.name) (pid \(snapshot.app.processIdentifier))",
            "Snapshot: \(snapshot.id.rawValue)"
        ]

        if let bundleIdentifier = snapshot.app.bundleIdentifier {
            lines.append("Bundle: \(bundleIdentifier)")
        }
        if let screenshot = snapshot.screenshot {
            lines.append("Screenshot: \(screenshot.mediaType), \(screenshot.width)x\(screenshot.height), \(screenshot.base64Data.count) base64 chars")
        }

        var nextIndex = 0
        for window in snapshot.windows {
            append(window, depth: 0, nextIndex: &nextIndex, lines: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private func append(_ node: AXNode, depth: Int, nextIndex: inout Int, lines: inout [String]) {
        let index = nextIndex
        nextIndex += 1

        let indent = String(repeating: "\t", count: depth)
        var parts = ["\(indent)\(index)", node.role]
        if let title = node.title, !title.isEmpty {
            parts.append(title)
        } else if let value = node.value, !value.isEmpty {
            parts.append(value)
        }
        if !node.actions.isEmpty {
            parts.append("Actions: \(node.actions.joined(separator: ", "))")
        }
        if let truncationReason = node.truncationReason {
            parts.append("Truncated: \(truncationReason)")
        }
        lines.append(parts.joined(separator: " "))

        for child in node.children {
            append(child, depth: depth + 1, nextIndex: &nextIndex, lines: &lines)
        }
    }
}
