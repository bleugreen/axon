import ApplicationServices
import Foundation

public enum AXElementStoreError: Error, CustomStringConvertible {
    case invalidHandle(String)
    case missingSnapshot(SnapshotID)
    case missingElement(SnapshotHandle)

    public var description: String {
        switch self {
        case let .invalidHandle(value):
            return "Invalid snapshot handle: \(value)"
        case let .missingSnapshot(snapshotID):
            return "Snapshot is not retained: \(snapshotID.rawValue)"
        case let .missingElement(handle):
            return "Snapshot element is not retained: \(handle.rawValue)"
        }
    }
}

public final class AXElementStore: @unchecked Sendable {
    public static let defaultMaxSnapshots = 32

    private let lock = NSLock()
    private let maxSnapshots: Int
    private var elementsBySnapshot: [SnapshotID: [AXUIElement]] = [:]
    private var summariesBySnapshot: [SnapshotID: SnapshotSummary] = [:]
    private var snapshotOrder: [SnapshotID] = []

    public convenience init() {
        self.init(maxSnapshots: AXElementStore.defaultMaxSnapshots)
    }

    public init(maxSnapshots: Int) {
        self.maxSnapshots = max(1, maxSnapshots)
    }

    public func store(snapshotID: SnapshotID, elements: [AXUIElement]) {
        store(snapshotID: snapshotID, elements: elements, summary: nil)
    }

    public func store(snapshotID: SnapshotID, elements: [AXUIElement], summary: SnapshotSummary?) {
        lock.lock()
        defer { lock.unlock() }

        elementsBySnapshot[snapshotID] = elements
        if let summary {
            summariesBySnapshot[snapshotID] = summary
        }
        snapshotOrder.removeAll { $0 == snapshotID }
        snapshotOrder.append(snapshotID)
        pruneOldSnapshots()
    }

    public func store(summary: SnapshotSummary) {
        lock.lock()
        defer { lock.unlock() }

        summariesBySnapshot[summary.id] = summary
        snapshotOrder.removeAll { $0 == summary.id }
        snapshotOrder.append(summary.id)
        pruneOldSnapshots()
    }

    public func append(snapshotID: SnapshotID, elements newElements: [AXUIElement]) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard var elements = elementsBySnapshot[snapshotID] else {
            throw AXElementStoreError.missingSnapshot(snapshotID)
        }
        let baseIndex = elements.count
        elements.append(contentsOf: newElements)
        elementsBySnapshot[snapshotID] = elements
        snapshotOrder.removeAll { $0 == snapshotID }
        snapshotOrder.append(snapshotID)
        pruneOldSnapshots()
        return baseIndex
    }

    public func element(for target: String) throws -> AXUIElement {
        let handle: SnapshotHandle
        do {
            handle = try SnapshotHandle(target)
        } catch {
            throw AXElementStoreError.invalidHandle(target)
        }
        return try element(for: handle)
    }

    public func element(for handle: SnapshotHandle) throws -> AXUIElement {
        lock.lock()
        defer { lock.unlock() }

        guard let elements = elementsBySnapshot[handle.snapshotID] else {
            throw AXElementStoreError.missingSnapshot(handle.snapshotID)
        }
        guard elements.indices.contains(handle.nodeIndex) else {
            throw AXElementStoreError.missingElement(handle)
        }
        return elements[handle.nodeIndex]
    }

    public func summary(for snapshotID: SnapshotID) throws -> SnapshotSummary {
        lock.lock()
        defer { lock.unlock() }

        guard let summary = summariesBySnapshot[snapshotID] else {
            throw AXElementStoreError.missingSnapshot(snapshotID)
        }
        return summary
    }

    private func pruneOldSnapshots() {
        while snapshotOrder.count > maxSnapshots {
            let evicted = snapshotOrder.removeFirst()
            elementsBySnapshot.removeValue(forKey: evicted)
            summariesBySnapshot.removeValue(forKey: evicted)
        }
    }
}
