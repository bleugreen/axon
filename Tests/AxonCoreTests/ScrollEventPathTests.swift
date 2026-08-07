import ApplicationServices
import CoreGraphics
import Testing
@testable import AxonCore

private let scrollFrame = AXFrame(x: 10, y: 20, width: 100, height: 40)

@Test func scrollEventPathChunksDeltaIntoWheelStepsThatSumExactly() {
    let steps = ScrollEventPathSynthesizer.path(deltaX: 0, deltaY: -400)

    #expect(steps.count > 1)
    #expect(steps.allSatisfy { abs($0.deltaY) <= 120 })
    #expect(steps.reduce(0) { $0 + $1.deltaY } == -400)
    #expect(steps.reduce(0) { $0 + $1.deltaX } == 0)
}

@Test func scrollEventPathIsEmptyWithoutDelta() {
    #expect(ScrollEventPathSynthesizer.path(deltaX: 0, deltaY: 0).isEmpty)
}

@Test func scrollEventPathCapsStepCountAndStillSumsExactly() {
    let steps = ScrollEventPathSynthesizer.path(deltaX: 0, deltaY: 100_000)

    #expect(steps.count == 16)
    #expect(steps.reduce(0) { $0 + $1.deltaY } == 100_000)

    let uneven = ScrollEventPathSynthesizer.path(deltaX: -37, deltaY: 1_000)
    #expect(uneven.reduce(0) { $0 + $1.deltaY } == 1_000)
    #expect(uneven.reduce(0) { $0 + $1.deltaX } == -37)
}

@Test func scrollPointTargetPostsWheelWithoutConsultingAccessibility() throws {
    var hitTests = 0
    var posted: [CGEvent] = []
    var sleeps: [Int] = []
    let executor = AXPrimitiveActionExecutor(
        elementStore: AXElementStore(),
        overlay: nil,
        postEvent: { posted.append($0) },
        postEventToProcess: { event, _ in posted.append(event) },
        sleepMilliseconds: { sleeps.append($0) },
        hitTest: { _ in
            hitTests += 1
            return nil
        }
    )

    let result = try executor.scroll(
        target: .point(ActionPoint(x: 1_720, y: 694, coordinateSpace: .screen)),
        app: nil,
        deltaX: 0,
        deltaY: -400,
        policy: .foregroundPermitted
    )

    #expect(hitTests == 0)
    #expect(result.strategy == "CGEventScroll")
    #expect(result.success == false)
    #expect(result.dispatchSuccess)
    #expect(result.message == "Scroll wheel events were dispatched, but semantic outcome is unverified without a postcondition")
    #expect(result.dispatchSuccess)
    #expect(result.details["semanticSuccess"] == .null)
    #expect(result.details["semanticStatus"] == .string("unverified"))
    #expect(result.details["eventPath"]?["eventCount"] == .int(posted.count))
    #expect(result.details["eventPath"]?["totalDeltaY"] == .double(-400))
    #expect(result.details["eventPath"]?["units"] == .string("pixel"))
    #expect(result.details["at"]?["x"] == .double(1_720))
    #expect(posted.count > 1)
    #expect(sleeps.count == posted.count - 1)
}

@Test func scrollWheelEventsCarryPixelDeltasSignAndTargetLocation() throws {
    var posted: [CGEvent] = []
    let executor = AXPrimitiveActionExecutor(
        elementStore: AXElementStore(),
        overlay: nil,
        postEvent: { posted.append($0) },
        postEventToProcess: { event, _ in posted.append(event) },
        sleepMilliseconds: { _ in },
        hitTest: { _ in nil }
    )

    _ = try executor.scroll(
        target: .point(ActionPoint(x: 1_720, y: 694, coordinateSpace: .screen)),
        app: nil,
        deltaX: 60,
        deltaY: -400,
        policy: .foregroundPermitted
    )

    // The event routes to whatever window sits under its location field; without this it lands at
    // the screen origin.
    #expect(posted.allSatisfy { $0.location == CGPoint(x: 1_720, y: 694) })
    #expect(posted.allSatisfy { $0.getIntegerValueField(.scrollWheelEventIsContinuous) == 1 })

    // Pixel units put the requested magnitude in the point-delta fields; the plain delta fields
    // carry a derived line value one tenth the size. Axis1 is vertical, axis2 horizontal, and a
    // negative vertical delta scrolls down, matching the AX path's direction convention.
    let pixelY = posted.reduce(0.0) { $0 + $1.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) }
    let pixelX = posted.reduce(0.0) { $0 + $1.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) }
    #expect(pixelY == -400)
    #expect(pixelX == 60)
    #expect(posted.allSatisfy { $0.getDoubleValueField(.scrollWheelEventDeltaAxis1) <= 0 })
    let lineY = posted.reduce(0.0) { $0 + $1.getDoubleValueField(.scrollWheelEventDeltaAxis1) }
    #expect(lineY == -40)
}

@Test func scrollFallsBackToWheelAtElementCenterWhenNothingIsScrollable() throws {
    let store = AXElementStore()
    store.store(snapshotID: SnapshotID("scroll"), elements: [AXUIElementCreateApplication(123)])
    var posted: [CGEvent] = []
    let executor = AXPrimitiveActionExecutor(
        elementStore: store,
        overlay: nil,
        postEvent: { posted.append($0) },
        postEventToProcess: { event, _ in posted.append(event) },
        sleepMilliseconds: { _ in },
        hitTest: { _ in nil },
        frameProvider: { _ in scrollFrame },
        parentProvider: { _ in nil }
    )

    let result = try executor.scroll(target: .handle("scroll:0"), app: nil, deltaX: 0, deltaY: -240, policy: .foregroundPermitted)

    // The handle carries the owning process, so the wheel binds to it and stays in the background
    // even though the caller was willing to escalate.
    #expect(result.strategy == "CGEventScrollToPid")
    #expect(result.delivery == .pixel)
    #expect(result.success == false)
    #expect(result.dispatchSuccess)
    #expect(result.details["eventPath"]?["totalDeltaY"] == .double(-240))
    #expect(posted.allSatisfy { $0.location == CGPoint(x: 60, y: 40) })
}

@Test func scrollReportsUnresolvableScreenPointRatherThanAMissingDescendant() throws {
    let store = AXElementStore()
    store.store(snapshotID: SnapshotID("scroll"), elements: [AXUIElementCreateApplication(123)])
    var posted: [CGEvent] = []
    let executor = AXPrimitiveActionExecutor(
        elementStore: store,
        overlay: nil,
        postEvent: { posted.append($0) },
        postEventToProcess: { event, _ in posted.append(event) },
        sleepMilliseconds: { _ in },
        hitTest: { _ in nil },
        frameProvider: { _ in nil },
        parentProvider: { _ in nil }
    )

    let result = try executor.scroll(target: .handle("scroll:0"), app: nil, deltaX: 0, deltaY: -240, policy: .foregroundPermitted)

    #expect(result.success == false)
    #expect(result.message == "scroll target has no resolvable screen point")
    #expect(result.dispatchSuccess == false)
    #expect(posted.isEmpty)
}

@Test func scrollWithoutDeltaIsANoOpThatClaimsNoDispatch() throws {
    var posted: [CGEvent] = []
    var activations: [pid_t] = []
    let executor = AXPrimitiveActionExecutor(
        elementStore: AXElementStore(),
        overlay: nil,
        postEvent: { posted.append($0) },
        postEventToProcess: { event, _ in posted.append(event) },
        sleepMilliseconds: { _ in },
        hitTest: { _ in nil },
        activateProcess: { activations.append($0); return true }
    )

    let result = try executor.scroll(
        target: .point(ActionPoint(x: 10, y: 20, coordinateSpace: .screen)),
        app: "Example",
        deltaX: 0,
        deltaY: 0,
        policy: .foregroundPermitted
    )

    // Asking for no movement is satisfied without doing anything, which is a success that claims
    // no dispatch and names no rung.
    #expect(result.success == true)
    #expect(result.dispatchSuccess == false)
    #expect(result.delivery == nil)
    #expect(result.details["eventPath"]?["eventCount"] == .int(0))
    #expect(result.details["semanticStatus"] == .string("noop"))
    #expect(result.message == "No scroll delta was requested; no events were posted")
    #expect(posted.isEmpty)
    #expect(activations.isEmpty)
}

@Test func scrollSmallerThanOnePixelReportsThatNothingMoved() throws {
    var posted: [CGEvent] = []
    let executor = AXPrimitiveActionExecutor(
        elementStore: AXElementStore(),
        overlay: nil,
        postEvent: { posted.append($0) },
        postEventToProcess: { event, _ in posted.append(event) },
        sleepMilliseconds: { _ in },
        hitTest: { _ in nil }
    )

    let result = try executor.scroll(
        target: .point(ActionPoint(x: 10, y: 20, coordinateSpace: .screen)),
        app: nil,
        deltaX: 0,
        deltaY: 0.4,
        policy: .foregroundPermitted
    )

    #expect(result.success == false)
    #expect(result.dispatchSuccess == false)
    #expect(result.details["semanticStatus"] == nil)
    #expect(result.details["eventPath"]?["eventCount"] == .int(0))
    #expect(result.message == "scroll delta rounds to no pixel of wheel movement")
    #expect(posted.isEmpty)
}

@Test func scrollDropsSubPixelAxisWithoutDroppingTheAxisThatMoves() throws {
    var posted: [CGEvent] = []
    let executor = AXPrimitiveActionExecutor(
        elementStore: AXElementStore(),
        overlay: nil,
        postEvent: { posted.append($0) },
        postEventToProcess: { event, _ in posted.append(event) },
        sleepMilliseconds: { _ in },
        hitTest: { _ in nil }
    )

    let result = try executor.scroll(
        target: .point(ActionPoint(x: 10, y: 20, coordinateSpace: .screen)),
        app: nil,
        deltaX: 0.4,
        deltaY: -400,
        policy: .foregroundPermitted
    )

    #expect(result.success == false)
    #expect(result.dispatchSuccess)
    #expect(result.details["eventPath"]?["totalDeltaY"] == .double(-400))
    #expect(result.details["eventPath"]?["totalDeltaX"] == .double(0))
    #expect(!posted.isEmpty)
}

@Test func scrollNeverActivatesTheNamedApp() throws {
    // A posted wheel routes by the event's location regardless of which app is frontmost, so
    // raising the app would only take the user's focus. Naming an app must stay side-effect free
    // for every target kind and every outcome.
    var log: [String] = []
    let store = AXElementStore()
    store.store(snapshotID: SnapshotID("scroll"), elements: [AXUIElementCreateApplication(123)])

    func executor(frame: AXFrame?) -> AXPrimitiveActionExecutor {
        AXPrimitiveActionExecutor(
            elementStore: store,
            overlay: nil,
            postEvent: { _ in log.append("post") },
            postEventToProcess: { _, pid in log.append("postToPid:\(pid)") },
            sleepMilliseconds: { _ in },
            hitTest: { _ in nil },
            frameProvider: { _ in frame },
            parentProvider: { _ in nil },
            activateProcess: { log.append("activate:\($0)"); return true }
        )
    }

    let scrolling = executor(frame: scrollFrame)
    _ = try scrolling.scroll(
        target: .point(ActionPoint(x: 10, y: 20, coordinateSpace: .screen)),
        app: "Example",
        deltaX: 0,
        deltaY: -400,
        policy: .foregroundPermitted
    )
    #expect(log.contains { $0.hasPrefix("post") })
    #expect(!log.contains { $0.hasPrefix("activate") })

    log = []
    _ = try scrolling.scroll(target: .handle("scroll:0"), app: "Example", deltaX: 0, deltaY: -400, policy: .foregroundPermitted)
    #expect(log.contains { $0.hasPrefix("post") })
    #expect(!log.contains { $0.hasPrefix("activate") })

    log = []
    let result = try executor(frame: nil).scroll(target: .handle("scroll:0"), app: "Example", deltaX: 0, deltaY: -400, policy: .foregroundPermitted)
    #expect(result.success == false)
    #expect(log.isEmpty)
}

// MARK: - The accessibility rung

/// A stand-in accessibility subtree. Elements are identified by fake process identifiers, which is
/// the only identity an `AXUIElement` carries when there is no live application behind it.
private struct FakeAXNode {
    var role: String
    var frame: AXFrame?
    var actions: [String] = []
    var children: [pid_t] = []
}

private struct FakeAXTree {
    let nodes: [pid_t: FakeAXNode]

    func element(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    private func node(for element: AXUIElement) -> FakeAXNode? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }
        return nodes[pid]
    }

    var attributeProvider: (AXUIElement, String) -> AnyObject? {
        { element, attribute in
            guard let node = node(for: element) else {
                return nil
            }
            switch attribute {
            case kAXRoleAttribute:
                return node.role as AnyObject
            case kAXChildrenAttribute:
                return node.children.map { AXUIElementCreateApplication($0) } as AnyObject
            default:
                return nil
            }
        }
    }

    var frameProvider: (AXUIElement) -> AXFrame? {
        { node(for: $0)?.frame }
    }

    var actionNamesProvider: (AXUIElement) -> [String] {
        { node(for: $0)?.actions ?? [] }
    }
}

/// A scroll area with two descendants below the viewport. The nearer one is a plain row advertising
/// no scrolling action, exactly as Finder's sidebar rows do; the further one advertises
/// `AXScrollToVisible`, as Music's lists do.
private let scrollAreaPid: pid_t = 200
private let advertisedFrame = AXFrame(x: 0, y: 200, width: 200, height: 20)
private let scrollTree = FakeAXTree(nodes: [
    scrollAreaPid: FakeAXNode(
        role: kAXScrollAreaRole,
        frame: AXFrame(x: 0, y: 0, width: 200, height: 100),
        children: [201, 202]
    ),
    201: FakeAXNode(role: "AXRow", frame: AXFrame(x: 0, y: 480, width: 200, height: 20), actions: ["AXShowDefaultUI"]),
    202: FakeAXNode(role: "AXList", frame: advertisedFrame, actions: ["AXScrollToVisible"])
])

private func scrollExecutor(
    performAction: @escaping (AXUIElement, String) -> AXError,
    posted: @escaping (CGEvent) -> Void,
    processProvider: ((AXUIElement) -> pid_t?)? = nil
) -> AXPrimitiveActionExecutor {
    let store = AXElementStore()
    store.store(snapshotID: SnapshotID("scroll"), elements: [scrollTree.element(scrollAreaPid)])
    return AXPrimitiveActionExecutor(
        elementStore: store,
        overlay: nil,
        postEvent: posted,
        postEventToProcess: { event, _ in posted(event) },
        sleepMilliseconds: { _ in },
        hitTest: { _ in nil },
        frameProvider: scrollTree.frameProvider,
        parentProvider: { _ in nil },
        processProvider: processProvider,
        attributeProvider: scrollTree.attributeProvider,
        actionNamesProvider: scrollTree.actionNamesProvider,
        performAction: performAction
    )
}

@Test func scrollPressesTheAccessibilityActionOnTheDescendantThatAdvertisesIt() throws {
    // The nearer row is the better geometric answer and the wrong one: it cannot perform the
    // action. Selecting the further list is what keeps the accessibility rung working in the apps
    // that do expose it.
    var posted: [CGEvent] = []
    var attempts: [String] = []
    let executor = scrollExecutor(
        performAction: { _, name in attempts.append(name); return .success },
        posted: { posted.append($0) }
    )

    let result = try executor.scroll(target: .handle("scroll:0"), app: nil, deltaX: 0, deltaY: -400, policy: .foregroundPermitted)

    #expect(attempts == ["AXScrollToVisible"])
    #expect(result.strategy == "AXScrollToVisible")
    #expect(result.delivery == .semantic)
    #expect(result.success)
    #expect(result.details["scrollTargetFrame"] == advertisedFrame.jsonValue)
    #expect(posted.isEmpty)
}

@Test func scrollAdvancesToTheWheelWhenTheAccessibilityActionIsNotAMechanism() throws {
    // An element that advertises an action and then reports it unsupported refused nothing: the app
    // was never asked to decide, so the wheel rung below is still owed its attempt.
    for error in [AXError.actionUnsupported, .attributeUnsupported] {
        var posted: [CGEvent] = []
        var attempts = 0
        let executor = scrollExecutor(
            performAction: { _, _ in attempts += 1; return error },
            posted: { posted.append($0) }
        )

        let result = try executor.scroll(target: .handle("scroll:0"), app: nil, deltaX: 0, deltaY: -400, policy: .foregroundPermitted)

        #expect(attempts == 1)
        #expect(result.strategy == "CGEventScrollToPid")
        #expect(result.delivery == .pixel)
        #expect(result.dispatchSuccess)
        #expect(result.details["eventPath"]?["totalDeltaY"] == .double(-400))
        // The wheel is aimed at the element the caller named, never at the ranked descendant, so
        // the descendant's frame has no business describing this dispatch.
        #expect(result.details["scrollTargetFrame"] == nil)
        #expect(posted.allSatisfy { $0.location == CGPoint(x: 100, y: 50) })
        #expect(!posted.isEmpty)
    }
}

@Test func scrollDoesNotAdvancePastAnAccessibilityActionTheAppAnswered() throws {
    // The app was asked and something went wrong. That is a failed scroll, not a licence to send
    // unrelated global input at the same coordinates.
    var posted: [CGEvent] = []
    let executor = scrollExecutor(
        performAction: { _, _ in .cannotComplete },
        posted: { posted.append($0) }
    )

    let result = try executor.scroll(target: .handle("scroll:0"), app: nil, deltaX: 0, deltaY: -400, policy: .foregroundPermitted)

    #expect(result.strategy == "AXScrollToVisible")
    #expect(result.success == false)
    #expect(result.message == "AXScrollToVisible returned cannotComplete (-25204)")
    #expect(posted.isEmpty)
}

@Test func scrollReportsTheAccessibilityFailureWhenNoWheelRungRemains() throws {
    // With no process to bind to and no permission to use the shared devices, the wheel never runs.
    // The caller must hear what accessibility said, not that the wheel had nowhere to aim.
    var posted: [CGEvent] = []
    let executor = scrollExecutor(
        performAction: { _, _ in .actionUnsupported },
        posted: { posted.append($0) },
        processProvider: { _ in nil }
    )

    let result = try executor.scroll(target: .handle("scroll:0"), app: nil, deltaX: 0, deltaY: -400, policy: .backgroundOnly)

    #expect(result.success == false)
    #expect(result.message?.hasPrefix("AXScrollToVisible returned actionUnsupported (-25206)") == true)
    #expect(result.refusal != nil)
    #expect(posted.isEmpty)
}
