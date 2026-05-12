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
    private let lock = NSLock()
    private var elementsBySnapshot: [SnapshotID: [AXUIElement]] = [:]

    public init() {}

    public func store(snapshotID: SnapshotID, elements: [AXUIElement]) {
        lock.lock()
        elementsBySnapshot[snapshotID] = elements
        lock.unlock()
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
}

