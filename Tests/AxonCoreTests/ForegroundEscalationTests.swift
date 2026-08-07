import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import AxonCore

private let escalationFrame = AXFrame(x: 10, y: 20, width: 100, height: 40)
private let priorProcess: pid_t = 11
private let targetProcess: pid_t = 22

/// A scriptable stand-in for the window server: who holds the foreground, where the real pointer
/// is, and what activation is allowed to accomplish.
private final class FakeSession: @unchecked Sendable {
    var frontmost: pid_t = priorProcess
    var pointer = CGPoint(x: 500, y: 500)
    /// Processes that refuse to come forward, so activation cannot be proved.
    var refusesActivation: Set<pid_t> = []
    /// True when posting drags the real pointer somewhere it will not return from.
    var pointerIsStuck = false
    var pointerAfterPost: CGPoint?
    private(set) var log: [String] = []
    private(set) var globalPosts = 0
    private(set) var targetedPosts: [pid_t] = []
    private(set) var frontmostDuringDispatch: [pid_t] = []

    func activate(_ pid: pid_t) -> Bool {
        log.append("activate:\(pid)")
        guard !refusesActivation.contains(pid) else {
            return false
        }
        frontmost = pid
        return true
    }

    func movePointer(to point: CGPoint) {
        log.append("pointer:\(Int(point.x)),\(Int(point.y))")
        guard !pointerIsStuck else { return }
        pointer = point
    }

    /// A `type` executor whose semantic rung always fails, because setting `AXValue` on a synthetic
    /// element never takes. That is what puts the pointer-and-keystroke rungs in play.
    ///
    /// `occludedUntilFrontmost` models the real window server: an app's window is not hit-testable
    /// at the top of the stack until it has actually been raised.
    func typeExecutor(
        store: AXElementStore,
        element: AXUIElement,
        process: pid_t? = targetProcess,
        occludedUntilFrontmost: Bool = false
    ) -> AXPrimitiveActionExecutor {
        let occluder = AXUIElementCreateApplication(9_999)
        return AXPrimitiveActionExecutor(
            elementStore: store,
            overlay: nil,
            postEvent: { _ in
                self.log.append("post")
                self.globalPosts += 1
                self.frontmostDuringDispatch.append(self.frontmost)
                if let pointerAfterPost = self.pointerAfterPost {
                    self.pointer = pointerAfterPost
                }
            },
            postEventToProcess: { _, pid in
                self.log.append("postToPid:\(pid)")
                self.targetedPosts.append(pid)
                self.frontmostDuringDispatch.append(self.frontmost)
            },
            sleepMilliseconds: { _ in },
            // A fixed layout, because the Carbon input-source lookup behind the real one is not
            // safe to call from tests running in parallel.
            makeKeyboardLayout: {
                KeyboardLayoutMap(strokes: [
                    "h": KeyboardLayoutMap.Stroke(keyCode: 4, flags: []),
                    "e": KeyboardLayoutMap.Stroke(keyCode: 14, flags: []),
                    "l": KeyboardLayoutMap.Stroke(keyCode: 37, flags: []),
                    "o": KeyboardLayoutMap.Stroke(keyCode: 31, flags: [])
                ])
            },
            hitTest: { _ in
                guard occludedUntilFrontmost, self.frontmost != targetProcess else {
                    return element
                }
                return occluder
            },
            frameProvider: { _ in escalationFrame },
            parentProvider: { _ in nil },
            processProvider: { _ in process },
            frontmostApp: {
                ForegroundApp(
                    processIdentifier: self.frontmost,
                    name: "pid \(self.frontmost)",
                    bundleIdentifier: "com.example.p\(self.frontmost)"
                )
            },
            activateProcess: { self.activate($0) },
            pointerLocation: { self.pointer },
            movePointer: { self.movePointer(to: $0) },
            settleTimeoutMs: 40,
            settleIntervalMs: 10
        )
    }
}

private func escalationStore() -> (AXElementStore, AXUIElement) {
    let element = AXUIElementCreateApplication(Int32(targetProcess))
    let store = AXElementStore()
    store.store(snapshotID: SnapshotID("fg"), elements: [element])
    return (store, element)
}

@Test func backgroundOnlyTypeStopsAtThePixelRungWithoutActivatingAnything() throws {
    let session = FakeSession()
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .backgroundOnly)

    #expect(result.delivery == .pixel)
    #expect(result.dispatchSuccess)
    #expect(result.success == false)
    // The pixel rung could not prove the field took the value, and backgroundOnly declines the
    // only rung above it.
    #expect(result.refusal?.reason == .foregroundNotPermitted)
    #expect(session.globalPosts == 0)
    #expect(session.targetedPosts.allSatisfy { $0 == targetProcess })
    #expect(!session.log.contains { $0.hasPrefix("activate") })
    #expect(session.frontmost == priorProcess)
    #expect(session.pointer == CGPoint(x: 500, y: 500))
}

@Test func foregroundEscalationRaisesTheTargetDispatchesThenRestoresThePriorApp() throws {
    let session = FakeSession()
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .foregroundPermitted)

    #expect(result.delivery == .foreground)
    #expect(result.dispatchSuccess)
    #expect(session.globalPosts > 0)
    // Every global event was posted while the target held the foreground.
    #expect(session.frontmostDuringDispatch.filter { $0 != targetProcess }.isEmpty == false)
    #expect(session.log.contains("activate:\(targetProcess)"))
    #expect(session.log.contains("activate:\(priorProcess)"))
    #expect(session.frontmost == priorProcess)

    let cleanup = result.details["foreground"]
    #expect(cleanup?["priorApp"] == .string("com.example.p11"))
    #expect(cleanup?["priorAppProcessIdentifier"] == .int(Int(priorProcess)))
    #expect(cleanup?["alreadyFrontmost"] == .bool(false))
    #expect(cleanup?["activationProved"] == .bool(true))
    #expect(cleanup?["restored"] == .bool(true))
}

@Test func foregroundEscalationSkipsActivationWhenTheTargetAlreadyHoldsTheForeground() throws {
    let session = FakeSession()
    session.frontmost = targetProcess
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .foregroundPermitted)

    #expect(result.delivery == .foreground)
    #expect(session.globalPosts > 0)
    #expect(!session.log.contains { $0.hasPrefix("activate") })
    #expect(result.details["foreground"]?["alreadyFrontmost"] == .bool(true))
    #expect(result.details["foreground"]?["restored"] == .bool(true))
    #expect(session.frontmost == targetProcess)
}

@Test func foregroundEscalationRefusesWithoutPostingWhenActivationCannotBeProved() throws {
    let session = FakeSession()
    session.refusesActivation = [targetProcess]
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .foregroundPermitted)

    #expect(result.refusal?.reason == .activationNotProved)
    #expect(result.refusal?.requiredRung == .foreground)
    #expect(result.refusal?.capability == .globalInput)
    #expect(result.dispatchSuccess == false)
    #expect(result.delivery == nil)
    #expect(session.globalPosts == 0)
    #expect(session.frontmost == priorProcess)
    #expect(result.details["foreground"]?["activationProved"] == .bool(false))
}

@Test func foregroundRestorationFailureKeepsDispatchEvidenceAndFailsOverall() throws {
    let session = FakeSession()
    // The target comes forward but will not give the foreground back.
    session.refusesActivation = [priorProcess]
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .foregroundPermitted)

    #expect(result.delivery == .foreground)
    #expect(result.dispatchSuccess)
    #expect(result.success == false)
    #expect(result.details["foreground"]?["restored"] == .bool(false))
    #expect(result.message?.contains("not restored") == true)
    #expect(session.globalPosts > 0)
}

@Test func foregroundDispatchPutsTheRealPointerBackWhenPostingMovedIt() throws {
    let session = FakeSession()
    session.pointerAfterPost = CGPoint(x: 900, y: 900)
    let origin = session.pointer
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .foregroundPermitted)

    #expect(result.details["foreground"]?["pointerRestored"] == .bool(true))
    #expect(session.pointer == origin)
}

@Test func foregroundDispatchThatCannotRestoreThePointerFailsOverall() throws {
    let session = FakeSession()
    session.pointerAfterPost = CGPoint(x: 900, y: 900)
    session.pointerIsStuck = true
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .foregroundPermitted)

    #expect(result.dispatchSuccess)
    #expect(result.success == false)
    #expect(result.details["foreground"]?["pointerRestored"] == .bool(false))
}

@Test func foregroundDispatchThatNeverMovedThePointerReportsNothingToRestore() throws {
    let session = FakeSession()
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .foregroundPermitted)

    #expect(result.details["foreground"]?["pointerRestored"] == .null)
    #expect(!session.log.contains { $0.hasPrefix("pointer:") })
}

@Test func backgroundPixelDeliveryReportsTheInvariantsItKept() throws {
    let session = FakeSession()
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .backgroundOnly)

    let evidence = result.details["backgroundDelivery"]
    #expect(evidence?["targetProcessIdentifier"] == .int(Int(targetProcess)))
    #expect(evidence?["frontmostAppUnchanged"] == .bool(true))
    #expect(evidence?["pointerUnchanged"] == .bool(true))
    // The window the input was bound to, and the coordinates it was converted through.
    #expect(result.details["targetWindow"] == nil || result.details["targetWindow"]?["frame"] != nil)
}

@Test func foregroundEscalationWaitsForTheRaisedWindowBeforeValidatingTheTarget() throws {
    // An app is reported frontmost before the window server finishes raising its window, so a hit
    // test taken the instant activation is proved still sees the old stack. Validating only once
    // there would reject the target as occluded by the very window the escalation moved aside.
    let session = FakeSession()
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element, occludedUntilFrontmost: true)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .foregroundPermitted)

    #expect(result.delivery == .foreground)
    #expect(result.dispatchSuccess)
    #expect(session.globalPosts > 0)
    #expect(result.details["foreground"]?["activationProved"] == .bool(true))
    #expect(result.details["foreground"]?["restored"] == .bool(true))
}

@Test func anOccludedTargetUnderBackgroundOnlyDispatchesNothingAndRefuses() throws {
    // The background rung cannot raise anything, so its occlusion check is final. Nothing is
    // posted, and the caller is told the escalation that would resolve it was declined.
    let session = FakeSession()
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element, occludedUntilFrontmost: true)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .backgroundOnly)

    #expect(result.success == false)
    #expect(result.dispatchSuccess == false)
    #expect(result.refusal?.reason == .foregroundNotPermitted)
    #expect(result.message?.contains("occluded") == true)
    #expect(session.globalPosts == 0)
    #expect(session.targetedPosts.isEmpty)
    #expect(!session.log.contains { $0.hasPrefix("activate") })
}

@Test func withoutProcessIdentityBackgroundOnlyRefusesAndForegroundNeverActivates() throws {
    let session = FakeSession()
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element, process: nil)

    let refused = try executor.type(target: "fg:0", value: "hello", policy: .backgroundOnly)
    #expect(refused.refusal?.reason == .foregroundNotPermitted)
    #expect(session.globalPosts == 0)
    #expect(session.targetedPosts.isEmpty)

    let escalated = try executor.type(target: "fg:0", value: "hello", policy: .foregroundPermitted)
    #expect(escalated.delivery == .foreground)
    #expect(session.globalPosts > 0)
    // Nothing to raise means nothing is raised, and the prior app keeps the session throughout.
    #expect(!session.log.contains { $0.hasPrefix("activate") })
    #expect(escalated.details["foreground"]?["alreadyFrontmost"] == .bool(true))
    #expect(session.frontmost == priorProcess)
}
