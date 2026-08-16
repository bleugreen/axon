import AppKit
import ApplicationServices
import CoreGraphics
import Testing
@testable import AxonCore

private let pointerFrame = AXFrame(x: 10, y: 20, width: 100, height: 40)

private final class MutatingPointerOverlay: VisualOverlay {
    private let mutation: () -> Void

    init(mutation: @escaping () -> Void) {
        self.mutation = mutation
    }

    func showTarget(_: VisualTarget) {
        mutation()
    }
}

/// The process every element in these tests belongs to, so background delivery has an identity to
/// bind to and never reaches the real global event tap.
private let pointerProcess: pid_t = 4_242

@Test func handleClickValidatesAfterVisualOverlayDelay() throws {
    let intended = AXUIElementCreateSystemWide()
    let unrelated = AXUIElementCreateApplication(123)
    let store = AXElementStore()
    store.store(snapshotID: SnapshotID("pointer"), elements: [intended])
    var hit = intended
    var posted: [CGEventType] = []
    let overlay = MutatingPointerOverlay { hit = unrelated }
    let executor = AXPrimitiveActionExecutor(
        elementStore: store,
        overlay: overlay,
        overlayConfiguration: VisualOverlayConfiguration(enabled: true, actionDelay: 0),
        postEvent: { posted.append($0.type) },
        postEventToProcess: { event, _ in posted.append(event.type) },
        hitTest: { _ in hit },
        frameProvider: { _ in pointerFrame },
        parentProvider: { _ in nil },
        processProvider: { _ in pointerProcess },
        frontmostApp: { ForegroundApp(processIdentifier: 7, name: "Prior", bundleIdentifier: "com.example.prior") },
        pointerLocation: { .zero }
    )

    let result = try executor.click(target: "pointer:0", policy: .backgroundOnly)

    #expect(result.success == false)
    #expect(result.message?.contains("occluded") == true)
    #expect(posted.isEmpty)
}

private func pointerExecutor(
    intended: AXUIElement,
    hit: AXUIElement?,
    frames: @escaping (AXUIElement) -> AXFrame? = { _ in pointerFrame },
    parent: @escaping (AXUIElement) -> AXUIElement? = { _ in nil },
    process: pid_t? = pointerProcess,
    posted: @escaping (CGEvent) -> Void
) -> AXPrimitiveActionExecutor {
    let store = AXElementStore()
    store.store(snapshotID: SnapshotID("pointer"), elements: [intended])
    return AXPrimitiveActionExecutor(
        elementStore: store,
        overlay: nil,
        postEvent: posted,
        postEventToProcess: { event, _ in posted(event) },
        sleepMilliseconds: { _ in },
        hitTest: { _ in hit },
        frameProvider: frames,
        parentProvider: parent,
        processProvider: { _ in process },
        frontmostApp: { ForegroundApp(processIdentifier: 7, name: "Prior", bundleIdentifier: "com.example.prior") },
        activateProcess: { _ in true },
        pointerLocation: { .zero }
    )
}

@Test func dragRevalidatesDestinationAtTerminalDispatchAndCancelsAtLastSafePoint() throws {
    let intended = AXUIElementCreateSystemWide()
    let unrelated = AXUIElementCreateApplication(123)
    let store = AXElementStore()
    store.store(snapshotID: SnapshotID("pointer"), elements: [intended])
    var hitTests = 0
    var posted: [(CGEventType, CGPoint)] = []
    let executor = AXPrimitiveActionExecutor(
        elementStore: store,
        overlay: nil,
        postEvent: { posted.append(($0.type, $0.location)) },
        postEventToProcess: { event, _ in posted.append((event.type, event.location)) },
        sleepMilliseconds: { _ in },
        hitTest: { _ in
            defer { hitTests += 1 }
            return hitTests < 1 ? intended : unrelated
        },
        frameProvider: { _ in pointerFrame },
        parentProvider: { _ in nil },
        processProvider: { _ in pointerProcess },
        frontmostApp: { ForegroundApp(processIdentifier: 7, name: "Prior", bundleIdentifier: "com.example.prior") },
        pointerLocation: { .zero }
    )

    let result = try executor.drag(
        from: .point(ActionPoint(x: 0, y: 0, coordinateSpace: .screen)),
        to: .handle("pointer:0"),
        app: nil,
        durationMs: 300,
        policy: .backgroundOnly
    )

    #expect(result.success == false)
    #expect(result.details["cancelledSafely"] == .bool(true))
    #expect(posted.last?.0 == .leftMouseUp)
    #expect(posted.last?.1 != CGPoint(x: 60, y: 40))
}

@Test func handleClickAcceptsHitDescendantOfIntendedElement() throws {
    let intended = AXUIElementCreateSystemWide()
    let child = AXUIElementCreateApplication(123)
    var posted: [CGEventType] = []
    let executor = pointerExecutor(
        intended: intended,
        hit: child,
        parent: { CFEqual($0, child) ? intended : nil }
    ) { posted.append($0.type) }

    let result = try executor.click(target: "pointer:0", policy: .backgroundOnly)

    // A pointer click cannot read back what it achieved, so an accepted dispatch is all it may
    // claim; `run` upgrades it to success through an expects postcondition.
    #expect(result.success == false)
    #expect(result.dispatchSuccess)
    #expect(result.delivery == .pixel)
    #expect(posted == [.leftMouseDown, .leftMouseUp])
}

@Test func handleClickRejectsHitAncestorOfIntendedElement() throws {
    let intended = AXUIElementCreateSystemWide()
    let parent = AXUIElementCreateApplication(123)
    var posted: [CGEventType] = []
    let executor = pointerExecutor(
        intended: intended,
        hit: parent,
        parent: { CFEqual($0, intended) ? parent : nil }
    ) { posted.append($0.type) }

    let result = try executor.click(target: "pointer:0", policy: .backgroundOnly)

    #expect(result.success == false)
    #expect(posted.isEmpty)
}

@Test func handleClickRejectsMismatchedHitWithoutPostingPointerEvents() throws {
    let intended = AXUIElementCreateSystemWide()
    let unrelated = AXUIElementCreateApplication(123)
    var posted: [CGEventType] = []
    let executor = pointerExecutor(intended: intended, hit: unrelated) { posted.append($0.type) }

    let result = try executor.click(target: "pointer:0", policy: .backgroundOnly)

    #expect(result.success == false)
    #expect(result.message?.contains("occluded") == true)
    #expect(posted.isEmpty)
}

@Test func handleClickPostsWhenHitMatchesIntendedElement() throws {
    let intended = AXUIElementCreateSystemWide()
    var posted: [CGEventType] = []
    let executor = pointerExecutor(intended: intended, hit: intended) { posted.append($0.type) }

    let result = try executor.click(target: "pointer:0", policy: .backgroundOnly)

    #expect(result.success == false)
    #expect(result.dispatchSuccess)
    #expect(result.delivery == .pixel)
    #expect(result.strategy == "CGEventToPid")
    #expect(posted == [.leftMouseDown, .leftMouseUp])
}

@Test func handleClickWithoutProcessIdentityRefusesUnderBackgroundOnly() throws {
    let intended = AXUIElementCreateSystemWide()
    var posted: [CGEventType] = []
    let executor = pointerExecutor(
        intended: intended,
        hit: intended,
        process: nil
    ) { posted.append($0.type) }

    let result = try executor.click(target: "pointer:0", policy: .backgroundOnly)

    #expect(result.success == false)
    #expect(result.dispatchSuccess == false)
    #expect(result.delivery == nil)
    #expect(result.refusal?.reason == .foregroundNotPermitted)
    #expect(posted.isEmpty)
}

@Test func handleClickWithoutProcessIdentityEscalatesWhenForegroundIsPermitted() throws {
    let intended = AXUIElementCreateSystemWide()
    var posted: [CGEventType] = []
    let executor = pointerExecutor(
        intended: intended,
        hit: intended,
        process: nil
    ) { posted.append($0.type) }

    let result = try executor.click(target: "pointer:0", policy: .foregroundPermitted)

    #expect(result.delivery == .foreground)
    #expect(result.dispatchSuccess)
    #expect(result.strategy == "CGEvent")
    #expect(posted == [.leftMouseDown, .leftMouseUp])
}

@Test func anAppScopedPointTakesTheTargetedRungAndProvesNothingAboutTheForeground() throws {
    // `CGEventToPid` is a separate mechanism from foreground activation and answers a different
    // question. A point that names an application is delivered to that process directly: nothing is
    // raised, nothing reaches the shared devices, and the result carries no foreground evidence at
    // all — so a working targeted click is never evidence that the transaction above it behaves.
    var global: [CGEventType] = []
    var targeted: [pid_t] = []
    var activations: [pid_t] = []
    // Resolvable by pid, so the point carries a genuine application identity without depending on
    // any particular application being installed.
    let target = try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier)
    let executor = AXPrimitiveActionExecutor(
        elementStore: AXElementStore(),
        overlay: nil,
        postEvent: { global.append($0.type) },
        postEventToProcess: { _, pid in targeted.append(pid) },
        sleepMilliseconds: { _ in },
        frameProvider: { _ in pointerFrame },
        parentProvider: { _ in nil },
        processProvider: { _ in nil },
        frontmostApp: { ForegroundApp(processIdentifier: 7, name: "Prior", bundleIdentifier: "com.example.prior") },
        activateProcess: { activations.append($0); return true },
        pointerLocation: { .zero }
    )

    let result = try executor.click(
        point: ActionPoint(x: 30, y: 40, coordinateSpace: .screen, app: String(target)),
        policy: .foregroundPermitted
    )

    #expect(result.delivery == .pixel)
    #expect(result.strategy == "CGEventToPid")
    #expect(targeted == [target, target])
    #expect(global.isEmpty)
    #expect(activations.isEmpty)
    #expect(result.details["foreground"] == nil)
}

@Test func typeFallbackRejectsMismatchedHitBeforeMouseOrKeyboardEvents() throws {
    let intended = AXUIElementCreateSystemWide()
    let unrelated = AXUIElementCreateApplication(123)
    var posted: [CGEventType] = []
    let executor = pointerExecutor(intended: intended, hit: unrelated) { posted.append($0.type) }

    let result = try executor.type(target: "pointer:0", value: "unsafe", policy: .backgroundOnly)

    #expect(result.success == false)
    #expect(result.message?.contains("occluded") == true)
    #expect(posted.isEmpty)
}

@Test func dragRejectsMismatchedHandleEndpointBeforeAnyPointerEvent() throws {
    let intended = AXUIElementCreateSystemWide()
    let unrelated = AXUIElementCreateApplication(123)
    var posted: [CGEventType] = []
    let executor = pointerExecutor(intended: intended, hit: unrelated) { posted.append($0.type) }

    let result = try executor.drag(
        from: .handle("pointer:0"),
        to: .point(ActionPoint(x: 200, y: 200, coordinateSpace: .screen)),
        app: nil,
        durationMs: nil,
        policy: .backgroundOnly
    )

    #expect(result.success == false)
    #expect(result.dispatchSuccess == false)
    #expect(posted.isEmpty)
}

@Test func handleClickDistinguishesMovementDetectedDuringValidation() throws {
    let intended = AXUIElementCreateSystemWide()
    let unrelated = AXUIElementCreateApplication(123)
    var reads = 0
    let executor = pointerExecutor(intended: intended, hit: unrelated, frames: { _ in
        defer { reads += 1 }
        return reads == 0 ? pointerFrame : AXFrame(x: 200, y: 200, width: 100, height: 40)
    }) { _ in }

    let result = try executor.click(target: "pointer:0", policy: .backgroundOnly)

    #expect(result.success == false)
    #expect(result.message?.contains("moved") == true)
}