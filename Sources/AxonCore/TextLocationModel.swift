import Foundation

public enum TextLocationSource: String, Codable, Equatable, Sendable {
    case auto
    case ax
    case screenshot
}

public struct TextLocationTarget: Codable, Equatable, Sendable {
    public let app: String
    public let text: TextMatch
    public let source: TextLocationSource

    public init(app: String, text: TextMatch, source: TextLocationSource = .auto) {
        self.app = app
        self.text = text
        self.source = source
    }
}

public struct TextLocationCandidate: Codable, Equatable, Sendable {
    public let index: Int
    public let handle: SnapshotHandle?
    public let role: String
    public let matchedText: String
    public let source: TextLocationSource
    public let frame: AXFrame
    public let point: ActionPoint
    public let reasons: [String]

    public init(
        index: Int,
        handle: SnapshotHandle?,
        role: String,
        matchedText: String,
        source: TextLocationSource,
        frame: AXFrame,
        point: ActionPoint,
        reasons: [String]
    ) {
        self.index = index
        self.handle = handle
        self.role = role
        self.matchedText = matchedText
        self.source = source
        self.frame = frame
        self.point = point
        self.reasons = reasons
    }
}

public struct TextLocationResolution: Codable, Equatable, Sendable {
    public let status: LocatorResolutionStatus
    public let snapshotID: SnapshotID
    public let best: TextLocationCandidate?
    public let candidates: [TextLocationCandidate]

    public init(
        status: LocatorResolutionStatus,
        snapshotID: SnapshotID,
        best: TextLocationCandidate?,
        candidates: [TextLocationCandidate]
    ) {
        self.status = status
        self.snapshotID = snapshotID
        self.best = best
        self.candidates = candidates
    }

    public var point: ActionPoint? {
        best?.point
    }
}

public struct TextLocationResolver: Sendable {
    public init() {}

    public func resolve(_ target: TextLocationTarget, in snapshot: AppSnapshot) -> TextLocationResolution {
        let candidates: [TextLocationCandidate]
        switch target.source {
        case .auto, .ax:
            candidates = axCandidates(matching: target.text, in: snapshot)
        case .screenshot:
            candidates = []
        }

        let status: LocatorResolutionStatus
        let best: TextLocationCandidate?
        switch candidates.count {
        case 0:
            status = .missing
            best = nil
        case 1:
            status = .unique
            best = candidates[0]
        default:
            status = .ambiguous
            best = nil
        }

        return TextLocationResolution(status: status, snapshotID: snapshot.id, best: best, candidates: candidates)
    }

    private func axCandidates(matching text: TextMatch, in snapshot: AppSnapshot) -> [TextLocationCandidate] {
        snapshot.indexedNodes.compactMap { indexed in
            guard let frame = indexed.node.frame,
                  frame.width > 0,
                  frame.height > 0,
                  let match = firstTextMatch(in: indexed.node, matching: text)
            else {
                return nil
            }

            let point = ActionPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            return TextLocationCandidate(
                index: indexed.index,
                handle: snapshot.handle(for: indexed.index),
                role: indexed.node.role,
                matchedText: match.value,
                source: .ax,
                frame: frame,
                point: point,
                reasons: ["\(match.field) \(text.reasonFragment)"]
            )
        }
    }

    private func firstTextMatch(in node: AXNode, matching text: TextMatch) -> (field: String, value: String)? {
        let fields: [(String, String?)] = [
            ("title", node.title),
            ("value", node.value),
            ("description", node.description),
            ("identifier", node.identifier),
            ("help", node.help)
        ]
        for (field, value) in fields {
            if let value, text.matches(value) {
                return (field, value)
            }
        }
        return nil
    }
}

public extension TextLocationTarget {
    init(jsonValue: JSONValue) throws {
        guard case let .object(object) = jsonValue else {
            throw JSONRPCError.invalidParams("location must be an object")
        }
        guard case let .string(app) = object["app"], !app.isEmpty else {
            throw JSONRPCError.invalidParams("location must include string app")
        }
        guard let textValue = object["text"], textValue != .null else {
            throw JSONRPCError.invalidParams("location must include text")
        }

        self.init(
            app: app,
            text: try TextMatch(locationJSONValue: textValue, field: "text"),
            source: try TextLocationSource(jsonValue: object["source"] ?? .string(TextLocationSource.auto.rawValue))
        )
    }
}

public extension TextLocationResolution {
    var jsonValue: JSONValue {
        .object([
            "status": .string(status.rawValue),
            "snapshotID": .string(snapshotID.rawValue),
            "best": best.map(\.jsonValue) ?? .null,
            "point": point.map(\.jsonValue) ?? .null,
            "candidates": .array(candidates.map(\.jsonValue))
        ])
    }
}

public extension TextLocationCandidate {
    var jsonValue: JSONValue {
        .object([
            "index": .int(index),
            "handle": handle.map { .string($0.rawValue) } ?? .null,
            "role": .string(role),
            "matchedText": .string(matchedText),
            "source": .string(source.rawValue),
            "frame": frame.jsonValue,
            "point": point.jsonValue,
            "reasons": .array(reasons.map(JSONValue.string))
        ])
    }
}

private extension TextLocationSource {
    init(jsonValue: JSONValue) throws {
        guard case let .string(rawValue) = jsonValue else {
            throw JSONRPCError.invalidParams("location source must be a string")
        }
        guard let source = TextLocationSource(rawValue: rawValue) else {
            throw JSONRPCError.invalidParams("Unsupported location source: \(rawValue)")
        }
        self = source
    }
}

private extension TextMatch {
    init(locationJSONValue jsonValue: JSONValue, field: String) throws {
        if case let .string(value) = jsonValue {
            self = .exact(value)
            return
        }

        guard case let .object(object) = jsonValue else {
            throw JSONRPCError.invalidParams("\(field) must be a string or matcher object")
        }

        let caseSensitive = boolValue("caseSensitive", in: object) ?? false
        if case let .string(value) = object["exact"] {
            self = .exact(value, caseSensitive: caseSensitive)
            return
        }
        if case let .string(value) = object["contains"] {
            self = .contains(value, caseSensitive: caseSensitive)
            return
        }

        throw JSONRPCError.invalidParams("\(field) matcher must contain exact or contains")
    }
}

private func boolValue(_ key: String, in object: [String: JSONValue]) -> Bool? {
    guard case let .bool(value) = object[key] else {
        return nil
    }
    return value
}
