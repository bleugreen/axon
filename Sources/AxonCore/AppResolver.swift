import AppKit

public enum AppResolverError: Error, CustomStringConvertible {
    case notFound(String)

    public var description: String {
        switch self {
        case let .notFound(query):
            return "No running app matched '\(query)'"
        }
    }
}

public struct AppResolver {
    public init() {}

    public func runningApps() -> [AppIdentity] {
        Self.appIdentities(from: runningAppDescriptors())
    }

    public func recordableApps(recency: AppRecencySnapshot = .empty) -> [AppIdentity] {
        Self.recordableApps(from: runningAppDescriptors(), recency: recency)
    }

    public static func recordableApps(
        from descriptors: [RunningAppDescriptor],
        recency: AppRecencySnapshot = .empty
    ) -> [AppIdentity] {
        descriptors
            .filter { descriptor in
                !descriptor.isTerminated && descriptor.activationPolicy == .regular
            }
            .sorted { lhs, rhs in
                let lhsRecency = recency.lastActivatedAt(for: lhs)
                let rhsRecency = recency.lastActivatedAt(for: rhs)
                switch (lhsRecency, rhsRecency) {
                case let (lhs?, rhs?) where lhs != rhs:
                    return lhs > rhs
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    let lhsName = lhs.localizedName ?? lhs.bundleIdentifier ?? "pid \(lhs.processIdentifier)"
                    let rhsName = rhs.localizedName ?? rhs.bundleIdentifier ?? "pid \(rhs.processIdentifier)"
                    let order = lhsName.localizedCaseInsensitiveCompare(rhsName)
                    if order != .orderedSame {
                        return order == .orderedAscending
                    }
                    return lhs.processIdentifier < rhs.processIdentifier
                }
            }
            .map(identity(from:))
    }

    public func resolveIdentity(_ query: String) throws -> AppIdentity {
        let app = try resolve(query)
        return AppIdentity(
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            processIdentifier: app.processIdentifier
        )
    }

    public func resolve(_ query: String) throws -> NSRunningApplication {
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        if let pid = pid(from: query),
           let app = apps.first(where: { $0.processIdentifier == pid }) {
            return app
        }

        if let exactBundleMatch = apps.first(where: { $0.bundleIdentifier == query }) {
            return exactBundleMatch
        }

        let lowercasedQuery = query.lowercased()
        if let nameMatch = apps.first(where: { ($0.localizedName ?? "").lowercased() == lowercasedQuery }) {
            return nameMatch
        }

        if let containsMatch = apps.first(where: { app in
            let name = app.localizedName?.lowercased() ?? ""
            let bundle = app.bundleIdentifier?.lowercased() ?? ""
            return name.contains(lowercasedQuery) || bundle.contains(lowercasedQuery)
        }) {
            return containsMatch
        }

        throw AppResolverError.notFound(query)
    }

    private func pid(from query: String) -> pid_t? {
        if let int = Int32(query) {
            return pid_t(int)
        }
        if query.hasPrefix("pid:"), let int = Int32(query.dropFirst(4)) {
            return pid_t(int)
        }
        return nil
    }

    private func runningAppDescriptors() -> [RunningAppDescriptor] {
        NSWorkspace.shared.runningApplications.map { app in
            RunningAppDescriptor(
                bundleIdentifier: app.bundleIdentifier,
                localizedName: app.localizedName,
                processIdentifier: app.processIdentifier,
                activationPolicy: AppActivationPolicy(app.activationPolicy),
                isTerminated: app.isTerminated
            )
        }
    }

    private static func appIdentities(from descriptors: [RunningAppDescriptor]) -> [AppIdentity] {
        descriptors
            .filter { !$0.isTerminated }
            .map(identity(from:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func identity(from descriptor: RunningAppDescriptor) -> AppIdentity {
        AppIdentity(
            bundleIdentifier: descriptor.bundleIdentifier,
            name: descriptor.localizedName ?? descriptor.bundleIdentifier ?? "pid \(descriptor.processIdentifier)",
            processIdentifier: descriptor.processIdentifier
        )
    }
}

public struct AppRecencySnapshot: Codable, Equatable, Sendable {
    public static let empty = AppRecencySnapshot(entries: [])

    public let entries: [AppRecencyEntry]

    public init(entries: [AppRecencyEntry]) {
        self.entries = entries
    }

    public func lastActivatedAt(for descriptor: RunningAppDescriptor) -> Double? {
        var best: Double?
        for entry in entries where entry.matches(descriptor) {
            if best.map({ entry.lastActivatedAt > $0 }) ?? true {
                best = entry.lastActivatedAt
            }
        }
        return best
    }
}

public struct AppRecencyEntry: Codable, Equatable, Sendable {
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let lastActivatedAt: Double

    public init(bundleIdentifier: String?, processIdentifier: Int32?, lastActivatedAt: Double) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.lastActivatedAt = lastActivatedAt
    }

    public func matches(_ descriptor: RunningAppDescriptor) -> Bool {
        if let processIdentifier, processIdentifier == descriptor.processIdentifier {
            return true
        }
        if let bundleIdentifier, bundleIdentifier == descriptor.bundleIdentifier {
            return true
        }
        return false
    }
}

public enum AppActivationPolicy: String, Codable, Equatable, Sendable {
    case regular
    case accessory
    case prohibited
    case unknown

    init(_ policy: NSApplication.ActivationPolicy) {
        switch policy {
        case .regular:
            self = .regular
        case .accessory:
            self = .accessory
        case .prohibited:
            self = .prohibited
        @unknown default:
            self = .unknown
        }
    }
}

public struct RunningAppDescriptor: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let localizedName: String?
    public let processIdentifier: Int32
    public let activationPolicy: AppActivationPolicy
    public let isTerminated: Bool

    public init(
        bundleIdentifier: String?,
        localizedName: String?,
        processIdentifier: Int32,
        activationPolicy: AppActivationPolicy,
        isTerminated: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.processIdentifier = processIdentifier
        self.activationPolicy = activationPolicy
        self.isTerminated = isTerminated
    }
}
