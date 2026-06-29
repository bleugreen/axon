import Foundation

public struct ReleaseUpdate: Equatable, Sendable {
    public let currentVersion: String
    public let latestVersion: String
    public let releaseURL: URL
    public let isUpdateAvailable: Bool
}

public enum ReleaseUpdateError: Error, Equatable, CustomStringConvertible {
    case invalidHTTPStatus(Int)
    case missingReleaseVersion

    public var description: String {
        switch self {
        case let .invalidHTTPStatus(status):
            return "Update check returned HTTP \(status)"
        case .missingReleaseVersion:
            return "Update check did not find a release version"
        }
    }
}

public struct ReleaseUpdateChecker: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let releaseAPIURL: URL
    private let fetch: Fetch

    public init(
        releaseAPIURL: URL = URL(string: "https://api.github.com/repos/bleugreen/axon/releases/latest")!,
        fetch: @escaping Fetch = ReleaseUpdateChecker.defaultFetch
    ) {
        self.releaseAPIURL = releaseAPIURL
        self.fetch = fetch
    }

    public func check(currentVersion: String = AxonVersion.current) async throws -> ReleaseUpdate {
        let data = try await fetch(releaseAPIURL)
        let release = try Self.release(from: data)
        return ReleaseUpdate(
            currentVersion: currentVersion,
            latestVersion: release.version,
            releaseURL: release.url,
            isUpdateAvailable: Self.isVersion(release.version, newerThan: currentVersion)
        )
    }

    public static func release(from data: Data) throws -> (version: String, url: URL) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String
        else {
            throw ReleaseUpdateError.missingReleaseVersion
        }
        let version = normalizedVersion(tagName)
        let fallbackURLString = "https://github.com/bleugreen/axon/releases/tag/\(tagName)"
        let url = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: fallbackURLString)!
        return (version, url)
    }

    public static func isVersion(_ version: String, newerThan currentVersion: String) -> Bool {
        let lhs = versionComponents(version)
        let rhs = versionComponents(currentVersion)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left > right
            }
        }
        return false
    }

    public static func defaultFetch(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Axon/\(AxonVersion.current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode)
        {
            throw ReleaseUpdateError.invalidHTTPStatus(httpResponse.statusCode)
        }
        return data
    }

    private static func normalizedVersion(_ version: String) -> String {
        var output = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.hasPrefix("v") || output.hasPrefix("V") {
            output.removeFirst()
        }
        return output
    }

    private static func versionComponents(_ version: String) -> [Int] {
        normalizedVersion(version)
            .split(separator: ".")
            .map { component in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}
