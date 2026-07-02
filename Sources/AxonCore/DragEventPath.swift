import CoreGraphics
import Foundation

public struct DragEventStep: Equatable, Sendable {
    public let type: CGEventType
    public let point: CGPoint

    public init(type: CGEventType, point: CGPoint) {
        self.type = type
        self.point = point
    }
}

public enum DragEventPathSynthesizer {
    private static let dragThresholdPoints = 6.0
    private static let minimumDragUpdates = 6
    private static let hoverSettleUpdates = 2

    public static func path(from start: CGPoint, to end: CGPoint, durationMs: Int?) -> [DragEventStep] {
        var steps = [DragEventStep(type: .leftMouseDown, point: start)]
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let distance = hypot(deltaX, deltaY)

        if distance > 0 {
            let thresholdDistance = min(Self.dragThresholdPoints, Double(distance))
            let thresholdRatio = thresholdDistance / Double(distance)
            steps.append(DragEventStep(
                type: .leftMouseDragged,
                point: CGPoint(x: start.x + deltaX * thresholdRatio, y: start.y + deltaY * thresholdRatio)
            ))
        }

        let duration = max(durationMs ?? 250, 0)
        let durationDrivenUpdates = max(Self.minimumDragUpdates, duration / 50)
        for index in 1...durationDrivenUpdates {
            let ratio = Double(index) / Double(durationDrivenUpdates)
            steps.append(DragEventStep(
                type: .leftMouseDragged,
                point: CGPoint(x: start.x + deltaX * ratio, y: start.y + deltaY * ratio)
            ))
        }

        for _ in 0..<Self.hoverSettleUpdates {
            steps.append(DragEventStep(type: .leftMouseDragged, point: end))
        }
        steps.append(DragEventStep(type: .leftMouseUp, point: end))
        return steps
    }
}
