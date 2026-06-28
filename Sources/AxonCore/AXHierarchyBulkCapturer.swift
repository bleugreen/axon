import ApplicationServices
import AppKit
import Darwin
import Foundation

struct AXHierarchyBulkCapture {
    let windows: [AXNode]
    let retainedElements: [AXUIElement]

    var looksLikeCompleteAppTree: Bool {
        containsRole("AXWebArea") || (nodeCount > 64 && !containsRole("AXMenuBar") && !containsRole("AXMenuItem"))
    }

    private var nodeCount: Int {
        windows.reduce(0) { $0 + $1.deepNodeCount }
    }

    private func containsRole(_ role: String) -> Bool {
        windows.contains { $0.containsRole(role) }
    }
}

struct AXHierarchyBulkCapturer {
    private static let maxArrayCount = -1
    private static let maxDepth = -1
    private static let messagingTimeout: Float = 3.0
    private static let deniedBundleIdentifiers: Set<String> = [
        "org.mozilla.firefox"
    ]

    private let loader: AXUIElementCopyHierarchyLoader?
    private let includeActions: Bool

    init(loader: AXUIElementCopyHierarchyLoader? = AXUIElementCopyHierarchyLoader.load(), includeActions: Bool = true) {
        self.loader = loader
        self.includeActions = includeActions
    }

    func capture(appElement: AXUIElement) -> AXHierarchyBulkCapture? {
        guard
            ProcessInfo.processInfo.environment["AXON_DISABLE_BULK_HIERARCHY"] != "1",
            Self.permitsBulkHierarchy(element: appElement),
            let loader
        else {
            return nil
        }

        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
        let attributes = AXHierarchyBulkParser.scalarAttributes + AXHierarchyBulkParser.childAttributes
        let options: NSDictionary = [
            loader.arrayAttributesKey: AXHierarchyBulkParser.childAttributes,
            loader.maxArrayCountKey: Self.maxArrayCount,
            loader.maxDepthKey: Self.maxDepth,
            loader.truncateStringsKey: true,
            loader.returnAttributeErrorsKey: false
        ]
        var result: CFTypeRef?
        let error = loader.copyHierarchy(appElement, attributes as CFArray, options, &result)
        guard
            error == .success,
            let hierarchy = result as? NSDictionary
        else {
            return nil
        }

        let actionProvider: AXHierarchyBulkParser.ActionProvider
        if includeActions {
            actionProvider = Self.actionNames
        } else {
            actionProvider = { _ in [] }
        }
        return AXHierarchyBulkParser(actionProvider: actionProvider).parse(hierarchy)
    }

    static func permitsBulkHierarchy(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return true
        }
        return !deniedBundleIdentifiers.contains(bundleIdentifier)
    }

    private static func permitsBulkHierarchy(element: AXUIElement) -> Bool {
        guard
            let processIdentifier = processIdentifier(from: element),
            let app = NSRunningApplication(processIdentifier: processIdentifier)
        else {
            return true
        }
        return permitsBulkHierarchy(bundleIdentifier: app.bundleIdentifier)
    }

    private static func processIdentifier(from element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else {
            return nil
        }
        return processIdentifier
    }

    private static func actionNames(for object: AnyObject) -> [String] {
        guard let element = AXHierarchyElementBridge.axElement(from: object) else {
            return []
        }
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else {
            return []
        }
        return (names as? [String]) ?? []
    }
}

public enum AXFullTreeCaptureError: Error, CustomStringConvertible {
    case missingAccessibilityPermission
    case unavailable

    public var description: String {
        switch self {
        case .missingAccessibilityPermission:
            return "Accessibility permission is not trusted"
        case .unavailable:
            return "Full accessibility hierarchy capture is unavailable"
        }
    }
}

public struct AXFullTreeCapturer {
    private static let messagingTimeout: Float = 0.2
    private static let preferredChildAttributes = [
        kAXWindowsAttribute as String,
        kAXChildrenAttribute as String,
        "AXChildrenInNavigationOrder",
        "AXVisibleChildren",
        "AXContents",
        "AXRows",
        "AXColumns",
        "AXTabs",
        "AXCells"
    ]
    private static let excludedChildAttributes: Set<String> = [
        kAXParentAttribute as String,
        kAXWindowAttribute as String,
        kAXTopLevelUIElementAttribute as String,
        kAXFocusedUIElementAttribute as String,
        kAXFocusedWindowAttribute as String,
        "AXSelectedChildren",
        "AXLinkedUIElements"
    ]

    private let appResolver: AppResolver
    private let screenshotCapturer: ScreenshotCapturer
    private let elementStore: AXElementStore?

    public init(
        appResolver: AppResolver = AppResolver(),
        screenshotCapturer: ScreenshotCapturer = ScreenshotCapturer(),
        elementStore: AXElementStore? = nil
    ) {
        self.appResolver = appResolver
        self.screenshotCapturer = screenshotCapturer
        self.elementStore = elementStore
    }

    public func capture(app query: String, screenshot: Bool = false) throws -> AppSnapshot {
        guard AccessibilityPermission.isTrusted() else {
            throw AXFullTreeCaptureError.missingAccessibilityPermission
        }

        let app = try appResolver.resolve(query)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let appIdentity = AppIdentity(
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            processIdentifier: app.processIdentifier
        )
        let allowBulkHierarchy = AXHierarchyBulkCapturer.permitsBulkHierarchy(bundleIdentifier: app.bundleIdentifier)
        let bulkCapture = allowBulkHierarchy ? AXHierarchyBulkCapturer().capture(appElement: appElement).flatMap { capture in
            capture.looksLikeCompleteAppTree ? capture : nil
        } : nil
        let capture = bulkCapture ?? dynamicCapture(appElement: appElement, allowBulkHierarchy: allowBulkHierarchy)

        let encodedScreenshot = screenshot ? screenshotCapturer.capture(app: appIdentity, axWindows: capture.windows) : nil
        let snapshot = AppSnapshot(
            id: SnapshotID.next(),
            app: appIdentity,
            windows: capture.windows,
            screenshot: encodedScreenshot
        )
        elementStore?.store(snapshotID: snapshot.id, elements: capture.retainedElements, summary: SnapshotSummary(snapshot: snapshot))
        return snapshot
    }

    private func dynamicCapture(appElement: AXUIElement, allowBulkHierarchy: Bool) -> AXHierarchyBulkCapture {
        var retainedElements: [AXUIElement] = []
        let rootElements = dynamicRootElements(from: appElement)
        let windows = rootElements.map { window in
            scopedWindowNode(element: window, retainedElements: &retainedElements, allowBulkHierarchy: allowBulkHierarchy)
        }
        return AXHierarchyBulkCapture(windows: windows, retainedElements: retainedElements)
    }

    private func dynamicRootElements(from appElement: AXUIElement) -> [AXUIElement] {
        let explicitWindows = [
            "AXMainWindow",
            kAXFocusedWindowAttribute as String,
            kAXWindowsAttribute as String
        ].flatMap { childElements($0, from: appElement).elements }
        let windows = deduplicated(explicitWindows)
        if !windows.isEmpty {
            return windows
        }
        let children = childGroups(from: appElement).flatMap(\.elements)
        let windowChildren = children.filter { stringAttribute(kAXRoleAttribute, from: $0) == "AXWindow" }
        return windowChildren.isEmpty ? children : windowChildren
    }

    private func deduplicated(_ elements: [AXUIElement]) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var seen: Set<UInt> = []
        for element in elements where seen.insert(CFHash(element)).inserted {
            result.append(element)
        }
        return result
    }

    private func scopedWindowNode(
        element: AXUIElement,
        retainedElements: inout [AXUIElement],
        allowBulkHierarchy: Bool
    ) -> AXNode {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        retainedElements.append(element)
        var subtreeElements: [AXUIElement] = []
        let webNodes: [AXNode]
        if allowBulkHierarchy {
            let webAreas = webAreas(in: element)
            webNodes = webAreas.compactMap { webArea -> AXNode? in
                guard let scoped = AXHierarchyBulkCapturer(includeActions: false).capture(appElement: webArea),
                      let webNode = scoped.windows.first
                else {
                    return nil
                }
                subtreeElements.append(contentsOf: scoped.retainedElements)
                return webNode.withInferredActions()
            }
        } else {
            webNodes = []
        }
        if !webNodes.isEmpty {
            retainedElements.append(contentsOf: subtreeElements)
            return nodeSummary(element: element, childCount: webNodes.count, children: webNodes)
        }

        var visited: Set<UInt> = [CFHash(element)]
        let children = childGroups(from: element).flatMap(\.elements).map { child in
            dynamicNode(element: child, retainedElements: &retainedElements, visited: &visited, depth: 1)
        }
        return nodeSummary(element: element, childCount: children.count, children: children)
    }

    private func dynamicNode(
        element: AXUIElement,
        retainedElements: inout [AXUIElement],
        visited: inout Set<UInt>,
        depth: Int
    ) -> AXNode {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        let identity = CFHash(element)
        if depth > 6 || visited.contains(identity) {
            return nodeSummary(element: element, childCount: 0, children: [])
        }
        visited.insert(identity)
        retainedElements.append(element)
        let groups = childGroups(from: element)
        let children = groups.flatMap(\.elements).map { child in
            dynamicNode(element: child, retainedElements: &retainedElements, visited: &visited, depth: depth + 1)
        }
        let childCount = groups.reduce(0) { $0 + $1.count }
        return nodeSummary(element: element, childCount: childCount, children: children)
    }

    private func webAreas(in root: AXUIElement) -> [AXUIElement] {
        var queue: [AXUIElement] = [root]
        var visited: Set<UInt> = []
        var result: [AXUIElement] = []
        while !queue.isEmpty, visited.count < 500 {
            let element = queue.removeFirst()
            guard visited.insert(CFHash(element)).inserted else {
                continue
            }
            if stringAttribute(kAXRoleAttribute, from: element) == "AXWebArea" {
                result.append(element)
                continue
            }
            queue.append(contentsOf: childGroups(from: element).flatMap(\.elements))
        }
        return result
    }

    private func nodeSummary(element: AXUIElement, childCount: Int, children: [AXNode]) -> AXNode {
        AXNode(
            role: stringAttribute(kAXRoleAttribute, from: element) ?? "AXUnknown",
            subrole: stringAttribute(kAXSubroleAttribute, from: element),
            title: stringAttribute(kAXTitleAttribute, from: element),
            value: stringValue(rawAttribute(kAXValueAttribute, from: element)),
            description: stringAttribute(kAXDescriptionAttribute, from: element),
            help: stringAttribute(kAXHelpAttribute, from: element),
            identifier: stringAttribute("AXIdentifier", from: element),
            enabled: boolAttribute(kAXEnabledAttribute, from: element),
            focused: boolAttribute(kAXFocusedAttribute, from: element),
            frame: frame(from: element),
            actions: inferredActions(role: stringAttribute(kAXRoleAttribute, from: element)),
            childCount: childCount > 0 ? childCount : nil,
            children: children
        )
    }

    private func childGroups(from element: AXUIElement) -> [(attribute: String, count: Int, elements: [AXUIElement])] {
        let dynamicNames = attributeNames(from: element)
            .filter { !Self.preferredChildAttributes.contains($0) }
            .filter { !Self.excludedChildAttributes.contains($0) }
            .filter { name in
                let lowercased = name.lowercased()
                return lowercased.contains("children")
                    || lowercased.contains("contents")
                    || lowercased.contains("rows")
                    || lowercased.contains("columns")
                    || lowercased.contains("tabs")
                    || lowercased.contains("cells")
            }
        var seenAttributes: Set<String> = []
        var seenElements: Set<UInt> = []
        var groups: [(attribute: String, count: Int, elements: [AXUIElement])] = []
        for attribute in Self.preferredChildAttributes + dynamicNames {
            guard seenAttributes.insert(attribute).inserted else {
                continue
            }
            let values = childElements(attribute, from: element)
            let elements = values.elements.filter { child in
                seenElements.insert(CFHash(child)).inserted
            }
            guard !elements.isEmpty else {
                continue
            }
            groups.append((attribute, values.count, elements))
        }
        return groups
    }

    private func childElements(_ attribute: String, from element: AXUIElement) -> (count: Int, elements: [AXUIElement]) {
        var count: CFIndex = 0
        if AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success, count > 0 {
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0, count, &values) == .success else {
                return (Int(count), [])
            }
            return (Int(count), (values as? [AXUIElement]) ?? [])
        }

        guard let raw = rawAttribute(attribute, from: element) else {
            return (0, [])
        }
        if CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return (1, [unsafeDowncast(raw, to: AXUIElement.self)])
        }
        let elements = (raw as? [AXUIElement]) ?? []
        return (elements.count, elements)
    }

    private func attributeNames(from element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else {
            return []
        }
        return (names as? [String]) ?? []
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        rawAttribute(attribute, from: element) as? String
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        rawAttribute(attribute, from: element) as? Bool
    }

    private func rawAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringValue(_ value: CFTypeRef?) -> String? {
        guard let value else {
            return nil
        }
        switch CFGetTypeID(value) {
        case CFStringGetTypeID():
            return value as? String
        case CFNumberGetTypeID(), CFBooleanGetTypeID():
            return "\(value)"
        default:
            return nil
        }
    }

    private func frame(from element: AXUIElement) -> AXFrame? {
        guard
            let position = rawAttribute(kAXPositionAttribute, from: element),
            let size = rawAttribute(kAXSizeAttribute, from: element),
            CFGetTypeID(position) == AXValueGetTypeID(),
            CFGetTypeID(size) == AXValueGetTypeID()
        else {
            return nil
        }

        var point = CGPoint.zero
        var cgSize = CGSize.zero
        guard
            AXValueGetValue((position as! AXValue), .cgPoint, &point),
            AXValueGetValue((size as! AXValue), .cgSize, &cgSize)
        else {
            return nil
        }
        return AXFrame(x: point.x, y: point.y, width: cgSize.width, height: cgSize.height)
    }

    private func inferredActions(role: String?) -> [String] {
        switch role {
        case "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem":
            return ["AXPress"]
        default:
            return []
        }
    }
}

struct AXHierarchyBulkParser {
    typealias ActionProvider = (AnyObject) -> [String]

    static let scalarAttributes = [
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXTitleAttribute,
        kAXValueAttribute,
        kAXDescriptionAttribute,
        kAXHelpAttribute,
        "AXIdentifier",
        kAXEnabledAttribute,
        kAXFocusedAttribute,
        kAXPositionAttribute,
        kAXSizeAttribute
    ]

    static let childAttributes = [
        kAXWindowsAttribute,
        kAXChildrenAttribute,
        "AXVisibleChildren",
        "AXContents",
        "AXRows",
        "AXColumns",
        "AXTabs",
        "AXCells",
        "AXChildrenInNavigationOrder"
    ]

    private let actionProvider: ActionProvider

    init(actionProvider: @escaping ActionProvider = { _ in [] }) {
        self.actionProvider = actionProvider
    }

    func parse(_ result: NSDictionary) -> AXHierarchyBulkCapture {
        let keys = result.allKeys.compactMap { $0 as AnyObject }
        let referencedKeys = referencedElementKeys(in: result, keys: keys)
        let appKey = keys.first { attributes(for: $0, in: result).flatMap { stringSlot(kAXRoleAttribute, in: $0) } == "AXApplication" }
        let windowKeys = appKey.flatMap { attributes(for: $0, in: result).map { childKeys(kAXWindowsAttribute, in: $0, result: result) } } ?? []
        let topLevelKeys = windowKeys.isEmpty ? inferredWindowRootKeys(in: result, keys: keys, referencedKeys: referencedKeys) : windowKeys
        var retainedElements: [AXUIElement] = []
        var visited = Set<HierarchyObjectKey>()
        let windows = topLevelKeys.compactMap { key in
            node(for: key, in: result, retainedElements: &retainedElements, path: &visited)
        }
        return AXHierarchyBulkCapture(windows: windows, retainedElements: retainedElements)
    }

    private func inferredWindowRootKeys(
        in result: NSDictionary,
        keys: [AnyObject],
        referencedKeys: Set<HierarchyObjectKey>
    ) -> [AnyObject] {
        let unreferenced = keys.filter { !referencedKeys.contains(HierarchyObjectKey($0)) }
        let unreferencedWindows = unreferenced.filter { attributes(for: $0, in: result).flatMap { stringSlot(kAXRoleAttribute, in: $0) } == "AXWindow" }
        if !unreferencedWindows.isEmpty {
            return unreferencedWindows
        }
        let allWindows = keys.filter { attributes(for: $0, in: result).flatMap { stringSlot(kAXRoleAttribute, in: $0) } == "AXWindow" }
        return allWindows.isEmpty ? unreferenced : allWindows
    }

    private func referencedElementKeys(in result: NSDictionary, keys: [AnyObject]) -> Set<HierarchyObjectKey> {
        var referenced = Set<HierarchyObjectKey>()
        for key in keys {
            guard let attributes = attributes(for: key, in: result) else {
                continue
            }
            for attribute in Self.childAttributes {
                for child in childKeys(attribute, in: attributes, result: result) {
                    referenced.insert(HierarchyObjectKey(child))
                }
            }
        }
        return referenced
    }

    private func node(
        for key: AnyObject,
        in result: NSDictionary,
        retainedElements: inout [AXUIElement],
        path: inout Set<HierarchyObjectKey>
    ) -> AXNode? {
        let objectKey = HierarchyObjectKey(key)
        guard !path.contains(objectKey), let attributes = attributes(for: key, in: result) else {
            return nil
        }
        path.insert(objectKey)
        defer { path.remove(objectKey) }

        if let element = AXHierarchyElementBridge.axElement(from: key) {
            retainedElements.append(element)
        }

        var seenChildren = Set<HierarchyObjectKey>()
        var childCount = 0
        var children: [AXNode] = []
        for attribute in Self.childAttributes where attribute != kAXWindowsAttribute {
            let childObjects = childKeys(attribute, in: attributes, result: result)
            childCount += arraySlotCount(attribute, in: attributes) ?? childObjects.count
            for child in childObjects {
                let childKey = HierarchyObjectKey(child)
                guard seenChildren.insert(childKey).inserted else {
                    continue
                }
                if let childNode = node(for: child, in: result, retainedElements: &retainedElements, path: &path) {
                    children.append(childNode)
                }
            }
        }

        return AXNode(
            role: stringSlot(kAXRoleAttribute, in: attributes) ?? "AXUnknown",
            subrole: stringSlot(kAXSubroleAttribute, in: attributes),
            title: stringSlot(kAXTitleAttribute, in: attributes),
            value: stringSlot(kAXValueAttribute, in: attributes),
            description: stringSlot(kAXDescriptionAttribute, in: attributes),
            help: stringSlot(kAXHelpAttribute, in: attributes),
            identifier: stringSlot("AXIdentifier", in: attributes),
            enabled: boolSlot(kAXEnabledAttribute, in: attributes),
            focused: boolSlot(kAXFocusedAttribute, in: attributes),
            frame: frame(in: attributes),
            actions: actionProvider(key),
            childCount: childCount > 0 ? childCount : nil,
            children: children
        )
    }

    private func attributes(for key: AnyObject, in result: NSDictionary) -> NSDictionary? {
        result.object(forKey: key) as? NSDictionary
    }

    private func childKeys(_ attribute: String, in attributes: NSDictionary, result: NSDictionary) -> [AnyObject] {
        guard let values = slotValue(attribute, in: attributes) as? [Any] else {
            return []
        }
        return values.compactMap { child in
            let object = child as AnyObject
            return result.object(forKey: object) == nil ? nil : object
        }
    }

    private func arraySlotCount(_ attribute: String, in attributes: NSDictionary) -> Int? {
        guard
            let slot = attributes.object(forKey: attribute) as? NSDictionary,
            let count = slot.object(forKey: "count") as? NSNumber
        else {
            return nil
        }
        return count.intValue
    }

    private func stringSlot(_ attribute: String, in attributes: NSDictionary) -> String? {
        guard let value = slotValue(attribute, in: attributes) else {
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

    private func boolSlot(_ attribute: String, in attributes: NSDictionary) -> Bool? {
        guard let value = slotValue(attribute, in: attributes) else {
            return nil
        }
        if let bool = value as? Bool {
            return bool
        }
        return (value as? NSNumber)?.boolValue
    }

    private func slotValue(_ attribute: String, in attributes: NSDictionary) -> AnyObject? {
        guard let slot = attributes.object(forKey: attribute) else {
            return nil
        }
        if let dictionary = slot as? NSDictionary {
            return dictionary.object(forKey: "value") as AnyObject?
        }
        return slot as AnyObject
    }

    private func frame(in attributes: NSDictionary) -> AXFrame? {
        guard let positionRaw = slotValue(kAXPositionAttribute, in: attributes),
              let sizeRaw = slotValue(kAXSizeAttribute, in: attributes),
              CFGetTypeID(positionRaw as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw as CFTypeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        let position = positionRaw as! AXValue
        let size = sizeRaw as! AXValue
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
}

private struct HierarchyObjectKey: Hashable {
    private let object: AnyObject
    private let cachedHash: Int

    init(_ object: AnyObject) {
        self.object = object
        self.cachedHash = (object as? NSObject)?.hash ?? ObjectIdentifier(object).hashValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(cachedHash)
    }

    static func == (lhs: HierarchyObjectKey, rhs: HierarchyObjectKey) -> Bool {
        if lhs.object === rhs.object {
            return true
        }
        if let lhs = lhs.object as? NSObject {
            return lhs.isEqual(rhs.object)
        }
        return false
    }
}

private enum AXHierarchyElementBridge {
    private static let systemWideTypeID = CFGetTypeID(AXUIElementCreateSystemWide())

    static func axElement(from object: AnyObject) -> AXUIElement? {
        guard CFGetTypeID(object as CFTypeRef) == systemWideTypeID else {
            return nil
        }
        return (object as! AXUIElement)
    }
}

private extension AXNode {
    var deepNodeCount: Int {
        1 + children.reduce(0) { $0 + $1.deepNodeCount }
    }

    func containsRole(_ expectedRole: String) -> Bool {
        role == expectedRole || children.contains { $0.containsRole(expectedRole) }
    }

    func withInferredActions() -> AXNode {
        AXNode(
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
            actions: actions.isEmpty ? Self.inferredActions(role: role) : actions,
            childCount: childCount,
            truncationReason: truncationReason,
            children: children.map { $0.withInferredActions() }
        )
    }

    static func inferredActions(role: String?) -> [String] {
        switch role {
        case "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem":
            return ["AXPress"]
        default:
            return []
        }
    }
}

struct AXUIElementCopyHierarchyLoader {
    typealias CopyHierarchy = @convention(c) (AXUIElement, CFArray, CFDictionary?, UnsafeMutablePointer<CFTypeRef?>) -> AXError

    let copyHierarchy: CopyHierarchy
    let arrayAttributesKey: CFString
    let maxArrayCountKey: CFString
    let maxDepthKey: CFString
    let truncateStringsKey: CFString
    let returnAttributeErrorsKey: CFString

    static func load() -> AXUIElementCopyHierarchyLoader? {
        guard
            let handle = dlopen(nil, RTLD_LAZY),
            let function = dlsym(handle, "AXUIElementCopyHierarchy"),
            let arrayAttributesKey = cfString(named: "kAXUIElementCopyHierarchyArrayAttributesKey", in: handle),
            let maxArrayCountKey = cfString(named: "kAXUIElementCopyHierarchyMaxArrayCountKey", in: handle),
            let maxDepthKey = cfString(named: "kAXUIElementCopyHierarchyMaxDepthKey", in: handle),
            let truncateStringsKey = cfString(named: "kAXUIElementCopyHierarchyTruncateStringsKey", in: handle),
            let returnAttributeErrorsKey = cfString(named: "kAXUIElementCopyHierarchyReturnAttributeErrorsKey", in: handle)
        else {
            return nil
        }

        return AXUIElementCopyHierarchyLoader(
            copyHierarchy: unsafeBitCast(function, to: CopyHierarchy.self),
            arrayAttributesKey: arrayAttributesKey,
            maxArrayCountKey: maxArrayCountKey,
            maxDepthKey: maxDepthKey,
            truncateStringsKey: truncateStringsKey,
            returnAttributeErrorsKey: returnAttributeErrorsKey
        )
    }

    private static func cfString(named symbol: String, in handle: UnsafeMutableRawPointer) -> CFString? {
        guard let pointer = dlsym(handle, symbol) else {
            return nil
        }
        return pointer.assumingMemoryBound(to: CFString.self).pointee
    }
}
