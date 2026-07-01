import Foundation

public struct RecordedAncestorCandidate: Equatable, Sendable {
    public let role: String
    public let subrole: String?
    public let identifier: String?
    public let title: String?

    public init(role: String, subrole: String? = nil, identifier: String? = nil, title: String? = nil) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
    }
}

public enum RecordedLocatorBuilder {
    private static let structuralRoles: Set<String> = [
        "AXGroup",
        "AXWebArea",
        "AXScrollArea",
        "AXSplitter",
        "AXToolbar"
    ]
    private static let stableOutOfTreeRoles: Set<String> = [
        "AXButton",
        "AXLink",
        "AXMenuItem"
    ]

    public static func locator(
        role: String,
        subrole: String?,
        identifier: String?,
        title: String?,
        value: String? = nil,
        description: String?,
        actions: [String],
        windowTitle: String?,
        ancestors: [RecordedAncestorCandidate] = []
    ) -> [String: JSONValue] {
        var locator: [String: JSONValue] = ["role": .string(role)]
        if let subrole, !subrole.isEmpty {
            locator["subrole"] = .string(subrole)
        }
        if let identifier, !identifier.isEmpty {
            locator["identifier"] = .string(identifier)
        }
        if let title, !title.isEmpty {
            locator["title"] = .string(title)
        }
        if let value, !value.isEmpty, !AXRoleSemantics.isEditableTextRole(role) {
            locator["value"] = .string(value)
        }
        if let description, !description.isEmpty {
            locator["description"] = .string(description)
        }
        if !actions.isEmpty {
            locator["actions"] = .array(actions.map(JSONValue.string))
        }
        let serializedAncestors = ancestors.compactMap(serializedAncestor)
        if !serializedAncestors.isEmpty {
            locator["ancestors"] = .array(serializedAncestors)
        } else if windowTitle != nil {
            locator["ancestors"] = .array([.object(["role": .string("AXWindow")])])
        }
        return locator
    }

    public static func strictReplayWarning(
        for locator: [String: JSONValue],
        role: String,
        hasWindowAncestor: Bool
    ) -> String? {
        if role != "AXWindow", !hasWindowAncestor, !canReplayOutsideWindow(role: role, locator: locator) {
            return "AX element is outside captured window tree; recorded point fallback"
        }
        if structuralRoles.contains(role) {
            return "structural AX element is not a stable replay target; recorded point fallback"
        }
        if role == "AXStaticText", !hasStableIdentity(locator) {
            return "anonymous AXStaticText is not a stable replay target; recorded point fallback"
        }
        return nil
    }

    private static func hasStableIdentity(_ locator: [String: JSONValue]) -> Bool {
        for key in ["identifier", "title", "description"] where locator[key] != nil {
            return true
        }
        return false
    }

    private static func canReplayOutsideWindow(role: String, locator: [String: JSONValue]) -> Bool {
        stableOutOfTreeRoles.contains(role) && hasStableIdentity(locator)
    }

    private static func serializedAncestor(_ ancestor: RecordedAncestorCandidate) -> JSONValue? {
        guard ancestor.role != "AXApplication" else {
            return nil
        }
        var object: [String: JSONValue] = ["role": .string(ancestor.role)]
        if ancestor.role != "AXWindow", let subrole = ancestor.subrole, !subrole.isEmpty {
            object["subrole"] = .string(subrole)
        }
        if ancestor.role != "AXWindow", let identifier = ancestor.identifier, !identifier.isEmpty {
            object["identifier"] = .string(identifier)
        }
        if ancestor.role != "AXWindow", let title = ancestor.title, !title.isEmpty {
            object["title"] = .string(title)
        }
        return .object(object)
    }
}
