import Foundation

/// What the update check learned about the newest published release.
///
/// The asset and checksum URLs are the difference between telling a user an update exists and
/// installing it. They are optional because a release can exist without them — a publish caught
/// mid-flight, or a tag cut without the macOS job — and that is a state to report rather than a
/// crash. `ReleaseInstaller` refuses to place anything when they are missing.
public struct ReleaseUpdate: Equatable, Sendable {
    public let currentVersion: String
    public let latestVersion: String
    /// The release page, which stays useful as a "Release Notes" affordance and as the honest
    /// fallback when an automatic install refuses.
    public let releaseURL: URL
    public let assetURL: URL?
    public let checksumURL: URL?
    public let isUpdateAvailable: Bool

    public init(
        currentVersion: String,
        latestVersion: String,
        releaseURL: URL,
        assetURL: URL? = nil,
        checksumURL: URL? = nil,
        isUpdateAvailable: Bool
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.releaseURL = releaseURL
        self.assetURL = assetURL
        self.checksumURL = checksumURL
        self.isUpdateAvailable = isUpdateAvailable
    }
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

/// Resolves the newest published release from GitHub's releases API.
///
/// The tap cask was the wrong source twice over: it is the last artifact the release workflow
/// publishes and it sits behind a five-minute CDN cache, so a check inside the post-release window
/// read the previous version and concluded "up to date"; and a cask names no asset, so the answer
/// could never be more than a link to a web page. The releases API is what `install.sh` already
/// trusts — published first, strongly consistent, and it names every asset by URL.
public struct ReleaseUpdateChecker: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    /// One published release, as much of it as an updater needs.
    public struct Release: Equatable, Sendable {
        public let version: String
        public let releaseURL: URL
        public let assetURL: URL?
        public let checksumURL: URL?
    }

    public static let defaultLatestReleaseURL =
        URL(string: "https://api.github.com/repos/bleugreen/axon/releases/latest")!

    private let latestReleaseURL: URL
    private let fetch: Fetch

    public init(
        latestReleaseURL: URL = ReleaseUpdateChecker.defaultLatestReleaseURL,
        fetch: @escaping Fetch = ReleaseUpdateChecker.defaultFetch
    ) {
        self.latestReleaseURL = latestReleaseURL
        self.fetch = fetch
    }

    public func check(currentVersion: String = AxonVersion.current) async throws -> ReleaseUpdate {
        let data = try await fetch(latestReleaseURL)
        let release = try Self.release(from: data)
        return ReleaseUpdate(
            currentVersion: currentVersion,
            latestVersion: release.version,
            releaseURL: release.releaseURL,
            assetURL: release.assetURL,
            checksumURL: release.checksumURL,
            isUpdateAvailable: Self.isVersion(release.version, newerThan: currentVersion)
        )
    }

    /// The macOS archive published for a version, by the name `package-app` gives it.
    public static func macOSAssetName(version: String) -> String {
        "Axon-\(version)-macos-aarch64.zip"
    }

    public static func release(from data: Data) throws -> Release {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String
        else {
            throw ReleaseUpdateError.missingReleaseVersion
        }
        let version = normalizedVersion(tag)
        guard !version.isEmpty else {
            throw ReleaseUpdateError.missingReleaseVersion
        }

        // `html_url` is what GitHub itself calls the release page; the derived tag URL is only a
        // fallback for a response that omits it.
        let releaseURL = (object["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/bleugreen/axon/releases/tag/\(tag)")!

        let assetName = macOSAssetName(version: version)
        let assets = (object["assets"] as? [[String: Any]]) ?? []
        func downloadURL(named name: String) -> URL? {
            assets
                .first { $0["name"] as? String == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        return Release(
            version: version,
            releaseURL: releaseURL,
            assetURL: downloadURL(named: assetName),
            checksumURL: downloadURL(named: "\(assetName).sha256")
        )
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

    /// A user clicking "Check for Updates" is asking for a fresh answer, so the request refuses
    /// every cache between here and GitHub.
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
