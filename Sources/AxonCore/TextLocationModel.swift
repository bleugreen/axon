import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Vision

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

public struct NormalizedTextBoundingBox: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RecognizedTextObservation: Codable, Equatable, Sendable {
    public let text: String
    public let boundingBox: NormalizedTextBoundingBox
    public let confidence: Double?

    public init(text: String, boundingBox: NormalizedTextBoundingBox, confidence: Double? = nil) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
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

public typealias TextRecognitionHandler = @Sendable (EncodedScreenshot) -> [RecognizedTextObservation]

public struct TextLocationResolver: Sendable {
    private let recognizeText: TextRecognitionHandler

    public init(recognizeText: @escaping TextRecognitionHandler = VisionTextRecognizer.recognizeText(in:)) {
        self.recognizeText = recognizeText
    }

    public func resolve(_ target: TextLocationTarget, in snapshot: AppSnapshot) -> TextLocationResolution {
        let candidates: [TextLocationCandidate]
        switch target.source {
        case .ax:
            candidates = axCandidates(matching: target.text, in: snapshot)
        case .auto:
            let axCandidates = axCandidates(matching: target.text, in: snapshot)
            candidates = axCandidates.isEmpty ? screenshotCandidates(matching: target.text, in: snapshot) : axCandidates
        case .screenshot:
            candidates = screenshotCandidates(matching: target.text, in: snapshot)
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

    private func screenshotCandidates(matching text: TextMatch, in snapshot: AppSnapshot) -> [TextLocationCandidate] {
        ScreenTextExtractor(recognizeText: recognizeText).extract(in: snapshot).enumerated().compactMap { index, item in
            guard text.matches(item.text) else {
                return nil
            }

            let frame = item.frame
            let point = ActionPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            var reasons = ["ocr \(text.reasonFragment)"]
            if let confidence = item.confidence {
                reasons.append("confidence \(confidence)")
            }
            return TextLocationCandidate(
                index: index,
                handle: nil,
                role: "OCRText",
                matchedText: item.text,
                source: .screenshot,
                frame: frame,
                point: point,
                reasons: reasons
            )
        }
    }
}

public enum VisionTextRecognizer {
    public static func recognizeText(in screenshot: EncodedScreenshot) -> [RecognizedTextObservation] {
        guard let data = Data(base64Encoded: screenshot.base64Data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return []
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            return RecognizedTextObservation(
                text: candidate.string,
                boundingBox: NormalizedTextBoundingBox(
                    x: observation.boundingBox.origin.x,
                    y: observation.boundingBox.origin.y,
                    width: observation.boundingBox.width,
                    height: observation.boundingBox.height
                ),
                confidence: Double(candidate.confidence)
            )
        }
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
        jsonValue(activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        .object([
            "status": .string(status.rawValue),
            "snapshotID": .string(snapshotID.rawValue),
            "best": best.map {
                $0.jsonValue(
                    activeSecretRedactor: activeSecretRedactor,
                    redactionScope: "\(snapshotID.rawValue)_text_best_\($0.index)"
                )
            } ?? .null,
            "point": point.map(\.jsonValue) ?? .null,
            "candidates": .array(candidates.map {
                $0.jsonValue(
                    activeSecretRedactor: activeSecretRedactor,
                    redactionScope: "\(snapshotID.rawValue)_text_candidate_\($0.index)"
                )
            })
        ])
    }
}

public extension TextLocationCandidate {
    var jsonValue: JSONValue {
        jsonValue(activeSecretRedactor: ActiveSecretRedactor(), redactionScope: "text_candidate_\(index)")
    }

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor, redactionScope: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "index": .int(index),
            "handle": handle.map { .string($0.rawValue) } ?? .null,
            "role": .string(role),
            "source": .string(source.rawValue),
            "frame": frame.jsonValue,
            "point": point.jsonValue
        ]
        let matchedTextWasRedacted = object.addRedactedString(
            "matchedText",
            matchedText,
            activeSecretRedactor: activeSecretRedactor,
            redactionContext: DeterministicRedactionContext(role: role, title: matchedText),
            redactionScope: redactionScope
        )
        let renderedReasons: [String]
        if matchedTextWasRedacted,
           case let .string(replacement)? = object["matchedText"] {
            renderedReasons = reasons.map { $0.replacingOccurrences(of: matchedText, with: replacement) }
        } else {
            renderedReasons = reasons
        }
        object["reasons"] = .array(renderedReasons.redactedReasonValues(
            activeSecretRedactor: activeSecretRedactor,
            redactionScope: redactionScope
        ))
        return .object(object)
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
