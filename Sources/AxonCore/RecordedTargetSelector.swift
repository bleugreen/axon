import Foundation

public struct RecordedElementCandidate: Equatable, Sendable {
    public let role: String
    public let subrole: String?
    public let identifier: String?
    public let title: String?
    public let value: String?
    public let description: String?
    public let actions: [String]
    public let windowTitle: String?
    public let hasWindowAncestor: Bool

    public init(
        role: String,
        subrole: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        actions: [String] = [],
        windowTitle: String? = nil,
        hasWindowAncestor: Bool
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.value = value
        self.description = description
        self.actions = actions
        self.windowTitle = windowTitle
        self.hasWindowAncestor = hasWindowAncestor
    }

    var stableText: String? {
        for text in [title, value, description, identifier] {
            if let text, !text.isEmpty {
                return text
            }
        }
        return nil
    }
}

public struct RecordedTargetSelection: Equatable, Sendable {
    public let candidate: RecordedElementCandidate
    public let locator: [String: JSONValue]
    public let warnings: [String]

    public init(candidate: RecordedElementCandidate, locator: [String: JSONValue], warnings: [String]) {
        self.candidate = candidate
        self.locator = locator
        self.warnings = warnings
    }
}

public enum RecordedTargetSelector {
    private static let actionableRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXComboBox",
        "AXLink",
        "AXMenuButton",
        "AXMenuItem",
        "AXPopUpButton",
        "AXRadioButton",
        "AXTextArea",
        "AXTextField"
    ]

    public static func select(from candidates: [RecordedElementCandidate]) -> RecordedTargetSelection? {
        let actionable = candidates.indices.lazy
            .filter { actionableRoles.contains(candidates[$0].role) }
            .compactMap { selection(at: $0, in: candidates) }
            .first
        if let actionable {
            return actionable
        }
        return candidates.indices.lazy.compactMap { selection(at: $0, in: candidates) }.first
    }

    private static func selection(
        at index: Int,
        in candidates: [RecordedElementCandidate]
    ) -> RecordedTargetSelection? {
        let candidate = candidateWithBorrowedTextIfNeeded(at: index, in: candidates)
        let locator = RecordedLocatorBuilder.locator(
            role: candidate.role,
            subrole: candidate.subrole,
            identifier: candidate.identifier,
            title: candidate.title,
            description: candidate.description,
            actions: candidate.actions,
            windowTitle: candidate.windowTitle
        )
        guard RecordedLocatorBuilder.strictReplayWarning(
            for: locator,
            role: candidate.role,
            hasWindowAncestor: candidate.hasWindowAncestor
        ) == nil else {
            return nil
        }

        var warnings: [String] = []
        if locator.keys.count == 1 {
            warnings.append("locator only contains AX role and may be ambiguous")
        }
        return RecordedTargetSelection(candidate: candidate, locator: locator, warnings: warnings)
    }

    private static func candidateWithBorrowedTextIfNeeded(
        at index: Int,
        in candidates: [RecordedElementCandidate]
    ) -> RecordedElementCandidate {
        let candidate = candidates[index]
        guard actionableRoles.contains(candidate.role),
              candidate.stableText == nil,
              let borrowedText = candidates[..<index].compactMap(\.stableText).first
        else {
            return candidate
        }

        return RecordedElementCandidate(
            role: candidate.role,
            subrole: candidate.subrole,
            identifier: candidate.identifier,
            title: borrowedText,
            value: candidate.value,
            description: candidate.description,
            actions: candidate.actions,
            windowTitle: candidate.windowTitle,
            hasWindowAncestor: candidate.hasWindowAncestor
        )
    }
}
