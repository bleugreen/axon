import AppKit
import AxonCore
import SwiftUI

struct AXTreeInspector: View {
    let appName: String?
    let actedOnTarget: JSONValue?
    let refreshToken: Int

    @State private var roots: [AXTreeNode] = []
    @State private var isResolvingActedOnTarget = false
    @State private var query = ""
    @State private var selectedNodeID: String?
    @State private var isLoading = false
    @State private var error: String?
    @State private var expandedIDs: Set<String> = []
    @State private var overlay = AppKitTargetBadgeOverlay(waitsForDisplay: false)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search tree", text: $query)
                    .textFieldStyle(.roundedBorder)

                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(appName == nil || isLoading)
                .help("Refresh AX tree")
            }
            .padding(12)

            if let appName {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredRoots) { node in
                                AXTreeNodeRow(
                                    node: node,
                                    depth: 0,
                                    query: normalizedQuery,
                                    selectedNodeID: $selectedNodeID,
                                    expandedIDs: $expandedIDs,
                                    select: selectNode
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                    }
                    .overlay {
                        if roots.isEmpty {
                            Text("No tree captured for \(appName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("No target app in recipe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let selectedNode {
                Divider()
                AXTreeNodeDetails(node: selectedNode)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: appName) {
            refresh()
        }
        .onChange(of: refreshToken) {
            refresh()
        }
        .onChange(of: actedOnTarget) {
            jumpToActedOnTarget()
        }
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredRoots: [AXTreeNode] {
        guard !normalizedQuery.isEmpty else {
            return roots
        }
        return roots.compactMap { $0.filtered(matching: normalizedQuery) }
    }

    private var selectedNode: AXTreeNode? {
        guard let selectedNodeID else {
            return nil
        }
        for root in roots {
            if let node = root.find(id: selectedNodeID) {
                return node
            }
        }
        return nil
    }

    private func refresh() {
        guard let appName, !appName.isEmpty else {
            roots = []
            error = nil
            return
        }
        guard !isLoading else {
            return
        }
        isLoading = true
        error = nil

        Task.detached(priority: .userInitiated) {
            let result: Result<[AXTreeNode], Error>
            let reader = FullAXTreeReader()
            do {
                result = .success(try reader.read(appName: appName))
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                isLoading = false
                switch result {
                case let .success(nodes):
                    roots = nodes
                    expandedIDs = nodes.defaultExpandedIDs()
                    if let selectedNodeID, nodes.containsNode(id: selectedNodeID) == false {
                        self.selectedNodeID = nil
                    }
                    jumpToActedOnTarget()
                case let .failure(error):
                    roots = []
                    self.error = String(describing: error)
                }
            }
        }
    }

    private func selectNode(_ node: AXTreeNode) {
        selectedNodeID = node.id
        guard let frame = node.frame else {
            return
        }
        overlay.showTarget(VisualTarget(
            frame: frame,
            label: node.displayTitle,
            state: .planned,
            duration: 1.1
        ))
    }

    private func jumpToActedOnTarget() {
        guard let appName, let actedOnTarget, !isResolvingActedOnTarget else {
            return
        }
        isResolvingActedOnTarget = true
        Task.detached(priority: .userInitiated) {
            let result: Result<ActedOnNodeCue?, Error>
            do {
                let response = try SocketClient(
                    path: AxonEnvironment.socketPath(),
                    responseTimeoutSeconds: SocketClient.defaultBatchResponseTimeoutSeconds
                ).send(JSONRPCRequest(
                    id: .string("editor.ax-tree.find-target"),
                    method: "find",
                    params: .object([
                        "app": .string(appName),
                        "locator": actedOnTarget
                    ])
                ))
                if let error = response.error {
                    throw AXTreeInspectorError.message(error.message)
                }
                result = .success(ActedOnNodeCue(json: response.result?["resolution"]?["best"]))
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                isResolvingActedOnTarget = false
                if case let .success(cue?) = result {
                    applyActedOnCue(cue)
                }
            }
        }
    }

    private func applyActedOnCue(_ cue: ActedOnNodeCue) {
        if let frame = cue.frame {
            overlay.showTarget(VisualTarget(
                frame: frame,
                label: cue.displayTitle,
                state: .planned,
                duration: 1.2
            ))
        }

        if let handle = cue.handle, roots.containsNode(id: handle) {
            selectedNodeID = handle
            expandedIDs.formUnion(roots.ancestorIDs(to: handle))
            return
        }
        if let match = roots.bestMatch(for: cue) {
            selectedNodeID = match.id
            expandedIDs.formUnion(roots.ancestorIDs(to: match.id))
        }
    }
}

private struct FullAXTreeReader: Sendable {
    func read(appName: String) throws -> [AXTreeNode] {
        let response = try SocketClient(
            path: AxonEnvironment.socketPath(),
            responseTimeoutSeconds: SocketClient.defaultBatchResponseTimeoutSeconds
        ).send(JSONRPCRequest(
            id: .string("editor.ax-tree.look"),
            method: "look",
            params: .object([
                "target": .string(appName),
                "tree": .bool(true)
            ])
        ))
        if let error = response.error {
            throw AXTreeInspectorError.message(error.message)
        }
        guard let snapshot = response.result?["snapshot"] else {
            throw AXTreeInspectorError.message("AX tree response did not include a snapshot")
        }
        return try AXTreeNode.nodes(fromSnapshotJSON: snapshot)
    }
}

private struct ActedOnNodeCue {
    let handle: String?
    let role: String?
    let title: String?
    let frame: AXFrame?

    init?(json: JSONValue?) {
        guard case let .object(object)? = json else {
            return nil
        }
        handle = object["handle"]?.stringValue
        role = object["role"]?.stringValue
        title = object["title"]?.stringValue
        frame = AXFrame(json: object["frame"])
    }

    var displayTitle: String {
        let title = [role, title].compactMap { $0?.nilIfEmpty }.joined(separator: " ")
        return title.isEmpty ? "Acted-on node" : title
    }
}

private struct AXTreeNodeRow: View {
    let node: AXTreeNode
    let depth: Int
    let query: String
    @Binding var selectedNodeID: String?
    @Binding var expandedIDs: Set<String>
    let select: (AXTreeNode) -> Void

    @ViewBuilder
    var body: some View {
        if node.shouldHideInTree(query: query) {
            EmptyView()
        } else if node.shouldCollapseInTree(query: query) {
            ForEach(node.children) { child in
                AXTreeNodeRow(
                    node: child,
                    depth: depth,
                    query: query,
                    selectedNodeID: $selectedNodeID,
                    expandedIDs: $expandedIDs,
                    select: select
                )
            }
        } else {
            treeRow
        }
    }

    private var treeRow: some View {
        let isExpanded = expandedIDs.contains(node.id) || !query.isEmpty
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    toggleExpanded(isExpanded: isExpanded)
                } label: {
                    Image(systemName: node.hasChildren ? isExpanded ? "chevron.down" : "chevron.right" : "circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(!node.hasChildren)
                .help(isExpanded ? "Collapse children" : "Expand children")

                Button {
                    select(node)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(node.role)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            if node.isActionable {
                                Image(systemName: "cursorarrow.click.2")
                                    .font(.caption2)
                                    .foregroundStyle(RecipeEditorPalette.action)
                            }
                            Spacer(minLength: 0)
                        }
                        if let subtitle = node.subtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(node.helpText)
            }
            .padding(.leading, CGFloat(depth) * 8)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selectedNodeID == node.id ? RecipeEditorPalette.selectionFill : Color.clear)
            )

            if isExpanded {
                ForEach(node.children) { child in
                    AXTreeNodeRow(
                        node: child,
                        depth: depth + 1,
                        query: query,
                        selectedNodeID: $selectedNodeID,
                        expandedIDs: $expandedIDs,
                        select: select
                    )
                }
            }
        }
    }

    private func toggleExpanded(isExpanded: Bool) {
        if expandedIDs.contains(node.id) {
            expandedIDs.remove(node.id)
        } else {
            expandedIDs.insert(node.id)
        }
    }
}

private struct AXTreeNodeDetails: View {
    let node: AXTreeNode

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Details")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            detail("Role", node.role)
            detail("Title", node.title)
            detail("Value", node.value)
            detail("Identifier", node.identifier)
            if let frame = node.frame {
                detail("Frame", "\(Int(frame.x)), \(Int(frame.y))  \(Int(frame.width)) x \(Int(frame.height))")
            }
            if !node.actions.isEmpty {
                detail("Actions", node.actions.joined(separator: ", "))
            }
            detail("Source", node.source)
            if node.isRepeated {
                detail("Repeated", "Already visited in this refresh")
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                Text(value)
                    .font(.caption.monospaced())
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct AXTreeNode: Identifiable, Equatable {
    let id: String
    let handle: String?
    let role: String
    let title: String?
    let value: String?
    let description: String?
    let identifier: String?
    let frame: AXFrame?
    let actions: [String]
    let source: String?
    let childCount: Int
    let isRepeated: Bool
    let children: [AXTreeNode]

    static func nodes(fromSnapshotJSON snapshot: JSONValue) throws -> [AXTreeNode] {
        guard case let .object(object) = snapshot,
              case let .array(windows)? = object["windows"]
        else {
            throw AXTreeInspectorError.message("AX tree response did not include window nodes")
        }

        var nextIndex = 0
        return try windows.map { window in
            try AXTreeNode(json: window, nextIndex: &nextIndex)
        }
    }

    private init(json: JSONValue, nextIndex: inout Int) throws {
        guard case let .object(object) = json else {
            throw AXTreeInspectorError.message("AX tree node was not an object")
        }
        let index = nextIndex
        nextIndex += 1
        let children = try (object["children"]?.treeArrayValue ?? []).map { child in
            try AXTreeNode(json: child, nextIndex: &nextIndex)
        }
        let handle = object["handle"]?.stringValue
        self.init(
            id: handle ?? "node-\(index)",
            handle: handle,
            role: object["role"]?.stringValue ?? "AXUnknown",
            title: object["title"]?.stringValue,
            value: object["value"]?.stringValue,
            description: object["description"]?.stringValue,
            identifier: object["identifier"]?.stringValue,
            frame: AXFrame(json: object["frame"]),
            actions: object["actions"]?.stringArrayValue ?? [],
            source: nil,
            childCount: object["childCount"]?.intValue ?? children.count,
            isRepeated: false,
            children: children
        )
    }

    private init(
        id: String,
        handle: String?,
        role: String,
        title: String?,
        value: String?,
        description: String?,
        identifier: String?,
        frame: AXFrame?,
        actions: [String],
        source: String?,
        childCount: Int,
        isRepeated: Bool,
        children: [AXTreeNode]
    ) {
        self.id = id
        self.handle = handle
        self.role = role
        self.title = title
        self.value = value
        self.description = description
        self.identifier = identifier
        self.frame = frame
        self.actions = actions
        self.source = source
        self.childCount = childCount
        self.isRepeated = isRepeated
        self.children = children
    }

    var titleOrValue: String? {
        rawTitleOrValue ?? inferredDescendantLabel
    }

    var displayTitle: String {
        titleOrValue.map { "\(role) \($0)" } ?? role
    }

    var contextLabel: String? {
        guard hasChildren else {
            return nil
        }
        let count = childCount > 0 ? childCount : children.count
        return count == 1 ? "1 child" : "\(count) children"
    }

    var subtitle: String? {
        titleOrValue ?? contextLabel
    }

    var helpText: String {
        var parts = [role]
        if let titleOrValue {
            parts.append(titleOrValue)
        }
        if let contextLabel {
            parts.append(contextLabel)
        }
        if !actions.isEmpty {
            parts.append("Actions: \(actions.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }

    var isActionable: Bool {
        actions.isEmpty == false
    }

    var hasChildren: Bool {
        childCount > 0 || !children.isEmpty
    }

    func find(id: String) -> AXTreeNode? {
        if self.id == id {
            return self
        }
        for child in children {
            if let found = child.find(id: id) {
                return found
            }
        }
        return nil
    }

    func filtered(matching query: String) -> AXTreeNode? {
        let matchingChildren = children.compactMap { $0.filtered(matching: query) }
        if searchableText.contains(query) || !matchingChildren.isEmpty {
            return AXTreeNode(
                id: id,
                handle: handle,
                role: role,
                title: title,
                value: value,
                description: description,
                identifier: identifier,
                frame: frame,
                actions: actions,
                source: source,
                childCount: childCount,
                isRepeated: isRepeated,
                children: matchingChildren
            )
        }
        return nil
    }

    private var searchableText: String {
        [role, title, value, description, identifier, actions.joined(separator: " ")]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    func matchScore(for cue: ActedOnNodeCue) -> Double? {
        var score = 0.0
        if let expectedRole = cue.role, expectedRole != role {
            score += 80
        }
        if let expectedTitle = cue.title?.nilIfEmpty,
           let titleOrValue,
           expectedTitle != titleOrValue {
            score += 40
        }
        if let expectedFrame = cue.frame {
            guard let frame else {
                return nil
            }
            let distance = frame.distance(to: expectedFrame)
            guard distance < 12 else {
                return nil
            }
            score += distance
        }
        return score
    }

    func ancestorIDs(to targetID: String) -> [String]? {
        if id == targetID {
            return []
        }
        for child in children {
            if let childPath = child.ancestorIDs(to: targetID) {
                return [id] + childPath
            }
        }
        return nil
    }

    func collectDefaultExpandedIDs(depth: Int, into ids: inout Set<String>) {
        guard shouldExpandByDefault(depth: depth) else {
            return
        }
        ids.insert(id)
        for child in children {
            child.collectDefaultExpandedIDs(depth: depth + 1, into: &ids)
        }
    }

    private func shouldExpandByDefault(depth: Int) -> Bool {
        guard !children.isEmpty else {
            return false
        }
        if depth < 2 || children.count == 1 {
            return true
        }
        if isAnonymousStructuralParent, depth < 5, childCount <= 128 {
            return true
        }
        return depth < 10 && children.count <= 8 && isStructuralParent
    }

    private var isStructuralParent: Bool {
        switch role {
        case "AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXWebArea", "AXTabPanel", "AXSplitGroup":
            return true
        default:
            return false
        }
    }

    private var isAnonymousStructuralParent: Bool {
        isStructuralParent && rawTitleOrValue == nil
    }

    func shouldCollapseInTree(query: String) -> Bool {
        query.isEmpty && isAnonymousStructuralParent && children.count == 1
    }

    func shouldHideInTree(query: String) -> Bool {
        query.isEmpty
            && isAnonymousStructuralParent
            && children.isEmpty
            && childCount == 0
            && !hasVisibleFrame
    }

    private var inferredDescendantLabel: String? {
        guard isActionable || isStructuralParent else {
            return nil
        }
        var labels: [String] = []
        collectDescendantLabels(into: &labels, depth: 0)
        let joined = labels.prefix(4).joined(separator: " ")
        return joined.nilIfEmpty.map { String($0.prefix(80)) }
    }

    private func collectDescendantLabels(into labels: inout [String], depth: Int) {
        guard labels.count < 4, depth < 3 else {
            return
        }
        for child in children {
            if let label = child.rawTitleOrValue, !labels.contains(label) {
                labels.append(label)
                if labels.count >= 4 {
                    return
                }
            }
            child.collectDescendantLabels(into: &labels, depth: depth + 1)
        }
    }

    private var rawTitleOrValue: String? {
        title?.nilIfEmpty ?? value?.nilIfEmpty ?? description?.nilIfEmpty
    }

    private var hasVisibleFrame: Bool {
        guard let frame else {
            return false
        }
        return frame.width > 0 && frame.height > 0
    }
}

private enum AXTreeInspectorError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message):
            return message
        }
    }
}

private extension Array where Element == AXTreeNode {
    func containsNode(id: String) -> Bool {
        contains { $0.find(id: id) != nil }
    }

    func bestMatch(for cue: ActedOnNodeCue) -> AXTreeNode? {
        var best: (node: AXTreeNode, score: Double)?
        for node in self {
            node.collectBestMatch(for: cue, best: &best)
        }
        return best?.node
    }

    func ancestorIDs(to targetID: String) -> Set<String> {
        for node in self {
            if let ids = node.ancestorIDs(to: targetID) {
                return Set(ids)
            }
        }
        return []
    }

    func defaultExpandedIDs() -> Set<String> {
        var ids = Set<String>()
        for node in self {
            node.collectDefaultExpandedIDs(depth: 0, into: &ids)
        }
        return ids
    }
}

private extension AXFrame {
    init?(json: JSONValue?) {
        guard case let .object(object)? = json else {
            return nil
        }
        guard let x = object["x"]?.numberValue,
              let y = object["y"]?.numberValue,
              let width = object["width"]?.numberValue,
              let height = object["height"]?.numberValue
        else {
            return nil
        }
        self.init(x: x, y: y, width: width, height: height)
    }

    func distance(to other: AXFrame) -> Double {
        abs(x - other.x)
            + abs(y - other.y)
            + abs(width - other.width)
            + abs(height - other.height)
    }

}

private extension AXTreeNode {
    func collectBestMatch(for cue: ActedOnNodeCue, best: inout (node: AXTreeNode, score: Double)?) {
        if let score = matchScore(for: cue),
           best.map({ score < $0.score }) ?? true {
            best = (self, score)
        }
        for child in children {
            child.collectBestMatch(for: cue, best: &best)
        }
    }
}

private extension JSONValue {
    var treeArrayValue: [JSONValue]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    var numberValue: Double? {
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

    var stringArrayValue: [String]? {
        guard case let .array(values) = self else {
            return nil
        }
        return values.compactMap(\.stringValue)
    }

}
