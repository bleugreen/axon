import Foundation
import Testing
@testable import AxonCore

private func releaseJSON(tag: String, assetNames: [String]) -> Data {
    let assets = assetNames.map { name in
        """
        {"name": "\(name)", "browser_download_url": "https://example.test/\(name)"}
        """
    }.joined(separator: ",")
    return Data("""
    {
      "tag_name": "\(tag)",
      "html_url": "https://github.com/bleugreen/axon/releases/tag/\(tag)",
      "assets": [\(assets)]
    }
    """.utf8)
}

@Test func releaseUpdateCheckerParsesTagAssetAndChecksumURLs() throws {
    let data = releaseJSON(
        tag: "v0.3.6",
        assetNames: [
            "axon-linux-0.3.6-linux-x86_64.tar.gz",
            "Axon-0.3.6-macos-aarch64.zip",
            "Axon-0.3.6-macos-aarch64.zip.sha256"
        ]
    )

    let release = try ReleaseUpdateChecker.release(from: data)

    #expect(release.version == "0.3.6")
    #expect(release.releaseURL.absoluteString == "https://github.com/bleugreen/axon/releases/tag/v0.3.6")
    #expect(release.assetURL?.absoluteString == "https://example.test/Axon-0.3.6-macos-aarch64.zip")
    #expect(release.checksumURL?.absoluteString == "https://example.test/Axon-0.3.6-macos-aarch64.zip.sha256")
}

@Test func releaseUpdateCheckerAcceptsATagWithoutAVPrefix() throws {
    let release = try ReleaseUpdateChecker.release(from: releaseJSON(tag: "0.3.6", assetNames: []))

    #expect(release.version == "0.3.6")
}

/// A release published without its macOS archive is a state to report, not a crash: the menu can
/// still say an update exists, and `ReleaseInstaller` is the thing that refuses.
@Test func releaseUpdateCheckerReportsAReleaseWithNoMacOSAsset() throws {
    let release = try ReleaseUpdateChecker.release(
        from: releaseJSON(tag: "v0.3.6", assetNames: ["axon-win-0.3.6-windows-x86_64.zip"])
    )

    #expect(release.assetURL == nil)
    #expect(release.checksumURL == nil)
}

@Test func releaseUpdateCheckerRejectsAResponseWithoutATag() {
    #expect(throws: ReleaseUpdateError.self) {
        try ReleaseUpdateChecker.release(from: Data(#"{"message": "Not Found"}"#.utf8))
    }
}

@Test func releaseUpdateCheckerComparesVersionsNumerically() {
    #expect(ReleaseUpdateChecker.isVersion("0.1.10", newerThan: "0.1.2"))
    #expect(ReleaseUpdateChecker.isVersion("v0.2.0", newerThan: "0.1.9"))
    #expect(!ReleaseUpdateChecker.isVersion("0.1.1", newerThan: "0.1.1"))
    #expect(!ReleaseUpdateChecker.isVersion("0.1.1", newerThan: "0.1.2"))
}

@Test func releaseUpdateCheckerReportsAvailableUpdate() async throws {
    let checker = ReleaseUpdateChecker { _ in
        releaseJSON(
            tag: "v0.1.2",
            assetNames: ["Axon-0.1.2-macos-aarch64.zip", "Axon-0.1.2-macos-aarch64.zip.sha256"]
        )
    }

    let update = try await checker.check(currentVersion: "0.1.1")

    #expect(update.currentVersion == "0.1.1")
    #expect(update.latestVersion == "0.1.2")
    #expect(update.isUpdateAvailable)
    #expect(update.assetURL?.lastPathComponent == "Axon-0.1.2-macos-aarch64.zip")
}
