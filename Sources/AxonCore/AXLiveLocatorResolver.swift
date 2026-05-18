import ApplicationServices
import AppKit
import Foundation

public final class AXLiveLocatorResolver: @unchecked Sendable {
    private let appResolver: AppResolver
    private let elementStore: AXElementStore
    private let messagingTimeout: Float
    private let cacheTTL: TimeInterval
    private let cacheLock = NSLock()
    private var cache: [String: CachedElement] = [:]

    private static let wideScopeRoles: Set<String> = [
        "AXWebArea",
        "AXTable",
        "AXOutline",
        "AXScrollArea"
    ]

    public init(
        appResolver: AppResolver = AppResolver(),
        elementStore: AXElementStore,
        messagingTimeout: Float = AXSnapshotCapturer.defaultMessagingTimeout,
        cacheTTL: TimeInterval = 30
    ) {
        self.appResolver = appResolver
        self.elementStore = elementStore
        self.messagingTimeout = messagingTimeout
        self.cacheTTL = cacheTTL
    }

    public func resolve(app query: String, locator: AXLocator, scrollToVisible: Bool = false) throws -> LocatorResolution {
        if let cached = cachedElement(app: query, locator: locator) {
            if let resolution = fastResolution(app: query, locator: locator, candidateElements: [cached], cacheResult: false) {
                debug("cache hit")
                if scrollToVisible,
                   let handle = resolution.best?.handle,
                   let element = try? elementStore.element(for: handle) {
                    scrollElementToVisible(element)
                }
                return resolution
            }
            debug("cache entry failed validation")
        }

        if let resolution = try resolveFast(app: query, locator: locator, scrollToVisible: scrollToVisible) {
            return resolution
        }

        let capture = try capture(app: query)
        let resolution = LocatorResolver().resolve(locator, in: capture.snapshot)

        if scrollToVisible,
           resolution.status == .unique,
           let index = resolution.best?.handle?.nodeIndex,
           capture.elements.indices.contains(index) {
            scrollElementToVisible(capture.elements[index])
        }
        if resolution.status == .unique,
           let index = resolution.best?.handle?.nodeIndex,
           capture.elements.indices.contains(index) {
            storeCachedElement(capture.elements[index], app: query, locator: locator)
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

    private func resolveFast(app query: String, locator: AXLocator, scrollToVisible: Bool) throws -> LocatorResolution? {
        guard AccessibilityPermission.isTrusted() else {
            throw SnapshotCaptureError.missingAccessibilityPermission
        }

        let app = try appResolver.resolve(query)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        let windows = elements(attribute: kAXWindowsAttribute, from: appElement)
        guard !windows.isEmpty else {
            return nil
        }

        let scopes = scopesForFastResolution(windows: windows, locator: locator)
        debug("fast scopes: \(scopes.count)")
        for scope in scopes {
            debug("scope role=\(nodeSummary(for: scope.element).role) search=\(supportsSearchPredicate(scope.element))")
            if supportsSearchPredicate(scope.element),
               let searchText = searchText(for: locator),
               let searchKey = searchKey(for: locator),
               let result = predicateResolution(
                   app: query,
                   locator: locator,
                   scope: scope,
                   searchKey: searchKey,
                   searchText: searchText,
                   scrollToVisible: scrollToVisible
               ) {
                return result
            }
        }

        let candidateElements = scopes.flatMap { boundedDescendants(of: $0.element, limit: 250) }
        debug("bounded candidates: \(candidateElements.count)")
        if let result = fastResolution(app: query, locator: locator, candidateElements: candidateElements, cacheResult: true) {
            if scrollToVisible,
               result.status == .unique,
               let handle = result.best?.handle,
               let element = try? elementStore.element(for: handle) {
                scrollElementToVisible(element)
            }
            return result
        }

        return nil
    }

    private func scopesForFastResolution(windows: [AXUIElement], locator: AXLocator) -> [ScopedElement] {
        if !locator.ancestors.isEmpty {
            let narrowed = narrowScopes(from: windows, ancestors: locator.ancestors)
            if !narrowed.isEmpty {
                return narrowed
            }
        }

        let searchableScopes = windows.flatMap { window in
            [ScopedElement(element: window, ancestors: [])] + boundedDescendants(of: window, limit: 120)
                .map { element in ScopedElement(element: element, ancestors: []) }
                .filter { scope in
                    Self.wideScopeRoles.contains(nodeSummary(for: scope.element).role) || supportsSearchPredicate(scope.element)
                }
        }
        return searchableScopes.isEmpty ? windows.map { ScopedElement(element: $0, ancestors: []) } : searchableScopes
    }

    private func narrowScopes(from windows: [AXUIElement], ancestors: [AXAncestorLocator]) -> [ScopedElement] {
        var scopes = windows.map { ScopedElement(element: $0, ancestors: []) }
        for ancestor in ancestors {
            var nextScopes: [ScopedElement] = []
            for scope in scopes {
                let scopeNode = nodeSummary(for: scope.element)
                if ancestor.matches(scopeNode) {
                    nextScopes.append(ScopedElement(element: scope.element, ancestors: scope.ancestors))
                    continue
                }
                for match in matchingDescendants(of: scope.element, ancestor: ancestor, maxDepth: 8, maxVisited: 500) {
                    nextScopes.append(ScopedElement(element: match, ancestors: scope.ancestors + [scope.element]))
                }
            }
            scopes = deduplicated(nextScopes)
            if scopes.isEmpty {
                return []
            }
        }
        return scopes
    }

    private func predicateResolution(
        app query: String,
        locator: AXLocator,
        scope: ScopedElement,
        searchKey: String,
        searchText: String,
        scrollToVisible: Bool
    ) -> LocatorResolution? {
        let params: [String: Any] = [
            "AXSearchKey": searchKey,
            "AXSearchText": searchText,
            "AXResultsLimit": 8
        ]
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            scope.element,
            "AXUIElementsForSearchPredicate" as CFString,
            params as CFDictionary,
            &result
        ) == .success else {
            return nil
        }
        guard let elements = result as? [AXUIElement], !elements.isEmpty else {
            debug("predicate empty for \(searchKey) \(searchText)")
            return nil
        }
        debug("predicate returned \(elements.count) for \(searchKey) \(searchText)")

        guard let resolution = fastResolution(app: query, locator: locator, candidateElements: elements, cacheResult: true) else {
            return nil
        }
        if scrollToVisible,
           resolution.status == .unique,
           let handle = resolution.best?.handle,
           let element = try? elementStore.element(for: handle) {
            scrollElementToVisible(element)
        }
        return resolution
    }

    private func fastResolution(
        app query: String,
        locator: AXLocator,
        candidateElements: [AXUIElement],
        cacheResult: Bool
    ) -> LocatorResolution? {
        let appIdentity: AppIdentity
        do {
            appIdentity = try appResolver.resolveIdentity(query)
        } catch {
            return nil
        }

        var matches: [(element: AXUIElement, candidate: LocatorCandidate)] = []
        for element in deduplicated(candidateElements) {
            let capture = miniCapture(app: appIdentity, leaf: element)
            let resolution = LocatorResolver().resolve(locator, in: capture.snapshot)
            guard resolution.status == .unique,
                  let best = resolution.best,
                  best.index == capture.elements.count - 1
            else {
                continue
            }
            matches.append((element, best))
        }
        debug("fast matches: \(matches.count) of \(candidateElements.count)")

        guard !matches.isEmpty else {
            return nil
        }

        let snapshotID = SnapshotID.next()
        let nodes = matches.map { nodeSummary(for: $0.element) }
        let elements = matches.map(\.element)
        let snapshot = AppSnapshot(id: snapshotID, app: appIdentity, windows: nodes, screenshot: nil)
        elementStore.store(
            snapshotID: snapshotID,
            elements: elements,
            summary: SnapshotSummary(snapshot: snapshot)
        )
        let candidates = matches.enumerated().map { offset, match in
            LocatorCandidate(
                index: offset,
                handle: SnapshotHandle(snapshotID: snapshotID, nodeIndex: offset),
                role: match.candidate.role,
                title: match.candidate.title,
                frame: match.candidate.frame,
                score: match.candidate.score,
                reasons: match.candidate.reasons
            )
        }

        if candidates.count == 1, cacheResult {
            storeCachedElement(elements[0], app: query, locator: locator)
        }

        return LocatorResolution(
            status: candidates.count == 1 ? .unique : .ambiguous,
            snapshotID: snapshotID,
            best: candidates.count == 1 ? candidates[0] : nil,
            candidates: candidates
        )
    }

    private func miniCapture(app: AppIdentity, leaf: AXUIElement) -> LiveLocatorCapture {
        let rootToLeaf = elementPath(to: leaf)
        let nodes = rootToLeaf.map(nodeSummary)
        let nested = nest(nodes)
        let snapshot = AppSnapshot(
            id: SnapshotID.next(),
            app: app,
            windows: nested.map { $0 },
            screenshot: nil
        )
        return LiveLocatorCapture(snapshot: snapshot, elements: rootToLeaf)
    }

    private func nest(_ nodes: [AXNode]) -> [AXNode] {
        guard let first = nodes.first else {
            return []
        }
        var nested = nodes.last!
        if nodes.count > 1 {
            for node in nodes.dropLast().reversed() {
                nested = AXNode(
                    role: node.role,
                    subrole: node.subrole,
                    title: node.title,
                    value: node.value,
                    description: node.description,
                    help: node.help,
                    identifier: node.identifier,
                    enabled: node.enabled,
                    focused: node.focused,
                    frame: node.frame,
                    actions: node.actions,
                    truncationReason: node.truncationReason,
                    children: [nested]
                )
            }
            return [nested]
        }
        return [first]
    }

    private func elementPath(to leaf: AXUIElement) -> [AXUIElement] {
        var reversed: [AXUIElement] = []
        var current: AXUIElement? = leaf
        for _ in 0..<16 {
            guard let element = current else {
                break
            }
            reversed.append(element)
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parentElement = parent,
                  CFGetTypeID(parentElement) == AXUIElementGetTypeID()
            else {
                break
            }
            current = (parentElement as! AXUIElement)
        }
        return Array(reversed.reversed())
    }

    private func matchingDescendants(
        of element: AXUIElement,
        ancestor: AXAncestorLocator,
        maxDepth: Int,
        maxVisited: Int
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue = children(of: element).map { ($0, 1) }
        var visited = 0
        while !queue.isEmpty, visited < maxVisited {
            let (next, depth) = queue.removeFirst()
            visited += 1
            if ancestor.matches(nodeSummary(for: next)) {
                result.append(next)
            }
            if depth < maxDepth {
                queue.append(contentsOf: children(of: next).map { ($0, depth + 1) })
            }
        }
        return result
    }

    private func boundedDescendants(of element: AXUIElement, limit: Int) -> [AXUIElement] {
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
        elements(attribute: kAXChildrenAttribute, from: element)
    }

    private func supportsSearchPredicate(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success,
              let values = names as? [String]
        else {
            return false
        }
        return values.contains("AXUIElementsForSearchPredicate")
    }

    private func searchKey(for locator: AXLocator) -> String? {
        switch locator.role {
        case "AXLink":
            return "AXLinkSearchKey"
        case "AXButton":
            return "AXButtonSearchKey"
        case "AXTextField", "AXTextArea":
            return "AXTextFieldSearchKey"
        case "AXStaticText":
            return "AXStaticTextSearchKey"
        case "AXCheckBox":
            return "AXCheckBoxSearchKey"
        case "AXRadioButton":
            return "AXControlSearchKey"
        default:
            return locator.role == nil ? "AXAnyTypeSearchKey" : "AXControlSearchKey"
        }
    }

    private func searchText(for locator: AXLocator) -> String? {
        for matcher in [locator.title, locator.label, locator.value, locator.description, locator.identifier] {
            if let text = matcher?.searchText, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func nodeSummary(for element: AXUIElement) -> AXNode {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
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
            actions: actionNames(for: element)
        )
    }

    private func deduplicated(_ elements: [AXUIElement]) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var seen = Set<UInt>()
        for element in elements {
            let key = CFHash(element)
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(element)
        }
        return result
    }

    private func deduplicated(_ scopes: [ScopedElement]) -> [ScopedElement] {
        var result: [ScopedElement] = []
        var seen = Set<UInt>()
        for scope in scopes {
            let key = CFHash(scope.element)
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(scope)
        }
        return result
    }

    private func cachedElement(app: String, locator: AXLocator) -> AXUIElement? {
        let key = cacheKey(app: app, locator: locator)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = cache[key] else {
            debug("cache miss entries=\(cache.count)")
            return nil
        }
        if entry.expiresAt < Date() {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.element
    }

    private func storeCachedElement(_ element: AXUIElement, app: String, locator: AXLocator) {
        let key = cacheKey(app: app, locator: locator)
        cacheLock.lock()
        cache[key] = CachedElement(element: element, expiresAt: Date().addingTimeInterval(cacheTTL))
        let count = cache.count
        cacheLock.unlock()
        debug("cache store entries=\(count)")
    }

    private func cacheKey(app: String, locator: AXLocator) -> String {
        var parts: [String] = ["app=\(app)"]
        parts.append("role=\(locator.role ?? "")")
        parts.append("subrole=\(locator.subrole ?? "")")
        parts.append("title=\(locator.title?.cacheFragment ?? "")")
        parts.append("label=\(locator.label?.cacheFragment ?? "")")
        parts.append("value=\(locator.value?.cacheFragment ?? "")")
        parts.append("description=\(locator.description?.cacheFragment ?? "")")
        parts.append("identifier=\(locator.identifier?.cacheFragment ?? "")")
        parts.append("actions=\(locator.actions.joined(separator: ","))")
        for ancestor in locator.ancestors {
            parts.append([
                "ancestor",
                ancestor.role ?? "",
                ancestor.subrole ?? "",
                ancestor.identifier?.cacheFragment ?? "",
                ancestor.title?.cacheFragment ?? "",
                ancestor.label?.cacheFragment ?? ""
            ].joined(separator: ":"))
        }
        return parts.joined(separator: "\n")
    }

    private func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["AXON_LOCATOR_DEBUG"] == "1" else {
            return
        }
        FileHandle.standardError.write(Data("[locator] \(message)\n".utf8))
    }
}

private struct LiveLocatorCapture {
    let snapshot: AppSnapshot
    let elements: [AXUIElement]
}

private struct ScopedElement {
    let element: AXUIElement
    let ancestors: [AXUIElement]
}

private struct CachedElement {
    let element: AXUIElement
    let expiresAt: Date
}

private extension TextMatch {
    var searchText: String {
        switch self {
        case let .exact(value, _), let .contains(value, _):
            return value
        }
    }

    var cacheFragment: String {
        switch self {
        case let .exact(value, caseSensitive):
            return "exact:\(caseSensitive):\(value)"
        case let .contains(value, caseSensitive):
            return "contains:\(caseSensitive):\(value)"
        }
    }
}
