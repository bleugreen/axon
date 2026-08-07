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
        caseSensitive ? value : value.lowercased().precomposedStringWithCanonicalMapping
    }
}

private extension TextMatch {
    var evidenceValue: String {
        switch self {
        case let .exact(value, _), let .contains(value, _): value
        }
    }
}

public enum LocatorEvidenceField: String, Codable, Equatable, Sendable {
    case role, subrole, title, label, value, description, identifier
    case actions, ancestors, window, nearbyText, frame
}

public enum LocatorEvidenceOutcome: String, Codable, Equatable, Sendable {
    case matched
    case tolerated
    case absent
    case unevaluated
}

public struct LocatorEvidenceItem: Codable, Equatable, Sendable {
    public let field: LocatorEvidenceField
    public let outcome: LocatorEvidenceOutcome
    public let expected: String?
    public let actual: String?

    public init(field: LocatorEvidenceField, outcome: LocatorEvidenceOutcome, expected: String? = nil, actual: String? = nil) {
        self.field = field
        self.outcome = outcome
        self.expected = expected
        self.actual = actual
    }
}

public enum LocatorResolutionPath: String, Codable, Equatable, Sendable {
    case cached, predicate, scopedScan, fullSnapshot
}

public enum LocatorContextCompleteness: String, Codable, Equatable, Sendable {
    case full, path
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
    public let window: AXAncestorLocator?
    public let nearbyText: [TextMatch]
    public let frame: AXFrame?

    public init(
        role: String? = nil,
        subrole: String? = nil,
        title: TextMatch? = nil,
        label: TextMatch? = nil,
        value: TextMatch? = nil,
        description: TextMatch? = nil,
        identifier: TextMatch? = nil,
        actions: [String] = [],
        ancestors: [AXAncestorLocator] = [],
        window: AXAncestorLocator? = nil,
        nearbyText: [TextMatch] = [],
        frame: AXFrame? = nil
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
        self.window = window
        self.nearbyText = nearbyText
        self.frame = frame
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case subrole
        case title
        case label
        case value
        case description
        case identifier
        case actions
        case ancestors
        case window
        case nearbyText
        case frame
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            role: try container.decodeIfPresent(String.self, forKey: .role),
            subrole: try container.decodeIfPresent(String.self, forKey: .subrole),
            title: try container.decodeIfPresent(TextMatch.self, forKey: .title),
            label: try container.decodeIfPresent(TextMatch.self, forKey: .label),
            value: try container.decodeIfPresent(TextMatch.self, forKey: .value),
            description: try container.decodeIfPresent(TextMatch.self, forKey: .description),
            identifier: try container.decodeIfPresent(TextMatch.self, forKey: .identifier),
            actions: try container.decodeIfPresent([String].self, forKey: .actions) ?? [],
            ancestors: try container.decodeIfPresent([AXAncestorLocator].self, forKey: .ancestors) ?? [],
            window: try container.decodeIfPresent(AXAncestorLocator.self, forKey: .window),
            nearbyText: try container.decodeIfPresent([TextMatch].self, forKey: .nearbyText) ?? [],
            frame: try container.decodeIfPresent(AXFrame.self, forKey: .frame)
        )
    }
}

public enum LocatorResolutionStatus: String, Codable, Equatable, Sendable {
    case unique
    case ambiguous
    case missing
}

public enum LocatorConfidence: String, Codable, Equatable, Sendable {
    case none
    case low
    case medium
    case high
}

public struct LocatorCandidate: Codable, Equatable, Sendable {
    public let index: Int
    public let handle: SnapshotHandle?
    public let role: String
    public let title: String?
    public let frame: AXFrame?
    public let score: Int
    public let reasons: [String]
    public let evidence: [LocatorEvidenceItem]
    public let observedLocator: AXLocator?

    public init(
        index: Int,
        handle: SnapshotHandle?,
        role: String,
        title: String?,
        frame: AXFrame? = nil,
        score: Int,
        reasons: [String],
        evidence: [LocatorEvidenceItem] = [],
        observedLocator: AXLocator? = nil
    ) {
        self.index = index
        self.handle = handle
        self.role = role
        self.title = title
        self.frame = frame
        self.score = score
        self.reasons = reasons
        self.evidence = evidence
        self.observedLocator = observedLocator
    }
}

public struct LocatorResolution: Codable, Equatable, Sendable {
    public let status: LocatorResolutionStatus
    public let snapshotID: SnapshotID
    public let best: LocatorCandidate?
    public let candidates: [LocatorCandidate]
    public let confidence: LocatorConfidence
    public let path: LocatorResolutionPath
    public let context: LocatorContextCompleteness

    init(
        snapshotID: SnapshotID,
        candidates: [LocatorCandidate],
        path: LocatorResolutionPath = .fullSnapshot,
        context: LocatorContextCompleteness = .full
    ) {
        let best = Self.uniqueHighestScoringCandidate(in: candidates)
        let status: LocatorResolutionStatus = candidates.isEmpty ? .missing : (best == nil ? .ambiguous : .unique)
        self.init(
            status: status,
            snapshotID: snapshotID,
            best: best,
            candidates: candidates,
            confidence: Self.confidence(status: status, best: best),
            path: path,
            context: context
        )
    }

    public init(
        status: LocatorResolutionStatus,
        snapshotID: SnapshotID,
        best: LocatorCandidate?,
        candidates: [LocatorCandidate],
        confidence: LocatorConfidence? = nil,
        path: LocatorResolutionPath = .fullSnapshot,
        context: LocatorContextCompleteness = .full
    ) {
        self.status = status
        self.snapshotID = snapshotID
        self.best = best
        self.candidates = candidates
        self.confidence = confidence ?? Self.confidence(status: status, best: best)
        self.path = path
        self.context = context
    }

    private static func uniqueHighestScoringCandidate(in candidates: [LocatorCandidate]) -> LocatorCandidate? {
        guard let highestScore = candidates.map(\.score).max() else {
            return nil
        }
        let highestScoring = candidates.filter { $0.score == highestScore }
        return highestScoring.count == 1 ? highestScoring[0] : nil
    }

    private static func confidence(status: LocatorResolutionStatus, best: LocatorCandidate?) -> LocatorConfidence {
        guard status == .unique, let best else {
            return .none
        }
        let semanticScore = best.score / 1_000
        if semanticScore >= 4 {
            return .high
        }
        if semanticScore >= 2 {
            return .medium
        }
        return semanticScore >= 1 ? .low : .none
    }
}

public struct LocatorResolver: Sendable {
    private let usesMacOSCompensations: Bool
    private static let descendantLabelRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXLink",
        "AXMenuButton",
        "AXMenuItem",
        "AXPopUpButton",
        "AXRadioButton"
    ]
    private static let nearbyTextRoles: Set<String> = [
        "AXHeading",
        "AXStaticText",
        "AXTextArea",
        "AXTextField"
    ]
    private static let sectionLikeRoles: Set<String> = [
        "AXGroup",
        "AXOutline",
        "AXScrollArea",
        "AXTable",
        "AXToolbar",
        "AXWebArea"
    ]

    public init() {
        usesMacOSCompensations = true
    }

    init(platformNeutral: Bool) {
        usesMacOSCompensations = !platformNeutral
    }

    public func resolve(
        _ locator: AXLocator,
        in snapshot: AppSnapshot,
        path: LocatorResolutionPath = .fullSnapshot,
        context completeness: LocatorContextCompleteness = .full
    ) -> LocatorResolution {
        let candidates = indexedNodesWithContext(in: snapshot).compactMap { indexed, context -> LocatorCandidate? in
            candidate(for: indexed, context: context, locator: locator, snapshot: snapshot, completeness: completeness)
        }

        return LocatorResolution(snapshotID: snapshot.id, candidates: candidates, path: path, context: completeness)
    }

    private func candidate(
        for indexed: IndexedAXNode,
        context: LocatorNodeContext,
        locator: AXLocator,
        snapshot: AppSnapshot,
        completeness: LocatorContextCompleteness
    ) -> LocatorCandidate? {
        let node = indexed.node
        var reasons: [String] = []
        var evidence: [LocatorEvidenceItem] = []

        guard matchesExact(locator.role, actual: node.role, field: .role, label: "role", reasons: &reasons, evidence: &evidence),
              matchesExact(locator.subrole, actual: node.subrole, field: .subrole, label: "subrole", reasons: &reasons, evidence: &evidence),
              matchesTitle(locator.title, node: node, reasons: &reasons, evidence: &evidence),
              matchesLabel(locator.label, node: node, reasons: &reasons, evidence: &evidence),
              matchesValue(locator.value, node: node, reasons: &reasons, evidence: &evidence),
              matches(locator.description, actual: node.description, field: .description, label: "description", reasons: &reasons, evidence: &evidence),
              matches(locator.identifier, actual: node.identifier, field: .identifier, label: "identifier", reasons: &reasons, evidence: &evidence),
              matchesWindow(locator.window, node: node, ancestors: context.ancestors, reasons: &reasons),
              matchesAncestors(locator.ancestors, actual: context.ancestors, snapshot: snapshot, reasons: &reasons)
        else {
            return nil
        }
        addActionReasons(locator.actions, actual: node.actions, reasons: &reasons)
        if !locator.actions.isEmpty {
            evidence.append(.init(field: .actions, outcome: locator.actions.contains(where: node.actions.contains) ? .matched : .absent, expected: locator.actions.joined(separator: ", "), actual: node.actions.joined(separator: ", ")))
        }
        addNearbyTextReasons(locator.nearbyText, context: context, completeness: completeness, reasons: &reasons, evidence: &evidence)
        let score = score(for: locator, node: node, reasons: reasons)
        addGeometryReason(locator.frame, nodeFrame: node.frame, baseScore: score.base, reasons: &reasons)
        if let frame = locator.frame {
            evidence.append(.init(field: .frame, outcome: reasons.contains(where: { $0.hasPrefix("frame distance ") }) ? .matched : .absent, expected: String(describing: frame), actual: node.frame.map(String.init(describing:))))
        }
        if !locator.ancestors.isEmpty {
            evidence.append(.init(field: .ancestors, outcome: .matched, expected: String(locator.ancestors.count), actual: String(context.ancestors.count)))
        }
        if locator.window != nil {
            evidence.append(.init(field: .window, outcome: .matched))
        }
        let windowTitle = context.ancestors.first(where: { $0.role == "AXWindow" })?.title
        let observedLocator = try? AXLocator(jsonValue: .object(RecordedLocatorBuilder.locator(from: node, ancestors: context.ancestors, windowTitle: windowTitle)))

        return LocatorCandidate(
            index: indexed.index,
            handle: snapshot.handle(for: indexed.index),
            role: node.role,
            title: node.title,
            frame: node.frame,
            score: score.total,
            reasons: reasons,
            evidence: evidence,
            observedLocator: observedLocator
        )
    }

    private func score(for locator: AXLocator, node: AXNode, reasons: [String]) -> LocatorScore {
        var baseScore = reasons.count
        if let value = locator.value, value.matches(node.value) {
            baseScore += 2
        }
        let geometryScore = geometryScore(expected: locator.frame, actual: node.frame, baseScore: baseScore)
        return LocatorScore(base: baseScore, geometry: geometryScore)
    }

    private func matchesExact(_ expected: String?, actual: String?, field: LocatorEvidenceField, label: String, reasons: inout [String], evidence: inout [LocatorEvidenceItem]) -> Bool {
        guard let expected else {
            return true
        }
        guard actual == expected else {
            return false
        }
        reasons.append("\(label) \(expected)")
        evidence.append(.init(field: field, outcome: .matched, expected: expected, actual: actual))
        return true
    }

    private func matches(_ matcher: TextMatch?, actual: String?, field: LocatorEvidenceField, label: String, reasons: inout [String], evidence: inout [LocatorEvidenceItem]) -> Bool {
        guard let matcher else {
            return true
        }
        guard matcher.matches(actual) else {
            return false
        }
        reasons.append("\(label) \(matcher.reasonFragment)")
        evidence.append(.init(field: field, outcome: .matched, expected: matcher.evidenceValue, actual: actual))
        return true
    }

    private func matchesValue(_ matcher: TextMatch?, node: AXNode, reasons: inout [String], evidence: inout [LocatorEvidenceItem]) -> Bool {
        guard let matcher else {
            return true
        }
        if matcher.matches(node.value) {
            reasons.append("value \(matcher.reasonFragment)")
            evidence.append(.init(field: .value, outcome: .matched, expected: matcher.evidenceValue, actual: node.value))
            return true
        }
        let tolerated = node.editable == true || (usesMacOSCompensations && AXRoleSemantics.isEditableTextRole(node.role))
        if tolerated { evidence.append(.init(field: .value, outcome: .tolerated, expected: matcher.evidenceValue, actual: node.value)) }
        return tolerated
    }

    private func matchesTitle(_ matcher: TextMatch?, node: AXNode, reasons: inout [String], evidence: inout [LocatorEvidenceItem]) -> Bool {
        // macOS AX often leaves an editable control's accessible name unset and exposes its useful
        // text only through AXValue. Treating a stale recorded title as a positive signal avoids
        // rejecting that control. This is an AX-backend compensation, not shared locator semantics.
        guard let matcher else {
            return true
        }
        if matcher.matches(node.title) {
            reasons.append("title \(matcher.reasonFragment)")
            evidence.append(.init(field: .title, outcome: .matched, expected: matcher.evidenceValue, actual: node.title))
            return true
        }
        guard usesMacOSCompensations else {
            return false
        }
        // Unlike UIA Name, AXTitle does not derive an actionable element's name from descendants.
        // Consult descendant labels only for AX roles whose name is commonly represented by child
        // static text. This is an AX-backend compensation, not shared locator semantics.
        guard Self.descendantLabelRoles.contains(node.role),
              descendantLabels(of: node).contains(where: matcher.matches)
        else {
            let tolerated = AXRoleSemantics.isEditableTextRole(node.role)
            if tolerated { evidence.append(.init(field: .title, outcome: .tolerated, expected: matcher.evidenceValue, actual: node.title)) }
            return tolerated
        }
        reasons.append("descendant title \(matcher.reasonFragment)")
        evidence.append(.init(field: .title, outcome: .matched, expected: matcher.evidenceValue, actual: descendantLabels(of: node).first(where: matcher.matches)))
        return true
    }

    private func matchesLabel(_ matcher: TextMatch?, node: AXNode, reasons: inout [String], evidence: inout [LocatorEvidenceItem]) -> Bool {
        // AX snapshots have no computed, cross-role Name field. displayLabel and descendant text
        // reconstruct the human-facing label that macOS exposes across several attributes/nodes.
        // Editable-role mismatch handling is likewise AX-local; the shared contract remains strict.
        guard let matcher else {
            return true
        }
        let label = usesMacOSCompensations ? node.displayLabel : node.label
        if matcher.matches(label) {
            reasons.append("label \(matcher.reasonFragment)")
            evidence.append(.init(field: .label, outcome: .matched, expected: matcher.evidenceValue, actual: label))
            return true
        }
        guard usesMacOSCompensations,
              descendantLabels(of: node).contains(where: matcher.matches)
        else {
            let tolerated = usesMacOSCompensations && AXRoleSemantics.isEditableTextRole(node.role)
            if tolerated { evidence.append(.init(field: .label, outcome: .tolerated, expected: matcher.evidenceValue, actual: label)) }
            return tolerated
        }
        reasons.append("descendant label \(matcher.reasonFragment)")
        evidence.append(.init(field: .label, outcome: .matched, expected: matcher.evidenceValue, actual: descendantLabels(of: node).first(where: matcher.matches)))
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

    private func matchesWindow(
        _ expected: AXAncestorLocator?,
        node: AXNode,
        ancestors: [AXNode],
        reasons: inout [String]
    ) -> Bool {
        guard let expected else {
            return true
        }
        if !usesMacOSCompensations {
            let window = ancestors.first ?? node
            guard ancestorMatches(expected, node: window) else {
                return false
            }
            reasons.append("window scope")
            addScopedReasons(expected, prefix: "window", reasons: &reasons)
            return true
        }
        // AX represents top-level windows as AXWindow. The shared `window.role` field carries native
        // vocabulary for other backends, so it has no additional discriminating meaning on macOS.
        let windowMatcher = AXAncestorLocator(
            role: "AXWindow",
            subrole: expected.subrole,
            identifier: expected.identifier,
            title: expected.title,
            label: expected.label
        )
        let window = node.role == "AXWindow" ? node : ancestors.first { $0.role == "AXWindow" }
        guard let window, windowMatcher.matches(window) else {
            return false
        }
        reasons.append("window role AXWindow")
        if let subrole = windowMatcher.subrole {
            reasons.append("window subrole \(subrole)")
        }
        if let identifier = windowMatcher.identifier {
            reasons.append("window identifier \(identifier.reasonFragment)")
        }
        if let title = windowMatcher.title {
            reasons.append("window title \(title.reasonFragment)")
        }
        if let label = windowMatcher.label {
            reasons.append("window label \(label.reasonFragment)")
        }
        return true
    }

    private func addScopedReasons(_ locator: AXAncestorLocator, prefix: String, reasons: inout [String]) {
        if prefix == "ancestor", let role = locator.role { reasons.append("ancestor role \(role)") }
        if let subrole = locator.subrole { reasons.append("\(prefix) subrole \(subrole)") }
        if let identifier = locator.identifier { reasons.append("\(prefix) identifier \(identifier.reasonFragment)") }
        if let title = locator.title { reasons.append("\(prefix) title \(title.reasonFragment)") }
        if let label = locator.label { reasons.append("\(prefix) label \(label.reasonFragment)") }
    }

    private func ancestorMatches(_ locator: AXAncestorLocator, node: AXNode) -> Bool {
        guard locator.role == nil || locator.role == node.role,
              locator.subrole == nil || locator.subrole == node.subrole,
              locator.identifier == nil || locator.identifier?.matches(node.identifier) == true,
              locator.title == nil || locator.title?.matches(node.title) == true
        else {
            return false
        }
        let label = usesMacOSCompensations ? node.displayLabel : node.label
        return locator.label == nil || locator.label?.matches(label) == true
    }

    private func addNearbyTextReasons(_ expected: [TextMatch], context: LocatorNodeContext, completeness: LocatorContextCompleteness, reasons: inout [String], evidence: inout [LocatorEvidenceItem]) {
        guard !expected.isEmpty else {
            evidence.append(.init(field: .nearbyText, outcome: .absent, expected: expected.map(\.evidenceValue).joined(separator: ", ")))
            return
        }
        if completeness == .path {
            evidence.append(.init(field: .nearbyText, outcome: .unevaluated, expected: expected.map(\.evidenceValue).joined(separator: ", ")))
            return
        }
        let nearbyStrings = nearbyTextStrings(in: context)
        guard !nearbyStrings.isEmpty else {
            return
        }
        for matcher in expected where nearbyStrings.contains(where: matcher.matches) {
            reasons.append("nearby text \(matcher.reasonFragment)")
        }
        evidence.append(.init(field: .nearbyText, outcome: expected.contains(where: { matcher in nearbyStrings.contains(where: matcher.matches) }) ? .matched : .absent, expected: expected.map(\.evidenceValue).joined(separator: ", "), actual: nearbyStrings.joined(separator: ", ")))
    }

    private func nearbyTextStrings(in context: LocatorNodeContext) -> [String] {
        if !usesMacOSCompensations {
            return (context.siblings + context.ancestors).compactMap(\.sharedLabel)
        }
        var strings: [String] = []
        for sibling in context.siblings where Self.nearbyTextRoles.contains(sibling.role) {
            if let label = sibling.displayLabel {
                strings.append(label)
            }
        }
        for ancestor in context.ancestors where Self.sectionLikeRoles.contains(ancestor.role) {
            if let label = ancestor.displayLabel {
                strings.append(label)
            }
        }
        return strings
    }

    private func addGeometryReason(_ expected: AXFrame?, nodeFrame: AXFrame?, baseScore: Int, reasons: inout [String]) {
        guard let expected, let nodeFrame, baseScore > 0 else {
            return
        }
        let distance = normalizedFrameDistance(expected: expected, actual: nodeFrame)
        guard geometryScore(forNormalizedDistance: distance) > 0 else {
            return
        }
        reasons.append("frame distance \(String(format: "%.2f", distance))")
    }

    private func matchesAncestors(
        _ expected: [AXAncestorLocator],
        actual ancestors: [AXNode],
        snapshot: AppSnapshot,
        reasons: inout [String]
    ) -> Bool {
        var searchStart = 0
        for locator in expected {
            if usesMacOSCompensations, matchesAppAncestor(locator, snapshot: snapshot) {
                reasons.append("ancestor role AXApplication")
                continue
            }
            guard let matchIndex = ancestors[searchStart...].firstIndex(where: { ancestorMatches(locator, node: $0) }) else {
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
        // AppSnapshot stores application identity outside the captured AX window trees. Resolve an
        // AXApplication constraint against that metadata without pretending it is ordinary ancestry.
        // This is a macOS snapshot-shape compensation, not shared ordered-ancestor semantics.
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

    private func geometryScore(expected: AXFrame?, actual: AXFrame?, baseScore: Int) -> Int {
        guard let expected, let actual, baseScore > 0 else {
            return 0
        }
        return geometryScore(forNormalizedDistance: normalizedFrameDistance(expected: expected, actual: actual))
    }

    private func geometryScore(forNormalizedDistance distance: Double) -> Int {
        max(0, 100 - Int((distance * 100).rounded()))
    }

    private func normalizedFrameDistance(expected: AXFrame, actual: AXFrame) -> Double {
        let expectedCenterX = expected.x + expected.width / 2
        let expectedCenterY = expected.y + expected.height / 2
        let actualCenterX = actual.x + actual.width / 2
        let actualCenterY = actual.y + actual.height / 2
        let centerDistance = hypot(expectedCenterX - actualCenterX, expectedCenterY - actualCenterY)
        let diagonal = max(hypot(expected.width, expected.height), 1)
        return centerDistance / diagonal
    }

    private func indexedNodesWithContext(in snapshot: AppSnapshot) -> [(IndexedAXNode, LocatorNodeContext)] {
        var result: [(IndexedAXNode, LocatorNodeContext)] = []
        var nextIndex = 0
        for (windowIndex, window) in snapshot.windows.enumerated() {
            let siblings = snapshot.windows.enumerated().compactMap { index, sibling in
                index == windowIndex ? nil : sibling
            }
            append(window, ancestors: [], siblings: siblings, nextIndex: &nextIndex, to: &result)
        }
        return result
    }

    private func append(
        _ node: AXNode,
        ancestors: [AXNode],
        siblings: [AXNode],
        nextIndex: inout Int,
        to result: inout [(IndexedAXNode, LocatorNodeContext)]
    ) {
        let index = nextIndex
        nextIndex += 1
        let context = LocatorNodeContext(ancestors: ancestors, siblings: siblings)
        result.append((IndexedAXNode(index: index, node: node), context))

        let childAncestors = ancestors + [node]
        for (childIndex, child) in node.children.enumerated() {
            let childSiblings = node.children.enumerated().compactMap { index, sibling in
                index == childIndex ? nil : sibling
            }
            append(child, ancestors: childAncestors, siblings: childSiblings, nextIndex: &nextIndex, to: &result)
        }
    }
}

private struct LocatorNodeContext {
    let ancestors: [AXNode]
    let siblings: [AXNode]
}

private struct LocatorScore {
    let base: Int
    let geometry: Int

    var total: Int {
        base * 1_000 + geometry
    }
}

private extension AXNode {
    var sharedLabel: String? {
        for value in [label, title, value, description, identifier] {
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    var displayLabel: String? {
        for value in [label, title, value, description, identifier, help] {
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
