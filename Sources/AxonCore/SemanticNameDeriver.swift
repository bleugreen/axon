import Foundation

public struct SemanticElementName: Codable, Equatable, Sendable {
    public let name: String
    public let role: String
    public let label: String
    public let sourceIndex: Int
    public let segmentCount: Int
    public let characterCount: Int
    public let collisionFree: Bool
    public let disambiguation: String?
    /// A presentation-only label for distinguishing candidates that share an ambiguous name.
    public let candidateLabel: String?
    public let resolution: SemanticNameResolution
    public let identityKey: String
}

public enum SemanticNameResolution: String, Codable, Equatable, Sendable {
    case unique
    case ambiguous
}

/// A name-centric view suitable for building a semantic index without re-grouping elements.
public struct SemanticNameGroup: Codable, Equatable, Sendable {
    public let name: String
    public let sourceIndices: [Int]
    public let resolution: SemanticNameResolution
}

public struct SemanticNameSummary: Codable, Equatable, Sendable {
    public let eligibleElementCount: Int
    public let collisionFreeCount: Int
    public let segmentHistogram: [Int: Int]
    public let characterHistogram: [Int: Int]
    public let disambiguationHistogram: [String: Int]

    public var collisionFreeFraction: Double {
        guard eligibleElementCount > 0 else { return 1 }
        return Double(collisionFreeCount) / Double(eligibleElementCount)
    }

    private static func appendDistinct(_ segment: String, to lineage: [String]) -> [String] {
        lineage.last == segment ? lineage : lineage + [segment]
    }
}

public struct SemanticNameStudy: Codable, Equatable, Sendable {
    public let elements: [SemanticElementName]
    public let groups: [SemanticNameGroup]
    public let summary: SemanticNameSummary
}

public struct SemanticNameStability: Codable, Equatable, Sendable {
    public let comparableElements: Int
    public let stableNames: Int
    public let missingIdentities: Int
    public let ambiguousIdentities: Int

    public var fraction: Double {
        guard comparableElements > 0 else { return 1 }
        return Double(stableNames) / Double(comparableElements)
    }
}

/// Experimental semantic naming over the JSON emitted by `axon look --json`.
///
/// The implementation deliberately consumes the serialized boundary rather than macOS accessibility
/// objects. Roles are normalized to the observation vocabulary, geometry never participates, and
/// identifiers that resemble framework allocation artifacts are rejected.
public enum SemanticNameDeriver {
    private struct Candidate {
        let index: Int
        let role: String
        let label: String
        let stableIdentifier: String?
        let lineage: [String]
        let humanLineage: [Bool]
        var segments: [String]
        var collisionFree = true
        var disambiguation: String?
        var candidateLabel: String?

        var identityKey: String {
            ([role, label] + lineage + [stableIdentifier ?? ""]).joined(separator: "\u{1f}")
        }
    }

    public static func derive(from snapshotJSON: JSONValue, maximumSegmentLength: Int = 32) -> SemanticNameStudy {
        guard case let .object(snapshot) = snapshotJSON,
              case let .array(windows)? = snapshot["windows"]
        else {
            return study(from: [])
        }

        var candidates: [Candidate] = []
        var fallbackIndex = 0
        for window in windows {
            collect(
                window,
                semanticLineage: [],
                humanLineage: [],
                candidates: &candidates,
                fallbackIndex: &fallbackIndex,
                maximumSegmentLength: maximumSegmentLength
            )
        }
        disambiguate(&candidates)

        let elements = candidates.map { candidate in
            let name = candidate.segments.joined(separator: "/")
            return SemanticElementName(
                name: name,
                role: candidate.role,
                label: candidate.label,
                sourceIndex: candidate.index,
                segmentCount: candidate.segments.count,
                characterCount: name.count,
                collisionFree: candidate.collisionFree,
                disambiguation: candidate.disambiguation,
                candidateLabel: candidate.candidateLabel,
                resolution: candidate.collisionFree ? .unique : .ambiguous,
                identityKey: candidate.identityKey
            )
        }
        return study(from: elements)
    }

    public static func stability(from first: SemanticNameStudy, to second: SemanticNameStudy) -> SemanticNameStability {
        let firstGroups = Dictionary(grouping: first.elements, by: \.identityKey)
        let secondGroups = Dictionary(grouping: second.elements, by: \.identityKey)
        var comparable = 0
        var stable = 0
        var missing = 0
        var ambiguous = 0

        for (key, before) in firstGroups {
            guard before.count == 1 else {
                ambiguous += before.count
                continue
            }
            comparable += 1
            guard let after = secondGroups[key] else {
                missing += 1
                continue
            }
            guard after.count == 1 else {
                ambiguous += 1
                continue
            }
            if before[0].name == after[0].name { stable += 1 }
        }
        return SemanticNameStability(
            comparableElements: comparable,
            stableNames: stable,
            missingIdentities: missing,
            ambiguousIdentities: ambiguous
        )
    }

    public static func isAutogeneratedIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"^_NS:\d+$"#, options: .regularExpression) != nil { return true }
        if trimmed.range(of: #"^<AXUIElement 0x[0-9a-fA-F]+>"#, options: .regularExpression) != nil { return true }
        return false
    }

    public static func slug(_ value: String, maximumLength: Int = 32) -> String? {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar).lowercased()) : "-"
        }
        let collapsed = String(scalars).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maximumLength { return collapsed }
        let prefix = collapsed.prefix(maximumLength)
        if prefix.last == "-" || collapsed.dropFirst(maximumLength).first == "-" {
            return String(prefix).trimmingCharacters(in: CharacterSet(charactersIn: "-")).nilIfEmpty
        }
        return String(prefix).split(separator: "-", omittingEmptySubsequences: true).dropLast().joined(separator: "-").nilIfEmpty
            ?? String(prefix)
    }

    private static func collect(
        _ value: JSONValue,
        semanticLineage: [String],
        humanLineage: [Bool],
        candidates: inout [Candidate],
        fallbackIndex: inout Int,
        maximumSegmentLength: Int
    ) {
        guard case let .object(node) = value else { return }
        let index = integer(node["index"]) ?? fallbackIndex
        fallbackIndex += 1
        let rawRole = string(node["role"])
        let role = normalizedRole(rawRole)
        let identifier = string(node["identifier"]).flatMap { isAutogeneratedIdentifier($0) ? nil : meaningful($0) }
        let humanLabel = ["title", "label", "value", "description", "help"]
            .compactMap { meaningful(string(node[$0])) }
            .first
        let rawLabel = humanLabel ?? identifier
        let labelSegment = rawLabel.flatMap { slug($0, maximumLength: maximumSegmentLength) }
        let landmark = anonymousLandmark(role: role)
        let lineageSegment = labelSegment ?? landmark
        let nextLineage: [String]
        let nextHumanLineage: [Bool]
        if rawRole == "AXMenuBar" {
            nextLineage = ["menu"]
            nextHumanLineage = [true]
        } else if labelSegment == nil, landmark == "menu", semanticLineage.contains("menu") {
            nextLineage = semanticLineage
            nextHumanLineage = humanLineage
        } else {
            nextLineage = lineageSegment.map { appendDistinct($0, to: semanticLineage) } ?? semanticLineage
            nextHumanLineage = lineageSegment.map { segment in
                semanticLineage.last == segment
                    ? humanLineage
                    : humanLineage + [humanLabel != nil || landmark != nil]
            } ?? humanLineage
        }

        if let rawLabel, let leaf = labelSegment, !isAnonymousStructural(role: role) {
            let lineage = semanticLineage + [leaf]
            candidates.append(Candidate(
                index: index,
                role: role,
                label: rawLabel,
                stableIdentifier: identifier,
                lineage: lineage,
                humanLineage: humanLineage + [humanLabel != nil],
                segments: initialSegments(from: lineage)
            ))
        }

        if case let .array(children)? = node["children"] {
            for child in children {
                collect(
                    child,
                    semanticLineage: nextLineage,
                    humanLineage: nextHumanLineage,
                    candidates: &candidates,
                    fallbackIndex: &fallbackIndex,
                    maximumSegmentLength: maximumSegmentLength
                )
            }
        }
    }

    private static func disambiguate(_ candidates: inout [Candidate]) {
        var groups = Dictionary(grouping: candidates.indices, by: { candidates[$0].segments.joined(separator: "/") })
        var occupiedNames = Set(groups.keys)

        // A fourth segment is allowed only when one human-readable ancestor resolves the
        // entire collision. Never continue walking toward the root to manufacture uniqueness.
        for (_, indices) in groups.sorted(by: { $0.key < $1.key }) where indices.count > 1 {
            let proposals = indices.map { index -> [String]? in
                let candidate = candidates[index]
                guard candidate.segments.count == 3, candidate.lineage.count > 3 else { return nil }
                let ancestorIndex = candidate.lineage.count - 4
                guard candidate.humanLineage[ancestorIndex] else { return nil }
                return [candidate.lineage[ancestorIndex]] + candidate.segments
            }
            let names = proposals.compactMap { $0?.joined(separator: "/") }
            guard names.count == indices.count,
                  Set(names).count == indices.count,
                  names.allSatisfy({ !occupiedNames.contains($0) })
            else { continue }
            for (index, proposal) in zip(indices, proposals) {
                candidates[index].segments = proposal!
                candidates[index].disambiguation = "ancestor"
                occupiedNames.insert(proposal!.joined(separator: "/"))
            }
        }

        groups = Dictionary(grouping: candidates.indices, by: { candidates[$0].segments.joined(separator: "/") })
        for (_, indices) in groups.sorted(by: { $0.key < $1.key }) where indices.count > 1 {
            let identifierSlugs = indices.map { index in
                candidates[index].stableIdentifier.flatMap { slug($0, maximumLength: 24) }
            }
            let counts = Dictionary(grouping: identifierSlugs.compactMap { $0 }, by: { $0 }).mapValues(\.count)
            for (index, identifierSlug) in zip(indices, identifierSlugs) {
                if let identifierSlug, counts[identifierSlug] == 1 {
                    let leaf = candidates[index].segments[candidates[index].segments.count - 1]
                    var suffix = identifierSlug
                    var attempt = 0
                    while occupiedNames.contains((candidates[index].segments.dropLast() + ["\(leaf)-\(suffix)"]).joined(separator: "/")) {
                        attempt += 1
                        suffix = attempt == 1 ? "\(identifierSlug)-id" : "\(identifierSlug)-id-\(attempt)"
                    }
                    candidates[index].segments[candidates[index].segments.count - 1] = "\(leaf)-\(suffix)"
                    occupiedNames.insert(candidates[index].segments.joined(separator: "/"))
                    candidates[index].disambiguation = "identifier"
                }
            }
        }

        groups = Dictionary(grouping: candidates.indices, by: { candidates[$0].segments.joined(separator: "/") })
        for (_, indices) in groups.sorted(by: { $0.key < $1.key }) where indices.count > 1 {
            let roleCounts = Dictionary(grouping: indices.map { candidates[$0].role }, by: { $0 }).mapValues(\.count)
            if roleCounts.count > 1 {
                for index in indices where roleCounts[candidates[index].role] == 1 {
                    let role = candidates[index].role
                    let leaf = candidates[index].segments[candidates[index].segments.count - 1]
                    var suffix = role
                    var attempt = 0
                    while occupiedNames.contains((candidates[index].segments.dropLast() + ["\(leaf)-\(suffix)"]).joined(separator: "/")) {
                        attempt += 1
                        suffix = attempt == 1 ? "\(role)-role" : "\(role)-role-\(attempt)"
                    }
                    candidates[index].segments[candidates[index].segments.count - 1] = "\(leaf)-\(suffix)"
                    occupiedNames.insert(candidates[index].segments.joined(separator: "/"))
                    candidates[index].disambiguation = "role"
                }
            }
        }

        groups = Dictionary(grouping: candidates.indices, by: { candidates[$0].segments.joined(separator: "/") })
        for indices in groups.values where indices.count > 1 {
            for (ordinal, index) in indices.sorted(by: { candidates[$0].index < candidates[$1].index }).enumerated() {
                candidates[index].collisionFree = false
                candidates[index].disambiguation = "ambiguous"
                candidates[index].candidateLabel = "\(candidates[index].segments.joined(separator: "/"))-\(ordinal + 1)"
            }
        }
    }

    private static func initialSegments(from lineage: [String]) -> [String] {
        var result = Array(lineage.suffix(3))
        if lineage.first == "menu", result.first != "menu" {
            result = ["menu"] + Array(lineage.suffix(2))
        }
        return result
    }

    private static func appendDistinct(_ segment: String, to lineage: [String]) -> [String] {
        lineage.last == segment ? lineage : lineage + [segment]
    }

    private static func study(from elements: [SemanticElementName]) -> SemanticNameStudy {
        let groups = Dictionary(grouping: elements, by: \.name).map { name, elements in
            SemanticNameGroup(
                name: name,
                sourceIndices: elements.map(\.sourceIndex).sorted(),
                resolution: elements.count == 1 ? .unique : .ambiguous
            )
        }.sorted(by: { $0.name < $1.name })
        return SemanticNameStudy(
            elements: elements,
            groups: groups,
            summary: SemanticNameSummary(
                eligibleElementCount: elements.count,
                collisionFreeCount: elements.filter(\.collisionFree).count,
                segmentHistogram: Dictionary(grouping: elements, by: \.segmentCount).mapValues(\.count),
                characterHistogram: Dictionary(grouping: elements, by: \.characterCount).mapValues(\.count),
                disambiguationHistogram: Dictionary(grouping: elements.compactMap(\.disambiguation), by: { $0 }).mapValues(\.count)
            )
        )
    }

    private static func anonymousLandmark(role: String) -> String? {
        ["menu", "window", "toolbar", "list", "web"].contains(role) ? role : nil
    }

    private static func isAnonymousStructural(role: String) -> Bool {
        ["item", "cell", "row", "group", "scroll", "splitter"].contains(role)
    }

    private static func normalizedRole(_ role: String?) -> String {
        switch role {
        case "AXWindow", "window": "window"
        case "AXButton", "button", "Button", "ControlType.Button", "push button": "button"
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "field",
             "Edit", "ControlType.Edit", "text entry": "field"
        case "AXStaticText", "text": "text"
        case "AXHeading", "heading": "heading"
        case "AXLink", "link", "Hyperlink", "ControlType.Hyperlink": "link"
        case "AXMenu", "AXMenuBar", "AXMenuItem", "menu": "menu"
        case "AXList", "AXOutline", "AXTable", "list", "List", "ControlType.List": "list"
        case "AXRow", "row": "row"
        case "AXCell", "cell": "cell"
        case "AXWebArea", "web": "web"
        case "AXScrollArea", "scroll": "scroll"
        case "AXGroup", "group": "group"
        default: role?.replacingOccurrences(of: "AX", with: "").lowercased() ?? "node"
        }
    }

    private static func meaningful(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<redacted:") else { return nil }
        return trimmed
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case let .string(string)? = value else { return nil }
        return string
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case let .int(integer)? = value else { return nil }
        return integer
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}