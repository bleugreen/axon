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
        hitTest: { _ in hit },
        frameProvider: { _ in pointerFrame },
        parentProvider: { _ in nil }
    )

    let result = try executor.click(target: "pointer:0")

    #expect(result.success == false)
    #expect(result.message?.contains("occluded") == true)
    #expect(posted.isEmpty)
}

private func pointerExecutor(
    intended: AXUIElement,
    hit: AXUIElement?,
    frames: @escaping (AXUIElement) -> AXFrame? = { _ in pointerFrame },
    parent: @escaping (AXUIElement) -> AXUIElement? = { _ in nil },
    posted: @escaping (CGEvent) -> Void
) -> AXPrimitiveActionExecutor {
    let store = AXElementStore()
    store.store(snapshotID: SnapshotID("pointer"), elements: [intended])
    return AXPrimitiveActionExecutor(
        elementStore: store,
        overlay: nil,
        postEvent: posted,
        sleepMilliseconds: { _ in },
        hitTest: { _ in hit },
        frameProvider: frames,
        parentProvider: parent
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
        sleepMilliseconds: { _ in },
        hitTest: { _ in
            defer { hitTests += 1 }
            return hitTests < 1 ? intended : unrelated
        },
        frameProvider: { _ in pointerFrame },
        parentProvider: { _ in nil }
    )

    let result = try executor.drag(
        from: .point(ActionPoint(x: 0, y: 0, coordinateSpace: .screen)),
        to: .handle("pointer:0"),
        app: nil,
        durationMs: 300
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

    let result = try executor.click(target: "pointer:0")

    #expect(result.success)
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

    let result = try executor.click(target: "pointer:0")

    #expect(result.success == false)
    #expect(posted.isEmpty)
}

@Test func handleClickRejectsMismatchedHitWithoutPostingPointerEvents() throws {
    let intended = AXUIElementCreateSystemWide()
    let unrelated = AXUIElementCreateApplication(123)
    var posted: [CGEventType] = []
    let executor = pointerExecutor(intended: intended, hit: unrelated) { posted.append($0.type) }

    let result = try executor.click(target: "pointer:0")

    #expect(result.success == false)
    #expect(result.message?.contains("occluded") == true)
    #expect(posted.isEmpty)
}

@Test func handleClickPostsWhenHitMatchesIntendedElement() throws {
    let intended = AXUIElementCreateSystemWide()
    var posted: [CGEventType] = []
    let executor = pointerExecutor(intended: intended, hit: intended) { posted.append($0.type) }

    let result = try executor.click(target: "pointer:0")

    #expect(result.success)
    #expect(posted == [.leftMouseDown, .leftMouseUp])
}

@Test func typeFallbackRejectsMismatchedHitBeforeMouseOrKeyboardEvents() throws {
    let intended = AXUIElementCreateSystemWide()
    let unrelated = AXUIElementCreateApplication(123)
    var posted: [CGEventType] = []
    let executor = pointerExecutor(intended: intended, hit: unrelated) { posted.append($0.type) }

    let result = try executor.type(target: "pointer:0", value: "unsafe")

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
        durationMs: nil
    )

    #expect(result.success == false)
    #expect(result.details["dispatchSuccess"] == .bool(false))
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

    let result = try executor.click(target: "pointer:0")

    #expect(result.success == false)
    #expect(result.message?.contains("moved") == true)
}