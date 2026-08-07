import CoreGraphics
import Foundation

public struct ScrollEventStep: Equatable, Sendable {
    public let deltaX: Double
    public let deltaY: Double

    public init(deltaX: Double, deltaY: Double) {
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

/// Splits a requested scroll delta into wheel-sized steps. A single large wheel event is clamped or
/// ignored outright by some views, and a real wheel never arrives as one jump, so the delta travels
/// as a short burst instead.
public enum ScrollEventPathSynthesizer {
    /// One classic wheel notch.
    private static let maxDeltaPerStep = 120.0
    private static let maxSteps = 16

    public static func path(deltaX: Double, deltaY: Double) -> [ScrollEventStep] {
        let magnitude = max(abs(deltaX), abs(deltaY))
        guard magnitude > 0, magnitude.isFinite else {
            return []
        }

        let requestedSteps = Int((magnitude / Self.maxDeltaPerStep).rounded(.up))
        let stepCount = min(Self.maxSteps, max(1, requestedSteps))

        // The final step carries the residual rather than another even share, so the emitted steps
        // sum to exactly the requested delta: a caller asking for 400 gets 400, not 399.99999.
        var steps: [ScrollEventStep] = []
        var emittedX = 0.0
        var emittedY = 0.0
        for index in 0..<stepCount {
            let isLast = index == stepCount - 1
            let stepX = isLast ? deltaX - emittedX : deltaX / Double(stepCount)
            let stepY = isLast ? deltaY - emittedY : deltaY / Double(stepCount)
            emittedX += stepX
            emittedY += stepY
            steps.append(ScrollEventStep(deltaX: stepX, deltaY: stepY))
        }
        return steps
    }
}
