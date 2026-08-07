import ApplicationServices
import AppKit
import Foundation

public final class AXPrimitiveActionExecutor {
    private let elementStore: AXElementStore
    private let appResolver: AppResolver
    private let overlay: VisualOverlay?
    private let overlayConfiguration: VisualOverlayConfiguration
    private let postEvent: (CGEvent) -> Void
    private let sleepMilliseconds: (Int) -> Void
    /// Re-read per text action so a mid-session input source switch is picked up.
    private let makeKeyboardLayout: () -> KeyboardLayoutMap
    private let activateApp: (String) throws -> Void
    private let hitTest: (CGPoint) -> AXUIElement?
    private let frameProvider: (AXUIElement) -> AXFrame?
    private let parentProvider: (AXUIElement) -> AXUIElement?
    private let elementsEqual: (AXUIElement, AXUIElement) -> Bool

    public init(
        elementStore: AXElementStore,
        appResolver: AppResolver = AppResolver(),
        overlay: VisualOverlay? = VisualOverlayFactory.makeFromEnvironment(),
        overlayConfiguration: VisualOverlayConfiguration = .fromEnvironment(),
        postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        sleepMilliseconds: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000) },
        makeKeyboardLayout: @escaping () -> KeyboardLayoutMap = { KeyboardLayoutMap.current() },
        activateApp: ((String) throws -> Void)? = nil,
        hitTest: ((CGPoint) -> AXUIElement?)? = nil,
        frameProvider: ((AXUIElement) -> AXFrame?)? = nil,
        parentProvider: ((AXUIElement) -> AXUIElement?)? = nil,
        elementsEqual: @escaping (AXUIElement, AXUIElement) -> Bool = { CFEqual($0, $1) }
    ) {
        self.elementStore = elementStore
        self.appResolver = appResolver
        self.overlay = overlay
        self.overlayConfiguration = overlayConfiguration
        self.postEvent = postEvent
        self.sleepMilliseconds = sleepMilliseconds
        self.makeKeyboardLayout = makeKeyboardLayout
        self.activateApp = activateApp ?? { query in try appResolver.resolve(query).activate() }
        self.hitTest = hitTest ?? Self.systemHitTest
        self.frameProvider = frameProvider ?? Self.copyFrame
        self.parentProvider = parentProvider ?? Self.copyParent
        self.elementsEqual = elementsEqual
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
            click: click(target:),
            clickPoint: click(point:),
            invoke: invoke(target:name:),
            type: type(target:value:),
            keyboard: keyboard(app:intent:),
            scroll: scroll(target:app:deltaX:deltaY:),
            drag: drag(from:to:app:durationMs:)
        )
    }

    public func click(target: String) throws -> PrimitiveActionResult {
        let element = try elementStore.element(for: target)
        if actionNames(for: element).contains(kAXPressAction) {
            return try invoke(target: target, name: kAXPressAction)
        }

        showTargetBeforeAction(element, label: "CGClick")
        guard let point = centerPoint(of: element) else {
            return PrimitiveActionResult(
                action: "click",
                target: target,
                strategy: "CGEvent",
                success: false,
                message: "Element has no usable frame for click fallback"
            )
        }

        guard let failure = pointerValidationFailure(element: element, point: point) else {
            postMouseClick(at: point)
            return PrimitiveActionResult(action: "click", target: target, strategy: "CGEvent", success: true)
        }
        return PrimitiveActionResult(
            action: "click", target: target, strategy: "CGEvent", success: false,
            message: failure
        )
    }

    public func click(point: ActionPoint) throws -> PrimitiveActionResult {
        let cgPoint = CGPoint(x: point.x, y: point.y)
        postMouseClick(at: cgPoint)
        return PrimitiveActionResult(
            action: "click",
            target: point.targetDescription,
            strategy: "CGEvent",
            success: true,
            details: ["point": point.jsonValue]
        )
    }

    public func invoke(target: String, name: String) throws -> PrimitiveActionResult {
        let element = try elementStore.element(for: target)
        showTargetBeforeAction(element, label: name)
        let result = AXUIElementPerformAction(element, name as CFString)
        return PrimitiveActionResult(
            action: name,
            target: target,
            strategy: "AXAction",
            success: result == .success,
            message: result == .success ? nil : "AXUIElementPerformAction returned \(result.rawValue)"
        )
    }

    public func type(target: String, value: String) throws -> PrimitiveActionResult {
        let element = try elementStore.element(for: target)
        showTargetBeforeAction(element, label: "AXValue")
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        if Self.axValueWasVerified(
            setResult: result,
            readValue: stringValue(copyRawAttribute(kAXValueAttribute, from: element)),
            expected: value
        ) {
            return PrimitiveActionResult(
                action: "type",
                target: target,
                strategy: "AXValue",
                success: true
            )
        }

        guard let point = centerPoint(of: element) else {
            return PrimitiveActionResult(
                action: "type",
                target: target,
                strategy: "AXValue",
                success: false,
                message: result == .success
                    ? "AXUIElementSetAttributeValue did not update the element value"
                    : "AXUIElementSetAttributeValue returned \(result.rawValue)"
            )
        }

        if let failure = pointerValidationFailure(element: element, point: point) {
            return PrimitiveActionResult(
                action: "type", target: target, strategy: "CGEventKeyboard", success: false,
                message: failure
            )
        }
        postMouseClick(at: point)
        Thread.sleep(forTimeInterval: 0.05)
        let selectAllDispatched: Bool
        if let selectAll = KeyStroke("command+a") {
            selectAllDispatched = postKeyStroke(selectAll)
            Thread.sleep(forTimeInterval: 0.02)
        } else {
            selectAllDispatched = false
        }
        let textDispatched = postKeyboardText(value)
        let dispatched = selectAllDispatched && textDispatched
        return PrimitiveActionResult.unverifiedDispatch(
            action: "type",
            target: target,
            strategy: "CGEventKeyboard",
            dispatched: dispatched,
            message: dispatched
                ? "Keyboard fallback events were dispatched, but the field value could not be verified"
                : "Unable to create keyboard events for text fallback",
            details: [:]
        )
    }

    public func keyboard(app: String?, intent: KeyboardIntent) throws -> PrimitiveActionResult {
        if let app {
            try activate(app: app)
        }
        let target = app ?? "frontmost"
        let dispatched: Bool
        var intentDetails: [String: JSONValue]
        switch intent {
        case let .key(key):
            dispatched = postKeyStroke(try KeyStroke(validating: key))
            intentDetails = ["key": .string(key), "mode": .string("key")]
        case let .text(text):
            dispatched = postKeyboardText(text)
            intentDetails = ["text": .string(text), "mode": .string("text")]
        }
        return PrimitiveActionResult.unverifiedDispatch(
            action: "keyboard",
            target: target,
            strategy: "CGEventKeyboard",
            dispatched: dispatched,
            message: dispatched
                ? "Keyboard events were dispatched, but semantic outcome is unverified without a postcondition"
                : "Unable to create keyboard events",
            details: intentDetails
        )
    }

    static func axValueWasVerified(setResult: AXError, readValue: String?, expected: String) -> Bool {
        setResult == .success && readValue == expected
    }

    /// Which strategy runs is decided by what the caller named, not by trying one and catching its
    /// failure. A point is a pointer-space instruction, so it takes the pointer-space mechanism and
    /// never consults the AX tree. An element or app names something semantic, where
    /// `AXScrollToVisible` is more precise and immune to window occlusion, so AX stays primary there
    /// and the wheel covers the case where AX has nothing to work with.
    public func scroll(
        target: PointerTarget?,
        app: String?,
        deltaX: Double,
        deltaY: Double
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
            details["dispatchSuccess"] = .bool(false)
            details["semanticSuccess"] = .null
            details["semanticStatus"] = .string("noop")
            details["eventPath"] = Self.eventPathSummary(steps: [])
            return PrimitiveActionResult(
                action: "scroll",
                target: description,
                strategy: "CGEventScroll",
                success: true,
                message: "No scroll delta was requested; no events were posted",
                details: details
            )
        }

        if case let .point(point) = target {
            return try scrollWheelResult(
                target: description,
                app: app,
                at: CGPoint(x: point.x, y: point.y),
                deltaX: deltaX,
                deltaY: deltaY,
                details: details
            )
        }

        // Only a bare app target needs the app resolved; a handle carries its own element, and
        // resolving anyway would reject a live handle because some unrelated app name went stale.
        let resolvedApp = target == nil ? try app.map(appResolver.resolve) : nil
        if let scrollTarget = try scrollToVisibleTarget(target: target, app: resolvedApp, deltaX: deltaX, deltaY: deltaY) {
            let result = AXUIElementPerformAction(scrollTarget.element, "AXScrollToVisible" as CFString)
            details["scrollTargetFrame"] = scrollTarget.frame.jsonValue
            // The app acknowledging the action is the dispatch; it is still not proof that the
            // viewport moved, and it is not a dispatch at all when the action itself errors.
            details["dispatchSuccess"] = .bool(result == .success)
            details["semanticSuccess"] = .null
            details["semanticStatus"] = .string("unverified")
            return PrimitiveActionResult(
                action: "scroll",
                target: description,
                strategy: "AXScrollToVisible",
                success: result == .success,
                message: result == .success ? nil : "AXScrollToVisible returned \(result.rawValue)",
                details: details
            )
        }

        guard let point = try wheelPoint(target: target, app: resolvedApp) else {
            details["dispatchSuccess"] = .bool(false)
            return PrimitiveActionResult(
                action: "scroll",
                target: description,
                strategy: "CGEventScroll",
                success: false,
                message: "scroll target has no resolvable screen point",
                details: details
            )
        }
        return try scrollWheelResult(
            target: description,
            app: app,
            at: point,
            deltaX: deltaX,
            deltaY: deltaY,
            details: details
        )
    }

    private func scrollWheelResult(
        target: String,
        app: String?,
        at point: CGPoint,
        deltaX: Double,
        deltaY: Double,
        details: [String: JSONValue]
    ) throws -> PrimitiveActionResult {
        // Activation belongs to the wheel and only to the wheel: a wheel reaches whichever window is
        // topmost under the point, so an occluded target window would swallow it. AXScrollToVisible
        // addresses an element directly and is immune to occlusion, so activating for it would take
        // the user's focus for nothing.
        if let app {
            try activate(app: app)
        }
        let dispatch = postScrollWheel(at: point, deltaX: deltaX, deltaY: deltaY)
        var details = details
        details["at"] = ActionPoint(x: point.x, y: point.y, coordinateSpace: .screen).jsonValue
        details["eventPath"] = Self.eventPathSummary(steps: dispatch.steps)
        guard !dispatch.steps.isEmpty else {
            details["dispatchSuccess"] = .bool(false)
            return PrimitiveActionResult(
                action: "scroll",
                target: target,
                strategy: "CGEventScroll",
                success: false,
                message: dispatch.creationFailed
                    ? "Unable to create scroll wheel events"
                    : "scroll delta rounds to no pixel of wheel movement",
                details: details
            )
        }
        details["dispatchSuccess"] = .bool(true)
        details["semanticSuccess"] = .null
        details["semanticStatus"] = .string("unverified")
        return PrimitiveActionResult(
            action: "scroll",
            target: target,
            strategy: "CGEventScroll",
            success: true,
            details: details
        )
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

    public func drag(
        from: PointerTarget,
        to: PointerTarget,
        app: String?,
        durationMs: Int?
    ) throws -> PrimitiveActionResult {
        if let app {
            try activate(app: app)
        }
        let start = try resolvedPointerTarget(from)
        let end = try resolvedPointerTarget(to)
        if let failure = start.validationFailure ?? end.validationFailure {
            return PrimitiveActionResult(
                action: "drag",
                target: "\(from.targetDescription)->\(to.targetDescription)",
                strategy: "CGEventDrag",
                success: false,
                message: failure,
                details: ["dispatchSuccess": .bool(false)]
            )
        }
        let dispatch = postMouseDrag(from: start, to: end, durationMs: durationMs)
        if let failure = dispatch.validationFailure {
            return PrimitiveActionResult(
                action: "drag",
                target: "\(from.targetDescription)->\(to.targetDescription)",
                strategy: "CGEventDrag",
                success: false,
                message: failure,
                details: ["dispatchSuccess": .bool(false), "cancelledSafely": .bool(true)]
            )
        }
        let eventSteps = dispatch.steps
        return PrimitiveActionResult(
            action: "drag",
            target: "\(from.targetDescription)->\(to.targetDescription)",
            strategy: "CGEventDrag",
            success: false,
            message: "Drag pointer events were dispatched, but semantic outcome is unverified without a postcondition",
            details: [
                "dispatchSuccess": .bool(true),
                "semanticSuccess": .null,
                "semanticStatus": .string("unverified"),
                "from": ActionPoint(x: start.point.x, y: start.point.y, coordinateSpace: .screen).jsonValue,
                "to": ActionPoint(x: end.point.x, y: end.point.y, coordinateSpace: .screen).jsonValue,
                "durationMs": durationMs.map(JSONValue.int) ?? .null,
                "eventPath": .object([
                    "eventCount": .int(eventSteps.count),
                    "updates": .int(eventSteps.filter { $0.type == .leftMouseDragged }.count),
                    "hasThresholdMotion": .bool(eventSteps.count > 2)
                ])
            ]
        )
    }

    private func activate(app query: String) throws {
        try activateApp(query)
    }

    private func actionNames(for element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else {
            return []
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

        let candidates = descendants(of: container, limit: 5_000).compactMap { element -> ScrollToVisibleTarget? in
            guard let frame = frame(of: element), isOutside(frame, from: containerFrame, deltaX: deltaX, deltaY: deltaY) else {
                return nil
            }
            return ScrollToVisibleTarget(element: element, frame: frame)
        }
        guard !candidates.isEmpty else {
            return nil
        }

        let desired = desiredScrollCoordinate(from: containerFrame, deltaX: deltaX, deltaY: deltaY)
        return candidates.min { lhs, rhs in
            scrollDistance(lhs.frame, desired: desired, deltaX: deltaX, deltaY: deltaY)
                < scrollDistance(rhs.frame, desired: desired, deltaX: deltaX, deltaY: deltaY)
        }
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

    private func isOutside(_ frame: AXFrame, from container: AXFrame, deltaX: Double, deltaY: Double) -> Bool {
        if abs(deltaY) >= abs(deltaX) {
            return deltaY < 0 ? frame.y >= container.maxY : frame.maxY <= container.y
        }
        return deltaX < 0 ? frame.x >= container.maxX : frame.maxX <= container.x
    }

    private func desiredScrollCoordinate(from container: AXFrame, deltaX: Double, deltaY: Double) -> Double {
        if abs(deltaY) >= abs(deltaX) {
            return deltaY < 0 ? container.maxY + abs(deltaY) : container.y - abs(deltaY)
        }
        return deltaX < 0 ? container.maxX + abs(deltaX) : container.x - abs(deltaX)
    }

    private func scrollDistance(_ frame: AXFrame, desired: Double, deltaX: Double, deltaY: Double) -> Double {
        let coordinate = abs(deltaY) >= abs(deltaX) ? frame.midY : frame.midX
        return abs(coordinate - desired)
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

    private func postMouseClick(at point: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        if let down { postEvent(down) }
        if let up { postEvent(up) }
    }

    @discardableResult
    private func postMouseDrag(
        from start: ResolvedPointerTarget,
        to end: ResolvedPointerTarget,
        durationMs: Int?
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
                    postEvent(cancel)
                }
                return DragDispatch(steps: postedSteps, validationFailure: failure)
            }
            let event = CGEvent(mouseEventSource: nil, mouseType: step.type, mouseCursorPosition: step.point, mouseButton: .left)
            if let event {
                postEvent(event)
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
    private func postScrollWheel(at point: CGPoint, deltaX: Double, deltaY: Double) -> ScrollDispatch {
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
            postEvent(event)
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
    private func postKeyStroke(_ keyStroke: KeyStroke) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyStroke.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyStroke.keyCode, keyDown: false)
        else {
            return false
        }
        down.flags = keyStroke.flags
        up.flags = keyStroke.flags
        postEvent(down)
        postEvent(up)
        return true
    }

    private func postKeyboardText(_ text: String) -> Bool {
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
            postEvent(down)
            postEvent(up)
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

private extension AXFrame {
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
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
