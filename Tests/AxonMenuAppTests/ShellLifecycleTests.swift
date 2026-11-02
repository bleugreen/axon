import AxonClient
@testable import AxonMenuApp
import Foundation
import Testing

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-menu-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func handoff(into directory: URL, opened: OpenedURLs) -> RecordingHandoff {
    RecordingHandoff(
        directory: directory,
        now: { Date(timeIntervalSince1970: 1_800_000_000) },
        openEditor: { opened.urls.append($0) }
    )
}

private final class OpenedURLs {
    var urls: [URL] = []
}

@Test func aMenuRecordingIsWrittenUnderLibraryAndOpenedForReview() throws {
    let directory = try temporaryDirectory("review")
    let opened = OpenedURLs()
    let result = RecordingResult(sessionId: "recording-0001", destination: nil, script: "version: 2\n", actionCount: 0)
    let file = try handoff(into: directory, opened: opened)
        .deliver(result, scope: .application(RecordingApp(name: "Calculator", bundleIdentifier: "com.apple.calculator")))

    #expect(file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
    #expect(file.lastPathComponent.hasSuffix("-Calculator.axn"))
    #expect(try String(contentsOf: file, encoding: .utf8) == "version: 2\n")
    #expect(opened.urls.count == 1)
    #expect(opened.urls.first?.host == AxonEditorURL.reviewHost)
}

@Test func anEditorRecordingIsOpenedForInsertAtItsDestination() throws {
    let directory = try temporaryDirectory("insert")
    let opened = OpenedURLs()
    let result = RecordingResult(
        sessionId: "recording-0002",
        destination: RecordingDestination(documentId: "doc-7F3A", beforeBlockId: "block-12"),
        script: "version: 2\n",
        actionCount: 0
    )
    try handoff(into: directory, opened: opened).deliver(result, scope: .allApplications)

    let url = try #require(opened.urls.first)
    #expect(url.host == AxonEditorURL.insertHost)
    #expect(AxonEditorURL.documentID(from: url) == "doc-7F3A")
    #expect(AxonEditorURL.beforeBlockID(from: url) == "block-12")
}

@Test func recordingsLiveUnderLibraryNotAProtectedOrPurgedFolder() {
    let path = RecordingHandoff.defaultDirectory.path
    #expect(path.hasSuffix("/Library/Application Support/Axon/Recordings"))
    #expect(!path.hasPrefix(FileManager.default.temporaryDirectory.path))
}

/// The shell's one process-spawning dependency in shell-v1: the enclosing bundle's CLI and exactly
/// `daemon install`, so a different CLI can stand behind that path without touching the shell.
@Test func theFinisherRunsTheEnclosingBundlesCLIWithDaemonInstall() {
    let configuration = UpdateFinisher.configuration(
        enclosingBundle: URL(fileURLWithPath: "/Applications/Axon.app"),
        socketPath: "/tmp/axon.sock"
    )
    #expect(configuration.label == "dev.axon.updater")
    #expect(configuration.propertyListObject["ProgramArguments"] as? [String] == [
        "/Applications/Axon.app/Contents/Resources/bin/axon", "daemon", "install"
    ])
    #expect(configuration.keepAlive == .never)
    #expect(ShellContract.finisherArguments == ["daemon", "install"])
}

/// The update replaces the enclosing `Axon.app`, and its layout is detected from there, not from
/// the nested shell bundle.
@Test func theUpdateTargetIsTheEnclosingBundleInEitherLayout() throws {
    let root = try temporaryDirectory("layout")
    let versioned = root.appendingPathComponent("0.4.0/Axon.app")
    let shell = versioned.appendingPathComponent(AppBundle.nestedMenuRelativePath)
    try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
    try "0.4.0".write(to: root.appendingPathComponent("0.4.0/\(InstallLayout.markerName)"), atomically: true, encoding: .utf8)

    let enclosing = try #require(AppBundle.enclosingApp(ofNested: shell))
    #expect(enclosing.standardizedFileURL == versioned.standardizedFileURL)
    #expect(InstallLayout.detect(bundleURL: enclosing) == .versioned(root: root.standardizedFileURL, version: "0.4.0"))

    let fixed = URL(fileURLWithPath: "/Applications/Axon.app")
    let fixedShell = fixed.appendingPathComponent(AppBundle.nestedMenuRelativePath)
    #expect(AppBundle.enclosingApp(ofNested: fixedShell) == fixed)
    #expect(InstallLayout.detect(bundleURL: fixed) == .fixedLocation(bundleURL: fixed))

    // A bundle that is not nested at Contents/Library/Applications has no enclosing app.
    #expect(AppBundle.enclosingApp(ofNested: URL(fileURLWithPath: "/Applications/Axon Menu.app")) == nil)
}

/// The shell anchors updates to its team and to the outer bundle's identifier, never its own.
@Test func theUpdateRequirementNamesTheOuterBundleNotTheCaller() {
    let requirement = ReleaseInstaller.updateRequirement(team: "JBS95V8M7P")
    #expect(requirement == "anchor apple generic and identifier \"com.bleugreen.axon\" and certificate leaf[subject.OU] = \"JBS95V8M7P\"")
    #expect(!requirement.contains(AppBundle.axonMenuIdentifier))
}
