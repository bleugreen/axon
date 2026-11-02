import Foundation

public struct AppIdentity: Codable, Equatable, Sendable {
    public let bundleIdentifier: String?
    public let name: String
    public let processIdentifier: Int32

    public init(bundleIdentifier: String?, name: String, processIdentifier: Int32) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.processIdentifier = processIdentifier
    }

    /// How to name this application so a resolver finds the same process again.
    ///
    /// The bundle identifier when there is one, because it survives localization and renames; a
    /// process without one is named by pid, which `AppResolver` accepts and which cannot be
    /// confused with another running application. Deliberately not `name`, whose own fallback
    /// (`"pid 42"`) does not parse back.
    public var resolverQuery: String {
        bundleIdentifier ?? "pid:\(processIdentifier)"
    }
}
