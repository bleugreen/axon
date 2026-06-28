import ApplicationServices
import AppKit
import Foundation

public final class AXPrimitiveActionExecutor {
    private let elementStore: AXElementStore
    private let appResolver: AppResolver
    private let overlay: VisualOverlay?
    private let overlayConfiguration: VisualOverlayConfiguration

    public init(
        elementStore: AXElementStore,
        appResolver: AppResolver = AppResolver(),
        overlay: VisualOverlay? = VisualOverlayFactory.makeFromEnvironment(),
        overlayConfiguration: VisualOverlayConfiguration = .fromEnvironment()
    ) {
        self.elementStore = elementStore
        self.appResolver = appResolver
        self.overlay = overlay
        self.overlayConfiguration = overlayConfiguration
    }

    public func handlers() -> PrimitiveActionHandlers {
        PrimitiveActionHandlers(
            click: click(target:),
            clickPoint: click(point:),
            invoke: invoke(target:name:),
            type: type(target:value:),
            keyboard: keyboard(app:keys:),
            scroll: scroll(target:app:deltaX:deltaY:),
            drag: drag(from:to:app:durationMs:)
        )
    }

    public func click(target: String) throws -> PrimitiveActionResult {
        let element = try elementStore.element(for: target)
        if actionNames(for: element).contains(kAXPressAction) {
            return try invoke(target: target, name: kAXPressAction)
        }

        guard let point = centerPoint(of: element) else {
            return PrimitiveActionResult(
                action: "click",
                target: target,
                strategy: "CGEvent",
                success: false,
                message: "Element has no usable frame for click fallback"
            )
        }

        showTargetBeforeAction(element, label: "CGClick")
        postMouseClick(at: point)
        return PrimitiveActionResult(action: "click", target: target, strategy: "CGEvent", success: true)
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
        if result == .success, stringValue(copyRawAttribute(kAXValueAttribute, from: element)) == value {
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

        postMouseClick(at: point)
        Thread.sleep(forTimeInterval: 0.05)
        if let selectAll = KeyStroke("command+a") {
            postKeyStroke(selectAll)
            Thread.sleep(forTimeInterval: 0.02)
        }
        let typed = postKeyboardText(value)
        return PrimitiveActionResult(
            action: "type",
            target: target,
            strategy: "CGEventKeyboard",
            success: typed,
            message: typed ? nil : "Unable to create keyboard events for text fallback"
        )
    }

    public func keyboard(app: String?, keys: String) throws -> PrimitiveActionResult {
        if let app {
            try activate(app: app)
        }
        let target = app ?? "frontmost"
        if let keyStroke = keyStrokeIntent(from: keys) {
            postKeyStroke(keyStroke)
            return PrimitiveActionResult(
                action: "keyboard",
                target: target,
                strategy: "CGEventKeyboard",
                success: true,
                details: ["keys": .string(keys), "mode": .string("keystroke")]
            )
        }
        let success = postKeyboardText(keys)
        return PrimitiveActionResult(
            action: "keyboard",
            target: target,
            strategy: "CGEventKeyboard",
            success: success,
            details: ["keys": .string(keys), "mode": .string("text")]
        )
    }

    public func scroll(
        target: PointerTarget?,
        app: String?,
        deltaX: Double,
        deltaY: Double
    ) throws -> PrimitiveActionResult {
        let resolvedApp = try app.map(appResolver.resolve)
        let scrollTarget = try scrollToVisibleTarget(target: target, app: resolvedApp, deltaX: deltaX, deltaY: deltaY)
        guard let scrollTarget else {
            return PrimitiveActionResult(
                action: "scroll",
                target: target?.targetDescription ?? app ?? "frontmost",
                strategy: "AXScrollToVisible",
                success: false,
                message: "No offscreen accessibility descendant found for scroll direction",
                details: [
                    "deltaX": .double(deltaX),
                    "deltaY": .double(deltaY)
                ]
            )
        }
        let result = AXUIElementPerformAction(scrollTarget.element, "AXScrollToVisible" as CFString)
        var details: [String: JSONValue] = [
            "deltaX": .double(deltaX),
            "deltaY": .double(deltaY)
        ]
        if let target {
            details["targetSpec"] = target.jsonValue
        }
        details["scrollTargetFrame"] = scrollTarget.frame.jsonValue
        return PrimitiveActionResult(
            action: "scroll",
            target: target?.targetDescription ?? app ?? "frontmost",
            strategy: "AXScrollToVisible",
            success: result == .success,
            message: result == .success ? nil : "AXScrollToVisible returned \(result.rawValue)",
            details: details
        )
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
        let start = try point(for: from)
        let end = try point(for: to)
        postMouseDrag(from: start, to: end, durationMs: durationMs)
        return PrimitiveActionResult(
            action: "drag",
            target: "\(from.targetDescription)->\(to.targetDescription)",
            strategy: "CGEventDrag",
            success: true,
            details: [
                "from": ActionPoint(x: start.x, y: start.y).jsonValue,
                "to": ActionPoint(x: end.x, y: end.y).jsonValue,
                "durationMs": durationMs.map(JSONValue.int) ?? .null
            ]
        )
    }

    private func activate(app query: String) throws {
        let app = try appResolver.resolve(query)
        app.activate()
    }

    private func actionNames(for element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else {
            return []
        }
        return (names as? [String]) ?? []
    }

    private func centerPoint(of element: AXUIElement) -> CGPoint? {
        guard let frame = frame(of: element) else {
            return nil
        }
        return CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
    }

    private func point(for target: PointerTarget) throws -> CGPoint {
        switch target {
        case let .point(point):
            return CGPoint(x: point.x, y: point.y)
        case let .handle(handle):
            let element = try elementStore.element(for: handle)
            guard let point = centerPoint(of: element) else {
                throw JSONRPCError.invalidParams("Element has no usable frame: \(handle)")
            }
            return point
        }
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
        guard
            let position: AXValue = copyAttribute(kAXPositionAttribute, from: element),
            let size: AXValue = copyAttribute(kAXSizeAttribute, from: element)
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
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func postMouseDrag(from start: CGPoint, to end: CGPoint, durationMs: Int?) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)
        let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: end, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        if let durationMs, durationMs > 0 {
            Thread.sleep(forTimeInterval: Double(durationMs) / 1_000)
        }
        drag?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func postKeyStroke(_ keyStroke: KeyStroke) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyStroke.keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyStroke.keyCode, keyDown: false)
        down?.flags = keyStroke.flags
        up?.flags = keyStroke.flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func postKeyboardText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            var value = UniChar(scalar.value)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else {
                return false
            }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    private func keyStrokeIntent(from keys: String) -> KeyStroke? {
        if keys.contains("+") {
            return KeyStroke(keys)
        }
        switch keys.lowercased() {
        case "return", "enter", "tab", "space", "delete", "backspace", "escape", "esc", "left", "right", "down", "up":
            return KeyStroke(keys)
        default:
            return nil
        }
    }
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

private struct KeyStroke {
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

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]
}
