import Foundation

public struct ReleaseUpdate: Equatable, Sendable {
    public let currentVersion: String
    public let latestVersion: String
    public let releaseURL: URL
    public let isUpdateAvailable: Bool
}

public enum ReleaseUpdateError: Error, CustomStringConvertible {
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

    private let caskURL: URL
    private let fetch: Fetch

    public init(
        caskURL: URL = URL(string: "https://raw.githubusercontent.com/bleugreen/homebrew-tap/main/Casks/axon.rb")!,
        fetch: @escaping Fetch = ReleaseUpdateChecker.defaultFetch
    ) {
        self.caskURL = caskURL
        self.fetch = fetch
    }

    public func check(currentVersion: String = AxonVersion.current) async throws -> ReleaseUpdate {
        let data = try await fetch(caskURL)
        let release = try Self.release(from: data)
        return ReleaseUpdate(
            currentVersion: currentVersion,
            latestVersion: release.version,
            releaseURL: release.url,
            isUpdateAvailable: Self.isVersion(release.version, newerThan: currentVersion)
        )
    }

    public static func release(from data: Data) throws -> (version: String, url: URL) {
        guard let cask = String(data: data, encoding: .utf8),
              let rawVersion = cask.firstMatch(for: #"(?m)^\s*version\s+"([^"]+)""#)
        else {
            throw ReleaseUpdateError.missingReleaseVersion
        }
        let version = normalizedVersion(rawVersion)
        let url = URL(string: "https://github.com/bleugreen/axon/releases/tag/v\(version)")!
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
        request.setValue("Axon/\(AxonVersion.current)", forHTTPHeaderField: "User-Agent")
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

private extension String {
    func firstMatch(for pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, range: range),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: self)
        else {
            return nil
        }
        return String(self[matchRange])
    }
}
