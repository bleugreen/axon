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

    public func extract(in snapshot: AppSnapshot) -> [ScreenTextItem] {
        guard let screenshot = snapshot.screenshot,
              let windowFrame = snapshot.windows.compactMap(\.frame).first
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
        var object: [String: JSONValue] = [
            "text": .string(text),
            "frame": frame.jsonValue
        ]
        if let confidence {
            object["confidence"] = .double(confidence)
        }
        return .object(object)
    }
}
