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
    public static let defaultMaxDepth = 8
    public static let defaultMaxChildrenPerNode = 50
    public static let defaultMaxNodes = 400
    public static let defaultMaxWindows = 8
    public static let defaultMessagingTimeout: Float = 0.2

    private let appResolver: AppResolver
    private let screenshotCapturer: ScreenshotCapturer
    private let elementStore: AXElementStore?
    private let maxDepth: Int
    private let maxChildrenPerNode: Int
    private let maxNodes: Int
    private let maxWindows: Int
    private let messagingTimeout: Float

    public init(
        appResolver: AppResolver = AppResolver(),
        screenshotCapturer: ScreenshotCapturer = ScreenshotCapturer(),
        elementStore: AXElementStore? = nil,
        maxDepth: Int = Self.defaultMaxDepth,
        maxChildrenPerNode: Int = Self.defaultMaxChildrenPerNode,
        maxNodes: Int = Self.defaultMaxNodes,
        maxWindows: Int = Self.defaultMaxWindows,
        messagingTimeout: Float = Self.defaultMessagingTimeout
    ) {
        self.appResolver = appResolver
        self.screenshotCapturer = screenshotCapturer
        self.elementStore = elementStore
        self.maxDepth = maxDepth
        self.maxChildrenPerNode = maxChildrenPerNode
        self.maxNodes = maxNodes
        self.maxWindows = maxWindows
        self.messagingTimeout = messagingTimeout
    }

    public func capture(app query: String, includeScreenshot: Bool = true) throws -> AppSnapshot {
        guard AccessibilityPermission.isTrusted() else {
            throw SnapshotCaptureError.missingAccessibilityPermission
        }

        let app = try appResolver.resolve(query)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        var remainingNodes = maxNodes
        var retainedElements: [AXUIElement] = []
        let snapshotID = SnapshotID(UUID().uuidString)
        let windows = windowElements(from: appElement)
            .prefix(maxWindows)
            .compactMap { window -> AXNode? in
                guard remainingNodes > 0 else {
                    return nil
                }
                return serialize(window, depth: 0, remainingNodes: &remainingNodes, retainedElements: &retainedElements)
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
        let screenshot = includeScreenshot ? screenshotCapturer.capture(app: appIdentity, axWindows: annotatedWindows) : nil
        elementStore?.store(snapshotID: snapshotID, elements: retainedElements)

        return AppSnapshot(
            id: snapshotID,
            app: appIdentity,
            windows: annotatedWindows,
            screenshot: screenshot
        )
    }

    private func windowElements(from appElement: AXUIElement) -> [AXUIElement] {
        rangedElements(kAXWindowsAttribute, from: appElement, limit: maxWindows)
    }

    private func windowCount(from appElement: AXUIElement) -> Int {
        attributeValueCount(kAXWindowsAttribute, from: appElement)
    }

    private func serialize(
        _ element: AXUIElement,
        depth: Int,
        remainingNodes: inout Int,
        retainedElements: inout [AXUIElement]
    ) -> AXNode {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        retainedElements.append(element)
        remainingNodes -= 1

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
        let children: [AXNode]
        var truncationReasons: [String] = []
        if depth >= maxDepth || remainingNodes <= 0 {
            children = []
            if depth >= maxDepth {
                truncationReasons.append("max depth \(maxDepth) reached")
            }
            if remainingNodes <= 0 {
                truncationReasons.append("node budget \(maxNodes) exhausted")
            }
        } else {
            let childCount = attributeValueCount(kAXChildrenAttribute, from: element)
            if childCount > maxChildrenPerNode {
                truncationReasons.append("children limited to \(maxChildrenPerNode) of \(childCount)")
            }
            children = childElements(from: element).compactMap { child in
                guard remainingNodes > 0 else {
                    return nil
                }
                return serialize(child, depth: depth + 1, remainingNodes: &remainingNodes, retainedElements: &retainedElements)
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

    private func childElements(from element: AXUIElement) -> [AXUIElement] {
        rangedElements(kAXChildrenAttribute, from: element, limit: maxChildrenPerNode)
    }

    private func attributeValueCount(_ attribute: String, from element: AXUIElement) -> Int {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success else {
            return 0
        }
        return max(0, count)
    }

    private func rangedElements(_ attribute: String, from element: AXUIElement, limit: Int) -> [AXUIElement] {
        let count = min(attributeValueCount(attribute, from: element), limit)
        guard count > 0 else {
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
