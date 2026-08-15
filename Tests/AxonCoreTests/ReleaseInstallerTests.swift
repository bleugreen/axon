import Foundation
import Testing
@testable import AxonCore

// MARK: - Fixtures

/// Builds an Axon.app of `version`, nested editor and CLI included, at `bundleURL`.
private func makeAxonBundle(at bundleURL: URL, version: String, identifier: String = AppBundle.axonDaemonIdentifier) throws {
    let fileManager = FileManager.default

    func writePlist(_ values: [String: Any], to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
    }

    func writeExecutable(at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: url.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    try writePlist(
        [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "Axon"
        ],
        to: bundleURL.appendingPathComponent("Contents/Info.plist")
    )
    try writeExecutable(at: bundleURL.appendingPathComponent("Contents/MacOS/Axon"))
    try writeExecutable(at: bundleURL.appendingPathComponent(AppBundle.bundledCLIRelativePath))

    let editorURL = bundleURL.appendingPathComponent(AppBundle.nestedEditorRelativePath)
    try writePlist(
        [
            "CFBundleIdentifier": AppBundle.axonEditorIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "AxonEditor"
        ],
        to: editorURL.appendingPathComponent("Contents/Info.plist")
    )
    try writeExecutable(at: editorURL.appendingPathComponent("Contents/MacOS/AxonEditor"))
}

/// Packs an Axon.app into a release archive the way `scripts/package-app` does, and returns the
/// archive with the checksum a sidecar would publish for it.
private func makeReleaseArchive(version: String, in directory: URL) throws -> (archive: URL, sha256: String) {
    let stage = directory.appendingPathComponent("stage-\(version)", isDirectory: true)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    try makeAxonBundle(at: stage.appendingPathComponent("Axon.app"), version: version)

    let archive = directory.appendingPathComponent("Axon-\(version)-macos-aarch64.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", "Axon.app", archive.path]
    process.currentDirectoryURL = stage
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    return (archive, try ReleaseInstaller.sha256(ofFileAt: archive))
}

private func update(version: String, assets: Bool = true) -> ReleaseUpdate {
    ReleaseUpdate(
        currentVersion: "0.3.4",
        latestVersion: version,
        releaseURL: URL(string: "https://github.com/bleugreen/axon/releases/tag/v\(version)")!,
        assetURL: assets ? URL(string: "https://example.test/Axon-\(version)-macos-aarch64.zip") : nil,
        checksumURL: assets ? URL(string: "https://example.test/Axon-\(version)-macos-aarch64.zip.sha256") : nil,
        isUpdateAvailable: true
    )
}

/// An installer that serves a prepared archive and sidecar, and trusts the signature.
///
/// Signature verification anchors to the running process's own signature, which a test binary does
/// not have; every other gate is exercised for real.
private func installer(archive: URL, sidecar: String) -> ReleaseInstaller {
    ReleaseInstaller(
        fetch: { _ in Data(sidecar.utf8) },
        download: { _, destination, progress in
            try FileManager.default.copyItem(at: archive, to: destination)
            progress(1)
        },
        verifySignature: { _ in }
    )
}

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Layout detection

@Test func installLayoutClaimsAVersionedRootOnlyWithAxonsMarker() throws {
    let root = try temporaryDirectory("layout")
    defer { try? FileManager.default.removeItem(at: root) }

    let versionDirectory = root.appendingPathComponent("0.3.5", isDirectory: true)
    let bundleURL = versionDirectory.appendingPathComponent("Axon.app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    // Version-shaped but unmarked: this is not a directory Axon created, so it is not claimed.
    #expect(InstallLayout.detect(bundleURL: bundleURL) == .fixedLocation(bundleURL: bundleURL.standardizedFileURL))

    try Data("0.3.5\n".utf8).write(to: versionDirectory.appendingPathComponent(InstallLayout.markerName))
    #expect(InstallLayout.detect(bundleURL: bundleURL) == .versioned(root: root.standardizedFileURL, version: "0.3.5"))
}

@Test func installLayoutTreatsDraggedInstallsAsFixedLocations() {
    let applications = URL(fileURLWithPath: "/Applications/Axon.app")
    #expect(InstallLayout.detect(bundleURL: applications) == .fixedLocation(bundleURL: applications))

    let arbitrary = URL(fileURLWithPath: "/Users/someone/Desktop/Axon.app")
    #expect(InstallLayout.detect(bundleURL: arbitrary) == .fixedLocation(bundleURL: arbitrary))
}

@Test func versionShapedNamesExcludeEverythingThatIsNotARelease() {
    #expect(InstallLayout.isVersionShaped("0.3.5"))
    #expect(InstallLayout.isVersionShaped("1.0.0-rc.1"))
    #expect(!InstallLayout.isVersionShaped("current"))
    #expect(!InstallLayout.isVersionShaped("bin"))
    #expect(!InstallLayout.isVersionShaped("035"))
    #expect(!InstallLayout.isVersionShaped("v0.3.5"))
    #expect(!InstallLayout.isVersionShaped("0.3.5 copy"))
}

// MARK: - Verification

@Test func checksumParsingTakesTheFirstFieldAndRejectsMalformedSidecars() throws {
    let digest = String(repeating: "a", count: 64)
    #expect(try ReleaseInstaller.checksum(fromSidecar: Data("\(digest)  Axon.zip\n".utf8)) == digest)
    #expect(try ReleaseInstaller.checksum(fromSidecar: Data("\(digest.uppercased())  Axon.zip\n".utf8)) == digest)

    for malformed in ["", "not-a-digest  Axon.zip", String(repeating: "a", count: 63)] {
        #expect(throws: ReleaseInstallError.self) {
            try ReleaseInstaller.checksum(fromSidecar: Data(malformed.utf8))
        }
    }
}

@Test func installRefusesAReleaseWithNoMacOSAsset() async throws {
    let root = try temporaryDirectory("no-asset")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundleURL = root.appendingPathComponent("Axon.app", isDirectory: true)
    try makeAxonBundle(at: bundleURL, version: "0.3.4")

    await #expect(throws: ReleaseInstallError.self) {
        _ = try await installer(archive: root, sidecar: "")
            .install(update: update(version: "0.3.5", assets: false), replacing: bundleURL)
    }
    #expect(AppBundle.shortVersion(of: bundleURL) == "0.3.4")
}

@Test func installRefusesAndChangesNothingWhenTheChecksumDoesNotMatch() async throws {
    let workspace = try temporaryDirectory("checksum")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let bundleURL = workspace.appendingPathComponent("Axon.app", isDirectory: true)
    try makeAxonBundle(at: bundleURL, version: "0.3.4")
    let release = try makeReleaseArchive(version: "0.3.5", in: workspace)

    let wrongDigest = String(repeating: "b", count: 64)
    await #expect(throws: ReleaseInstallError.self) {
        _ = try await installer(archive: release.archive, sidecar: "\(wrongDigest)  archive.zip\n")
            .install(update: update(version: "0.3.5"), replacing: bundleURL)
    }
    #expect(AppBundle.shortVersion(of: bundleURL) == "0.3.4")
}

@Test func installRefusesAnArchiveWhoseRootIsNotAnAxonBundle() async throws {
    let workspace = try temporaryDirectory("layout-refusal")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let installTarget = workspace.appendingPathComponent("Axon.app", isDirectory: true)
    try makeAxonBundle(at: installTarget, version: "0.3.4")

    // A version directory holding the app, which is the pre-nesting archive shape.
    let stage = workspace.appendingPathComponent("stage", isDirectory: true)
    let nested = stage.appendingPathComponent("Axon-0.3.5", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try makeAxonBundle(at: nested.appendingPathComponent("Axon.app"), version: "0.3.5")
    let archive = workspace.appendingPathComponent("bad.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--keepParent", "Axon-0.3.5", archive.path]
    process.currentDirectoryURL = stage
    try process.run()
    process.waitUntilExit()

    let digest = try ReleaseInstaller.sha256(ofFileAt: archive)
    await #expect(throws: ReleaseInstallError.self) {
        _ = try await installer(archive: archive, sidecar: "\(digest)  bad.zip\n")
            .install(update: update(version: "0.3.5"), replacing: installTarget)
    }
    #expect(AppBundle.shortVersion(of: installTarget) == "0.3.4")
}

@Test func installRefusesAnArchiveThatReportsADifferentVersion() async throws {
    let workspace = try temporaryDirectory("version-skew")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let bundleURL = workspace.appendingPathComponent("Axon.app", isDirectory: true)
    try makeAxonBundle(at: bundleURL, version: "0.3.4")
    let release = try makeReleaseArchive(version: "0.3.5", in: workspace)

    await #expect(throws: ReleaseInstallError.self) {
        _ = try await installer(archive: release.archive, sidecar: "\(release.sha256)  archive.zip\n")
            .install(update: update(version: "0.3.6"), replacing: bundleURL)
    }
    #expect(AppBundle.shortVersion(of: bundleURL) == "0.3.4")
}

// MARK: - Placement

@Test func installReplacesABundleInPlaceAtAFixedLocation() async throws {
    let workspace = try temporaryDirectory("fixed-location")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let applications = workspace.appendingPathComponent("Applications", isDirectory: true)
    try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    let bundleURL = applications.appendingPathComponent("Axon.app", isDirectory: true)
    try makeAxonBundle(at: bundleURL, version: "0.3.4")
    let release = try makeReleaseArchive(version: "0.3.5", in: workspace)

    let installed = try await installer(archive: release.archive, sidecar: "\(release.sha256)  archive.zip\n")
        .install(update: update(version: "0.3.5"), replacing: bundleURL)

    #expect(installed.bundleURL.path == bundleURL.path)
    #expect(installed.version == "0.3.5")
    #expect(AppBundle.shortVersion(of: bundleURL) == "0.3.5")
    #expect(FileManager.default.isExecutableFile(atPath: installed.cliURL.path))
    #expect(AppBundle.pairedEditorURL(beside: bundleURL) != nil)
    // No staging or backup debris survives a successful swap.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: applications.path)
    #expect(leftovers == ["Axon.app"])
}

@Test func installAddsACompleteVersionDirectoryBesideTheCurrentOne() async throws {
    let workspace = try temporaryDirectory("versioned")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let root = workspace.appendingPathComponent("axon", isDirectory: true)
    let currentDirectory = root.appendingPathComponent("0.3.4", isDirectory: true)
    try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
    let bundleURL = currentDirectory.appendingPathComponent("Axon.app", isDirectory: true)
    try makeAxonBundle(at: bundleURL, version: "0.3.4")
    try Data("0.3.4\n".utf8).write(to: currentDirectory.appendingPathComponent(InstallLayout.markerName))
    let release = try makeReleaseArchive(version: "0.3.5", in: workspace)

    let installed = try await installer(archive: release.archive, sidecar: "\(release.sha256)  archive.zip\n")
        .install(update: update(version: "0.3.5"), replacing: bundleURL)

    let expected = root.appendingPathComponent("0.3.5/Axon.app")
    #expect(installed.bundleURL.path == expected.path)
    #expect(AppBundle.shortVersion(of: expected) == "0.3.5")
    // Complete the moment it is visible: the marker rides in before the rename.
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("0.3.5/\(InstallLayout.markerName)").path))
    // The previous release is left for pruning to decide about, not deleted mid-update.
    #expect(FileManager.default.fileExists(atPath: bundleURL.path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("0.3.5.installing").path))
}

// MARK: - Pruning

@Test func pruningKeepsTheCurrentAndPreviousReleasesAndRefusesEverythingProtected() throws {
    let root = try temporaryDirectory("prune")
    defer { try? FileManager.default.removeItem(at: root) }

    func makeInstall(_ version: String, marked: Bool = true) throws {
        let directory = root.appendingPathComponent(version, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Axon.app"),
            withIntermediateDirectories: true
        )
        if marked {
            try Data("\(version)\n".utf8).write(to: directory.appendingPathComponent(InstallLayout.markerName))
        }
    }

    for version in ["0.2.1", "0.3.3", "0.3.4", "0.3.5"] {
        try makeInstall(version)
    }
    // A bench layout Axon did not create: no marker, so never a candidate.
    try makeInstall("0.3.9", marked: false)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)

    let running = root.appendingPathComponent("0.3.5/Axon.app").path
    let superseded = InstallPruning.superseded(root: root, protecting: [running])
    #expect(superseded.map(\.lastPathComponent) == ["0.2.1", "0.3.3"])

    // The registration is protected no matter how old the directory holding it is.
    let registered = root.appendingPathComponent("0.2.1/Axon.app/Contents/MacOS/Axon").path
    let withRegistrationProtected = InstallPruning.superseded(root: root, protecting: [running, registered])
    #expect(withRegistrationProtected.map(\.lastPathComponent) == ["0.3.3"])

    // Orphans are every complete install nothing points at, however recent.
    let orphans = InstallPruning.orphaned(root: root, referencedPaths: [running])
    #expect(orphans.map(\.lastPathComponent) == ["0.3.4", "0.3.3", "0.2.1"])
}

// MARK: - The update finisher

@Test func updateFinisherRunsDaemonInstallOnceAndIsNeverKeptAlive() {
    let configuration = LaunchAgentConfiguration.updateFinisher(cliPath: "/Applications/Axon.app/Contents/Resources/bin/axon")
    let plist = configuration.propertyListObject

    #expect(configuration.label == "dev.axon.updater")
    #expect(plist["Label"] as? String == "dev.axon.updater")
    #expect(plist["ProgramArguments"] as? [String] == [
        "/Applications/Axon.app/Contents/Resources/bin/axon", "daemon", "install"
    ])
    #expect(plist["RunAtLoad"] as? Bool == true)
    // A finisher that could be restarted would loop on a failure it cannot fix.
    #expect(plist["KeepAlive"] as? Bool == false)
    #expect((plist["StandardOutPath"] as? String)?.hasSuffix("updater.out.log") == true)
}

@Test func daemonRegistrationKeepsItsOwnLabelAndSupervision() {
    let configuration = LaunchAgentConfiguration(
        program: DaemonProgram(executablePath: "/Applications/Axon.app/Contents/MacOS/Axon", identity: .appBundle(identifier: AppBundle.axonDaemonIdentifier))
    )

    #expect(configuration.label == "dev.axon.daemon")
    #expect(configuration.propertyListObject["KeepAlive"] as? Bool == true)
    #expect(configuration.propertyListObject["ProgramArguments"] as? [String] == [
        "/Applications/Axon.app/Contents/MacOS/Axon"
    ])
}

@Test func reapingTheUpdateFinisherIsIdempotent() throws {
    let directory = try temporaryDirectory("reap")
    defer { try? FileManager.default.removeItem(at: directory) }
    let plistPath = directory.appendingPathComponent("dev.axon.updater.plist")
    try Data("placeholder".utf8).write(to: plistPath)

    var bootouts: [[String]] = []
    let record: ([String]) throws -> ProcessResult = { arguments in
        bootouts.append(arguments)
        return ProcessResult(exitCode: 0)
    }

    LaunchAgentManager.reapUpdateFinisher(plistPath: plistPath, runProcess: record)
    #expect(!FileManager.default.fileExists(atPath: plistPath.path))

    // Nothing left to reap, and nothing thrown for it.
    LaunchAgentManager.reapUpdateFinisher(plistPath: plistPath, runProcess: record)
    #expect(bootouts.count == 2)
    #expect(bootouts.allSatisfy { $0.first == "bootout" && $0.last?.hasSuffix("/dev.axon.updater") == true })
}
