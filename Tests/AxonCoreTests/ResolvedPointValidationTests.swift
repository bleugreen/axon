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
    /// Successive answers to "where are this application's windows"; the last one repeats. A nil
    /// answer models a window query that did not answer, which is not evidence about the point.
    var windowReadings: [[AXFrame]?]
    /// Successive answers to "what is at this point"; the last one repeats.
    var hitOwners: [pid_t]
    /// Who holds the foreground. Activation moves it, so an escalation can prove itself.
    var frontmost: pid_t = 7
    private(set) var posted: [CGEventType] = []

    convenience init(windows: [AXFrame]?, hitOwners: [pid_t]) {
        self.init(windowReadings: [windows], hitOwners: hitOwners)
    }

    init(windowReadings: [[AXFrame]?], hitOwners: [pid_t]) {
        self.windowReadings = windowReadings
        self.hitOwners = hitOwners
    }

    private func nextOwner() -> pid_t {
        hitOwners.count > 1 ? hitOwners.removeFirst() : (hitOwners.first ?? 0)
    }

    private func nextWindows() -> [AXFrame]? {
        windowReadings.count > 1 ? windowReadings.removeFirst() : (windowReadings.first ?? nil)
    }

    func executor() -> AXPrimitiveActionExecutor {
        // One synthetic element per window position any reading can produce, so a frame read can be
        // answered per window. The reading in force decides which frames those elements report.
        let widest = windowReadings.map { ($0 ?? []).count }.max() ?? 0
        let windowElements = (0..<widest).map { AXUIElementCreateApplication(pid_t(9_100 + $0)) }
        let hitElement = AXUIElementCreateSystemWide()
        var currentFrames: [AXFrame] = []
        return AXPrimitiveActionExecutor(
            elementStore: AXElementStore(),
            overlay: nil,
            postEvent: { self.posted.append($0.type) },
            postEventToProcess: { event, _ in self.posted.append(event.type) },
            sleepMilliseconds: { _ in },
            hitTest: { _ in hitElement },
            frameProvider: { element in
                windowElements.firstIndex { CFEqual($0, element) }
                    .flatMap { currentFrames.indices.contains($0) ? currentFrames[$0] : nil }
            },
            parentProvider: { _ in nil },
            processProvider: { _ in self.nextOwner() },
            attributeProvider: { _, attribute in
                guard attribute == kAXWindowsAttribute else { return nil }
                // One reading is consumed per window-list query, which is what lets a test model a
                // window that is still being moved when the first look happens.
                guard let reading = self.nextWindows() else { return nil }
                currentFrames = reading
                return Array(windowElements.prefix(reading.count)) as AnyObject
            },
            frontmostApp: {
                ForegroundApp(
                    processIdentifier: self.frontmost,
                    name: "pid \(self.frontmost)",
                    bundleIdentifier: "com.example.p\(self.frontmost)"
                )
            },
            activateProcess: {
                self.frontmost = $0
                return true
            },
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

@Test func resolvedPointDispatchesInTheBackgroundWhileItStillLandsInTheTargetWindow() throws {
    let process = try resolvableProcess()
    let desktop = FakeDesktop(windows: [resolutionWindow], hitOwners: [process])

    let result = try desktop.executor().click(
        point: resolvedPoint(at: insidePoint, app: process),
        policy: .backgroundOnly
    )

    // The point still means what it meant, so the quiet rung carries it and nothing is activated.
    #expect(result.dispatchSuccess)
    #expect(result.delivery == .pixel)
    #expect(desktop.posted == [.leftMouseDown, .leftMouseUp])
}

@Test func resolvedPointOutsideEveryTargetWindowIsRefusedWithTheMeasuredDiscrepancy() throws {
    // The field failure, reproduced: coordinates computed against a 1251-wide window, dispatched at
    // x=1575. Before this guard the click went out and silently did nothing.
    let process = try resolvableProcess()
    let desktop = FakeDesktop(windows: [resolutionWindow], hitOwners: [process])

    let result = try desktop.executor().click(
        point: resolvedPoint(at: strayPoint, app: process),
        policy: .backgroundOnly
    )

    #expect(result.success == false)
    #expect(result.dispatchSuccess == false)
    #expect(desktop.posted.isEmpty)
    let message = try #require(result.message)
    #expect(message.contains("outside every window"))
    // The three measurements that make the next occurrence diagnosable from the result alone.
    #expect(message.contains("{x:1575,y:420}"))
    #expect(message.contains("computed against {x:100,y:80,width:1251,height:900}"))
    #expect(message.contains("bounds now {x:100,y:80,width:1251,height:900}"))
}

@Test func resolvedPointRefusesGlobalDeliveryWhenAnotherApplicationOwnsThePoint() throws {
    // Having failed the quiet rung, the ladder tries the loud one — where the question changes from
    // containment to ownership, because a global event goes to whatever is on top.
    let process = try resolvableProcess()
    let desktop = FakeDesktop(windows: [resolutionWindow], hitOwners: [4_242])

    let result = try desktop.executor().click(
        point: resolvedPoint(at: strayPoint, app: process),
        policy: .foregroundPermitted
    )

    #expect(result.success == false)
    #expect(result.dispatchSuccess == false)
    #expect(desktop.posted.isEmpty)
    let message = try #require(result.message)
    #expect(message.contains("belongs to process 4242"))
    #expect(message.contains("{x:1575,y:420}"))
}

@Test func resolvedPointWaitsOutAWindowThatIsStillBeingRaised() throws {
    // The reason the check runs inside a settle budget: an application is reported frontmost before
    // the window server finishes raising its window, so the first look still sees the old stack.
    let process = try resolvableProcess()
    let desktop = FakeDesktop(windows: [resolutionWindow], hitOwners: [4_242, 4_242, process])

    let result = try desktop.executor().click(
        point: resolvedPoint(at: strayPoint, app: process),
        policy: .foregroundPermitted
    )

    #expect(result.dispatchSuccess)
    #expect(result.delivery == .foreground)
    #expect(desktop.posted == [.leftMouseDown, .leftMouseUp])
}

@Test func resolvedPointIsNotRefusedWhenTheWindowListDidNotAnswer() throws {
    // An unanswered accessibility query is not evidence that the point is wrong. Refusing on it
    // would ground a working click on a transient fault.
    let process = try resolvableProcess()
    let desktop = FakeDesktop(windows: nil, hitOwners: [process])

    let result = try desktop.executor().click(
        point: resolvedPoint(at: strayPoint, app: process),
        policy: .backgroundOnly
    )

    #expect(result.dispatchSuccess)
    #expect(desktop.posted == [.leftMouseDown, .leftMouseUp])
}

@Test func aPointWithoutProvenanceIsDispatchedWithoutGeometricValidation() throws {
    // A coordinate the caller supplied has nothing to be measured against, so there is nothing to
    // check and the guard must not invent a claim about it.
    let process = try resolvableProcess()
    let desktop = FakeDesktop(windows: [resolutionWindow], hitOwners: [4_242])

    let result = try desktop.executor().click(
        point: resolvedPoint(at: strayPoint, app: process, provenance: nil),
        policy: .backgroundOnly
    )

    #expect(result.dispatchSuccess)
    #expect(desktop.posted == [.leftMouseDown, .leftMouseUp])
}
