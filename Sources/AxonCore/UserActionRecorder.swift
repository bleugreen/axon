import ApplicationServices
import AppKit
import Carbon
import Foundation

public enum UserActionRecorderError: Error, CustomStringConvertible {
    case eventTapUnavailable

    public var description: String {
        switch self {
        case .eventTapUnavailable:
            return "Unable to create passive event tap"
        }
    }
}

public enum UserRecordingScope: Equatable, Sendable {
    case app(AppIdentity)
    case all

    public static func pickerOptions(for apps: [AppIdentity]) -> [UserRecordingScope] {
        apps.map(UserRecordingScope.app) + [.all]
    }

    public var displayName: String {
        switch self {
        case let .app(app):
            return app.name
        case .all:
            return "All Running Apps"
        }
    }
}

public final class UserActionRecorder {
    private let scope: UserRecordingScope
    private let translator = UserRecordingTranslator()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var observer: AXObserver?
    private var observerSource: CFRunLoopSource?
    private var groups: [RecordedUserEventGroup] = []
    private var mouseDown: CGPoint?
    private var pendingText = ""
    private var notificationEvidence: [JSONValue] = []

    public convenience init(targetApp: AppIdentity) {
        self.init(scope: .app(targetApp))
    }

    public init(scope: UserRecordingScope) {
        self.scope = scope
    }

    public func start() throws {
        let mask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            throw UserActionRecorderError.eventTapUnavailable
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startObservingScopedApp()
    }

    public func stop() throws -> String {
        flushPendingText()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let observerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), observerSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        observer = nil
        observerSource = nil
        return try translator.yaml(from: groups)
    }

    fileprivate func handle(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if IsSecureEventInputEnabled() {
            pendingText = ""
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            mouseDown = event.location
        case .leftMouseUp:
            flushPendingText()
            recordMouseUp(at: event.location)
            mouseDown = nil
        case .scrollWheel:
            flushPendingText()
            recordScroll(event)
        case .keyDown:
            recordKeyDown(event)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func recordMouseUp(at point: CGPoint) {
        guard recordingApp(at: point) != nil else {
            return
        }
        let target = targetAtPoint(point)
        if let mouseDown, distance(mouseDown, point) > 6 {
            let from = targetAtPoint(mouseDown)
            groups.append(RecordedUserEventGroup(
                action: .drag(from: from.target, to: target.target, app: target.app?.name ?? from.app?.name, durationMs: nil),
                observed: target.observed + from.observed + drainNotificationEvidence(),
                warnings: target.warnings + from.warnings
            ))
            return
        }
        groups.append(RecordedUserEventGroup(
            action: .click(target: target.target),
            observed: target.observed + drainNotificationEvidence(),
            warnings: target.warnings
        ))
    }

    private func recordScroll(_ event: CGEvent) {
        let point = event.location
        guard recordingApp(at: point) != nil else {
            return
        }
        let target = targetAtPoint(point)
        let deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let deltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        groups.append(RecordedUserEventGroup(
            action: .scroll(target: target.target, app: target.app?.name, deltaX: deltaX, deltaY: deltaY == 0 ? -120 : deltaY),
            observed: target.observed + drainNotificationEvidence(),
            warnings: target.warnings
        ))
    }

    private func recordKeyDown(_ event: CGEvent) {
        guard let app = frontmostRecordingApp() else {
            flushPendingText()
            return
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let text = unicodeText(from: event)
        if let key = RecordedKeyClassifier.specialKeyName(keyCode: keyCode, text: text) {
            flushPendingText()
            groups.append(RecordedUserEventGroup(action: .pressKey(app: app.name, key: key), observed: drainNotificationEvidence()))
            return
        }

        if let text, !text.isEmpty {
            pendingText += text
        }
    }

    private func flushPendingText() {
        guard !pendingText.isEmpty else {
            return
        }
        defer { pendingText = "" }
        guard let focused = focusedElement(), !isSensitive(focused.element) else {
            return
        }
        let target = targetForElement(focused.element, app: focused.app)
        if let value: String = attribute(kAXValueAttribute, from: focused.element), !value.isEmpty {
            groups.append(RecordedUserEventGroup(
                action: .setValue(target: target.target, value: value),
                observed: target.observed + drainNotificationEvidence(),
                warnings: target.warnings
            ))
        } else {
            groups.append(RecordedUserEventGroup(
                action: .typeText(app: focused.app.name, text: pendingText),
                observed: target.observed + drainNotificationEvidence(),
                warnings: target.warnings + ["focused element did not expose AXValue; recorded keyboard fallback"]
            ))
        }
    }

    private func startObservingScopedApp() {
        guard case let .app(targetApp) = scope else {
            return
        }
        let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(targetApp.processIdentifier, recordingObserverCallback, &observer) == .success,
              let observer
        else {
            return
        }
        for notification in [
            kAXFocusedWindowChangedNotification,
            kAXFocusedUIElementChangedNotification,
            kAXWindowCreatedNotification,
            kAXValueChangedNotification,
            kAXMenuItemSelectedNotification
        ] {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }
        let source = AXObserverGetRunLoopSource(observer)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.observer = observer
        self.observerSource = source
    }

    fileprivate func recordNotification(_ notification: CFString, element: AXUIElement) {
        var object: [String: JSONValue] = [
            "kind": .string("ax-notification"),
            "notification": .string(notification as String)
        ]
        if let role: String = attribute(kAXRoleAttribute, from: element) {
            object["role"] = .string(role)
        }
        notificationEvidence.append(.object(object))
    }

    private func drainNotificationEvidence() -> [JSONValue] {
        defer { notificationEvidence.removeAll() }
        return notificationEvidence
    }

    private func targetAtPoint(_ point: CGPoint) -> (target: JSONValue, observed: [JSONValue], warnings: [String], app: AppIdentity?) {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        guard result == .success, let element, let app = recordingApp(for: element), !isSensitive(element) else {
            return pointTarget(point, app: frontmostRecordingApp(), warning: "AX hit-test unavailable; recorded point fallback")
        }
        return targetForElement(element, app: app, fallbackPoint: point)
    }

    private func targetForElement(_ element: AXUIElement, app: AppIdentity, fallbackPoint: CGPoint = .zero) -> (target: JSONValue, observed: [JSONValue], warnings: [String], app: AppIdentity?) {
        let candidates = elementCandidates(from: element)
        guard let hitRole = candidates.first?.role else {
            return pointTarget(fallbackPoint, app: app, warning: "AX element missing role; recorded point fallback")
        }
        guard let selection = RecordedTargetSelector.select(from: candidates) else {
            return pointTarget(fallbackPoint, app: app, warning: "AX element hierarchy did not contain a stable replay target; recorded point fallback")
        }
        return (
            .object(["app": .string(app.name), "locator": .object(selection.locator)]),
            [.object(["kind": .string("ax-target"), "role": .string(hitRole), "targetRole": .string(selection.candidate.role)])],
            selection.warnings,
            app
        )
    }

    private func elementCandidates(from element: AXUIElement) -> [RecordedElementCandidate] {
        let chain = elementAncestry(from: element)
        let roles: [String?] = chain.map { attribute(kAXRoleAttribute, from: $0) }
        return chain.indices.compactMap { index in
            guard let role = roles[index] else {
                return nil
            }
            let windowIndex = roles[index...].firstIndex { $0 == "AXWindow" }
            let windowTitle: String? = windowIndex.flatMap { attribute(kAXTitleAttribute, from: chain[$0]) }
            let ancestors = chain[(index + 1)...].reversed().compactMap { ancestor -> RecordedAncestorCandidate? in
                guard let role: String = attribute(kAXRoleAttribute, from: ancestor) else {
                    return nil
                }
                return RecordedAncestorCandidate(
                    role: role,
                    subrole: attribute(kAXSubroleAttribute, from: ancestor),
                    identifier: attribute("AXIdentifier", from: ancestor),
                    title: attribute(kAXTitleAttribute, from: ancestor)
                )
            }
            return RecordedElementCandidate(
                role: role,
                subrole: attribute(kAXSubroleAttribute, from: chain[index]),
                identifier: attribute("AXIdentifier", from: chain[index]),
                title: attribute(kAXTitleAttribute, from: chain[index]),
                value: attribute(kAXValueAttribute, from: chain[index]),
                description: attribute(kAXDescriptionAttribute, from: chain[index]),
                actions: actionNames(for: chain[index]),
                windowTitle: windowTitle,
                hasWindowAncestor: windowIndex != nil || role == "AXWindow",
                ancestors: ancestors
            )
        }
    }

    private func elementAncestry(from element: AXUIElement) -> [AXUIElement] {
        var chain: [AXUIElement] = []
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let element = current else {
                return chain
            }
            chain.append(element)
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success else {
                return chain
            }
            current = axElement(from: parent)
        }
        return chain
    }

    private func pointTarget(_ point: CGPoint, app: AppIdentity?, warning: String) -> (target: JSONValue, observed: [JSONValue], warnings: [String], app: AppIdentity?) {
        var target: [String: JSONValue] = [
            "point": .object(["x": .double(point.x), "y": .double(point.y)])
        ]
        if let app {
            target["app"] = .string(app.name)
        }
        return (
            .object(target),
            [.object(["kind": .string("point"), "x": .double(point.x), "y": .double(point.y)])],
            [warning],
            app
        )
    }

    private func recordingApp(at point: CGPoint) -> AppIdentity? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element
        else {
            return nil
        }
        return recordingApp(for: element)
    }

    private func focusedElement() -> (element: AXUIElement, app: AppIdentity)? {
        guard let focusedApp = frontmostRecordingApp() else {
            return nil
        }
        let app = AXUIElementCreateApplication(focusedApp.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success else {
            return nil
        }
        guard let element = axElement(from: value) else {
            return nil
        }
        return (element, focusedApp)
    }

    private func windowAncestor(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let element = current else {
                return nil
            }
            if let role: String = attribute(kAXRoleAttribute, from: element), role == "AXWindow" {
                return element
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success else {
                return nil
            }
            current = axElement(from: parent)
        }
        return nil
    }

    private func actionNames(for element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else {
            return []
        }
        return (names as? [String]) ?? []
    }

    private func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    private func axElement(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func pid(for element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }
        return pid
    }

    private func frontmostRecordingApp() -> AppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return recordingApp(from: app)
    }

    private func recordingApp(for element: AXUIElement) -> AppIdentity? {
        guard let pid = pid(for: element),
              let app = NSRunningApplication(processIdentifier: pid)
        else {
            return nil
        }
        return recordingApp(from: app)
    }

    private func recordingApp(from app: NSRunningApplication) -> AppIdentity? {
        guard !app.isTerminated, app.activationPolicy == .regular else {
            return nil
        }
        switch scope {
        case let .app(targetApp):
            guard app.processIdentifier == targetApp.processIdentifier else {
                return nil
            }
        case .all:
            break
        }
        return AppIdentity(
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            processIdentifier: app.processIdentifier
        )
    }

    private func isSensitive(_ element: AXUIElement) -> Bool {
        if let role: String = attribute(kAXRoleAttribute, from: element), role.localizedCaseInsensitiveContains("secure") {
            return true
        }
        if let subrole: String = attribute(kAXSubroleAttribute, from: element), subrole.localizedCaseInsensitiveContains("secure") {
            return true
        }
        if let description: String = attribute(kAXDescriptionAttribute, from: element), description.localizedCaseInsensitiveContains("password") {
            return true
        }
        return false
    }

    private func unicodeText(from event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else {
            return nil
        }
        return String(utf16CodeUnits: buffer, count: length)
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let recorder = Unmanaged<UserActionRecorder>.fromOpaque(refcon).takeUnretainedValue()
    return recorder.handle(event, type: type)
}

private func recordingObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else {
        return
    }
    let recorder = Unmanaged<UserActionRecorder>.fromOpaque(refcon).takeUnretainedValue()
    recorder.recordNotification(notification, element: element)
}
