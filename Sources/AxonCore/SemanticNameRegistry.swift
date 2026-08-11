import Foundation

public struct SemanticTargetQuery: Codable, Equatable, Hashable, Sendable {
    public let app: String
    public let name: String

    public init(app: String, name: String) {
        self.app = app
        self.name = name
    }
}

public struct SemanticNameRecord: Equatable, Sendable {
    public let query: SemanticTargetQuery
    public let appIdentity: AppIdentity
    public let snapshotID: SnapshotID
    public let sourceIndex: Int
    public let role: String
    public let label: String
    public let candidateLabel: String?
    public let locator: AXLocator
    /// Snapshot handles are an internal cache hint. They are deliberately absent from Codable/public JSON models.
    let retainedHandle: SnapshotHandle?
}

public enum SemanticNameLookup: Equatable, Sendable {
    case unique(SemanticNameRecord)
    case missing(SemanticTargetQuery)
    case ambiguous(SemanticTargetQuery, [SemanticNameRecord])
}

/// App-process-scoped semantic identity captured at observation time.
///
/// The registry follows snapshot retention rather than wall-clock time. Registering a relaunched app
/// atomically removes records for the previous process, and pruning a snapshot removes every name whose
/// durable evidence was derived from it.
public final class SemanticNameRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let maxSnapshots: Int
    private var recordsBySnapshot: [SnapshotID: [SemanticNameRecord]] = [:]
    private var snapshotOrder: [SnapshotID] = []
    private var processByAppKey: [String: Int32] = [:]

    public init(maxSnapshots: Int = AXElementStore.defaultMaxSnapshots) {
        self.maxSnapshots = max(1, maxSnapshots)
    }

    @discardableResult
    public func register(snapshot: AppSnapshot) -> [SemanticNameRecord] {
        let study = SemanticNameDeriver.derive(from: snapshot.jsonValue(includeTree: true))
        let contexts = Self.nodeContexts(in: snapshot)
        let records = study.elements.compactMap { element -> SemanticNameRecord? in
            guard let context = contexts[element.sourceIndex],
                  let locator = try? AXLocator(jsonValue: .object(RecordedLocatorBuilder.locator(
                    from: context.node,
                    ancestors: context.ancestors,
                    windowTitle: context.windowTitle
                  ))) else { return nil }
            return SemanticNameRecord(
                query: SemanticTargetQuery(app: snapshot.app.name, name: element.name),
                appIdentity: snapshot.app,
                snapshotID: snapshot.id,
                sourceIndex: element.sourceIndex,
                role: element.role,
                label: element.label,
                candidateLabel: element.candidateLabel,
                locator: locator,
                retainedHandle: snapshot.handle(for: element.sourceIndex)
            )
        }

        lock.lock()
        defer { lock.unlock() }
        invalidateRelaunchedApp(snapshot.app)
        recordsBySnapshot[snapshot.id] = records
        snapshotOrder.removeAll { $0 == snapshot.id }
        snapshotOrder.append(snapshot.id)
        for key in Self.appKeys(snapshot.app) { processByAppKey[key] = snapshot.app.processIdentifier }
        pruneOldSnapshots()
        return records
    }

    @discardableResult
    public func register(page: AXChildrenPage, app: AppIdentity) -> [SemanticNameRecord] {
        let snapshot = AppSnapshot(id: page.snapshotID, app: app, windows: page.children, screenshot: nil)
        let study = SemanticNameDeriver.derive(from: snapshot.jsonValue(includeTree: true))
        let contexts = Self.nodeContexts(in: snapshot)
        let records = study.elements.compactMap { element -> SemanticNameRecord? in
            guard let context = contexts[element.sourceIndex],
                  let locator = try? AXLocator(jsonValue: .object(RecordedLocatorBuilder.locator(
                    from: context.node, ancestors: context.ancestors, windowTitle: context.windowTitle
                  ))) else { return nil }
            return SemanticNameRecord(
                query: SemanticTargetQuery(app: app.name, name: element.name), appIdentity: app,
                snapshotID: page.snapshotID, sourceIndex: page.baseIndex + element.sourceIndex,
                role: element.role, label: element.label, candidateLabel: element.candidateLabel,
                locator: locator,
                retainedHandle: SnapshotHandle(snapshotID: page.snapshotID, nodeIndex: page.baseIndex + element.sourceIndex)
            )
        }
        lock.lock()
        defer { lock.unlock() }
        let existing = recordsBySnapshot[page.snapshotID] ?? []
        recordsBySnapshot[page.snapshotID] = existing + records
        return records
    }

    public func registerReplayEvidence(app: String, name: String, locator: AXLocator) {
        let role = locator.role ?? "unknown"
        let label = locator.label ?? locator.title ?? locator.description ?? name
        let record = SemanticNameRecord(
            query: SemanticTargetQuery(app: app, name: name),
            appIdentity: AppIdentity(bundleIdentifier: nil, name: app, processIdentifier: 0),
            snapshotID: SnapshotID("replay"), sourceIndex: -1, role: role, label: label,
            candidateLabel: nil, locator: locator, retainedHandle: nil
        )
        lock.lock()
        defer { lock.unlock() }
        var records = recordsBySnapshot[record.snapshotID] ?? []
        records.removeAll { $0.query == record.query }
        records.append(record)
        recordsBySnapshot[record.snapshotID] = records
        snapshotOrder.removeAll { $0 == record.snapshotID }
        snapshotOrder.append(record.snapshotID)
        pruneOldSnapshots()
    }

    public func lookup(app: String, name: String) -> SemanticNameLookup {
        let query = SemanticTargetQuery(app: app, name: name)
        lock.lock()
        defer { lock.unlock() }
        let matches = snapshotOrder.reversed().flatMap { recordsBySnapshot[$0] ?? [] }.filter {
            Self.matches(app, identity: $0.appIdentity) && $0.query.name == name
        }
        guard let newestSnapshot = matches.first?.snapshotID else { return .missing(query) }
        let newest = matches.filter { $0.snapshotID == newestSnapshot }
        return newest.count == 1 ? .unique(newest[0]) : .ambiguous(query, newest)
    }

    public func remove(snapshotID: SnapshotID) {
        lock.lock()
        defer { lock.unlock() }
        recordsBySnapshot.removeValue(forKey: snapshotID)
        snapshotOrder.removeAll { $0 == snapshotID }
    }

    private func invalidateRelaunchedApp(_ app: AppIdentity) {
        let changed = Self.appKeys(app).contains { key in
            processByAppKey[key].map { $0 != app.processIdentifier } ?? false
        }
        guard changed else { return }
        let stale = recordsBySnapshot.compactMap { snapshotID, records in
            records.contains(where: { Self.matches(app.name, identity: $0.appIdentity) }) ? snapshotID : nil
        }
        stale.forEach { recordsBySnapshot.removeValue(forKey: $0) }
        snapshotOrder.removeAll { stale.contains($0) }
    }

    private func pruneOldSnapshots() {
        while snapshotOrder.count > maxSnapshots {
            recordsBySnapshot.removeValue(forKey: snapshotOrder.removeFirst())
        }
    }

    private static func appKeys(_ app: AppIdentity) -> [String] {
        [app.name.lowercased(), app.bundleIdentifier?.lowercased()].compactMap { $0 }
    }

    private static func matches(_ query: String, identity: AppIdentity) -> Bool {
        appKeys(identity).contains(query.lowercased())
    }

    private struct NodeContext {
        let node: AXNode
        let ancestors: [AXNode]
        let windowTitle: String?
    }

    private static func nodeContexts(in snapshot: AppSnapshot) -> [Int: NodeContext] {
        var result: [Int: NodeContext] = [:]
        var index = 0
        func visit(_ node: AXNode, ancestors: [AXNode], windowTitle: String?) {
            result[index] = NodeContext(node: node, ancestors: ancestors, windowTitle: windowTitle)
            index += 1
            for child in node.children { visit(child, ancestors: ancestors + [node], windowTitle: windowTitle) }
        }
        for window in snapshot.windows { visit(window, ancestors: [], windowTitle: window.title) }
        return result
    }
}