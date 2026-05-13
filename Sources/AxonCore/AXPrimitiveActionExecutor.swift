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
            performAction: performAction(target:action:),
            setValue: setValue(target:value:),
            typeText: typeText(app:text:),
            pressKey: pressKey(app:key:),
            scroll: scroll(target:app:deltaX:deltaY:),
            drag: drag(from:to:app:durationMs:)
        )
    }

    public func click(target: String) throws -> PrimitiveActionResult {
        let element = try elementStore.element(for: target)
        if actionNames(for: element).contains(kAXPressAction) {
            return try performAction(target: target, action: kAXPressAction)
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

        showTarget(element, label: "CGClick", state: .planned)
        postMouseClick(at: point)
        let result = PrimitiveActionResult(action: "click", target: target, strategy: "CGEvent", success: true)
        showTarget(element, label: "CGClick", state: .succeeded)
        return result
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

    public func performAction(target: String, action: String) throws -> PrimitiveActionResult {
        let element = try elementStore.element(for: target)
        showTarget(element, label: action, state: .planned)
        let result = AXUIElementPerformAction(element, action as CFString)
        let actionResult = PrimitiveActionResult(
            action: action,
            target: target,
            strategy: "AXAction",
            success: result == .success,
            message: result == .success ? nil : "AXUIElementPerformAction returned \(result.rawValue)"
        )
        showTarget(element, label: action, state: actionResult.success ? .succeeded : .failed)
        return actionResult
    }

    public func setValue(target: String, value: String) throws -> PrimitiveActionResult {
        let element = try elementStore.element(for: target)
        showTarget(element, label: "AXValue", state: .planned)
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        let actionResult = PrimitiveActionResult(
            action: "set_value",
            target: target,
            strategy: "AXValue",
            success: result == .success,
            message: result == .success ? nil : "AXUIElementSetAttributeValue returned \(result.rawValue)"
        )
        showTarget(element, label: "AXValue", state: actionResult.success ? .succeeded : .failed)
        return actionResult
    }

    public func typeText(app: String, text: String) throws -> PrimitiveActionResult {
        try activate(app: app)
        for scalar in text.unicodeScalars {
            var value = UniChar(scalar.value)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else {
                return PrimitiveActionResult(action: "type_text", target: app, strategy: "CGEventKeyboard", success: false)
            }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return PrimitiveActionResult(action: "type_text", target: app, strategy: "CGEventKeyboard", success: true)
    }

    public func pressKey(app: String, key: String) throws -> PrimitiveActionResult {
        try activate(app: app)
        guard let keyStroke = KeyStroke(key) else {
            return PrimitiveActionResult(
                action: "press_key",
                target: app,
                strategy: "CGEventKeyboard",
                success: false,
                message: "Unsupported key: \(key)"
            )
        }
        postKeyStroke(keyStroke)
        return PrimitiveActionResult(action: "press_key", target: app, strategy: "CGEventKeyboard", success: true)
    }

    public func scroll(
        target: PointerTarget?,
        app: String?,
        deltaX: Double,
        deltaY: Double
    ) throws -> PrimitiveActionResult {
        if let app {
            try activate(app: app)
        }
        let point = try target.flatMap(point(for:))
        postScroll(deltaX: deltaX, deltaY: deltaY, at: point)
        var details: [String: JSONValue] = [
            "deltaX": .double(deltaX),
            "deltaY": .double(deltaY)
        ]
        if let point {
            details["point"] = ActionPoint(x: point.x, y: point.y).jsonValue
        }
        if let target {
            details["targetSpec"] = target.jsonValue
        }
        return PrimitiveActionResult(
            action: "scroll",
            target: target?.targetDescription ?? app ?? "frontmost",
            strategy: "CGEventScroll",
            success: true,
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

    private func showTarget(_ element: AXUIElement, label: String, state: VisualTargetState) {
        guard let overlay, overlayConfiguration.enabled, let frame = frame(of: element) else {
            return
        }
        let duration = state == .planned ? overlayConfiguration.plannedDuration : overlayConfiguration.resultDuration
        overlay.showTarget(VisualTarget(frame: frame, label: label, state: state, duration: duration))
    }

    private func copyAttribute<T>(_ attribute: String, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    private func postMouseClick(at point: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func postScroll(deltaX: Double, deltaY: Double, at point: CGPoint?) {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        )
        if let point {
            event?.location = point
        }
        event?.post(tap: .cghidEventTap)
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
