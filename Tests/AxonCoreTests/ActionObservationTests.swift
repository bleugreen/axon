import Foundation
import Testing
@testable import AxonCore

@Test func settleLoopStopsAsSoonAsTwoReadsAgree() {
    let before = buttonState(focused: false)
    let after = buttonState(focused: true)
    let observer = StubActionStateObserver(elementReads: [before, after, after, after])
    var sleeps: [Int] = []
    let collector = ActionObservationCollector(
        observer: observer,
        sleepMilliseconds: { sleeps.append($0) },
        now: { Date(timeIntervalSince1970: 1_775_000_000) }
    )

    collector.begin(tool: "click", handle: "s1:2")
    collector.finish(success: true)

    // One pre-action read, then two post-action reads that agree.
    #expect(observer.elementReadCount == 3)
    #expect(sleeps == [ActionObservationCollector.settleIntervalMs])
    #expect(collector.observation?.settled == true)
    #expect(collector.observation?.targetAfter?.focused == true)
}

@Test func settleLoopStaysInsideItsBudgetWhenReadingsKeepChanging() {
    let churning = (0..<64).map { Optional(buttonState(value: "tick-\($0)")) }
    let observer = StubActionStateObserver(elementReads: churning)
    var sleeps: [Int] = []
    // A frozen clock is the worst case: only the read bound can stop the loop.
    let collector = ActionObservationCollector(
        observer: observer,
        sleepMilliseconds: { sleeps.append($0) },
        now: { Date(timeIntervalSince1970: 1_775_000_000) }
    )

    collector.begin(tool: "click", handle: "s1:2")
    collector.finish(success: true)

    #expect(sleeps.reduce(0, +) <= ActionObservationCollector.settleBudgetMs)
    #expect(collector.observation?.settled == false)
}

@Test func actionsThatAreNotTransitionLikelyDoNotWaitToSettle() {
    let observer = StubActionStateObserver(elementReads: [buttonState(value: ""), buttonState(value: "Ada")])
    var sleeps: [Int] = []
    let collector = ActionObservationCollector(
        observer: observer,
        sleepMilliseconds: { sleeps.append($0) },
        now: Date.init
    )

    collector.begin(tool: "type", handle: "s1:2", inputs: ["Ada"])
    collector.finish(success: true)

    #expect(sleeps.isEmpty)
    #expect(observer.elementReadCount == 2)
    #expect(collector.observation?.settled == true)
}

@Test func inputEchoIsDecidedAtCaptureAgainstTheUnredactedInput() {
    let observer = StubActionStateObserver(elementReads: [buttonState(value: ""), buttonState(value: "Ada")])
    let collector = ActionObservationCollector(observer: observer, sleepMilliseconds: { _ in }, now: Date.init)

    collector.begin(tool: "type", handle: "s1:2", inputs: ["Ada"])
    collector.finish(success: true)

    #expect(collector.observation?.targetAfter?.valueDerivedFromInput == true)
}

@Test func aRefusedDispatchProducesNoObservation() {
    let observer = StubActionStateObserver(elementReads: [buttonState(focused: false), buttonState(focused: true)])
    let collector = ActionObservationCollector(observer: observer, sleepMilliseconds: { _ in }, now: Date.init)

    collector.begin(tool: "click", handle: "s1:2")
    collector.finish(success: false)

    #expect(collector.observation == nil)
    // Nothing was dispatched, so nothing is read back either.
    #expect(observer.elementReadCount == 1)
}

@Test func recorderSettlePolicyWaitsAfterToolsTheAgentPathDoesNot() {
    let observer = StubActionStateObserver(elementReads: [
        buttonState(value: ""),
        buttonState(value: "Ada"),
        buttonState(value: "Ada")
    ])
    var sleeps: [Int] = []
    let collector = ActionObservationCollector(
        observer: observer,
        sleepMilliseconds: { sleeps.append($0) },
        now: Date.init,
        settlesAfter: ActionObservationCollector.settlesAfterEveryTool
    )

    collector.begin(tool: "type", handle: "s1:2", inputs: ["Ada"])
    collector.finish(success: true)

    // `type` reads its own value back when the agent dispatches it, but a passive recorder has
    // no such guarantee, so the recorder's policy pays for the same settle wait on every tool.
    #expect(sleeps == [ActionObservationCollector.settleIntervalMs])
    #expect(collector.observation?.settled == true)
    #expect(collector.observation?.targetAfter?.value == "Ada")
}

// MARK: - Fixtures

/// Replays a fixed sequence of reads, holding the last one once the sequence runs out. That models
/// a surface that transitions once and then stays put, which is what a settle loop is looking for.
final class StubActionStateObserver: ActionStateObserving, @unchecked Sendable {
    private let elementReads: [ObservedElementState?]
    private let appReads: [ObservedAppState?]
    private(set) var elementReadCount = 0
    private(set) var appReadCount = 0

    init(elementReads: [ObservedElementState?] = [nil], appReads: [ObservedAppState?] = [nil]) {
        self.elementReads = elementReads.isEmpty ? [nil] : elementReads
        self.appReads = appReads.isEmpty ? [nil] : appReads
    }

    func elementState(handle: String) -> ObservedElementState? {
        defer { elementReadCount += 1 }
        return elementReads[min(elementReadCount, elementReads.count - 1)]
    }

    func appState(_ scope: ActionObservationScope) -> ObservedAppState? {
        defer { appReadCount += 1 }
        return appReads[min(appReadCount, appReads.count - 1)]
    }
}

func buttonState(
    app: String = "Example",
    role: String = "AXButton",
    locator: [String: JSONValue]? = ["role": .string("AXButton"), "title": .string("Submit")],
    value: String? = nil,
    focused: Bool? = nil,
    enabled: Bool? = nil
) -> ObservedElementState {
    ObservedElementState(
        app: app,
        role: role,
        locator: locator,
        value: value,
        focused: focused,
        enabled: enabled
    )
}
