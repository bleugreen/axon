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
        NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }
            .map { app in
                AppIdentity(
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                    processIdentifier: app.processIdentifier
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
}
