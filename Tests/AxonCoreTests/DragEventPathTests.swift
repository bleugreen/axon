import CoreGraphics
import Testing
@testable import AxonCore

@Test func dragEventPathIncludesThresholdUpdatesSettleAndMouseUp() {
    let steps = DragEventPathSynthesizer.path(
        from: CGPoint(x: 10, y: 20),
        to: CGPoint(x: 110, y: 220),
        durationMs: 300
    )

    #expect(steps.first == DragEventStep(type: .leftMouseDown, point: CGPoint(x: 10, y: 20)))
    #expect(steps.last == DragEventStep(type: .leftMouseUp, point: CGPoint(x: 110, y: 220)))
    #expect(steps.filter { $0.type == .leftMouseDragged }.count >= 9)
    #expect(steps[1].type == .leftMouseDragged)
    #expect(steps[1].point != CGPoint(x: 110, y: 220))
    #expect(steps.suffix(3).filter { $0.point == CGPoint(x: 110, y: 220) }.count == 3)
}

@Test func primitiveDragUsesInjectedEventSinkAndReportsDispatchOnly() throws {
    var posted: [(type: CGEventType, location: CGPoint)] = []
    var sleeps: [Int] = []
    let executor = AXPrimitiveActionExecutor(
        elementStore: AXElementStore(),
        overlay: nil,
        postEvent: { event in posted.append((event.type, event.location)) },
        sleepMilliseconds: { sleeps.append($0) }
    )

    let result = try executor.drag(
        from: .point(ActionPoint(x: 10, y: 20, coordinateSpace: .screen)),
        to: .point(ActionPoint(x: 110, y: 220, coordinateSpace: .screen)),
        app: nil,
        durationMs: 300
    )

    #expect(result.success == false)
    #expect(result.details["dispatchSuccess"] == .bool(true))
    #expect(result.details["semanticSuccess"] == .null)
    #expect(result.details["semanticStatus"] == .string("unverified"))
    #expect(posted.first?.type == .leftMouseDown)
    #expect(posted.last?.type == .leftMouseUp)
    #expect(posted.filter { $0.type == .leftMouseDragged }.count >= 9)
    #expect(sleeps.count == posted.count - 1)
}
