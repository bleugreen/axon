import Foundation

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
        description: String?,
        actions: [String],
        windowTitle: String?
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
        if let description, !description.isEmpty {
            locator["description"] = .string(description)
        }
        if !actions.isEmpty {
            locator["actions"] = .array(actions.map(JSONValue.string))
        }
        if windowTitle != nil {
            locator["ancestors"] = .array([
                .object(["role": .string("AXWindow")])
            ])
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
}
