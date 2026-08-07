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

private func dragExecutor(
    posted: @escaping (CGEvent) -> Void,
    sleeps: @escaping (Int) -> Void = { _ in }
) -> AXPrimitiveActionExecutor {
    AXPrimitiveActionExecutor(
        elementStore: AXElementStore(),
        overlay: nil,
        postEvent: posted,
        postEventToProcess: { event, _ in posted(event) },
        sleepMilliseconds: sleeps,
        frontmostApp: { ForegroundApp(processIdentifier: 7, name: "Prior", bundleIdentifier: "com.example.prior") },
        activateProcess: { _ in true },
        pointerLocation: { .zero }
    )
}

@Test func primitiveDragUsesInjectedEventSinkAndReportsDispatchOnly() throws {
    var posted: [(type: CGEventType, location: CGPoint)] = []
    var sleeps: [Int] = []
    let executor = dragExecutor(
        posted: { event in posted.append((event.type, event.location)) },
        sleeps: { sleeps.append($0) }
    )

    let result = try executor.drag(
        from: .point(ActionPoint(x: 10, y: 20, coordinateSpace: .screen)),
        to: .point(ActionPoint(x: 110, y: 220, coordinateSpace: .screen)),
        app: nil,
        durationMs: 300,
        policy: .foregroundPermitted
    )

    #expect(result.success == false)
    #expect(result.dispatchSuccess)
    #expect(result.delivery == .foreground)
    #expect(result.details["semanticSuccess"] == .null)
    #expect(result.details["semanticStatus"] == .string("unverified"))
    #expect(posted.first?.type == .leftMouseDown)
    #expect(posted.last?.type == .leftMouseUp)
    #expect(posted.filter { $0.type == .leftMouseDragged }.count >= 9)
    #expect(sleeps.count == posted.count - 1)
}

@Test func primitiveDragOnRawPointsRefusesUnderBackgroundOnly() throws {
    var posted: [CGEventType] = []
    let executor = dragExecutor(posted: { posted.append($0.type) })

    let result = try executor.drag(
        from: .point(ActionPoint(x: 10, y: 20, coordinateSpace: .screen)),
        to: .point(ActionPoint(x: 110, y: 220, coordinateSpace: .screen)),
        app: nil,
        durationMs: 300,
        policy: .backgroundOnly
    )

    #expect(result.success == false)
    #expect(result.dispatchSuccess == false)
    #expect(result.delivery == nil)
    #expect(result.refusal?.reason == .foregroundNotPermitted)
    #expect(result.refusal?.requiredRung == .foreground)
    #expect(result.refusal?.capability == .globalInput)
    #expect(posted.isEmpty)
}
