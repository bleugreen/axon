import ApplicationServices
import AppKit
import Foundation

public enum SnapshotCaptureError: Error, CustomStringConvertible {
    case missingAccessibilityPermission
    case unreadableAttribute(String)

    public var description: String {
        switch self {
        case .missingAccessibilityPermission:
            return "Accessibility permission is not trusted"
        case let .unreadableAttribute(attribute):
            return "Unable to read accessibility attribute: \(attribute)"
        }
    }
}

public struct AXSnapshotCapturer {
    public static let defaultMaxChildrenPerNode = 24
    public static let defaultMaxWindows = 8
    public static let defaultMessagingTimeout: Float = 0.2
    private static let rawChildCaptureSlack = 4

    private let appResolver: AppResolver
    private let screenshotCapturer: ScreenshotCapturer
    private let elementStore: AXElementStore?
    private let maxChildrenPerNode: Int
    private let maxWindows: Int
    private let messagingTimeout: Float

    private enum ChildCaptureMode {
        case normal
        case shallow
    }

    public init(
        appResolver: AppResolver = AppResolver(),
        screenshotCapturer: ScreenshotCapturer = ScreenshotCapturer(),
        elementStore: AXElementStore? = nil,
        maxChildrenPerNode: Int = Self.defaultMaxChildrenPerNode,
        maxWindows: Int = Self.defaultMaxWindows,
        messagingTimeout: Float = Self.defaultMessagingTimeout
    ) {
        self.appResolver = appResolver
        self.screenshotCapturer = screenshotCapturer
        self.elementStore = elementStore
        self.maxChildrenPerNode = maxChildrenPerNode
        self.maxWindows = maxWindows
        self.messagingTimeout = messagingTimeout
    }

    public func capture(app query: String, screenshot: Bool = false) throws -> AppSnapshot {
        guard AccessibilityPermission.isTrusted() else {
            throw SnapshotCaptureError.missingAccessibilityPermission
        }

        let app = try appResolver.resolve(query)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        var retainedElements: [AXUIElement] = []
        let snapshotID = SnapshotID.next()
        let windows = windowElements(from: appElement)
            .prefix(maxWindows)
            .map { window -> AXNode in
                serialize(window, retainedElements: &retainedElements, childCaptureMode: .normal)
            }
        let windowCount = windowCount(from: appElement)
        let truncationReason = windowCount > windows.count ? "windows limited to \(maxWindows) of \(windowCount)" : nil
        let annotatedWindows = windows.enumerated().map { index, window in
            guard index == 0, let truncationReason else {
                return window
            }
            return window.withAdditionalTruncationReason(truncationReason)
        }
        let appIdentity = AppIdentity(
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            processIdentifier: app.processIdentifier
        )
        let encodedScreenshot = screenshot ? screenshotCapturer.capture(app: appIdentity, axWindows: annotatedWindows) : nil
        let snapshot = AppSnapshot(
            id: snapshotID,
            app: appIdentity,
            windows: annotatedWindows,
            screenshot: encodedScreenshot
        )
        elementStore?.store(snapshotID: snapshotID, elements: retainedElements, summary: SnapshotSummary(snapshot: snapshot))
        return snapshot
    }

    public func captureChildren(parentHandle: String, offset: Int, limit: Int) throws -> AXChildrenPage {
        guard let elementStore else {
            throw AXElementStoreError.missingSnapshot(SnapshotID("unknown"))
        }
        let handle = try SnapshotHandle(parentHandle)
        let parent = try elementStore.element(for: handle)
        AXUIElementSetMessagingTimeout(parent, messagingTimeout)

        let total = attributeValueCount(kAXChildrenAttribute, from: parent)
        let offset = min(max(0, offset), total)
        let limit = min(max(1, limit), maxChildrenPerNode)
        let childElements = rangedElements(kAXChildrenAttribute, from: parent, start: offset, limit: min(limit, total - offset))
        var retainedElements: [AXUIElement] = []
        let children = childElements.map { child -> AXNode in
            serialize(child, retainedElements: &retainedElements, childCaptureMode: .normal)
        }
        let baseIndex = try elementStore.append(snapshotID: handle.snapshotID, elements: retainedElements)
        return AXChildrenPage(
            snapshotID: handle.snapshotID,
            parentHandle: parentHandle,
            offset: offset,
            limit: limit,
            total: total,
            baseIndex: baseIndex,
            children: children
        )
    }

    private func windowElements(from appElement: AXUIElement) -> [AXUIElement] {
        rangedElements(kAXWindowsAttribute, from: appElement, start: 0, limit: maxWindows)
    }

    private func windowCount(from appElement: AXUIElement) -> Int {
        attributeValueCount(kAXWindowsAttribute, from: appElement)
    }

    private func serialize(
        _ element: AXUIElement,
        retainedElements: inout [AXUIElement],
        childCaptureMode: ChildCaptureMode
    ) -> AXNode {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        retainedElements.append(element)

        let role: String = copyAttribute(kAXRoleAttribute, from: element) ?? "AXUnknown"
        let subrole: String? = copyAttribute(kAXSubroleAttribute, from: element)
        let title: String? = copyAttribute(kAXTitleAttribute, from: element)
        let value = stringValue(copyRawAttribute(kAXValueAttribute, from: element))
        let description: String? = copyAttribute(kAXDescriptionAttribute, from: element)
        let help: String? = copyAttribute(kAXHelpAttribute, from: element)
        let identifier: String? = copyAttribute("AXIdentifier", from: element)
        let enabled: Bool? = copyAttribute(kAXEnabledAttribute, from: element)
        let focused: Bool? = copyAttribute(kAXFocusedAttribute, from: element)
        let frame = frame(from: element)
        let actions = actionNames(for: element)
        var truncationReasons: [String] = []
        let children: [AXNode]
        if childCaptureMode == .shallow {
            children = []
        } else {
            let childCount = attributeValueCount(kAXChildrenAttribute, from: element)
            let childLimit = Self.childCaptureLimit(
                childCount: childCount,
                maxChildrenPerNode: maxChildrenPerNode
            )
            if childCount > childLimit {
                truncationReasons.append("children limited to \(childLimit) of \(childCount)")
            }
            children = childElements(from: element, limit: childLimit).enumerated().map { offset, child in
                serialize(
                    child,
                    retainedElements: &retainedElements,
                    childCaptureMode: offset < maxChildrenPerNode ? .normal : .shallow
                )
            }
        }

        return AXNode(
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            description: description,
            help: help,
            identifier: identifier,
            enabled: enabled,
            focused: focused,
            frame: frame,
            actions: actions,
            truncationReason: truncationReasons.isEmpty ? nil : truncationReasons.joined(separator: "; "),
            children: children
        )
    }

    static func childCaptureLimit(childCount: Int, maxChildrenPerNode: Int) -> Int {
        let displayLimit = max(1, maxChildrenPerNode)
        return min(childCount, displayLimit + Self.rawChildCaptureSlack)
    }

    private func childElements(from element: AXUIElement, limit: Int) -> [AXUIElement] {
        rangedElements(kAXChildrenAttribute, from: element, start: 0, limit: limit)
    }

    private func attributeValueCount(_ attribute: String, from element: AXUIElement) -> Int {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success else {
            return 0
        }
        return max(0, count)
    }

    private func rangedElements(_ attribute: String, from element: AXUIElement, start: Int, limit: Int) -> [AXUIElement] {
        let available = max(0, attributeValueCount(attribute, from: element) - start)
        let count = min(available, limit)
        guard count > 0 else {
            return []
        }

        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, attribute as CFString, start, count, &values) == .success else {
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
