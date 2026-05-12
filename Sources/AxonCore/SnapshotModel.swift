import Foundation

public struct SnapshotID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct AppIdentity: Codable, Equatable, Sendable {
    public let bundleIdentifier: String?
    public let name: String
    public let processIdentifier: Int32

    public init(bundleIdentifier: String?, name: String, processIdentifier: Int32) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.processIdentifier = processIdentifier
    }
}

public struct EncodedScreenshot: Codable, Equatable, Sendable {
    public let mediaType: String
    public let base64Data: String
    public let width: Int
    public let height: Int

    public init(mediaType: String, base64Data: String, width: Int, height: Int) {
        self.mediaType = mediaType
        self.base64Data = base64Data
        self.width = width
        self.height = height
    }
}

public struct AppSnapshot: Codable, Equatable, Sendable {
    public let id: SnapshotID
    public let app: AppIdentity
    public let windows: [AXNode]
    public let screenshot: EncodedScreenshot?

    public init(id: SnapshotID, app: AppIdentity, windows: [AXNode], screenshot: EncodedScreenshot?) {
        self.id = id
        self.app = app
        self.windows = windows
        self.screenshot = screenshot
    }

    public var indexedNodes: [IndexedAXNode] {
        var nodes: [IndexedAXNode] = []
        for window in windows {
            append(window, to: &nodes)
        }
        return nodes
    }

    public func handle(for nodeIndex: Int) -> SnapshotHandle? {
        guard indexedNodes.indices.contains(nodeIndex) else {
            return nil
        }
        return SnapshotHandle(snapshotID: id, nodeIndex: nodeIndex)
    }

    private func append(_ node: AXNode, to nodes: inout [IndexedAXNode]) {
        let index = nodes.count
        nodes.append(IndexedAXNode(index: index, node: node))
        for child in node.children {
            append(child, to: &nodes)
        }
    }
}

public struct IndexedAXNode: Codable, Equatable, Sendable {
    public let index: Int
    public let node: AXNode
}

public struct AXNode: Codable, Equatable, Sendable {
    public let role: String
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let description: String?
    public let help: String?
    public let identifier: String?
    public let enabled: Bool?
    public let focused: Bool?
    public let frame: AXFrame?
    public let actions: [String]
    public let truncationReason: String?
    public let children: [AXNode]

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        help: String? = nil,
        identifier: String? = nil,
        enabled: Bool? = nil,
        focused: Bool? = nil,
        frame: AXFrame? = nil,
        actions: [String] = [],
        truncationReason: String? = nil,
        children: [AXNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.help = help
        self.identifier = identifier
        self.enabled = enabled
        self.focused = focused
        self.frame = frame
        self.actions = actions
        self.truncationReason = truncationReason
        self.children = children
    }
}

public struct AXFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public extension AXNode {
    func withAdditionalTruncationReason(_ reason: String) -> AXNode {
        let combinedReason: String
        if let truncationReason, !truncationReason.isEmpty {
            combinedReason = "\(truncationReason); \(reason)"
        } else {
            combinedReason = reason
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
            truncationReason: combinedReason,
            children: children
        )
    }
}

public struct SnapshotHandle: Codable, Equatable, Sendable {
    public enum ParseError: Error {
        case invalidFormat
        case invalidIndex
    }

    public let snapshotID: SnapshotID
    public let nodeIndex: Int

    public var rawValue: String {
        "snapshot:\(snapshotID.rawValue):\(nodeIndex)"
    }

    public init(snapshotID: SnapshotID, nodeIndex: Int) {
        self.snapshotID = snapshotID
        self.nodeIndex = nodeIndex
    }

    public init(_ rawValue: String) throws {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "snapshot", !parts[1].isEmpty else {
            throw ParseError.invalidFormat
        }
        guard let index = Int(parts[2]) else {
            throw ParseError.invalidIndex
        }
        self.snapshotID = SnapshotID(String(parts[1]))
        self.nodeIndex = index
    }
}
