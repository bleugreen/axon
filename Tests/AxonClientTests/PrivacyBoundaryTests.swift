import Foundation
import Testing

/// The menu shell holds no privacy grant, and this is the check a reviewer can read for it.
///
/// The package graph already keeps `AxonMenuApp` from linking AxonCore. These scans close what the
/// graph cannot: AppKit re-exports ApplicationServices, so a privacy API is one call away from any
/// AppKit file, and a path under a protected folder needs no import at all.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private let shellSourceDirectories = ["Sources/AxonClient", "Sources/AxonMenuApp"]

private func shellSources() throws -> [(path: String, text: String)] {
    var sources: [(String, String)] = []
    for directory in shellSourceDirectories {
        let root = repositoryRoot.appendingPathComponent(directory)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            sources.append(("\(directory)/\(url.lastPathComponent)", try String(contentsOf: url, encoding: .utf8)))
        }
    }
    return sources
}

/// Code, without `//` comments, so a comment explaining the boundary does not trip it.
private func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
        .joined(separator: "\n")
}

@Test func theShellSourcesAreWhereThisTestLooks() throws {
    let names = try shellSources().map(\.path)
    #expect(names.contains("Sources/AxonClient/ShellContract.swift"))
    #expect(names.contains("Sources/AxonMenuApp/MenuShell.swift"))
}

@Test func theShellImportsNoPrivilegedFramework() throws {
    let forbidden = ["ApplicationServices", "ScreenCaptureKit", "Carbon", "Vision", "AxonCore"]
    for (path, text) in try shellSources() {
        for line in code(text).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("import ") || trimmed.hasPrefix("@testable import ") else { continue }
            let module = trimmed.split(separator: " ").last.map(String.init) ?? ""
            #expect(!forbidden.contains(module), "\(path) imports \(module)")
        }
    }
}

@Test func theShellCallsNoPrivacyGatedAPI() throws {
    let forbidden = [
        "AXIsProcessTrusted", "AXUIElement", "AEDetermine", "NSAppleScript", "NSAppleEventDescriptor",
        "CGPreflightScreenCaptureAccess", "CGRequestScreenCaptureAccess", "CGEvent.tapCreate",
        "CGEventTapCreate", "SCShareableContent", "CGWindowListCreateImage", "SocketServer"
    ]
    for (path, text) in try shellSources() {
        let body = code(text)
        for symbol in forbidden {
            #expect(!body.contains(symbol), "\(path) uses \(symbol)")
        }
    }
}

/// Desktop, Documents, and Downloads are covered by Files and Folders protection; the shell's
/// recordings go under `~/Library`, which is not.
@Test func theShellTouchesNoProtectedFolder() throws {
    let forbidden = [
        "~/Documents", "~/Desktop", "~/Downloads", "/Documents", "/Desktop", "/Downloads",
        ".documentDirectory", ".desktopDirectory", ".downloadsDirectory"
    ]
    for (path, text) in try shellSources() {
        let body = code(text)
        for fragment in forbidden {
            #expect(!body.contains(fragment), "\(path) reaches \(fragment)")
        }
    }
}
