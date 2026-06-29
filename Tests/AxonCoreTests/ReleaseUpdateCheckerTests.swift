import Foundation
import Testing
@testable import AxonCore

@Test func releaseUpdateCheckerParsesLatestRelease() throws {
    let data = Data("""
    {"tag_name":"v0.1.1","html_url":"https://github.com/bleugreen/axon/releases/tag/v0.1.1"}
    """.utf8)

    let release = try ReleaseUpdateChecker.release(from: data)

    #expect(release.version == "0.1.1")
    #expect(release.url.absoluteString == "https://github.com/bleugreen/axon/releases/tag/v0.1.1")
}

@Test func releaseUpdateCheckerFallsBackToConstructedURLWhenHtmlUrlAbsent() throws {
    let data = Data("""
    {"tag_name":"v0.1.2"}
    """.utf8)

    let release = try ReleaseUpdateChecker.release(from: data)

    #expect(release.version == "0.1.2")
    #expect(release.url.absoluteString == "https://github.com/bleugreen/axon/releases/tag/v0.1.2")
}

@Test func releaseUpdateCheckerThrowsWhenTagNameMissing() throws {
    let data = Data("""
    {"html_url":"https://github.com/bleugreen/axon/releases/tag/v0.1.1"}
    """.utf8)

    #expect(throws: ReleaseUpdateError.missingReleaseVersion) {
        try ReleaseUpdateChecker.release(from: data)
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
        Data("""
        {"tag_name":"v0.1.2","html_url":"https://github.com/bleugreen/axon/releases/tag/v0.1.2"}
        """.utf8)
    }

    let update = try await checker.check(currentVersion: "0.1.1")

    #expect(update.currentVersion == "0.1.1")
    #expect(update.latestVersion == "0.1.2")
    #expect(update.isUpdateAvailable)
}
