import AppKit
import ApplicationServices
import Foundation

/// Reads the handful of Accessibility attributes a postcondition can be derived from.
///
/// Targeted reads only. Capturing a full tree around every dispatched action would multiply the
/// cost of agent work for state nothing here consults, so this walks the element's own attributes,
/// its ancestry (for a durable locator), and the owning app's window titles and focus.
public struct AXElementObserver: ActionStateObserving {
    private static let messagingTimeout: Float = 0.2
    private static let maxAncestryDepth = 12

    private let elementStore: AXElementStore

    public init(elementStore: AXElementStore) {
        self.elementStore = elementStore
    }

    public func elementState(handle: String) -> ObservedElementState? {
        guard let element = try? elementStore.element(for: handle) else {
            return nil
        }
        return state(of: element)
    }

    public func appState(_ scope: ActionObservationScope) -> ObservedAppState? {
        switch scope {
        case let .element(handle):
            guard let element = try? elementStore.element(for: handle),
                  let application = application(owning: element)
            else {
                return nil
            }
            return appState(application)
        case let .app(name):
            guard let identity = try? AppResolver().resolveIdentity(name) else {
                return nil
            }
            let element = AXUIElementCreateApplication(identity.processIdentifier)
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
            return appState((element: element, name: identity.name))
        }
    }

    private func appState(_ application: (element: AXUIElement, name: String)) -> ObservedAppState {
        ObservedAppState(
            app: application.name,
            windowTitles: windowTitles(of: application.element),
            focused: focusedElement(of: application.element).flatMap(state(of:))
        )
    }

    private func state(of element: AXUIElement) -> ObservedElementState? {
        guard let role: String = attribute(kAXRoleAttribute, from: element),
              let app = application(owning: element)?.name
        else {
            return nil
        }

        let chain = ancestry(from: element)
        let windowIndex = chain.firstIndex { attribute(kAXRoleAttribute, from: $0) == "AXWindow" }
        let windowTitle: String? = windowIndex.flatMap { attribute(kAXTitleAttribute, from: chain[$0]) }
        let ancestors = chain.dropFirst().reversed().compactMap(ancestorCandidate(of:))
        let locator = RecordedLocatorBuilder.locator(
            role: role,
            subrole: attribute(kAXSubroleAttribute, from: element),
            identifier: attribute("AXIdentifier", from: element),
            title: attribute(kAXTitleAttribute, from: element),
            value: stringValue(of: element),
            description: attribute(kAXDescriptionAttribute, from: element),
            actions: actionNames(of: element),
            windowTitle: windowTitle,
            ancestors: ancestors
        )
        let durable = RecordedLocatorBuilder.strictReplayWarning(
            for: locator,
            role: role,
            hasWindowAncestor: windowIndex != nil || role == "AXWindow"
        ) == nil

        return ObservedElementState(
            app: app,
            role: role,
            locator: durable ? locator : nil,
            value: stringValue(of: element),
            focused: attribute(kAXFocusedAttribute, from: element),
            enabled: attribute(kAXEnabledAttribute, from: element)
        )
    }

    private func ancestorCandidate(of element: AXUIElement) -> RecordedAncestorCandidate? {
        guard let role: String = attribute(kAXRoleAttribute, from: element) else {
            return nil
        }
        return RecordedAncestorCandidate(
            role: role,
            subrole: attribute(kAXSubroleAttribute, from: element),
            identifier: attribute("AXIdentifier", from: element),
            title: attribute(kAXTitleAttribute, from: element)
        )
    }

    private func ancestry(from element: AXUIElement) -> [AXUIElement] {
        var chain: [AXUIElement] = []
        var current: AXUIElement? = element
        for _ in 0..<Self.maxAncestryDepth {
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

    /// Nil when the window list could not be read, which is a different fact from an app with no
    /// windows: reporting the failure as an empty list would make every window that was already
    /// open look newly appeared as soon as one read succeeds.
    private func windowTitles(of application: AXUIElement) -> [String]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else {
            return nil
        }
        return windows.compactMap { attribute(kAXTitleAttribute, from: $0) }.filter { !$0.isEmpty }
    }

    private func focusedElement(of application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success else {
            return nil
        }
        return axElement(from: value)
    }

    /// Identifies the owning app from the element's process, which is also how a handle target -
    /// carrying no app name of its own - gets one.
    private func application(owning element: AXUIElement) -> (element: AXUIElement, name: String)? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let running = NSRunningApplication(processIdentifier: pid),
              let name = running.localizedName ?? running.bundleIdentifier
        else {
            return nil
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        return (application, name)
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else {
            return []
        }
        return (names as? [String]) ?? []
    }

    /// AXValue is not always a string: checkboxes and steppers report numbers, and a fact about a
    /// toggle needs the same rendering the snapshot capturer gives it.
    private func stringValue(of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let raw
        else {
            return nil
        }
        if let string = raw as? String {
            return string
        }
        if let number = raw as? NSNumber {
            return number.stringValue
        }
        return nil
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
}
