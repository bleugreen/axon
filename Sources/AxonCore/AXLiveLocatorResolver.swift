import ApplicationServices
import AppKit
import Foundation

public struct AXLiveLocatorResolver {
    private let appResolver: AppResolver
    private let elementStore: AXElementStore
    private let messagingTimeout: Float

    public init(
        appResolver: AppResolver = AppResolver(),
        elementStore: AXElementStore,
        messagingTimeout: Float = AXSnapshotCapturer.defaultMessagingTimeout
    ) {
        self.appResolver = appResolver
        self.elementStore = elementStore
        self.messagingTimeout = messagingTimeout
    }

    public func resolve(app query: String, locator: AXLocator, scrollToVisible: Bool = false) throws -> LocatorResolution {
        let capture = try capture(app: query)
        let resolution = LocatorResolver().resolve(locator, in: capture.snapshot)

        if scrollToVisible,
           resolution.status == .unique,
           let index = resolution.best?.handle?.nodeIndex,
           capture.elements.indices.contains(index) {
            scrollElementToVisible(capture.elements[index])
        }

        return resolution
    }

    public func captureSnapshot(app query: String) throws -> AppSnapshot {
        try capture(app: query).snapshot
    }

    private func capture(app query: String) throws -> LiveLocatorCapture {
        guard AccessibilityPermission.isTrusted() else {
            throw SnapshotCaptureError.missingAccessibilityPermission
        }

        let app = try appResolver.resolve(query)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        let snapshotID = SnapshotID.next()
        var retainedElements: [AXUIElement] = []
        let windows = elements(attribute: kAXWindowsAttribute, from: appElement).map { window in
            serialize(window, retainedElements: &retainedElements)
        }
        let identity = AppIdentity(
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            processIdentifier: app.processIdentifier
        )
        let capture = LiveLocatorCapture(
            snapshot: AppSnapshot(id: snapshotID, app: identity, windows: windows, screenshot: nil),
            elements: retainedElements
        )
        elementStore.store(
            snapshotID: capture.snapshot.id,
            elements: capture.elements,
            summary: SnapshotSummary(snapshot: capture.snapshot)
        )
        return capture
    }

    private func serialize(_ element: AXUIElement, retainedElements: inout [AXUIElement]) -> AXNode {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        retainedElements.append(element)

        return AXNode(
            role: copyAttribute(kAXRoleAttribute, from: element) ?? "AXUnknown",
            subrole: copyAttribute(kAXSubroleAttribute, from: element),
            title: copyAttribute(kAXTitleAttribute, from: element),
            value: stringValue(copyRawAttribute(kAXValueAttribute, from: element)),
            description: copyAttribute(kAXDescriptionAttribute, from: element),
            help: copyAttribute(kAXHelpAttribute, from: element),
            identifier: copyAttribute("AXIdentifier", from: element),
            enabled: copyAttribute(kAXEnabledAttribute, from: element),
            focused: copyAttribute(kAXFocusedAttribute, from: element),
            frame: frame(from: element),
            actions: actionNames(for: element),
            children: elements(attribute: kAXChildrenAttribute, from: element).map { child in
                serialize(child, retainedElements: &retainedElements)
            }
        )
    }

    private func scrollElementToVisible(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        _ = AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
    }

    private func elements(attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success, count > 0 else {
            return []
        }

        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0, count, &values) == .success else {
            return []
        }
        return (values as? [AXUIElement]) ?? []
    }

    private func frame(from element: AXUIElement) -> AXFrame? {
        guard
            let position: AXValue = copyAttribute(kAXPositionAttribute, from: element),
            let size: AXValue = copyAttribute(kAXSizeAttribute, from: element)
        else {
            return nil
        }

        var point = CGPoint.zero
        var cgSize = CGSize.zero
        guard
            AXValueGetValue(position, .cgPoint, &point),
            AXValueGetValue(size, .cgSize, &cgSize)
        else {
            return nil
        }

        return AXFrame(x: point.x, y: point.y, width: cgSize.width, height: cgSize.height)
    }

    private func actionNames(for element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else {
            return []
        }
        return (names as? [String]) ?? []
    }

    private func copyRawAttribute(_ attribute: String, from element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func copyAttribute<T>(_ attribute: String, from element: AXUIElement) -> T? {
        copyRawAttribute(attribute, from: element) as? T
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
}

private struct LiveLocatorCapture {
    let snapshot: AppSnapshot
    let elements: [AXUIElement]
}
