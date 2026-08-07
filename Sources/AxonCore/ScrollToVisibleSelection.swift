import Foundation

/// One descendant weighed for the accessibility scroll rung: where it sits, and whether it says it
/// can perform the action at all.
public struct ScrollToVisibleCandidate: Equatable, Sendable {
    public let frame: AXFrame
    public let performsScrollToVisible: Bool

    public init(frame: AXFrame, performsScrollToVisible: Bool) {
        self.frame = frame
        self.performsScrollToVisible = performsScrollToVisible
    }
}

/// Chooses which descendant `AXScrollToVisible` is pressed on, from geometry and capability alone.
///
/// Two rules apply, in this order.
///
/// **Eligibility.** An element that does not advertise the action cannot perform it, so it is not a
/// candidate however well it is placed. Choosing on geometry alone commits to a mechanism that may
/// not exist — most list rows in AppKit apps advertise no scrolling action at all — and the request
/// then fails at the perform site with nothing having been tried.
///
/// **Ranking**, among what remains: the element nearest to where the requested delta wants the
/// viewport to end up, so that revealing it moves the viewport approximately that far. Eligibility
/// filters before ranking rather than breaking its ties, because the nearest ineligible element is
/// not a better answer than a reachable one further away — it is not an answer.
public enum ScrollToVisibleSelector {
    /// The index into `candidates` of the element to reveal, or `nil` when none can carry the scroll.
    public static func select(
        from candidates: [ScrollToVisibleCandidate],
        container: AXFrame,
        deltaX: Double,
        deltaY: Double
    ) -> Int? {
        guard deltaX != 0 || deltaY != 0 else {
            return nil
        }
        let desired = desiredCoordinate(container: container, deltaX: deltaX, deltaY: deltaY)
        return candidates.indices
            .filter { index in
                let candidate = candidates[index]
                return candidate.performsScrollToVisible
                    && isOutside(candidate.frame, container: container, deltaX: deltaX, deltaY: deltaY)
            }
            .min { lhs, rhs in
                distance(candidates[lhs].frame, to: desired, deltaX: deltaX, deltaY: deltaY)
                    < distance(candidates[rhs].frame, to: desired, deltaX: deltaX, deltaY: deltaY)
            }
    }

    /// Whether the delta would have to move the viewport for this frame to come into view.
    ///
    /// Exposed so a caller walking a live accessibility tree can apply the cheap geometric test
    /// before paying for a capability round trip per element. `select` applies it again, so the
    /// rule stays stated in one place whatever the caller filtered.
    public static func isOutside(_ frame: AXFrame, container: AXFrame, deltaX: Double, deltaY: Double) -> Bool {
        if abs(deltaY) >= abs(deltaX) {
            return deltaY < 0 ? frame.y >= container.maxY : frame.maxY <= container.y
        }
        return deltaX < 0 ? frame.x >= container.maxX : frame.maxX <= container.x
    }

    /// The edge of the container the requested delta reaches for, one delta beyond its own edge.
    private static func desiredCoordinate(container: AXFrame, deltaX: Double, deltaY: Double) -> Double {
        if abs(deltaY) >= abs(deltaX) {
            return deltaY < 0 ? container.maxY + abs(deltaY) : container.y - abs(deltaY)
        }
        return deltaX < 0 ? container.maxX + abs(deltaX) : container.x - abs(deltaX)
    }

    private static func distance(_ frame: AXFrame, to desired: Double, deltaX: Double, deltaY: Double) -> Double {
        let coordinate = abs(deltaY) >= abs(deltaX) ? frame.midY : frame.midX
        return abs(coordinate - desired)
    }
}

extension AXFrame {
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
}
