import ApplicationServices
import AppKit
import Foundation

/// Identity of whatever holds the foreground, captured so an escalation can hand it back.
public struct ForegroundApp: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let name: String?
    public let bundleIdentifier: String?

    public init(processIdentifier: pid_t, name: String?, bundleIdentifier: String?) {
        self.processIdentifier = processIdentifier
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }

    /// What the result reports as the prior app: the bundle identifier when there is one, because
    /// it is stable across localizations and renames.
    public var identity: String {
        bundleIdentifier ?? name ?? "pid:\(processIdentifier)"
    }
}

public final class AXPrimitiveActionExecutor {
    private let elementStore: AXElementStore
    private let appResolver: AppResolver
    private let overlay: VisualOverlay?
    private let overlayConfiguration: VisualOverlayConfiguration
    /// Global input, shared with the human at the keyboard. Only the foreground rung uses it.
    private let postEvent: (CGEvent) -> Void
    /// Process-targeted delivery. Does not activate the application and does not move the cursor,
    /// which is what makes the pixel rung a background mechanism.
    private let postEventToProcess: (CGEvent, pid_t) -> Void
    private let sleepMilliseconds: (Int) -> Void
    /// Re-read per text action so a mid-session input source switch is picked up.
    private let makeKeyboardLayout: () -> KeyboardLayoutMap
    private let hitTest: (CGPoint) -> AXUIElement?
    private let frameProvider: (AXUIElement) -> AXFrame?
    private let parentProvider: (AXUIElement) -> AXUIElement?
    private let processProvider: (AXUIElement) -> pid_t?
    private let attributeProvider: (AXUIElement, String) -> AnyObject?
    private let actionNamesProvider: (AXUIElement) -> [String]?
    /// The accessibility dispatch itself. Seamed so that what an action reported — and therefore
    /// whether the ladder settles or advances — is observable without a live application.
    private let performAction: (AXUIElement, String) -> AXError
    private let elementsEqual: (AXUIElement, AXUIElement) -> Bool
    private let frontmostApp: () -> ForegroundApp?
    private let activateProcess: (pid_t) -> Bool
    private let pointerLocation: () -> CGPoint
    private let movePointer: (CGPoint) -> Void
    private let settleTimeoutMs: Int
    private let settleIntervalMs: Int

    public init(
        elementStore: AXElementStore,
        appResolver: AppResolver = AppResolver(),
        overlay: VisualOverlay? = VisualOverlayFactory.makeFromEnvironment(),
        overlayConfiguration: VisualOverlayConfiguration = .fromEnvironment(),
        postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        postEventToProcess: @escaping (CGEvent, pid_t) -> Void = { event, pid in event.postToPid(pid) },
        sleepMilliseconds: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000) },
        makeKeyboardLayout: @escaping () -> KeyboardLayoutMap = { KeyboardLayoutMap.current() },
        hitTest: ((CGPoint) -> AXUIElement?)? = nil,
        frameProvider: ((AXUIElement) -> AXFrame?)? = nil,
        parentProvider: ((AXUIElement) -> AXUIElement?)? = nil,
        processProvider: ((AXUIElement) -> pid_t?)? = nil,
        attributeProvider: ((AXUIElement, String) -> AnyObject?)? = nil,
        actionNamesProvider: ((AXUIElement) -> [String]?)? = nil,
        performAction: ((AXUIElement, String) -> AXError)? = nil,
        elementsEqual: @escaping (AXUIElement, AXUIElement) -> Bool = { CFEqual($0, $1) },
        frontmostApp: (() -> ForegroundApp?)? = nil,
        activateProcess: ((pid_t) -> Bool)? = nil,
        pointerLocation: @escaping () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero },
        movePointer: @escaping (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) },
        settleTimeoutMs: Int = 750,
        settleIntervalMs: Int = 25
    ) {
        self.elementStore = elementStore
        self.appResolver = appResolver
        self.overlay = overlay
        self.overlayConfiguration = overlayConfiguration
        self.postEvent = postEvent
        self.postEventToProcess = postEventToProcess
        self.sleepMilliseconds = sleepMilliseconds
        self.makeKeyboardLayout = makeKeyboardLayout
        self.hitTest = hitTest ?? Self.systemHitTest
        self.frameProvider = frameProvider ?? Self.copyFrame
        self.parentProvider = parentProvider ?? Self.copyParent
        self.processProvider = processProvider ?? Self.copyProcessIdentifier
        self.attributeProvider = attributeProvider ?? Self.copyRawAttributeValue
        self.actionNamesProvider = actionNamesProvider ?? Self.copyActionNames
        self.performAction = performAction ?? { element, name in AXUIElementPerformAction(element, name as CFString) }
        self.elementsEqual = elementsEqual
        self.frontmostApp = frontmostApp ?? Self.systemFrontmostApp
        self.activateProcess = activateProcess ?? Self.systemActivate
        self.pointerLocation = pointerLocation
        self.movePointer = movePointer
        self.settleTimeoutMs = settleTimeoutMs
        self.settleIntervalMs = max(settleIntervalMs, 1)
    }

    /// The action name of the accessibility scroll rung. `kAXScrollToVisibleAction` is not bridged
    /// into Swift, so the literal exists here once rather than at both the selection and the
    /// perform site, where the two could drift apart silently.
    private static let scrollToVisibleAction = "AXScrollToVisible"

    private static func copyProcessIdentifier(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else {
            return nil
        }
        return pid
    }

    private static func systemFrontmostApp() -> ForegroundApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return ForegroundApp(
            processIdentifier: app.processIdentifier,
            name: app.localizedName,
            bundleIdentifier: app.bundleIdentifier
        )
    }

    private static func systemActivate(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        return app.activate()
    }

    private static func copyParent(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success else {
            return nil
        }
        return (value as! AXUIElement?)
    }

    public func handlers() -> PrimitiveActionHandlers {
        PrimitiveActionHandlers(
            click: click(target:policy:),
            clickPoint: click(point:policy:),
            invoke: invoke(target:name:policy:),
            type: type(target:value:policy:),
            keyboard: keyboard(app:intent:policy:),
            scroll: scroll(target:app:deltaX:deltaY:policy:),
            drag: drag(from:to:app:durationMs:policy:)
        )
    }

    public func click(target: String, policy: DeliveryPolicy) throws -> PrimitiveActionResult {
        let element = try elementStore.element(for: target)
        // A native press is the semantic rung: it neither focuses nor activates, and it is the only
        // click path that can prove its own outcome.
        if actionNames(for: element).contains(kAXPressAction) {
            return try invoke(target: target, name: kAXPressAction, policy: policy)
        }

        showTargetBeforeAction(element, label: "CGClick")
        let point = centerPoint(of: element)
        let process = processProvider(element)
        return deliver(
            action: "click",
            target: target,
            policy: policy,
            candidates: inputCandidates(
                processIdentifier: process,
                hasGeometry: point != nil,
                geometryMessage: "Element has no usable frame for pointer delivery",
                identityMessage: "Element does not belong to a resolvable process, so input cannot be bound to it",
                strategy: "CGEvent"
            )
        ) { candidate in
            guard let point else {
                return .settled(PrimitiveActionResult(
                    action: "click", target: target, strategy: candidate.strategy, success: false,
                    message: "Element has no usable frame for pointer delivery",
                    deliveryPolicy: policy
                ))
            }
            return Self.outcome(of: self.postClick(
                action: "click",
                target: target,
                policy: policy,
                candidate: candidate,
                point: point,
                element: element,
                process: process,
                details: [:]
            ))
        }
    }

    /// A rung that demonstrably did not take may advance; one that delivered must not, because a
    /// second dispatch would repeat an action the target may already have performed.
    private static func outcome(of result: PrimitiveActionResult) -> DeliveryAttempt {
        result.dispatchSuccess ? .settled(result) : .advance(result)
    }

    public func click(point: ActionPoint, policy: DeliveryPolicy) throws -> PrimitiveActionResult {
        let cgPoint = CGPoint(x: point.x, y: point.y)
        // A screen point only carries target identity when the caller named the application it came
        // from. Inferring a window from a bare coordinate is exactly the guess background delivery
        // must never make, so such a point can only travel on global input.
        let process = point.app.flatMap { processIdentifier(forApp: $0) }
        return deliver(
            action: "click",
            target: point.targetDescription,
            policy: policy,
            candidates: inputCandidates(
                processIdentifier: process,
                hasGeometry: true,
                geometryMessage: "",
                identityMessage: "A raw screen point carries no application or window identity; background delivery needs a handle, locator, text location, or an app-scoped point",
                strategy: "CGEvent"
            ),
            details: ["point": point.jsonValue]
        ) { candidate in
            Self.outcome(of: self.postClick(
                action: "click",
                target: point.targetDescription,
                policy: policy,
                candidate: candidate,
                point: cgPoint,
                element: nil,
                process: process,
                sourceWindowFrame: point.sourceWindowFrame,
                details: ["point": point.jsonValue]
            ))
        }
    }

    public func invoke(target: String, name: String, policy: DeliveryPolicy) throws -> PrimitiveActionResult {
        let element = try elementStore.element(for: target)
        showTargetBeforeAction(element, label: name)
        // Invoke has exactly one rung. A named accessibility action that the element refuses is a
        // failed action, never a reason to send unrelated global input at its coordinates.
        let result = performAction(element, name)
        return PrimitiveActionResult.dispatched(
            action: name,
            target: target,
            strategy: "AXAction",
            policy: policy,
            delivery: .semantic,
            success: result == .success,
            message: result == .success ? nil : "AXUIElementPerformAction returned \(result.axonDescription)"
        )
    }

    public func type(target: String, value: String, policy: DeliveryPolicy) throws -> PrimitiveActionResult {
        let element = try elementStore.element(for: target)
        showTargetBeforeAction(element, label: "AXValue")
        // The semantic rung: set the value and read it back. AXUIElementSetAttributeValue does not
        // need focus, so nothing here touches the foreground.
        let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        if Self.axValueWasVerified(
            setResult: setResult,
            readValue: stringValue(copyRawAttribute(kAXValueAttribute, from: element)),
            expected: value
        ) {
            return PrimitiveActionResult.dispatched(
                action: "type",
                target: target,
                strategy: "AXValue",
                policy: policy,
                delivery: .semantic,
                success: true
            )
        }
        let semanticFailure = setResult == .success
            ? "AXUIElementSetAttributeValue did not update the element value"
            : "AXUIElementSetAttributeValue returned \(setResult.axonDescription)"

        let point = centerPoint(of: element)
        let process = processProvider(element)
        var candidates = inputCandidates(
            processIdentifier: process,
            hasGeometry: point != nil,
            geometryMessage: "Element has no usable frame, so text cannot be delivered by pointer and keystroke",
            identityMessage: "Element does not belong to a resolvable process, so keystrokes cannot be bound to it",
            strategy: "CGEventKeyboard"
        )
        candidates.insert(
            DeliveryCandidate(rung: .semantic, capability: .semanticValue, strategy: "AXValue"),
            at: 0
        )
        return deliver(
            action: "type",
            target: target,
            policy: policy,
            candidates: candidates,
            // The semantic rung already ran above; the ladder starts from what comes after it.
            after: .semantic,
            fallback: PrimitiveActionResult(
                action: "type", target: target, strategy: "AXValue", success: false,
                message: semanticFailure, deliveryPolicy: policy, delivery: .semantic
            )
        ) { candidate in
            guard let point else {
                return .settled(PrimitiveActionResult(
                    action: "type", target: target, strategy: "AXValue", success: false,
                    message: semanticFailure, deliveryPolicy: policy, delivery: .semantic
                ))
            }
            // Typing is the one action that can prove its own outcome at every rung, so a rung
            // whose readback still shows the wrong value has genuinely not taken and may advance.
            let result = self.postTypedText(
                target: target,
                policy: policy,
                candidate: candidate,
                element: element,
                point: point,
                process: process,
                value: value
            )
            return result.success ? .settled(result) : .advance(result)
        }
    }

    public func keyboard(app: String?, intent: KeyboardIntent, policy: DeliveryPolicy) throws -> PrimitiveActionResult {
        let target = app ?? "frontmost"
        let process = app.flatMap { processIdentifier(forApp: $0) }
        var intentDetails: [String: JSONValue]
        switch intent {
        case let .key(key):
            _ = try KeyStroke(validating: key)
            intentDetails = ["key": .string(key), "mode": .string("key")]
        case let .text(text):
            intentDetails = ["text": .string(text), "mode": .string("text")]
        }
        // Keyboard input has no semantic rung: there is no element to mutate, only input to deliver.
        return deliver(
            action: "keyboard",
            target: target,
            policy: policy,
            candidates: inputCandidates(
                processIdentifier: process,
                hasGeometry: true,
                geometryMessage: "",
                identityMessage: app == nil
                    ? "keyboard without app has no target application, so input can only reach whatever holds the foreground"
                    : "app \(app ?? "") is not running, so keystrokes cannot be bound to it",
                strategy: "CGEventKeyboard"
            ),
            details: intentDetails
        ) { candidate in
            Self.outcome(of: self.postKeyboardIntent(
                target: target,
                policy: policy,
                candidate: candidate,
                process: process,
                intent: intent,
                details: intentDetails
            ))
        }
    }

    static func axValueWasVerified(setResult: AXError, readValue: String?, expected: String) -> Bool {
        setResult == .success && readValue == expected
    }

    /// Which strategy runs is decided by what the caller named, not by trying one and catching its
    /// failure. A point is a pointer-space instruction, so it takes the pointer-space mechanism and
    /// never consults the AX tree. An element or app names something semantic, where
    /// `AXScrollToVisible` is more precise and immune to window occlusion, so AX stays primary there
    /// and the wheel covers the case where AX has nothing to work with.
    ///
    /// The wheel is global input whatever it is aimed at, so it sits on the delivery ladder: it
    /// reaches a verified process in the background, and the shared devices only by opt-in.
    public func scroll(
        target: PointerTarget?,
        app: String?,
        deltaX: Double,
        deltaY: Double,
        policy: DeliveryPolicy
    ) throws -> PrimitiveActionResult {
        let description = target?.targetDescription ?? app ?? "frontmost"
        var details: [String: JSONValue] = [
            "deltaX": .double(deltaX),
            "deltaY": .double(deltaY)
        ]
        if let target {
            details["targetSpec"] = target.jsonValue
        }

        guard deltaX != 0 || deltaY != 0 else {
            details["semanticSuccess"] = .null
            details["semanticStatus"] = .string("noop")
            details["eventPath"] = Self.eventPathSummary(steps: [])
            return PrimitiveActionResult(
                action: "scroll",
                target: description,
                strategy: "CGEventScroll",
                success: true,
                message: "No scroll delta was requested; no events were posted",
                deliveryPolicy: policy,
                delivery: nil,
                dispatchSuccess: false,
                details: details
            )
        }

        if case let .point(point) = target {
            return scrollWheelResult(
                target: description,
                at: CGPoint(x: point.x, y: point.y),
                process: point.app.flatMap { processIdentifier(forApp: $0) },
                policy: policy,
                identityMessage: "A raw screen point carries no application identity, so a wheel burst cannot be bound to a process",
                deltaX: deltaX,
                deltaY: deltaY,
                details: details
            )
        }

        // Only a bare app target needs the app resolved; a handle carries its own element, and
        // resolving anyway would reject a live handle because some unrelated app name went stale.
        let resolvedApp = target == nil ? try app.map(appResolver.resolve) : nil
        // Carried down to the wheel only when the accessibility rung was attempted and turned out
        // not to be a mechanism at all, so that a caller with no wheel rung left still hears what
        // accessibility actually said.
        var semanticFallback: PrimitiveActionResult?
        if let scrollTarget = try scrollToVisibleTarget(target: target, app: resolvedApp, deltaX: deltaX, deltaY: deltaY) {
            // The semantic rung. AXScrollToVisible neither focuses nor activates, so it is always
            // allowed, and an app that refuses it has failed the scroll rather than earned an
            // unrelated wheel burst at the same coordinates.
            let error = performAction(scrollTarget.element, Self.scrollToVisibleAction)
            var semanticDetails = details
            semanticDetails["scrollTargetFrame"] = scrollTarget.frame.jsonValue
            // The app acknowledging the action is the dispatch; it is still not proof that the
            // viewport moved, and it is not a dispatch at all when the action itself errors.
            semanticDetails["semanticSuccess"] = .null
            semanticDetails["semanticStatus"] = .string("unverified")
            let semantic = PrimitiveActionResult.dispatched(
                action: "scroll",
                target: description,
                strategy: "AXScrollToVisible",
                policy: policy,
                delivery: .semantic,
                success: error == .success,
                message: error == .success ? nil : "AXScrollToVisible returned \(error.axonDescription)",
                details: semanticDetails
            )
            guard Self.semanticScrollAdvances(after: error) else {
                return semantic
            }
            semanticFallback = semantic
        }

        guard let point = try wheelPoint(target: target, app: resolvedApp) else {
            // An accessibility attempt that found no mechanism is the honest answer here. The wheel
            // having nowhere to aim is true but is not what went wrong.
            return semanticFallback ?? PrimitiveActionResult(
                action: "scroll",
                target: description,
                strategy: "CGEventScroll",
                success: false,
                message: "scroll target has no resolvable screen point",
                deliveryPolicy: policy,
                dispatchSuccess: false,
                details: details
            )
        }
        return scrollWheelResult(
            target: description,
            at: point,
            process: try scrollProcess(target: target, app: resolvedApp),
            policy: policy,
            identityMessage: "The scroll target does not belong to a resolvable process, so a wheel burst cannot be bound to it",
            deltaX: deltaX,
            deltaY: deltaY,
            details: details,
            semanticFallback: semanticFallback
        )
    }

    /// Whether an accessibility scroll that failed leaves the wheel rung below it still owed a try.
    ///
    /// An unsupported action was never refused, because the app was never asked to decide: the
    /// element advertised a mechanism it does not implement, and the tree is contradicting itself.
    /// Every other error is the app answering, and a scroll it answered badly is a failed scroll
    /// rather than a reason to send global input at the same coordinates.
    private static func semanticScrollAdvances(after error: AXError) -> Bool {
        error == .actionUnsupported || error == .attributeUnsupported
    }

    /// `scroll` never activates for the background rung, and the foreground rung activates only
    /// because the shared devices demand it. A posted wheel is routed by the event's location to
    /// the window under that point regardless of which application is frontmost, so raising the app
    /// buys nothing; a point covered by another window scrolls whatever is on top of it, and a
    /// caller who needs to know can compare window frames from `look`.
    private func scrollWheelResult(
        target: String,
        at point: CGPoint,
        process: pid_t?,
        policy: DeliveryPolicy,
        identityMessage: String,
        deltaX: Double,
        deltaY: Double,
        details: [String: JSONValue],
        semanticFallback: PrimitiveActionResult? = nil
    ) -> PrimitiveActionResult {
        var wheelDetails = details
        wheelDetails["at"] = ActionPoint(x: point.x, y: point.y, coordinateSpace: .screen).jsonValue
        return deliver(
            action: "scroll",
            target: target,
            policy: policy,
            candidates: inputCandidates(
                processIdentifier: process,
                hasGeometry: true,
                geometryMessage: "",
                identityMessage: identityMessage,
                strategy: "CGEventScroll"
            ),
            fallback: semanticFallback,
            details: wheelDetails
        ) { candidate in
            var dispatch: ScrollDispatch?
            let post: ((CGEvent) -> Void) -> Bool = { sink in
                let outcome = self.postScrollWheel(at: point, deltaX: deltaX, deltaY: deltaY, sink: sink)
                dispatch = outcome
                return !outcome.steps.isEmpty
            }
            let message = "Scroll wheel events were dispatched, but semantic outcome is unverified without a postcondition"
            let base: PrimitiveActionResult
            if candidate.rung == .pixel, let process {
                base = self.backgroundDispatch(
                    action: "scroll", target: target, policy: policy, strategy: candidate.strategy,
                    process: process, movesPointer: false, details: wheelDetails, message: message,
                    post: post
                )
            } else {
                // Deliberately no process to activate: a wheel routes by the event's location, so
                // raising the app would cost the user their focus and buy the scroll nothing. A
                // wheel carries no cursor position either, which is why neither rung has a pointer
                // to restore or to be held to.
                base = self.inForeground(
                    action: "scroll", target: target, policy: policy, process: nil,
                    restoresPointer: false, details: wheelDetails
                ) {
                    let dispatched = post(self.postEvent)
                    return .unverifiedDispatch(
                        action: "scroll", target: target, strategy: candidate.strategy, policy: policy,
                        delivery: .foreground, dispatched: dispatched, message: message,
                        details: wheelDetails
                    )
                }
            }
            let steps = dispatch?.steps ?? []
            guard !steps.isEmpty else {
                // A wheel burst that rounds away to nothing is not a dispatch, so it must not
                // claim one — nor an unverified semantic outcome it never attempted.
                var emptyDetails = base.details.filter { key, _ in
                    key != "semanticSuccess" && key != "semanticStatus"
                }
                emptyDetails["eventPath"] = Self.eventPathSummary(steps: [])
                return .settled(PrimitiveActionResult(
                    action: "scroll",
                    target: target,
                    strategy: candidate.strategy,
                    success: false,
                    message: dispatch?.creationFailed == true
                        ? "Unable to create scroll wheel events"
                        : "scroll delta rounds to no pixel of wheel movement",
                    deliveryPolicy: policy,
                    delivery: nil,
                    dispatchSuccess: false,
                    details: emptyDetails
                ))
            }
            return .settled(base.withSuccess(
                base.success,
                details: ["eventPath": Self.eventPathSummary(steps: steps)]
            ))
        }
    }

    private static func eventPathSummary(steps: [ScrollEventStep]) -> JSONValue {
        .object([
            "eventCount": .int(steps.count),
            "units": .string("pixel"),
            "totalDeltaX": .double(steps.reduce(0) { $0 + $1.deltaX }),
            "totalDeltaY": .double(steps.reduce(0) { $0 + $1.deltaY })
        ])
    }

    /// The screen point a wheel burst is posted at when the AX tree offers no scrollable descendant.
    private func wheelPoint(target: PointerTarget?, app: NSRunningApplication?) throws -> CGPoint? {
        switch target {
        case let .point(point):
            return CGPoint(x: point.x, y: point.y)
        case let .handle(handle):
            return centerPoint(of: try elementStore.element(for: handle))
        case nil:
            guard let app, let window = firstWindow(for: app) else {
                return nil
            }
            return centerPoint(of: window)
        }
    }

    /// The process a wheel burst binds to for background delivery.
    private func scrollProcess(target: PointerTarget?, app: NSRunningApplication?) throws -> pid_t? {
        switch target {
        case let .handle(handle):
            return processProvider(try elementStore.element(for: handle))
        case let .point(point):
            return point.app.flatMap { processIdentifier(forApp: $0) }
        case nil:
            return app?.processIdentifier
        }
    }

    public func drag(
        from: PointerTarget,
        to: PointerTarget,
        app: String?,
        durationMs: Int?,
        policy: DeliveryPolicy
    ) throws -> PrimitiveActionResult {
        let start = try resolvedPointerTarget(from)
        let end = try resolvedPointerTarget(to)
        let target = "\(from.targetDescription)->\(to.targetDescription)"
        // A drag has to stay inside one application for its whole path, so the identity that binds
        // background delivery is the app the caller named, or the process owning the start element.
        let process = app.flatMap { processIdentifier(forApp: $0) }
            ?? start.element.flatMap(processProvider)
            ?? end.element.flatMap(processProvider)
        let details: [String: JSONValue] = [
            "from": ActionPoint(x: start.point.x, y: start.point.y, coordinateSpace: .screen).jsonValue,
            "to": ActionPoint(x: end.point.x, y: end.point.y, coordinateSpace: .screen).jsonValue,
            "durationMs": durationMs.map(JSONValue.int) ?? .null
        ]
        return deliver(
            action: "drag",
            target: target,
            policy: policy,
            candidates: inputCandidates(
                processIdentifier: process,
                hasGeometry: true,
                geometryMessage: "",
                identityMessage: "Neither drag endpoint carries an application identity; background delivery needs an app, a handle, or a locator",
                strategy: "CGEventDrag"
            ),
            details: details
        ) { candidate in
            // Endpoint validation happens inside the rung, where `postMouseDrag` re-checks the
            // start before its first event and the destination before its last.
            let result = self.postDrag(
                target: target,
                policy: policy,
                candidate: candidate,
                process: process,
                start: start,
                end: end,
                durationMs: durationMs,
                details: details
            )
            // A drag cancelled mid-path already released the button safely; repeating it at a
            // louder rung would replay a gesture against a target that just moved.
            return result.details["cancelledSafely"] == .bool(true)
                ? .settled(result)
                : Self.outcome(of: result)
        }
    }

    // MARK: - Delivery

    private enum DeliveryAttempt {
        /// A conclusive outcome. Nothing further is tried.
        case settled(PrimitiveActionResult)
        /// This rung did not take. The ladder advances if the policy and runtime allow it.
        case advance(PrimitiveActionResult)
    }

    /// Whose foreground one dispatch is accountable for.
    ///
    /// These three are not interchangeable, and collapsing them into "a process or nothing" is what
    /// let a click report `alreadyFrontmost: true` in the same envelope that named a foreign
    /// application as the prior one — and then skip the activation that reading implied had already
    /// happened.
    private enum ForegroundTarget {
        /// A resolved process. Whether it holds the foreground is a comparison this dispatch can
        /// make, and raising it is a claim it must prove before anything is posted.
        case process(pid_t)
        /// The action addresses whoever holds the foreground rather than a named application, as an
        /// unaimed keystroke does. The foreground is the target by definition, so there is nothing
        /// to raise and nothing to prove.
        case currentForeground
        /// No application-level claim is available: either nothing named an application, or the
        /// mechanism routes by the event's location rather than by application, as a wheel burst
        /// does. Answering `alreadyFrontmost` here would answer a question nobody asked.
        case unattributed

        /// A target identified by a process when one was resolved, and explicitly unattributed when
        /// it was not. Never the current foreground by default: that is a claim only an action
        /// aimed at the foreground itself gets to make.
        init(resolved process: pid_t?) {
            self = process.map(ForegroundTarget.process) ?? .unattributed
        }

        /// The process background delivery binds to, which exists only for a resolved target.
        var process: pid_t? {
            guard case let .process(process) = self else {
                return nil
            }
            return process
        }
    }

    /// Walks an action's ladder, dispatching at the first rung the policy and runtime allow.
    ///
    /// The selection always happens before `attempt` runs, so a policy or capability denial returns
    /// a refusal without the action ever reaching a native API.
    private func deliver(
        action: String,
        target: String,
        policy: DeliveryPolicy,
        candidates: [DeliveryCandidate],
        after: DeliveryRung? = nil,
        fallback: PrimitiveActionResult? = nil,
        details: [String: JSONValue] = [:],
        attempt: (DeliveryCandidate) throws -> DeliveryAttempt
    ) rethrows -> PrimitiveActionResult {
        var lastFailure = fallback
        var selection = DeliveryPlanner.select(from: candidates, policy: policy, after: after)
        while true {
            switch selection {
            case let .refusal(refusal):
                guard let lastFailure else {
                    return .refused(action: action, target: target, policy: policy, refusal: refusal, details: details)
                }
                // Running out of rungs is not a refusal: nothing declined the action, it simply has
                // no mechanism left. The honest answer is what the last attempt actually reported.
                guard refusal.reason != .noDeliveryCandidate else {
                    return lastFailure
                }
                return lastFailure.refusing(refusal)
            case let .candidate(candidate):
                switch try attempt(candidate) {
                case let .settled(result):
                    return result
                case let .advance(result):
                    lastFailure = result
                    selection = DeliveryPlanner.select(from: candidates, policy: policy, after: candidate.rung)
                }
            }
        }
    }

    /// The pixel and foreground rungs shared by every action that delivers input.
    ///
    /// Background delivery needs a process to bind to; without one there is nowhere to send input
    /// except the global devices, and saying so is the whole point of the refusal.
    private func inputCandidates(
        processIdentifier process: pid_t?,
        hasGeometry: Bool,
        geometryMessage: String,
        identityMessage: String,
        strategy: String
    ) -> [DeliveryCandidate] {
        let geometryGap: (DeliveryRefusalReason, String)? = hasGeometry
            ? nil
            : (.targetIdentityUnavailable, geometryMessage)
        let pixelGap = geometryGap ?? (process == nil ? (.backgroundPixelUnsupported, identityMessage) : nil)
        return [
            DeliveryCandidate(
                rung: .pixel,
                capability: .backgroundPixelInput,
                strategy: "\(strategy)ToPid",
                unavailable: pixelGap?.0,
                unavailableMessage: pixelGap?.1
            ),
            DeliveryCandidate(
                rung: .foreground,
                capability: .globalInput,
                strategy: strategy,
                unavailable: geometryGap?.0,
                unavailableMessage: geometryGap?.1
            )
        ]
    }

    /// The process behind an application a caller named.
    ///
    /// Throwing is the point. Swallowing the resolver's failure returned `nil`, which is the same
    /// answer a deliberately anonymous coordinate gives, so a target the caller *did* name became a
    /// target with no identity — and delivery reads that as licence to post global input at
    /// whatever holds the foreground. A named application that cannot be found is a resolution
    /// failure, reported before any event is created.
    private func processIdentifier(forApp query: String) throws -> pid_t {
        try appResolver.resolve(query).processIdentifier
    }

    /// Where a rung's events go. The pixel rung addresses the target process directly; the
    /// foreground rung uses the same global devices the person at the keyboard uses.
    private func sink(for rung: DeliveryRung, process: pid_t?) -> (CGEvent) -> Void {
        guard rung == .pixel, let process else {
            return postEvent
        }
        return { [postEventToProcess] event in postEventToProcess(event, process) }
    }

    private struct SessionInvariants {
        let frontmost: pid_t?
        let pointer: CGPoint
    }

    private func captureInvariants() -> SessionInvariants {
        SessionInvariants(frontmost: frontmostApp()?.processIdentifier, pointer: pointerLocation())
    }

    /// What the pixel rung promised not to do, measured across one dispatch so the reported rung is
    /// a claim Axon has verified rather than one it assumed.
    ///
    /// A clause belongs here only when this dispatch could have caused it to fail. Someone using
    /// the machine while Axon delivers is the normal condition on a personal desktop rather than an
    /// anomaly, and a hand on the physical mouse moves the pointer for reasons that have nothing to
    /// do with the synthesis. A dispatch that posts no pointer events cannot have moved it, so
    /// every motion observed around such a dispatch is exogenous by construction, and asserting the
    /// pointer there reports a broken contract on evidence the delivery cannot have produced. The
    /// motion is still reported — an application that warps the cursor in response to delivered
    /// input shows up in `pointerUnchanged` — but it does not gate success, because nothing on this
    /// side can tell that application apart from the person at the machine.
    ///
    /// The frontmost clause has no such exemption: delivered input can genuinely provoke an
    /// application into activating itself, so every rung stays accountable for it.
    private static func invariantViolation(
        from before: SessionInvariants,
        to after: SessionInvariants,
        assertsPointer: Bool
    ) -> String? {
        if after.frontmost != before.frontmost {
            return "the frontmost application changed across the dispatch"
        }
        if assertsPointer, !pointsMatch(after.pointer, before.pointer) {
            return "the real pointer moved across the dispatch"
        }
        return nil
    }

    private static func pointsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.5 && abs(lhs.y - rhs.y) < 0.5
    }

    /// The window the input is bound to, and the window-relative coordinates it was converted
    /// through. This is the evidence that a pixel dispatch addressed a verified target.
    private func targetWindowEvidence(for element: AXUIElement, point: CGPoint) -> [String: JSONValue] {
        var current: AXUIElement? = element
        for _ in 0..<64 {
            guard let candidate = current else { break }
            let role: String? = copyAttribute(kAXRoleAttribute, from: candidate)
            if role == kAXWindowRole, let frame = frame(of: candidate) {
                let title: String? = copyAttribute(kAXTitleAttribute, from: candidate)
                return ["targetWindow": .object([
                    "title": title.map(JSONValue.string) ?? .null,
                    "frame": frame.jsonValue,
                    "windowPoint": .object([
                        "x": .double(point.x - frame.x),
                        "y": .double(point.y - frame.y)
                    ]),
                    "sourceCoordinateSpace": .string(ActionPointCoordinateSpace.screen.rawValue)
                ])]
            }
            current = parentProvider(candidate)
        }
        return [:]
    }

    private func postClick(
        action: String,
        target: String,
        policy: DeliveryPolicy,
        candidate: DeliveryCandidate,
        point: CGPoint,
        element: AXUIElement?,
        process: pid_t?,
        sourceWindowFrame: AXFrame? = nil,
        details: [String: JSONValue]
    ) -> PrimitiveActionResult {
        var evidence = details
        if let element {
            evidence.merge(targetWindowEvidence(for: element, point: point)) { _, new in new }
        }
        let message = "Click events were dispatched, but semantic outcome is unverified without a postcondition"
        // Validation runs inside the rung that is about to dispatch. Checking occlusion before the
        // foreground rung activates the app would test a window stack the dispatch is about to
        // change, and would refuse the very escalation that resolves it.
        func validationFailure(settling: Bool) -> PrimitiveActionResult? {
            guard let check = self.pointerValidationCheck(
                point: point,
                element: element,
                process: process,
                sourceWindowFrame: sourceWindowFrame,
                rung: candidate.rung
            ) else {
                return nil
            }
            let failure = settling ? self.settledValidationFailure(check) : check()
            guard let failure else { return nil }
            return PrimitiveActionResult(
                action: action, target: target, strategy: candidate.strategy, success: false,
                message: failure, deliveryPolicy: policy, dispatchSuccess: false, details: evidence
            )
        }
        if candidate.rung == .pixel, let process {
            if let failure = validationFailure(settling: false) {
                return failure
            }
            return backgroundDispatch(
                action: action, target: target, policy: policy, strategy: candidate.strategy,
                process: process, movesPointer: true, details: evidence, message: message
            ) { sink in
                self.postMouseClick(at: point, sink: sink)
            }
        }
        return inForeground(
            action: action, target: target, policy: policy, process: process,
            restoresPointer: true, details: evidence
        ) {
            if let failure = validationFailure(settling: true) {
                return failure
            }
            let dispatched = self.postMouseClick(at: point, sink: self.postEvent)
            return .unverifiedDispatch(
                action: action, target: target, strategy: candidate.strategy, policy: policy,
                delivery: .foreground, dispatched: dispatched,
                message: dispatched ? message : "Unable to create pointer events",
                details: evidence
            )
        }
    }

    private func postTypedText(
        target: String,
        policy: DeliveryPolicy,
        candidate: DeliveryCandidate,
        element: AXUIElement,
        point: CGPoint,
        process: pid_t?,
        value: String
    ) -> PrimitiveActionResult {
        var evidence = targetWindowEvidence(for: element, point: point)
        evidence["semanticFallback"] = .string("AXValue did not take; the field was refilled by pointer and keystroke")
        let message = "Keyboard events were dispatched, but the field value could not be verified"
        func validationFailure(settling: Bool) -> PrimitiveActionResult? {
            let check = { self.pointerValidationFailure(element: element, point: point) }
            let failure = settling ? self.settledValidationFailure(check) : check()
            guard let failure else { return nil }
            return PrimitiveActionResult(
                action: "type", target: target, strategy: candidate.strategy, success: false,
                message: failure, deliveryPolicy: policy, dispatchSuccess: false, details: evidence
            )
        }
        let post: ((CGEvent) -> Void) -> Bool = { sink in
            guard self.postMouseClick(at: point, sink: sink) else { return false }
            self.sleepMilliseconds(50)
            guard let selectAll = KeyStroke("command+a"), self.postKeyStroke(selectAll, sink: sink) else {
                return false
            }
            self.sleepMilliseconds(20)
            return self.postKeyboardText(value, sink: sink)
        }
        let base: PrimitiveActionResult
        if candidate.rung == .pixel, let process {
            if let failure = validationFailure(settling: false) {
                return failure
            }
            // The fallback clicks the field before it types into it, so this dispatch does
            // synthesize pointer input and is held to leaving the real pointer alone.
            base = backgroundDispatch(
                action: "type", target: target, policy: policy, strategy: candidate.strategy,
                process: process, movesPointer: true, details: evidence, message: message, post: post
            )
        } else {
            base = inForeground(
                action: "type", target: target, policy: policy, process: process,
                restoresPointer: true, details: evidence
            ) {
                if let failure = validationFailure(settling: true) {
                    return failure
                }
                let dispatched = post(self.postEvent)
                return .unverifiedDispatch(
                    action: "type", target: target, strategy: candidate.strategy, policy: policy,
                    delivery: .foreground, dispatched: dispatched,
                    message: dispatched ? message : "Unable to create keyboard events for text fallback",
                    details: evidence
                )
            }
        }
        // Unlike a click, a filled field can be read back, so this rung can still prove its goal.
        guard base.dispatchSuccess,
              stringValue(copyRawAttribute(kAXValueAttribute, from: element)) == value
        else {
            return base
        }
        return .dispatched(
            action: "type", target: target, strategy: candidate.strategy, policy: policy,
            delivery: base.delivery ?? candidate.rung, success: true,
            details: base.details.filter { key, _ in key != "semanticSuccess" && key != "semanticStatus" }
        )
    }

    private func postKeyboardIntent(
        target: String,
        policy: DeliveryPolicy,
        candidate: DeliveryCandidate,
        process: pid_t?,
        intent: KeyboardIntent,
        details: [String: JSONValue]
    ) -> PrimitiveActionResult {
        let message = "Keyboard events were dispatched, but semantic outcome is unverified without a postcondition"
        let post: ((CGEvent) -> Void) -> Bool = { sink in
            switch intent {
            case let .key(key):
                guard let stroke = KeyStroke(key) else { return false }
                return self.postKeyStroke(stroke, sink: sink)
            case let .text(text):
                return self.postKeyboardText(text, sink: sink)
            }
        }
        if candidate.rung == .pixel, let process {
            // Keystrokes touch no pointing device, so the pointer is reported around this dispatch
            // rather than asserted across it: on a machine someone is using, the mouse moving
            // during the delivery window says nothing about what the delivery did.
            return backgroundDispatch(
                action: "keyboard", target: target, policy: policy, strategy: candidate.strategy,
                process: process, movesPointer: false, details: details, message: message, post: post
            )
        }
        return inForeground(
            action: "keyboard", target: target, policy: policy, process: process,
            restoresPointer: false, details: details
        ) {
            let dispatched = post(self.postEvent)
            return .unverifiedDispatch(
                action: "keyboard", target: target, strategy: candidate.strategy, policy: policy,
                delivery: .foreground, dispatched: dispatched,
                message: dispatched ? message : "Unable to create keyboard events",
                details: details
            )
        }
    }

    private func postDrag(
        target: String,
        policy: DeliveryPolicy,
        candidate: DeliveryCandidate,
        process: pid_t?,
        start: ResolvedPointerTarget,
        end: ResolvedPointerTarget,
        durationMs: Int?,
        details: [String: JSONValue]
    ) -> PrimitiveActionResult {
        var dispatch: DragDispatch?
        let post: ((CGEvent) -> Void) -> Bool = { sink in
            let outcome = self.postMouseDrag(from: start, to: end, durationMs: durationMs, sink: sink)
            dispatch = outcome
            return outcome.validationFailure == nil
        }
        let message = "Drag pointer events were dispatched, but semantic outcome is unverified without a postcondition"
        let base: PrimitiveActionResult
        if candidate.rung == .pixel, let process {
            base = backgroundDispatch(
                action: "drag", target: target, policy: policy, strategy: candidate.strategy,
                process: process, movesPointer: true, details: details, message: message, post: post
            )
        } else {
            base = inForeground(
                action: "drag", target: target, policy: policy, process: process,
                restoresPointer: true, details: details
            ) {
                let dispatched = post(self.postEvent)
                return .unverifiedDispatch(
                    action: "drag", target: target, strategy: candidate.strategy, policy: policy,
                    delivery: .foreground, dispatched: dispatched,
                    message: dispatched ? message : "Unable to create pointer events",
                    details: details
                )
            }
        }
        guard let dispatch else {
            return base
        }
        // Mid-path validation is a real failure of the drag, not a reason to try a louder rung:
        // the path was cancelled with a mouse-up so nothing is left held down.
        if let failure = dispatch.validationFailure {
            // `cancelledSafely` reports that a half-finished gesture was released. A path that
            // never pressed the button down had nothing to cancel.
            return base.withSuccess(
                false,
                message: failure,
                details: dispatch.steps.isEmpty ? [:] : ["cancelledSafely": .bool(true)]
            )
        }
        return base.withSuccess(base.success, details: ["eventPath": .object([
            "eventCount": .int(dispatch.steps.count),
            "updates": .int(dispatch.steps.filter { $0.type == .leftMouseDragged }.count),
            "hasThresholdMotion": .bool(dispatch.steps.count > 2)
        ])])
    }

    /// Delivers through the target process without activating it, then proves the promises this
    /// dispatch is accountable for.
    ///
    /// `movesPointer` says whether this dispatch synthesizes pointer input, which is the same fact
    /// the foreground rung uses to decide whether it has a pointer to put back. Only a dispatch
    /// that answers yes is held to leaving the real pointer where it found it.
    private func backgroundDispatch(
        action: String,
        target: String,
        policy: DeliveryPolicy,
        strategy: String,
        process: pid_t,
        movesPointer: Bool,
        details: [String: JSONValue],
        message: String,
        post: ((CGEvent) -> Void) -> Bool
    ) -> PrimitiveActionResult {
        let before = captureInvariants()
        let dispatched = post(sink(for: .pixel, process: process))
        // One reading answers both the contract check and the reported evidence, so a result can
        // never call an invariant intact in the same breath as the message saying it broke.
        let after = captureInvariants()
        let violation = Self.invariantViolation(from: before, to: after, assertsPointer: movesPointer)
        var evidence = details
        evidence["backgroundDelivery"] = .object([
            "targetProcessIdentifier": .int(Int(process)),
            "frontmostAppUnchanged": .bool(after.frontmost == before.frontmost),
            "pointerUnchanged": .bool(Self.pointsMatch(after.pointer, before.pointer)),
            // Whether that reading is a promise this dispatch made or an observation of the desktop
            // it ran on.
            "pointerAsserted": .bool(movesPointer)
        ])
        guard dispatched else {
            return PrimitiveActionResult(
                action: action, target: target, strategy: strategy, success: false,
                message: "Unable to create events for background delivery to process \(process)",
                deliveryPolicy: policy, delivery: .pixel, dispatchSuccess: false, details: evidence
            )
        }
        if let violation {
            return PrimitiveActionResult(
                action: action, target: target, strategy: strategy, success: false,
                // What is reported is what was observed. A dispatch that synthesizes pointer input
                // cannot tell its own leaked event from the hand on the mouse, so it claims the
                // change it saw rather than blaming itself for one it may not have caused — and
                // either way it has not proved it stayed in the background.
                message: "Background delivery could not prove it stayed in the background: \(violation)",
                deliveryPolicy: policy, delivery: .pixel, dispatchSuccess: true, details: evidence
            )
        }
        return .unverifiedDispatch(
            action: action, target: target, strategy: strategy, policy: policy,
            delivery: .pixel, dispatched: true, message: message, details: evidence
        )
    }

    /// Runs one action in the foreground and hands the session back.
    ///
    /// Activation is proved before anything is posted, and restoration runs on every exit including
    /// a thrown error, so an escalation cannot leave the user's foreground where Axon put it.
    private func inForeground(
        action: String,
        target: String,
        policy: DeliveryPolicy,
        process: pid_t?,
        restoresPointer: Bool,
        details: [String: JSONValue],
        _ body: () -> PrimitiveActionResult
    ) -> PrimitiveActionResult {
        let prior = frontmostApp()
        let alreadyFrontmost = process == nil || prior?.processIdentifier == process
        // Nil, not true, when there is no process: an action that names no application activates
        // nothing, so there is no activation to have proved.
        var activationProved: Bool? = process == nil ? nil : alreadyFrontmost
        if !alreadyFrontmost, let process {
            _ = activateProcess(process)
            activationProved = settle { self.frontmostApp()?.processIdentifier == process }
        }
        guard activationProved != false else {
            let cleanup = ForegroundCleanup(
                priorApp: prior?.identity,
                priorAppProcessIdentifier: prior.map { Int($0.processIdentifier) },
                alreadyFrontmost: false,
                activationProved: false,
                restored: restoreForeground(prior: prior, alreadyFrontmost: false),
                pointerRestored: nil,
                message: "No events were posted"
            )
            var evidence = details
            evidence["foreground"] = cleanup.jsonValue
            return .refused(
                action: action, target: target, policy: policy,
                refusal: DeliveryRefusal(
                    reason: .activationNotProved,
                    requiredRung: .foreground,
                    capability: .globalInput,
                    message: "Foreground delivery could not prove the target became frontmost, so nothing was posted"
                ),
                details: evidence
            )
        }

        let pointerBefore = restoresPointer ? pointerLocation() : nil
        func handBack() -> ForegroundCleanup {
            let pointerRestored = restorePointer(to: pointerBefore)
            let restored = restoreForeground(prior: prior, alreadyFrontmost: alreadyFrontmost)
            return ForegroundCleanup(
                priorApp: prior?.identity,
                priorAppProcessIdentifier: prior.map { Int($0.processIdentifier) },
                alreadyFrontmost: alreadyFrontmost,
                activationProved: activationProved,
                restored: restored,
                pointerRestored: pointerRestored,
                message: restored ? nil : "The prior application did not return to the foreground"
            )
        }

        let result = body()
        let cleanup = handBack()
        let restorationFailed = !cleanup.restored || cleanup.pointerRestored == false
        return result.withSuccess(
            result.success,
            message: restorationFailed
                ? "\(result.message ?? "Foreground delivery completed"); the session was not restored afterwards"
                : nil,
            details: ["foreground": cleanup.jsonValue]
        )
    }

    private func restoreForeground(prior: ForegroundApp?, alreadyFrontmost: Bool) -> Bool {
        guard !alreadyFrontmost, let prior else {
            return true
        }
        if frontmostApp()?.processIdentifier == prior.processIdentifier {
            return true
        }
        _ = activateProcess(prior.processIdentifier)
        return settle { self.frontmostApp()?.processIdentifier == prior.processIdentifier }
    }

    /// Nil means the dispatch never moved the pointer, so there was nothing to put back.
    private func restorePointer(to origin: CGPoint?) -> Bool? {
        guard let origin, !Self.pointsMatch(pointerLocation(), origin) else {
            return nil
        }
        movePointer(origin)
        return settle { Self.pointsMatch(self.pointerLocation(), origin) }
    }

    /// Bounded wait for an observable session change. Never blocks past the settle budget, so a
    /// window server that refuses to cooperate produces a timeout rather than a hung daemon.
    private func settle(_ condition: () -> Bool) -> Bool {
        if condition() {
            return true
        }
        var waited = 0
        while waited < settleTimeoutMs {
            sleepMilliseconds(settleIntervalMs)
            waited += settleIntervalMs
            if condition() {
                return true
            }
        }
        return false
    }

    /// What the element says it can do, or `nil` when the tree did not answer. An empty list is an
    /// answer; a failed query is not, and the two must not be collapsed by a caller reasoning about
    /// whether a mechanism exists.
    private func advertisedActions(for element: AXUIElement) -> [String]? {
        actionNamesProvider(element)
    }

    /// The advertised actions with an unanswered query read as none.
    ///
    /// This is what `click` wants: its semantic rung is an optimization over a pointer press it can
    /// always fall back to, so an element that cannot say whether it takes `AXPress` is better
    /// clicked than pressed. `scroll` cannot reason this way, because for it the accessibility rung
    /// is the *safe* one — see `scrollToVisibleTarget`.
    private func actionNames(for element: AXUIElement) -> [String] {
        advertisedActions(for: element) ?? []
    }

    private static func copyActionNames(_ element: AXUIElement) -> [String]? {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else {
            return nil
        }
        return (names as? [String]) ?? []
    }

    private func centerPoint(of element: AXUIElement) -> CGPoint? {
        guard let frame = frameProvider(element) else {
            return nil
        }
        return CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
    }

    private func resolvedPointerTarget(_ target: PointerTarget) throws -> ResolvedPointerTarget {
        switch target {
        case let .point(point):
            return ResolvedPointerTarget(point: CGPoint(x: point.x, y: point.y), element: nil, validationFailure: nil)
        case let .handle(handle):
            let element = try elementStore.element(for: handle)
            guard let point = centerPoint(of: element) else {
                throw JSONRPCError.invalidParams("Element has no usable frame: \(handle)")
            }
            return ResolvedPointerTarget(
                point: point,
                element: element,
                validationFailure: pointerValidationFailure(element: element, point: point)
            )
        }
    }

    /// Waits, within the settle budget, for a just-activated window to actually reach the top.
    ///
    /// `NSRunningApplication` reports an app frontmost before the window server has finished
    /// raising its window, so a check taken the instant activation is proved still sees the old
    /// window stack. Validating once at that moment would reject the target as occluded by the very
    /// window the escalation just moved out of the way.
    ///
    /// The check is a closure rather than an element, because a point that names no element has the
    /// same problem and deserves the same budget rather than a second mechanism beside this one.
    private func settledValidationFailure(_ check: () -> String?) -> String? {
        var failure = check()
        guard failure != nil else {
            return nil
        }
        var waited = 0
        while waited < settleTimeoutMs {
            sleepMilliseconds(settleIntervalMs)
            waited += settleIntervalMs
            failure = check()
            if failure == nil {
                return nil
            }
        }
        return failure
    }

    /// What this dispatch must confirm before it posts anything, or nil when there is nothing it
    /// can honestly check.
    ///
    /// A point resolved from a capture is the interesting case. It has no element to hit-test
    /// against, but it does know the window frame its coordinates were computed from, and that is
    /// enough to catch the geometry having moved underneath it — which is the difference between
    /// clicking the intended text and clicking a screen coordinate that has come to mean somewhere
    /// else entirely. A point that carries neither element nor provenance is a bare caller-supplied
    /// coordinate, and there is nothing to compare it against.
    private func pointerValidationCheck(
        point: CGPoint,
        element: AXUIElement?,
        process: pid_t?,
        sourceWindowFrame: AXFrame?,
        rung: DeliveryRung
    ) -> (() -> String?)? {
        if let element {
            return { self.pointerValidationFailure(element: element, point: point) }
        }
        guard let process, let sourceWindowFrame else {
            return nil
        }
        // The same question at both rungs, because it is the same coordinate that has to still mean
        // what it meant. Only *where* it is asked differs: the pixel rung asks once, immediately
        // before a targeted post, while the foreground rung asks inside the settle budget, because
        // an activation it just performed may still be moving the window.
        //
        // Ownership of whatever sits at the point is deliberately not a second question. A targeted
        // post cannot be intercepted by a window stacked above, and the foreground rung is only ever
        // reached for such a point after this check has already refused it, so asking would be
        // answering something the ladder never gets to.
        return { self.sourceWindowFailure(point: point, process: process, sourceWindowFrame: sourceWindowFrame) }
    }

    /// Whether the window these coordinates were computed against is still where it was, with the
    /// point still inside it.
    ///
    /// Containment in *some* window of the application is not the same question and is not enough.
    /// An application with several windows can have a different one covering the old coordinates —
    /// two Safari windows is the configuration this whole guard came from — and a point that now
    /// lands in a window it was never computed from is precisely a stale coordinate, not a valid
    /// one. So the window has to be *the* window, identified by still reporting the frame the
    /// coordinates were measured against.
    ///
    /// Nothing here is a claim about stacking. A window that is still exactly where it was, with
    /// something else drawn on top, keeps its coordinates meaningful for a targeted post.
    private func sourceWindowFailure(point: CGPoint, process: pid_t, sourceWindowFrame: AXFrame) -> String? {
        guard let frames = windowFrames(forProcess: process) else {
            // The window list did not answer. An unanswered query is not evidence that the point is
            // wrong, and refusing on it would ground a working click on a transient fault.
            return nil
        }
        guard let source = frames.first(where: { $0.isClose(to: sourceWindowFrame) }) else {
            return discrepancy(
                "the window these coordinates were computed against is no longer at that frame",
                point: point,
                sourceWindowFrame: sourceWindowFrame,
                current: frames
            )
        }
        guard !source.contains(x: point.x, y: point.y) else {
            return nil
        }
        return discrepancy(
            "the point is outside the window these coordinates were computed against",
            point: point,
            sourceWindowFrame: sourceWindowFrame,
            current: frames
        )
    }

    /// A refusal that carries its own measurements, so the next occurrence is diagnosable from the
    /// result rather than from someone remembering this class of failure.
    private func discrepancy(
        _ reason: String,
        point: CGPoint,
        sourceWindowFrame: AXFrame,
        current: [AXFrame]
    ) -> String {
        let bounds = current.isEmpty
            ? "none"
            : current.map(\.description).joined(separator: ", ")
        return """
            Pointer target validation failed: \(reason). \
            Resolved point {x:\(Double(point.x).compactDescription),y:\(Double(point.y).compactDescription)}; \
            coordinates were computed against \(sourceWindowFrame); \
            target window bounds now \(bounds)
            """
    }

    /// The current frames of the target application's windows, or nil when the window list did not
    /// answer at all. An application that answered with no windows returns an empty list, which is
    /// an answer and not the same thing.
    private func windowFrames(forProcess process: pid_t) -> [AXFrame]? {
        let application = AXUIElementCreateApplication(process)
        guard let windows: [AXUIElement] = copyAttribute(kAXWindowsAttribute, from: application) else {
            return nil
        }
        let frames = windows.compactMap { frame(of: $0) }
        guard frames.isEmpty == windows.isEmpty else {
            // Windows exist but none would state its geometry, which is a failed query rather than
            // evidence about where the point landed.
            return nil
        }
        return frames
    }

    private func pointerValidationFailure(element: AXUIElement, point: CGPoint) -> String? {
        guard let hit = hitTest(point) else {
            return "Pointer target validation failed: accessibility hit test was unresolvable"
        }
        guard elementsShareAncestry(element, hit) else {
            if centerPoint(of: element) != point {
                return "Pointer target validation failed: target moved before dispatch"
            }
            return "Pointer target validation failed: target is occluded or hit testing resolved an unrelated element"
        }
        // Close the small race between the initial frame read and the hit test.
        guard centerPoint(of: element) == point else {
            return "Pointer target validation failed: target moved before dispatch"
        }
        return nil
    }

    private func elementsShareAncestry(_ intended: AXUIElement, _ hit: AXUIElement) -> Bool {
        // Hit testing commonly returns a more specific child (for example static text inside a
        // button). A parent hit does not prove that the intended descendant still occupies the point.
        isSameOrAncestor(intended, of: hit)
    }

    private func isSameOrAncestor(_ candidate: AXUIElement, of element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<64 {
            guard let value = current else { return false }
            if elementsEqual(candidate, value) { return true }
            current = parentProvider(value)
        }
        return false
    }

    private func scrollToVisibleTarget(
        target: PointerTarget?,
        app: NSRunningApplication?,
        deltaX: Double,
        deltaY: Double
    ) throws -> ScrollToVisibleTarget? {
        guard deltaX != 0 || deltaY != 0 else {
            return nil
        }
        let seed = try scrollSeedElement(target: target, app: app)
        guard let container = nearestScrollContainer(from: seed), let containerFrame = frame(of: container) else {
            return nil
        }

        // Only elements the delta could actually travel to are asked what they can do. The walk
        // visits up to 5,000 descendants and an action-names read is a round trip each, so the
        // cheap geometric test comes first and the capability question is asked of what survives it.
        var elements: [AXUIElement] = []
        var candidates: [ScrollToVisibleCandidate] = []
        for element in descendants(of: container, limit: 5_000) {
            guard let frame = frame(of: element),
                  ScrollToVisibleSelector.isOutside(frame, container: containerFrame, deltaX: deltaX, deltaY: deltaY)
            else {
                continue
            }
            elements.append(element)
            // Only a proved absence disqualifies a candidate. A capability query that failed says
            // nothing about the element, and dropping it on that basis would quietly convert a
            // transient accessibility fault into a wheel burst at the named element's center —
            // trading the rung that cannot disturb the wrong window for the one that can. Such a
            // candidate is kept, and the action sent to it answers the question honestly.
            let capability: ScrollToVisibleCapability
            switch advertisedActions(for: element) {
            case let .some(actions):
                capability = actions.contains(Self.scrollToVisibleAction) ? .advertised : .absent
            case .none:
                capability = .unknown
            }
            candidates.append(ScrollToVisibleCandidate(frame: frame, capability: capability))
        }

        guard let index = ScrollToVisibleSelector.select(
            from: candidates,
            container: containerFrame,
            deltaX: deltaX,
            deltaY: deltaY
        ) else {
            return nil
        }
        return ScrollToVisibleTarget(element: elements[index], frame: candidates[index].frame)
    }

    private func scrollSeedElement(target: PointerTarget?, app: NSRunningApplication?) throws -> AXUIElement {
        if let target {
            switch target {
            case let .handle(handle):
                return try elementStore.element(for: handle)
            case let .point(point):
                let cgPoint = CGPoint(x: point.x, y: point.y)
                if let element = element(at: cgPoint) {
                    return element
                }
                throw JSONRPCError.invalidParams("No accessibility element at point: \(point.targetDescription)")
            }
        }

        guard let app, let window = firstWindow(for: app) else {
            throw JSONRPCError.invalidParams("scroll requires a target or app")
        }
        return window
    }

    private func nearestScrollContainer(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var fallback: AXUIElement?
        for _ in 0..<30 {
            guard let candidate = current else {
                return fallback
            }
            let role: String? = copyAttribute(kAXRoleAttribute, from: candidate)
            if role == kAXScrollAreaRole || role == "AXWebArea" {
                return candidate
            }
            if role == kAXWindowRole, fallback == nil {
                fallback = firstDescendant(withRole: kAXScrollAreaRole, from: candidate) ?? candidate
            }
            current = copyAttribute(kAXParentAttribute, from: candidate)
        }
        return fallback
    }

    private func firstWindow(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows: [AXUIElement]? = copyAttribute(kAXWindowsAttribute, from: appElement)
        return windows?.first
    }

    private func firstDescendant(withRole targetRole: String, from element: AXUIElement) -> AXUIElement? {
        for child in children(of: element) {
            let role: String? = copyAttribute(kAXRoleAttribute, from: child)
            if role == targetRole {
                return child
            }
            if let found = firstDescendant(withRole: targetRole, from: child) {
                return found
            }
        }
        return nil
    }

    private func descendants(of element: AXUIElement, limit: Int) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue = children(of: element)
        while !queue.isEmpty, result.count < limit {
            let next = queue.removeFirst()
            result.append(next)
            queue.append(contentsOf: children(of: next))
        }
        return result
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        let children: [AXUIElement]? = copyAttribute(kAXChildrenAttribute, from: element)
        return children ?? []
    }

    private func element(at point: CGPoint) -> AXUIElement? {
        hitTest(point)
    }

    private static func systemHitTest(_ point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        guard result == .success else {
            return nil
        }
        return element
    }

    private func frame(of element: AXUIElement) -> AXFrame? {
        frameProvider(element)
    }

    private static func copyFrame(_ element: AXUIElement) -> AXFrame? {
        func attribute<T>(_ name: String) -> T? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? T
        }
        guard
            let position: AXValue = attribute(kAXPositionAttribute),
            let size: AXValue = attribute(kAXSizeAttribute)
        else {
            return nil
        }

        var point = CGPoint.zero
        var cgSize = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &cgSize)
        else {
            return nil
        }
        return AXFrame(x: point.x, y: point.y, width: cgSize.width, height: cgSize.height)
    }

    private func showTargetBeforeAction(_ element: AXUIElement, label: String) {
        guard let overlay, overlayConfiguration.enabled, let frame = frame(of: element) else {
            return
        }
        overlay.showTarget(VisualTarget(frame: frame, label: label, state: .planned, duration: overlayConfiguration.actionDelay))
    }

    private func copyAttribute<T>(_ attribute: String, from element: AXUIElement) -> T? {
        copyRawAttribute(attribute, from: element) as? T
    }

    private func copyRawAttribute(_ attribute: String, from element: AXUIElement) -> AnyObject? {
        attributeProvider(element, attribute)
    }

    private static func copyRawAttributeValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringValue(_ value: AnyObject?) -> String? {
        guard let value else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    @discardableResult
    private func postMouseClick(at point: CGPoint, sink: (CGEvent) -> Void) -> Bool {
        guard
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else {
            return false
        }
        sink(down)
        sink(up)
        return true
    }

    @discardableResult
    private func postMouseDrag(
        from start: ResolvedPointerTarget,
        to end: ResolvedPointerTarget,
        durationMs: Int?,
        sink: (CGEvent) -> Void
    ) -> DragDispatch {
        let steps = DragEventPathSynthesizer.path(from: start.point, to: end.point, durationMs: durationMs)
        let delayMs = max((durationMs ?? 250) / max(steps.count - 1, 1), 0)
        var postedSteps: [DragEventStep] = []
        for (index, step) in steps.enumerated() {
            let validationElement: AXUIElement? = index == 0
                ? start.element
                : (step.point == end.point ? end.element : nil)
            if let validationElement,
               let failure = pointerValidationFailure(element: validationElement, point: step.point) {
                if !postedSteps.isEmpty, let lastPoint = postedSteps.last?.point,
                   let cancel = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: lastPoint, mouseButton: .left) {
                    sink(cancel)
                }
                return DragDispatch(steps: postedSteps, validationFailure: failure)
            }
            let event = CGEvent(mouseEventSource: nil, mouseType: step.type, mouseCursorPosition: step.point, mouseButton: .left)
            if let event {
                sink(event)
                postedSteps.append(step)
            }
            if index < steps.count - 1, delayMs > 0 {
                sleepMilliseconds(delayMs)
            }
        }
        return DragDispatch(steps: postedSteps, validationFailure: nil)
    }

    /// Posts a wheel burst at `point`. A scroll wheel event carries no location of its own; macOS
    /// routes it to the window under the event's `location` field, so setting it is what makes the
    /// event reach the intended window rather than the screen origin.
    private func postScrollWheel(
        at point: CGPoint,
        deltaX: Double,
        deltaY: Double,
        sink: (CGEvent) -> Void
    ) -> ScrollDispatch {
        let steps = ScrollEventPathSynthesizer.path(deltaX: deltaX, deltaY: deltaY)
        var posted: [ScrollEventStep] = []
        var creationFailed = false
        var cumulativeX = 0.0
        var cumulativeY = 0.0
        var postedX: Int32 = 0
        var postedY: Int32 = 0
        for (index, step) in steps.enumerated() {
            cumulativeX += step.deltaX
            cumulativeY += step.deltaY
            // Round the running total rather than each step, so the integer wheel values still sum
            // to the requested delta instead of drifting by a unit per step.
            let wheelX = Self.clampedWheelDelta(cumulativeX) - postedX
            let wheelY = Self.clampedWheelDelta(cumulativeY) - postedY
            // A step that rounds to no movement on either axis carries nothing. Posting it would
            // report a dispatch that moves the viewport zero pixels.
            guard wheelX != 0 || wheelY != 0 else {
                continue
            }
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: wheelY,
                wheel2: wheelX,
                wheel3: 0
            ) else {
                creationFailed = true
                continue
            }
            event.location = point
            sink(event)
            postedX += wheelX
            postedY += wheelY
            posted.append(ScrollEventStep(deltaX: Double(wheelX), deltaY: Double(wheelY)))
            if index < steps.count - 1 {
                sleepMilliseconds(Self.scrollStepDelayMs)
            }
        }
        return ScrollDispatch(steps: posted, creationFailed: creationFailed)
    }

    private static let scrollStepDelayMs = 4

    private static func clampedWheelDelta(_ value: Double) -> Int32 {
        guard value.isFinite else {
            return value > 0 ? Int32.max : Int32.min
        }
        return Int32(min(max(value.rounded(), Double(Int32.min)), Double(Int32.max)))
    }

    @discardableResult
    private func postKeyStroke(_ keyStroke: KeyStroke, sink: (CGEvent) -> Void) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyStroke.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyStroke.keyCode, keyDown: false)
        else {
            return false
        }
        down.flags = keyStroke.flags
        up.flags = keyStroke.flags
        sink(down)
        sink(up)
        return true
    }

    private func postKeyboardText(_ text: String, sink: (CGEvent) -> Void) -> Bool {
        let layout = makeKeyboardLayout()
        for scalar in text.unicodeScalars {
            // The layout stroke is what keycode-reading consumers see; the Unicode payload is what
            // native controls read. Characters the layout cannot produce keep keycode 0 and travel
            // on the payload alone, which is all that ever worked for them.
            let stroke = layout.stroke(for: scalar)
            var utf16 = Array(String(scalar).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: stroke?.keyCode ?? 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: stroke?.keyCode ?? 0, keyDown: false)
            else {
                return false
            }
            if let stroke {
                down.flags = stroke.flags
                up.flags = stroke.flags
            }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            sink(down)
            sink(up)
        }
        return true
    }

}

private struct ResolvedPointerTarget {
    let point: CGPoint
    let element: AXUIElement?
    let validationFailure: String?
}

private struct ScrollDispatch {
    let steps: [ScrollEventStep]
    let creationFailed: Bool
}

private struct DragDispatch {
    let steps: [DragEventStep]
    let validationFailure: String?
}

private struct ScrollToVisibleTarget {
    let element: AXUIElement
    let frame: AXFrame
}


struct KeyStroke {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    init?(_ rawValue: String) {
        let parts = rawValue.split(separator: "+").map { String($0).lowercased() }
        guard let key = parts.last else {
            return nil
        }

        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command", "super":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "option", "alt":
                flags.insert(.maskAlternate)
            case "ctrl", "control":
                flags.insert(.maskControl)
            default:
                return nil
            }
        }

        guard let keyCode = KeyStroke.keyCodes[key] else {
            return nil
        }
        self.keyCode = keyCode
        self.flags = flags
    }

    init(validating rawValue: String) throws {
        guard let stroke = KeyStroke(rawValue) else {
            throw JSONRPCError.invalidParams("Unknown keyboard key or keystroke: \(rawValue)")
        }
        self = stroke
    }

    static func isValid(_ rawValue: String) -> Bool {
        KeyStroke(rawValue) != nil
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]
}
