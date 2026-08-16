import ApplicationServices
import AppKit
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
    /// Where the pointer ends up while a *background* dispatch is in flight. Posting to a process
    /// cannot move the cursor — that is the rung's whole promise — so this models the ordinary
    /// condition of a personal machine: someone using the mouse while Axon delivers.
    var pointerMovedDuringBackgroundPost: CGPoint?
    /// Successive answers to "where is the pointer", for the case where it is moving while Axon
    /// reads it. Each reading consumes one; afterwards the session answers `pointer` again.
    var pointerReadings: [CGPoint] = []
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

    func readPointer() -> CGPoint {
        guard !pointerReadings.isEmpty else { return pointer }
        return pointerReadings.removeFirst()
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
                if let moved = self.pointerMovedDuringBackgroundPost {
                    self.pointer = moved
                }
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
            pointerLocation: { self.readPointer() },
            movePointer: { self.movePointer(to: $0) },
            settleTimeoutMs: 40,
            settleIntervalMs: 10
        )
    }

    /// A click executor for a raw screen point. There is no element behind such a coordinate, so
    /// the only identity it carries is the application the caller named, and the only thing there
    /// is to validate is that the window its coordinates were measured against is still there.
    ///
    /// `windowFrame` is what that application's window currently reports. Modelling it as a
    /// function is what lets a test raise the window into place only once the application is
    /// actually frontmost, which is how the order of activation and validation becomes observable.
    func pointExecutor(
        targetProcess: pid_t,
        windowFrame: @escaping () -> AXFrame = { escalationFrame }
    ) -> AXPrimitiveActionExecutor {
        AXPrimitiveActionExecutor(
            elementStore: AXElementStore(),
            overlay: nil,
            postEvent: { _ in
                self.log.append("post")
                self.globalPosts += 1
                self.frontmostDuringDispatch.append(self.frontmost)
            },
            postEventToProcess: { _, pid in
                self.log.append("postToPid:\(pid)")
                self.targetedPosts.append(pid)
                self.frontmostDuringDispatch.append(self.frontmost)
            },
            sleepMilliseconds: { _ in },
            frameProvider: { _ in windowFrame() },
            parentProvider: { _ in nil },
            processProvider: { _ in nil },
            // The application's window list: how a point with provenance checks that the window its
            // coordinates came from is still where they were taken.
            attributeProvider: { _, attribute in
                attribute == kAXWindowsAttribute
                    ? [AXUIElementCreateApplication(targetProcess)] as AnyObject
                    : nil
            },
            frontmostApp: {
                ForegroundApp(
                    processIdentifier: self.frontmost,
                    name: "pid \(self.frontmost)",
                    bundleIdentifier: "com.example.p\(self.frontmost)"
                )
            },
            activateProcess: { self.activate($0) },
            pointerLocation: { self.readPointer() },
            movePointer: { self.movePointer(to: $0) },
            settleTimeoutMs: 40,
            settleIntervalMs: 10
        )
    }
}

/// The frame the click's coordinates were measured against, reported from somewhere else — a window
/// that has not been raised into place yet.
private let displacedFrame = AXFrame(x: 900, y: 900, width: 100, height: 40)

/// A point inside `escalationFrame`, so the coordinate is valid once the window is where its
/// provenance says it was.
private let escalationPoint = CGPoint(x: 50, y: 30)

/// An application identity the real resolver can answer, so a point carries a genuine process
/// without this test depending on any particular application being installed. Everything the
/// executor learns about the *foreground* still comes from the fake session.
private func resolvableProcess() throws -> pid_t {
    try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier)
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

@Test func foregroundRestorationFailureIsReportedWithoutChangingSemanticFailure() throws {
    let session = FakeSession()
    // The target comes forward but will not give the foreground back.
    session.refusesActivation = [priorProcess]
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .foregroundPermitted)

    #expect(result.delivery == .foreground)
    #expect(result.dispatchSuccess)
    // This synthetic field cannot verify its value, so semantic success remains false for that
    // independent reason. Failed cleanup is evidence in the result and message, not another gate.
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

@Test func foregroundDispatchThatCannotRestoreThePointerReportsItWithoutFailing() throws {
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

@Test func backgroundKeyboardDeliveryReportsPointerMotionItCannotHaveCausedWithoutFailing() throws {
    // The field case this exists for: an agent types a URL and presses Return while the person at
    // the machine is using the mouse. The keystrokes land, the pointer moves for reasons of its
    // own, and calling that a broken contract is a false negative on an action that worked.
    let session = FakeSession()
    session.pointerMovedDuringBackgroundPost = CGPoint(x: 900, y: 900)
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)
    // The frontmost application is always resolvable by pid, which gives the pixel rung a real
    // identity to bind to without depending on any particular app being installed.
    let target = try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier)

    let result = try executor.keyboard(app: String(target), intent: .key("End"), policy: .backgroundOnly)

    #expect(result.delivery == .pixel)
    #expect(result.dispatchSuccess)
    #expect(result.message?.contains("could not prove it stayed in the background") != true)
    let evidence = result.details["backgroundDelivery"]
    // The motion is reported rather than hidden; what changes is that it is not a verdict.
    #expect(evidence?["pointerUnchanged"] == .bool(false))
    #expect(evidence?["pointerAsserted"] == .bool(false))
    #expect(evidence?["frontmostAppUnchanged"] == .bool(true))
}

@Test func backgroundPointerDeliveryStillFailsWhenTheRealPointerMoves() throws {
    // The clause stays where the dispatch synthesizes pointer input: a pixel rung whose events
    // reached the shared devices would move the real cursor, and nothing on this side can tell that
    // from the hand on the mouse. So the observation stands as a failure to prove the rung, which
    // is the fail-safe direction — unlike a keyboard dispatch, which could not have done it.
    let session = FakeSession()
    session.pointerMovedDuringBackgroundPost = CGPoint(x: 900, y: 900)
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .backgroundOnly)

    #expect(result.delivery == .pixel)
    #expect(result.dispatchSuccess)
    #expect(result.success == false)
    #expect(result.message?.contains("the real pointer moved across the dispatch") == true)
    let evidence = result.details["backgroundDelivery"]
    #expect(evidence?["pointerUnchanged"] == .bool(false))
    #expect(evidence?["pointerAsserted"] == .bool(true))
}

@Test func backgroundDeliveryEvidenceAndVerdictComeFromOneReading() throws {
    // A pointer that is still moving answers two questions differently. Reading the session once
    // for the verdict and again for the evidence let a result call the pointer unchanged in the
    // same breath as the message saying it moved; both now quote the same observation.
    let session = FakeSession()
    session.pointerReadings = [CGPoint(x: 500, y: 500), CGPoint(x: 900, y: 900)]
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element)

    let result = try executor.type(target: "fg:0", value: "hello", policy: .backgroundOnly)

    #expect(result.message?.contains("the real pointer moved across the dispatch") == true)
    #expect(result.details["backgroundDelivery"]?["pointerUnchanged"] == .bool(false))
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
    // An element whose process cannot be read is a target this side cannot place, so there is no
    // application of which "already frontmost" is either true or false. Answering `true` claimed
    // the target was standing in a foreground that belongs to someone else.
    #expect(escalated.details["foreground"]?["alreadyFrontmost"] == .null)
    // And nothing is claimed about an activation that never had a target. Reporting `true` here
    // read as proof that the escalation had raised something, which sent a field investigation
    // after a mechanism this path never runs.
    #expect(escalated.details["foreground"]?["activationProved"] == .null)
    #expect(session.frontmost == priorProcess)
}

@Test func aPointNamingNoApplicationReportsActivationAsNotApplicable() throws {
    let session = FakeSession()
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element, process: nil)

    let result = try executor.click(
        point: ActionPoint(x: 10, y: 20, coordinateSpace: .screen),
        policy: .foregroundPermitted
    )

    #expect(result.delivery == .foreground)
    #expect(result.dispatchSuccess)
    #expect(result.details["foreground"]?["activationProved"] == .null)
    // And no claim about a target that does not exist. Reporting `alreadyFrontmost: true` beside a
    // foreign `priorApp` was the envelope refuting itself, and it read as confirmation that the
    // click had reached an application it had never even named.
    #expect(result.details["foreground"]?["alreadyFrontmost"] == .null)
    #expect(result.details["foreground"]?["priorApp"] == .string("com.example.p\(priorProcess)"))
    #expect(!session.log.contains { $0.hasPrefix("activate") })
}

@Test func theFieldClickRaisesSafariAndPostsGloballyRatherThanSettlingOnABackgroundPost() throws {
    // The reported request exactly: another application holds the foreground, and the caller clicks
    // a screen coordinate it measured inside the one it names. Nothing about that coordinate has
    // been checked against the named application's geometry, so the targeted rung must not take it
    // — posting it into the process is accepted and can do nothing, and a click has no
    // postcondition to notice with. What must happen instead is the transaction this issue is
    // about: raise the target, prove it, then post where the caller measured.
    let session = FakeSession()
    let target = try resolvableProcess()
    let executor = session.pointExecutor(targetProcess: target)

    let result = try executor.click(
        point: ActionPoint(
            x: escalationPoint.x,
            y: escalationPoint.y,
            coordinateSpace: .screen,
            app: String(target)
        ),
        policy: .foregroundPermitted
    )

    #expect(result.delivery == .foreground)
    #expect(result.strategy == "CGEvent")
    #expect(result.dispatchSuccess)
    // Not one event went to the process behind its own back.
    #expect(session.targetedPosts.isEmpty)
    #expect(session.globalPosts > 0)
    #expect(session.log.first == "activate:\(target)")
    #expect(session.frontmostDuringDispatch.allSatisfy { $0 == target })

    let cleanup = result.details["foreground"]
    #expect(cleanup?["priorApp"] == .string("com.example.p\(priorProcess)"))
    #expect(cleanup?["alreadyFrontmost"] == .bool(false))
    #expect(cleanup?["activationProved"] == .bool(true))
    #expect(cleanup?["restored"] == .bool(true))
    #expect(session.frontmost == priorProcess)
}

@Test func theFieldClickUnderBackgroundOnlyRefusesInsteadOfPostingIntoTheProcess() throws {
    // The same coordinate with the foreground withheld has no mechanism left, and says so. An
    // accepted post into the process would be the silent no-op this whole issue came from, dressed
    // as a delivery.
    let session = FakeSession()
    let target = try resolvableProcess()
    let executor = session.pointExecutor(targetProcess: target)

    let result = try executor.click(
        point: ActionPoint(
            x: escalationPoint.x,
            y: escalationPoint.y,
            coordinateSpace: .screen,
            app: String(target)
        ),
        policy: .backgroundOnly
    )

    #expect(result.dispatchSuccess == false)
    #expect(result.delivery == nil)
    #expect(result.refusal?.reason == .foregroundNotPermitted)
    #expect(result.refusal?.alsoRefused.contains { $0.message.contains("no window provenance") } == true)
    #expect(session.targetedPosts.isEmpty)
    #expect(session.globalPosts == 0)
    #expect(!session.log.contains { $0.hasPrefix("activate") })
}

@Test func aPointDerivedFromACaptureKeepsTheTargetedRungItsProvenanceEarns() throws {
    // The other half of the rule, so the fix above is a distinction and not a blanket ban: a point
    // that carries the window frame it was measured against can be checked against that frame, and
    // that check is what makes a targeted post honest. Such a point still delivers in the
    // background, activating nothing.
    let session = FakeSession()
    let target = try resolvableProcess()
    let executor = session.pointExecutor(targetProcess: target)

    let result = try executor.click(
        point: ActionPoint(
            x: escalationPoint.x,
            y: escalationPoint.y,
            coordinateSpace: .screen,
            app: String(target),
            sourceWindowFrame: escalationFrame
        ),
        policy: .backgroundOnly
    )

    #expect(result.delivery == .pixel)
    #expect(result.strategy == "CGEventToPid")
    #expect(result.dispatchSuccess)
    #expect(session.targetedPosts.allSatisfy { $0 == target })
    #expect(session.globalPosts == 0)
    #expect(!session.log.contains { $0.hasPrefix("activate") })
    #expect(result.details["foreground"] == nil)
}

@Test func anAppScopedPointRaisesItsOwnApplicationBeforePostingGlobalInput() throws {
    // The field case, at the rung it actually reaches: another application holds the foreground,
    // the caller clicks a point measured inside its own, and the targeted rung refuses because the
    // window is not where those coordinates were taken. What follows must be an activation that is
    // proved before a single global event is posted.
    let session = FakeSession()
    let target = try resolvableProcess()
    let executor = session.pointExecutor(
        targetProcess: target,
        windowFrame: { session.frontmost == target ? escalationFrame : displacedFrame }
    )

    let result = try executor.click(
        point: ActionPoint(
            x: escalationPoint.x,
            y: escalationPoint.y,
            coordinateSpace: .screen,
            app: String(target),
            sourceWindowFrame: escalationFrame
        ),
        policy: .foregroundPermitted
    )

    #expect(result.delivery == .foreground)
    #expect(result.dispatchSuccess)
    #expect(session.globalPosts > 0)
    // The refused targeted rung posted nothing, and activation was the first thing that happened.
    #expect(session.targetedPosts.isEmpty)
    #expect(session.log.first == "activate:\(target)")
    // Every global event landed while the target held the foreground — the whole point of raising
    // it, and exactly what the field envelope claimed without ever doing it.
    #expect(session.frontmostDuringDispatch.allSatisfy { $0 == target })

    let cleanup = result.details["foreground"]
    #expect(cleanup?["priorApp"] == .string("com.example.p\(priorProcess)"))
    #expect(cleanup?["priorAppProcessIdentifier"] == .int(Int(priorProcess)))
    // A foreign prior application and a resolved target can only mean this.
    #expect(cleanup?["alreadyFrontmost"] == .bool(false))
    #expect(cleanup?["activationProved"] == .bool(true))
    #expect(cleanup?["restored"] == .bool(true))
    #expect(session.frontmost == priorProcess)
}

@Test func anAppScopedPointRefusesWithoutPostingWhenItsApplicationWillNotComeForward() throws {
    let session = FakeSession()
    let target = try resolvableProcess()
    session.refusesActivation = [target]
    let executor = session.pointExecutor(
        targetProcess: target,
        windowFrame: { session.frontmost == target ? escalationFrame : displacedFrame }
    )

    let result = try executor.click(
        point: ActionPoint(
            x: escalationPoint.x,
            y: escalationPoint.y,
            coordinateSpace: .screen,
            app: String(target),
            sourceWindowFrame: escalationFrame
        ),
        policy: .foregroundPermitted
    )

    #expect(result.refusal?.reason == .activationNotProved)
    #expect(result.dispatchSuccess == false)
    #expect(session.globalPosts == 0)
    #expect(session.targetedPosts.isEmpty)
    #expect(result.details["foreground"]?["activationProved"] == .bool(false))
    #expect(result.details["foreground"]?["alreadyFrontmost"] == .bool(false))
    #expect(session.frontmost == priorProcess)
}

@Test func aPointNamingAnApplicationThatDoesNotResolveRefusesBeforeAnyDispatch() throws {
    // A named application that cannot be found used to come back as "no application", which is the
    // same answer a deliberately anonymous coordinate gives — and that answer sends the click to
    // the global devices. A target the caller did name must fail as a target, not become one.
    let session = FakeSession()
    let executor = session.pointExecutor(targetProcess: targetProcess)

    #expect(throws: AppResolverError.self) {
        try executor.click(
            point: ActionPoint(
                x: escalationPoint.x,
                y: escalationPoint.y,
                coordinateSpace: .screen,
                app: "com.example.not-running-\(UUID().uuidString)"
            ),
            policy: .foregroundPermitted
        )
    }

    #expect(session.globalPosts == 0)
    #expect(session.targetedPosts.isEmpty)
    #expect(!session.log.contains { $0.hasPrefix("activate") })
}

@Test func anUnaimedKeystrokeIsAimedAtTheForegroundAndSaysSo() throws {
    // The one case where "already frontmost" is honest without a resolved process: a keystroke that
    // names no application is addressed to whoever holds the foreground, so the foreground is the
    // target by definition. This is what separates it from a coordinate with no owner.
    let session = FakeSession()
    let (store, element) = escalationStore()
    let executor = session.typeExecutor(store: store, element: element, process: nil)

    let result = try executor.keyboard(app: nil, intent: .key("End"), policy: .foregroundPermitted)

    #expect(result.delivery == .foreground)
    #expect(result.dispatchSuccess)
    #expect(result.details["foreground"]?["alreadyFrontmost"] == .bool(true))
    #expect(result.details["foreground"]?["activationProved"] == .null)
    #expect(!session.log.contains { $0.hasPrefix("activate") })
    #expect(session.frontmost == priorProcess)
}
