import AppKit
import ApplicationServices
import CoreGraphics
import Testing
@testable import AxonCore

/// Validation of a point that was resolved from a capture rather than supplied by a caller.
///
/// Such a point carries no element to hit-test against, but it does know which application it came
/// from and which window frame its coordinates were computed against — which is exactly enough to
/// notice that the geometry moved underneath it before anything is posted.

/// The window the coordinates were computed against.
private let resolutionWindow = AXFrame(x: 100, y: 80, width: 1_251, height: 900)

/// Inside `resolutionWindow`, and inside the target's current window in the tests that leave it
/// where it was.
private let insidePoint = CGPoint(x: 700, y: 400)

/// Outside `resolutionWindow` entirely — the field report's x=1575 against a 1251-wide window.
private let strayPoint = CGPoint(x: 1_575, y: 420)

/// A scripted application: which windows it currently has, and what sits at the clicked point.
private final class FakeDesktop: @unchecked Sendable {
    /// Nil models a window query that did not answer, which is not evidence about the point.
    var windows: [AXFrame]?
    /// Successive answers to "what is at this point"; the last one repeats.
    var hitOwners: [pid_t]
    private(set) var posted: [CGEventType] = []

    init(windows: [AXFrame]?, hitOwners: [pid_t]) {
        self.windows = windows
        self.hitOwners = hitOwners
    }

    private func nextOwner() -> pid_t {
        hitOwners.count > 1 ? hitOwners.removeFirst() : (hitOwners.first ?? 0)
    }

    func executor() -> AXPrimitiveActionExecutor {
        // One synthetic element per window, so a frame read can be answered per window.
        let windowElements = (windows ?? []).indices.map { AXUIElementCreateApplication(pid_t(9_100 + $0)) }
        let frames = windows ?? []
        let hitElement = AXUIElementCreateSystemWide()
        return AXPrimitiveActionExecutor(
            elementStore: AXElementStore(),
            overlay: nil,
            postEvent: { self.posted.append($0.type) },
            postEventToProcess: { event, _ in self.posted.append(event.type) },
            sleepMilliseconds: { _ in },
            hitTest: { _ in hitElement },
            frameProvider: { element in
                windowElements.firstIndex { CFEqual($0, element) }.map { frames[$0] }
            },
            parentProvider: { _ in nil },
            processProvider: { _ in self.nextOwner() },
            attributeProvider: { _, attribute in
                guard attribute == kAXWindowsAttribute, self.windows != nil else { return nil }
                return windowElements as AnyObject
            },
            frontmostApp: { ForegroundApp(processIdentifier: 7, name: "Prior", bundleIdentifier: "com.example.prior") },
            activateProcess: { _ in true },
            pointerLocation: { .zero },
            movePointer: { _ in },
            settleTimeoutMs: 40,
            settleIntervalMs: 10
        )
    }
}

/// A live process id, so the point's application resolves without depending on which apps are
/// installed on the machine running the tests.
private func resolvableProcess() throws -> pid_t {
    try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier)
}

private func resolvedPoint(at point: CGPoint, app: pid_t, provenance: AXFrame? = resolutionWindow) -> ActionPoint {
    ActionPoint(
        x: point.x,
        y: point.y,
        coordinateSpace: .screen,
        app: String(app),
        sourceWindowFrame: provenance
    )
}
