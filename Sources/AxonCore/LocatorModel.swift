import Foundation

public enum TextMatch: Codable, Equatable, Sendable {
    case exact(String, caseSensitive: Bool = false)
    case contains(String, caseSensitive: Bool = false)

    public func matches(_ value: String?) -> Bool {
        guard let value else {
            return false
        }

        switch self {
        case let .exact(expected, caseSensitive):
            return normalized(value, caseSensitive: caseSensitive) == normalized(expected, caseSensitive: caseSensitive)
        case let .contains(needle, caseSensitive):
            return normalized(value, caseSensitive: caseSensitive)
                .contains(normalized(needle, caseSensitive: caseSensitive))
        }
    }

    public var reasonFragment: String {
        switch self {
        case let .exact(value, _):
            return "exact \(value)"
        case let .contains(value, _):
            return "contains \(value)"
        }
    }

    private func normalized(_ value: String, caseSensitive: Bool) -> String {
        caseSensitive ? value : value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public struct AXAncestorLocator: Codable, Equatable, Sendable {
    public let role: String?
    public let subrole: String?
    public let identifier: TextMatch?
    public let title: TextMatch?
    public let label: TextMatch?

    public init(
        role: String? = nil,
        subrole: String? = nil,
        identifier: TextMatch? = nil,
        title: TextMatch? = nil,
        label: TextMatch? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.label = label
    }

    func matches(_ node: AXNode) -> Bool {
        if let role, node.role != role {
            return false
        }
        if let subrole, node.subrole != subrole {
            return false
        }
        if let identifier, !identifier.matches(node.identifier) {
            return false
        }
        if let title, !title.matches(node.title) {
            return false
        }
        if let label, !label.matches(node.displayLabel) {
            return false
        }
        return true
    }
}

public struct AXLocator: Codable, Equatable, Sendable {
    public let role: String?
    public let subrole: String?
    public let title: TextMatch?
    public let label: TextMatch?
    public let value: TextMatch?
    public let description: TextMatch?
    public let identifier: TextMatch?
    public let actions: [String]
    public let ancestors: [AXAncestorLocator]

    public init(
        role: String? = nil,
        subrole: String? = nil,
        title: TextMatch? = nil,
        label: TextMatch? = nil,
        value: TextMatch? = nil,
        description: TextMatch? = nil,
        identifier: TextMatch? = nil,
        actions: [String] = [],
        ancestors: [AXAncestorLocator] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.value = value
        self.description = description
        self.identifier = identifier
        self.actions = actions
        self.ancestors = ancestors
    }
}

public enum LocatorResolutionStatus: String, Codable, Equatable, Sendable {
    case unique
    case ambiguous
    case missing
}

public struct LocatorCandidate: Codable, Equatable, Sendable {
    public let index: Int
    public let handle: SnapshotHandle?
    public let role: String
    public let title: String?
    public let frame: AXFrame?
    public let score: Int
    public let reasons: [String]

    public init(
        index: Int,
        handle: SnapshotHandle?,
        role: String,
        title: String?,
        frame: AXFrame? = nil,
        score: Int,
        reasons: [String]
    ) {
        self.index = index
        self.handle = handle
        self.role = role
        self.title = title
        self.frame = frame
        self.score = score
        self.reasons = reasons
    }
}

public struct LocatorResolution: Codable, Equatable, Sendable {
    public let status: LocatorResolutionStatus
    public let snapshotID: SnapshotID
    public let best: LocatorCandidate?
    public let candidates: [LocatorCandidate]

    init(snapshotID: SnapshotID, candidates: [LocatorCandidate]) {
        let best = Self.uniqueHighestScoringCandidate(in: candidates)
        self.init(
            status: candidates.isEmpty ? .missing : (best == nil ? .ambiguous : .unique),
            snapshotID: snapshotID,
            best: best,
            candidates: candidates
        )
    }

    public init(
        status: LocatorResolutionStatus,
        snapshotID: SnapshotID,
        best: LocatorCandidate?,
        candidates: [LocatorCandidate]
    ) {
        self.status = status
        self.snapshotID = snapshotID
        self.best = best
        self.candidates = candidates
    }

    private static func uniqueHighestScoringCandidate(in candidates: [LocatorCandidate]) -> LocatorCandidate? {
        guard let highestScore = candidates.map(\.score).max() else {
            return nil
        }
        let highestScoring = candidates.filter { $0.score == highestScore }
        return highestScoring.count == 1 ? highestScoring[0] : nil
    }
}

public struct LocatorResolver: Sendable {
    private static let descendantLabelRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXLink",
        "AXMenuButton",
        "AXMenuItem",
        "AXPopUpButton",
        "AXRadioButton"
    ]

    public init() {}

    public func resolve(_ locator: AXLocator, in snapshot: AppSnapshot) -> LocatorResolution {
        let candidates = indexedNodesWithAncestors(in: snapshot).compactMap { indexed, ancestors -> LocatorCandidate? in
            candidate(for: indexed, ancestors: ancestors, locator: locator, snapshot: snapshot)
        }

        return LocatorResolution(snapshotID: snapshot.id, candidates: candidates)
    }

    private func candidate(
        for indexed: IndexedAXNode,
        ancestors: [AXNode],
        locator: AXLocator,
        snapshot: AppSnapshot
    ) -> LocatorCandidate? {
        let node = indexed.node
        var reasons: [String] = []

        guard matchesExact(locator.role, actual: node.role, label: "role", reasons: &reasons),
              matchesExact(locator.subrole, actual: node.subrole, label: "subrole", reasons: &reasons),
              matchesTitle(locator.title, node: node, reasons: &reasons),
              matchesLabel(locator.label, node: node, reasons: &reasons),
              matchesValue(locator.value, node: node, reasons: &reasons),
              matches(locator.description, actual: node.description, label: "description", reasons: &reasons),
              matches(locator.identifier, actual: node.identifier, label: "identifier", reasons: &reasons),
              matchesAncestors(locator.ancestors, actual: ancestors, snapshot: snapshot, reasons: &reasons)
        else {
            return nil
        }
        addActionReasons(locator.actions, actual: node.actions, reasons: &reasons)
        addPrimaryWindowReason(for: indexed.node, ancestors: ancestors, snapshot: snapshot, reasons: &reasons)

        return LocatorCandidate(
            index: indexed.index,
            handle: snapshot.handle(for: indexed.index),
            role: node.role,
            title: node.title,
            frame: node.frame,
            score: score(for: locator, node: node, reasons: reasons),
            reasons: reasons
        )
    }

    private func score(for locator: AXLocator, node: AXNode, reasons: [String]) -> Int {
        var score = reasons.count
        if let value = locator.value, value.matches(node.value) {
            score += 2
        }
        return score
    }

    private func matchesExact(_ expected: String?, actual: String?, label: String, reasons: inout [String]) -> Bool {
        guard let expected else {
            return true
        }
        guard actual == expected else {
            return false
        }
        reasons.append("\(label) \(expected)")
        return true
    }

    private func matches(_ matcher: TextMatch?, actual: String?, label: String, reasons: inout [String]) -> Bool {
        guard let matcher else {
            return true
        }
        guard matcher.matches(actual) else {
            return false
        }
        reasons.append("\(label) \(matcher.reasonFragment)")
        return true
    }

    private func matchesValue(_ matcher: TextMatch?, node: AXNode, reasons: inout [String]) -> Bool {
        guard let matcher else {
            return true
        }
        if matcher.matches(node.value) {
            reasons.append("value \(matcher.reasonFragment)")
            return true
        }
        return AXRoleSemantics.isEditableTextRole(node.role)
    }

    private func matchesTitle(_ matcher: TextMatch?, node: AXNode, reasons: inout [String]) -> Bool {
        guard let matcher else {
            return true
        }
        if matcher.matches(node.title) {
            reasons.append("title \(matcher.reasonFragment)")
            return true
        }
        guard Self.descendantLabelRoles.contains(node.role),
              descendantLabels(of: node).contains(where: matcher.matches)
        else {
            return false
        }
        reasons.append("descendant title \(matcher.reasonFragment)")
        return true
    }

    private func matchesLabel(_ matcher: TextMatch?, node: AXNode, reasons: inout [String]) -> Bool {
        guard let matcher else {
            return true
        }
        if matcher.matches(node.displayLabel) {
            reasons.append("label \(matcher.reasonFragment)")
            return true
        }
        guard descendantLabels(of: node).contains(where: matcher.matches) else {
            return false
        }
        reasons.append("descendant label \(matcher.reasonFragment)")
        return true
    }

    private func descendantLabels(of node: AXNode) -> [String] {
        var labels: [String] = []
        var queue = node.children
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let label = next.displayLabel {
                labels.append(label)
            }
            queue.append(contentsOf: next.children)
        }
        return labels
    }

    private func addActionReasons(_ expected: [String], actual: [String], reasons: inout [String]) {
        for action in expected {
            if actual.contains(action) {
                reasons.append("action \(action)")
            }
        }
    }

    private func matchesAncestors(
        _ expected: [AXAncestorLocator],
        actual ancestors: [AXNode],
        snapshot: AppSnapshot,
        reasons: inout [String]
    ) -> Bool {
        var searchStart = 0
        for locator in expected {
            if matchesAppAncestor(locator, snapshot: snapshot) {
                reasons.append("ancestor role AXApplication")
                continue
            }
            guard let matchIndex = ancestors[searchStart...].firstIndex(where: locator.matches) else {
                return false
            }
            searchStart = ancestors.index(after: matchIndex)
            if let role = locator.role {
                reasons.append("ancestor role \(role)")
            }
            if let subrole = locator.subrole {
                reasons.append("ancestor subrole \(subrole)")
            }
            if let identifier = locator.identifier {
                reasons.append("ancestor identifier \(identifier.reasonFragment)")
            }
            if let title = locator.title {
                reasons.append("ancestor title \(title.reasonFragment)")
            }
            if let label = locator.label {
                reasons.append("ancestor label \(label.reasonFragment)")
            }
        }
        return true
    }

    private func matchesAppAncestor(_ locator: AXAncestorLocator, snapshot: AppSnapshot) -> Bool {
        guard locator.role == "AXApplication" else {
            return false
        }
        if let subrole = locator.subrole, !subrole.isEmpty {
            return false
        }
        if let identifier = locator.identifier, !identifier.matches(snapshot.app.bundleIdentifier) {
            return false
        }
        if let title = locator.title, !title.matches(snapshot.app.name) {
            return false
        }
        if let label = locator.label, !label.matches(snapshot.app.name) {
            return false
        }
        return true
    }

    private func addPrimaryWindowReason(
        for node: AXNode,
        ancestors: [AXNode],
        snapshot: AppSnapshot,
        reasons: inout [String]
    ) {
        guard snapshot.windows.count > 1, let firstWindow = snapshot.windows.first else {
            return
        }
        let candidateWindow = node.role == "AXWindow" ? node : ancestors.first
        if candidateWindow == firstWindow {
            reasons.append("primary window")
        }
    }

    private func indexedNodesWithAncestors(in snapshot: AppSnapshot) -> [(IndexedAXNode, [AXNode])] {
        var result: [(IndexedAXNode, [AXNode])] = []
        var nextIndex = 0
        for window in snapshot.windows {
            append(window, ancestors: [], nextIndex: &nextIndex, to: &result)
        }
        return result
    }

    private func append(
        _ node: AXNode,
        ancestors: [AXNode],
        nextIndex: inout Int,
        to result: inout [(IndexedAXNode, [AXNode])]
    ) {
        let index = nextIndex
        nextIndex += 1
        result.append((IndexedAXNode(index: index, node: node), ancestors))

        let childAncestors = ancestors + [node]
        for child in node.children {
            append(child, ancestors: childAncestors, nextIndex: &nextIndex, to: &result)
        }
    }
}

private extension AXNode {
    var displayLabel: String? {
        for value in [title, value, description, identifier, help] {
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
