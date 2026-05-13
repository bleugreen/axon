import Foundation
import Testing
@testable import AxonCore

@Test func releaseUpdateCheckerParsesLatestRelease() throws {
    let data = Data("""
    cask "axon" do
      version "0.1.1"
      url "https://github.com/bleugreen/axon/releases/download/v#{version}/Axon-#{version}.zip"
    end
    """.utf8)

    let release = try ReleaseUpdateChecker.release(from: data)

    #expect(release.version == "0.1.1")
    #expect(release.url.absoluteString == "https://github.com/bleugreen/axon/releases/tag/v0.1.1")
}

@Test func releaseUpdateCheckerComparesVersionsNumerically() {
    #expect(ReleaseUpdateChecker.isVersion("0.1.10", newerThan: "0.1.2"))
    #expect(ReleaseUpdateChecker.isVersion("v0.2.0", newerThan: "0.1.9"))
    #expect(!ReleaseUpdateChecker.isVersion("0.1.1", newerThan: "0.1.1"))
    #expect(!ReleaseUpdateChecker.isVersion("0.1.1", newerThan: "0.1.2"))
}

@Test func releaseUpdateCheckerReportsAvailableUpdate() async throws {
    let checker = ReleaseUpdateChecker { _ in
        Data("""
        cask "axon" do
          version "0.1.2"
        end
        """.utf8)
    }

    let update = try await checker.check(currentVersion: "0.1.1")

    #expect(update.currentVersion == "0.1.1")
    #expect(update.latestVersion == "0.1.2")
    #expect(update.isUpdateAvailable)
}
