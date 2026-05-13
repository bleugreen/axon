import ApplicationServices
import Foundation

public struct ObservedAppChange: Codable, Equatable, Sendable {
    public let sequence: Int
    public let reason: String

    public init(sequence: Int, reason: String) {
        self.sequence = sequence
        self.reason = reason
    }
}

public protocol AppChangeObserving: AnyObject, Sendable {
    func startObserving(app: AppIdentity)
    func token(for app: AppIdentity) -> Int
    func changes(since token: Int, app: AppIdentity) -> [ObservedAppChange]
}

public final class AppChangeTracker: AppChangeObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var sequence = 0
    private var changesByAppKey: [String: [ObservedAppChange]] = [:]

    public init() {}

    public func startObserving(app: AppIdentity) {}

    public func token(for app: AppIdentity) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sequence
    }

    @discardableResult
    public func recordChange(app: AppIdentity, reason: String) -> Int {
        lock.lock()
        defer { lock.unlock() }

        sequence += 1
        let change = ObservedAppChange(sequence: sequence, reason: reason)
        changesByAppKey[Self.key(for: app), default: []].append(change)
        return sequence
    }

    public func changes(since token: Int, app: AppIdentity) -> [ObservedAppChange] {
        lock.lock()
        defer { lock.unlock() }

        return changesByAppKey[Self.key(for: app), default: []]
            .filter { $0.sequence > token }
    }

    private static func key(for app: AppIdentity) -> String {
        "pid:\(app.processIdentifier)"
    }
}

public final class AXAppChangeObserverRegistry: AppChangeObserving, @unchecked Sendable {
    private final class Registration {
        let observer: AXObserver
        let appElement: AXUIElement

        init(observer: AXObserver, appElement: AXUIElement) {
            self.observer = observer
            self.appElement = appElement
        }
    }

    private let tracker: AppChangeTracker
    private let observerRunLoop: AXObserverRunLoop
    private let lock = NSLock()
    private var registrationsByPID: [Int32: Registration] = [:]

    public init(tracker: AppChangeTracker = AppChangeTracker(), observerRunLoop: AXObserverRunLoop = AXObserverRunLoop()) {
        self.tracker = tracker
        self.observerRunLoop = observerRunLoop
    }

    public func startObserving(app: AppIdentity) {
        lock.lock()
        if registrationsByPID[app.processIdentifier] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var observer: AXObserver?
        let context = Unmanaged.passUnretained(tracker).toOpaque()
        guard AXObserverCreate(app.processIdentifier, axObserverCallback, &observer) == .success,
              let observer
        else {
            return
        }

        for notification in Self.appNotifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, context)
        }
        CFRunLoopAddSource(observerRunLoop.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)

        lock.lock()
        registrationsByPID[app.processIdentifier] = Registration(observer: observer, appElement: appElement)
        lock.unlock()
    }

    public func token(for app: AppIdentity) -> Int {
        tracker.token(for: app)
    }

    public func changes(since token: Int, app: AppIdentity) -> [ObservedAppChange] {
        tracker.changes(since: token, app: app)
    }

    private static let appNotifications = [
        kAXFocusedWindowChangedNotification,
        kAXFocusedUIElementChangedNotification,
        kAXWindowCreatedNotification
    ]
}

public final class AXObserverRunLoop: @unchecked Sendable {
    public let runLoop: CFRunLoop

    public init() {
        let semaphore = DispatchSemaphore(value: 0)
        let box = RunLoopBox()
        let thread = Thread {
            box.runLoop = CFRunLoopGetCurrent()
            semaphore.signal()
            CFRunLoopRun()
        }
        thread.name = "dev.axon.axobserver"
        thread.start()
        semaphore.wait()
        self.runLoop = box.runLoop
    }
}

private final class RunLoopBox: @unchecked Sendable {
    var runLoop: CFRunLoop!
}

private func axObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else {
        return
    }
    let tracker = Unmanaged<AppChangeTracker>.fromOpaque(refcon).takeUnretainedValue()
    guard let app = appIdentity(forObservedElement: element) else {
        return
    }
    tracker.recordChange(app: app, reason: notification as String)
}

private func appIdentity(forObservedElement element: AXUIElement) -> AppIdentity? {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else {
        return nil
    }
    return AppIdentity(bundleIdentifier: nil, name: "pid \(pid)", processIdentifier: pid)
}
