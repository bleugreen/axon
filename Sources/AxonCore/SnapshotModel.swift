import Foundation

public struct SnapshotID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    private static let sequence = SnapshotIDSequence()

    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func next() -> SnapshotID {
        SnapshotID("s\(sequence.next())")
    }
}

public enum FocusObservation: Codable, Equatable, Sendable {
    case available(element: AXNode, handle: SnapshotHandle?)
    case none
    case inaccessible(error: String)
}

private final class SnapshotIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
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
    /// The screen-space frame of the window this image depicts, as of capture.
    ///
    /// Capture chooses one window out of the application's several, and every coordinate derived
    /// from the image — an OCR box, a screenshot-space point — is only meaningful against that
    /// window's origin. Recording the frame here is what lets a consumer convert through the window
    /// that was actually photographed instead of re-guessing one from the accessibility tree, where
    /// a different choice lands coordinates in a window the image never showed.
    ///
    /// Optional because a screenshot decoded from a recording made before this field existed cannot
    /// state it. A consumer that needs it must decline rather than substitute a guess.
    public let sourceWindowFrame: AXFrame?

    public init(
        mediaType: String,
        base64Data: String,
        width: Int,
        height: Int,
        sourceWindowFrame: AXFrame? = nil
    ) {
        self.mediaType = mediaType
        self.base64Data = base64Data
        self.width = width
        self.height = height
        self.sourceWindowFrame = sourceWindowFrame
    }
}

/// Stable machine-readable statements an observation carries about itself.
///
/// A note states a fact the tree cannot state, so a caller branches on the note rather than on
/// the tree's shape.
public enum ObservationNote {
    /// The captured application is running with no open top-level window.
    public static let noWindows = "no-windows"
}

/// What capture learned about an application's open top-level windows.
///
/// A failed query is a separate case from a count of zero, for the reason `FocusObservation`
/// separates `none` from `inaccessible`: an accessibility query that did not answer is not
/// evidence about the application. A windowed application that was busy enough to time out must
/// not be reported as having no window, so only `counted(0)` ever states `ObservationNote.noWindows`.
public enum WindowCountObservation: Codable, Equatable, Sendable {
    /// The application answered the window query with this many top-level windows.
    case counted(Int)
    /// The window query itself failed, so the window count is unknown.
    case inaccessible

    /// The answered count, or `nil` when the query did not answer.
    public var count: Int? {
        guard case let .counted(count) = self else {
            return nil
        }
        return count
    }
}

public struct AppSnapshot: Codable, Equatable, Sendable {
    public let id: SnapshotID
    public let app: AppIdentity
    public let windows: [AXNode]
    /// What the application itself said about how many top-level windows it has open.
    ///
    /// Deliberately not derived from `windows`. When an application exposes no windows, capture
    /// still roots the tree at its application-level chrome — the menu bar — because that chrome
    /// is how a caller opens a window again. Only this answer distinguishes "one window" from "no
    /// window, menu bar only", so it is the authority for `ObservationNote.noWindows`.
    public let windowCount: WindowCountObservation
    public let screenshot: EncodedScreenshot?
    public let focus: FocusObservation

    public init(
        id: SnapshotID,
        app: AppIdentity,
        windows: [AXNode],
        screenshot: EncodedScreenshot?,
        focus: FocusObservation = .none,
        windowCount: WindowCountObservation? = nil
    ) {
        self.id = id
        self.app = app
        self.windows = windows
        // A synthetic snapshot's roots are its windows; only live capture can answer otherwise.
        self.windowCount = windowCount ?? .counted(windows.count)
        self.screenshot = screenshot
        self.focus = focus
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

public struct AXChildrenPage: Codable, Equatable, Sendable {
    public let snapshotID: SnapshotID
    public let parentHandle: String
    public let offset: Int
    public let limit: Int
    public let total: Int
    public let baseIndex: Int
    public let children: [AXNode]

    public init(
        snapshotID: SnapshotID,
        parentHandle: String,
        offset: Int,
        limit: Int,
        total: Int,
        baseIndex: Int,
        children: [AXNode]
    ) {
        self.snapshotID = snapshotID
        self.parentHandle = parentHandle
        self.offset = offset
        self.limit = limit
        self.total = total
        self.baseIndex = baseIndex
        self.children = children
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
    public let label: String?
    public let value: String?
    public let description: String?
    public let help: String?
    public let identifier: String?
    public let enabled: Bool?
    public let focused: Bool?
    public let frame: AXFrame?
    public let actions: [String]
    public let editable: Bool?
    public let childCount: Int?
    public let truncationReason: String?
    public let children: [AXNode]

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        label: String? = nil,
        value: String? = nil,
        description: String? = nil,
        help: String? = nil,
        identifier: String? = nil,
        enabled: Bool? = nil,
        focused: Bool? = nil,
        frame: AXFrame? = nil,
        actions: [String] = [],
        editable: Bool? = nil,
        childCount: Int? = nil,
        truncationReason: String? = nil,
        children: [AXNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.value = value
        self.description = description
        self.help = help
        self.identifier = identifier
        self.enabled = enabled
        self.focused = focused
        self.frame = frame
        self.actions = actions
        self.editable = editable
        self.childCount = childCount
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

extension AXFrame: CustomStringConvertible {
    /// How a rectangle reads inside a diagnostic message, for example `{x:100,y:50,width:80,height:20}`.
    public var description: String {
        "{x:\(x.compactDescription),y:\(y.compactDescription),width:\(width.compactDescription),height:\(height.compactDescription)}"
    }
}

extension Double {
    /// Rendered for a human-readable message: a whole value loses its fractional part, so a frame
    /// reads `{x:100,...}` rather than `{x:100.0,...}`.
    var compactDescription: String {
        guard rounded() == self, magnitude < 1e15 else {
            return String(self)
        }
        return String(Int(self))
    }
}

public extension AXFrame {
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    /// Whether this rectangle covers a point, on the half-open convention a window's own edge
    /// follows: the leading edge belongs to the window, the trailing edge to whatever is beyond it.
    func contains(x pointX: Double, y pointY: Double) -> Bool {
        pointX >= x && pointX < maxX && pointY >= y && pointY < maxY
    }
}

public extension AXNode {
    func replacing(actions: [String]? = nil, children: [AXNode]? = nil) -> AXNode {
        AXNode(
            role: role,
            subrole: subrole,
            title: title,
            label: label,
            value: value,
            description: description,
            help: help,
            identifier: identifier,
            enabled: enabled,
            focused: focused,
            frame: frame,
            actions: actions ?? self.actions,
            editable: editable,
            childCount: childCount,
            truncationReason: truncationReason,
            children: children ?? self.children
        )
    }

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
            label: label,
            value: value,
            description: description,
            help: help,
            identifier: identifier,
            enabled: enabled,
            focused: focused,
            frame: frame,
            actions: actions,
            editable: editable,
            childCount: childCount,
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
        "\(snapshotID.rawValue):\(nodeIndex)"
    }

    public init(snapshotID: SnapshotID, nodeIndex: Int) {
        self.snapshotID = snapshotID
        self.nodeIndex = nodeIndex
    }

    public init(_ rawValue: String) throws {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            throw ParseError.invalidFormat
        }
        guard let index = Int(parts[1]) else {
            throw ParseError.invalidIndex
        }
        self.snapshotID = SnapshotID(String(parts[0]))
        self.nodeIndex = index
    }
}

public struct SnapshotSummary: Codable, Equatable, Sendable {
    public let id: SnapshotID
    public let app: AppIdentity
    public let windows: [WindowSignature]
    public let observationToken: Int?

    public init(id: SnapshotID, app: AppIdentity, windows: [WindowSignature], observationToken: Int? = nil) {
        self.id = id
        self.app = app
        self.windows = windows
        self.observationToken = observationToken
    }

    public init(snapshot: AppSnapshot, observationToken: Int? = nil) {
        self.init(
            id: snapshot.id,
            app: snapshot.app,
            windows: snapshot.windows.map(WindowSignature.init(node:)),
            observationToken: observationToken
        )
    }

    public var appQuery: String {
        app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
    }

    public func change(comparedTo current: SnapshotSummary) -> SnapshotChange {
        if app.bundleIdentifier != current.app.bundleIdentifier || app.processIdentifier != current.app.processIdentifier {
            return SnapshotChange(changed: true, reason: "app_identity_changed")
        }
        if windows != current.windows {
            return SnapshotChange(changed: true, reason: "window_signature_changed")
        }
        return SnapshotChange(changed: false, reason: "unchanged")
    }
}

public struct WindowSignature: Codable, Equatable, Sendable {
    public let role: String
    public let subrole: String?
    public let title: String?
    public let frame: FrameSignature?
    public let childCount: Int

    public init(role: String, subrole: String?, title: String?, frame: FrameSignature?, childCount: Int) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.frame = frame
        self.childCount = childCount
    }

    public init(node: AXNode) {
        self.init(
            role: node.role,
            subrole: node.subrole,
            title: node.title,
            frame: node.frame.map(FrameSignature.init(frame:)),
            childCount: node.childCount ?? node.children.count
        )
    }
}

public struct FrameSignature: Codable, Equatable, Sendable {
    private static let tolerance = 2

    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(frame: AXFrame) {
        self.init(
            x: Int(frame.x.rounded()),
            y: Int(frame.y.rounded()),
            width: Int(frame.width.rounded()),
            height: Int(frame.height.rounded())
        )
    }

    public static func == (lhs: FrameSignature, rhs: FrameSignature) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance &&
            abs(lhs.y - rhs.y) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }
}

public struct SnapshotChange: Codable, Equatable, Sendable {
    public let changed: Bool
    public let reason: String

    public init(changed: Bool, reason: String) {
        self.changed = changed
        self.reason = reason
    }
}
