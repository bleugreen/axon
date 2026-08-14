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
    private typealias CapturedTarget = (target: JSONValue, observed: [JSONValue], warnings: [String], app: AppIdentity?)

    private struct PendingTextContext {
        let element: AXUIElement
        let app: AppIdentity
        let actionTarget: CapturedTarget
        /// Begun at capture, not at flush: the burst's before-read must predate the typing it
        /// watches, so it cannot wait for the event that ends the burst.
        let observation: ActionObservationCollector
    }

    private let scope: UserRecordingScope
    private let translator = UserRecordingTranslator()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var observer: AXObserver?
    private var observerSource: CFRunLoopSource?
    private var groups: [RecordedUserEventGroup] = []
    private var mouseDown: CGPoint?
    private var mouseDownObservation: ActionObservationCollector?
    private var pendingText = ""
    private var pendingTextContext: PendingTextContext?
    private let notificationEvidence = AXNotificationEvidenceBuffer()
    /// Retains each recorded event's element so the stock `AXElementObserver` can read it by
    /// handle: the same targeted reads the agent dispatch path observes with, not a second set
    /// of attribute reads.
    private let elementStore = AXElementStore()
    private lazy var elementObserver = AXElementObserver(elementStore: elementStore)

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
            pendingTextContext = nil
            mouseDownObservation = nil
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            mouseDown = event.location
            mouseDownObservation = beginMouseObservation(at: event.location)
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
            mouseDownObservation = nil
            return
        }
        let target = targetAtPoint(point)
        if let mouseDown, distance(mouseDown, point) > 6 {
            let from = targetAtPoint(mouseDown)
            let index = groups.count
            groups.append(RecordedUserEventGroup(
                action: .drag(from: from.target, to: target.target, app: target.app?.name ?? from.app?.name, durationMs: nil),
                observed: target.observed + from.observed,
                warnings: target.warnings + from.warnings
            ))
            finishMouseObservation(groupIndex: index)
            return
        }
        let index = groups.count
        groups.append(RecordedUserEventGroup(
            action: .click(target: target.target),
            observed: target.observed,
            warnings: target.warnings
        ))
        finishMouseObservation(groupIndex: index)
    }

    /// The only before-read a passive tap can take: the press has not been delivered to the app
    /// yet, so the element under it is still in its pre-gesture state. Whether the gesture ends
    /// as a click or a drag is unknowable here; the tool name only labels the observation, and
    /// the translator derives facts from the recorded action either way.
    private func beginMouseObservation(at point: CGPoint) -> ActionObservationCollector? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element,
              recordingApp(for: element) != nil,
              !isSensitive(element)
        else {
            return nil
        }
        return beginObservation(tool: "click", element: element)
    }

    /// Finishes the settle wait and folds the outcome into the gesture's group. The group is
    /// appended before the wait, not after: the wait spins the run loop, and an event delivered
    /// during it must record after the gesture that is still settling, never before.
    private func finishMouseObservation(groupIndex: Int) {
        let collector = mouseDownObservation
        mouseDownObservation = nil
        collector?.finish(success: true)
        let group = groups[groupIndex]
        groups[groupIndex] = RecordedUserEventGroup(
            action: group.action,
            observed: group.observed + drainNotificationEvidence(),
            warnings: group.warnings,
            observation: collector?.observation
        )
    }

    private func pointEvidence(_ point: CGPoint) -> JSONValue {
        .object(["kind": .string("point"), "x": .double(point.x), "y": .double(point.y)])
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
            // Begun before the flush: the flush's settle wait gives the app time to process this
            // very key, which would contaminate the before-read with the key's own effect.
            let keyObservation = beginKeyObservation(app: app, key: key)
            flushPendingText()
            let index = groups.count
            groups.append(RecordedUserEventGroup(action: .pressKey(app: app.name, key: key)))
            keyObservation?.finish(success: true)
            groups[index] = RecordedUserEventGroup(
                action: groups[index].action,
                observed: drainNotificationEvidence(),
                observation: keyObservation?.observation
            )
            return
        }

        if let text, !text.isEmpty {
            if pendingText.isEmpty {
                pendingTextContext = pendingTextContextForCurrentFocus()
            }
            pendingText += text
        }
    }

    private func flushPendingText() {
        guard !pendingText.isEmpty else {
            return
        }
        // Cleared before the settle wait below: the wait spins the run loop, and an event
        // delivered during it must start a fresh burst rather than re-enter this flush.
        let text = pendingText
        let context = pendingTextContext ?? pendingTextContextForCurrentFocus()
        pendingText = ""
        pendingTextContext = nil
        guard let context, !isSensitive(context.element) else {
            return
        }

        // Appended before the settle wait, like every recorded group: the wait spins the run
        // loop, and an event delivered during it must record after this burst, never before.
        // The burst's own action is decided from a direct read; the wait feeds the observation.
        let index = groups.count
        if let value: String = attribute(kAXValueAttribute, from: context.element), !value.isEmpty {
            let factTarget = targetForElement(context.element, app: context.app)
            groups.append(RecordedUserEventGroup(
                action: .setValue(target: context.actionTarget.target, value: value, factTarget: factTarget.target),
                observed: context.actionTarget.observed + factTarget.observed,
                warnings: context.actionTarget.warnings + factTarget.warnings
            ))
        } else {
            groups.append(RecordedUserEventGroup(
                action: .typeText(app: context.app.name, text: text),
                observed: context.actionTarget.observed,
                warnings: context.actionTarget.warnings + ["focused element did not expose AXValue; recorded keyboard fallback"]
            ))
        }
        context.observation.finish(success: true)
        let group = groups[index]
        groups[index] = RecordedUserEventGroup(
            action: group.action,
            observed: group.observed + drainNotificationEvidence(),
            warnings: group.warnings,
            observation: context.observation.observation
        )
    }

    private func pendingTextContextForCurrentFocus() -> PendingTextContext? {
        guard let focused = focusedElement(), !isSensitive(focused.element) else {
            return nil
        }
        // The burst's full text is unknowable at the first keyDown, so the observation carries
        // no inputs; the translator excludes the recorded value through workflow inputs instead.
        return PendingTextContext(
            element: focused.element,
            app: focused.app,
            actionTarget: targetForElement(focused.element, app: focused.app),
            observation: beginObservation(tool: "type", element: focused.element)
        )
    }

    private func beginKeyObservation(app: AppIdentity, key: String) -> ActionObservationCollector? {
        if let focused = focusedElement(), !isSensitive(focused.element) {
            return beginObservation(tool: "keyboard", element: focused.element, inputs: [key])
        }
        return beginAppObservation(tool: "keyboard", app: app, inputs: [key])
    }

    private func beginObservation(tool: String, element: AXUIElement, inputs: [String] = []) -> ActionObservationCollector {
        let snapshotID = SnapshotID.next()
        elementStore.store(snapshotID: snapshotID, elements: [element])
        let collector = makeObservationCollector()
        collector.begin(tool: tool, handle: SnapshotHandle(snapshotID: snapshotID, nodeIndex: 0).rawValue, inputs: inputs)
        return collector
    }

    private func beginAppObservation(tool: String, app: AppIdentity, inputs: [String] = []) -> ActionObservationCollector {
        let collector = makeObservationCollector()
        collector.begin(tool: tool, app: app.name, inputs: inputs)
        return collector
    }

    private func makeObservationCollector() -> ActionObservationCollector {
        ActionObservationCollector(
            observer: elementObserver,
            sleepMilliseconds: { milliseconds in
                // Spinning the run loop, rather than sleeping the thread, keeps AX observer
                // notifications flowing into the evidence buffer while the settle loop waits, so
                // a transition the event caused is attributed to that event's group.
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, Double(milliseconds) / 1_000, true)
            },
            now: Date.init,
            settlesAfter: ActionObservationCollector.settlesAfterEveryTool
        )
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
        notificationEvidence.drain()
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

    private func targetForElement(_ element: AXUIElement, app: AppIdentity, fallbackPoint: CGPoint? = nil) -> (target: JSONValue, observed: [JSONValue], warnings: [String], app: AppIdentity?) {
        let candidates = elementCandidates(from: element)
        guard let hitRole = candidates.first?.role else {
            return pointTarget(fallbackPoint ?? .zero, app: app, warning: "AX element missing role; recorded point fallback")
        }
        guard let selection = RecordedTargetSelector.select(from: candidates) else {
            return pointTarget(fallbackPoint ?? .zero, app: app, warning: "AX element hierarchy did not contain a stable replay target; recorded point fallback")
        }
        do {
            let snapshot = try AXFullTreeCapturer(elementStore: elementStore).capture(app: app.name, screenshot: false)
            switch RecordedSemanticTargetBuilder.resolveTarget(
                app: app.name,
                locator: selection.locator,
                snapshot: snapshot
            ) {
            case let .target(target):
                var observed: [JSONValue] = [
                    .object(["kind": .string("ax-target"), "role": .string(hitRole), "targetRole": .string(selection.candidate.role)])
                ]
                if let fallbackPoint {
                    observed.append(pointEvidence(fallbackPoint))
                }
                return (
                    target,
                    observed,
                    selection.warnings,
                    app
                )
            case .ambiguous:
                return pointTarget(fallbackPoint ?? .zero, app: app, warning: "AX locator matched multiple elements; recorded point fallback")
            case .missing:
                break
            case .invalidLocator:
                return pointTarget(fallbackPoint ?? .zero, app: app, warning: "Recorded AX locator was invalid; recorded point fallback")
            }
        } catch {
            // The point fallback below is explicit because semantic identity could not be captured.
        }
        return pointTarget(fallbackPoint ?? .zero, app: app, warning: "Could not derive a canonical semantic name; recorded point fallback")
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
            [pointEvidence(point)],
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

final class AXNotificationEvidenceBuffer {
    private var entries: [JSONValue] = []

    func append(_ evidence: JSONValue) {
        entries.append(evidence)
    }

    func drain() -> [JSONValue] {
        defer { entries.removeAll() }
        return entries
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
