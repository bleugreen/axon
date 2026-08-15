import Foundation

public struct ScreenTextItem: Codable, Equatable, Sendable {
    public let text: String
    public let frame: AXFrame
    public let confidence: Double?

    public init(text: String, frame: AXFrame, confidence: Double? = nil) {
        self.text = text
        self.frame = frame
        self.confidence = confidence
    }
}

public struct ScreenTextExtractor: Sendable {
    private let recognizeText: TextRecognitionHandler

    public init(recognizeText: @escaping TextRecognitionHandler = VisionTextRecognizer.recognizeText(in:)) {
        self.recognizeText = recognizeText
    }

    /// Recognized text placed on screen, or nothing when the image cannot say which window it came
    /// from.
    ///
    /// A recognized box is normalized to the image, so it can only be placed against the frame of
    /// the window that image depicts. Falling back to some window of the application — the first in
    /// the accessibility tree, say — always produces a point *inside that other window*, which is
    /// how a click lands hundreds of pixels outside the window it was aimed at with nothing in the
    /// result to show for it. There is no safe guess here, so an image without provenance yields no
    /// items.
    public func extract(in snapshot: AppSnapshot) -> [ScreenTextItem] {
        guard let screenshot = snapshot.screenshot,
              let windowFrame = screenshot.sourceWindowFrame
        else {
            return []
        }

        return recognizeText(screenshot)
            .compactMap { observation -> ScreenTextItem? in
                let frame = screenFrame(from: observation.boundingBox, in: windowFrame)
                guard !observation.text.isEmpty, frame.width > 0, frame.height > 0 else {
                    return nil
                }
                return ScreenTextItem(text: observation.text, frame: frame, confidence: observation.confidence)
            }
            .sorted { lhs, rhs in
                if lhs.frame.y == rhs.frame.y {
                    return lhs.frame.x < rhs.frame.x
                }
                return lhs.frame.y < rhs.frame.y
            }
    }

    private func screenFrame(from boundingBox: NormalizedTextBoundingBox, in windowFrame: AXFrame) -> AXFrame {
        let x = windowFrame.x + boundingBox.x * windowFrame.width
        let y = windowFrame.y + (1 - boundingBox.y - boundingBox.height) * windowFrame.height
        let width = boundingBox.width * windowFrame.width
        let height = boundingBox.height * windowFrame.height
        return AXFrame(x: x, y: y, width: width, height: height)
    }
}

public extension ScreenTextItem {
    var jsonValue: JSONValue {
        jsonValue(activeSecretRedactor: ActiveSecretRedactor())
    }

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        var object: [String: JSONValue] = [
            "frame": frame.jsonValue
        ]
        object.addRedactedString(
            "text",
            text,
            activeSecretRedactor: activeSecretRedactor
        )
        if let confidence {
            object["confidence"] = .double(confidence)
        }
        return .object(object)
    }
}
