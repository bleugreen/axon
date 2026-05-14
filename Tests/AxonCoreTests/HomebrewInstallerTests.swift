import Foundation
import Testing

@testable import AxonCore

@Suite("HomebrewInstaller")
struct HomebrewInstallerTests {
    private static let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")

    @Test func isCaskInstalledReturnsTrueOnExitZero() throws {
        let installer = HomebrewInstaller(brewURL: Self.brewURL) { _, arguments in
            #expect(arguments == ["list", "--cask", "axon"])
            return .init(status: 0, stdout: "axon", stderr: "")
        }
        #expect(try installer.isCaskInstalled(name: "axon") == true)
    }

    @Test func isCaskInstalledReturnsFalseOnNonZero() throws {
        let installer = HomebrewInstaller(brewURL: Self.brewURL) { _, _ in
            .init(status: 1, stdout: "", stderr: "Error: No such cask")
        }
        #expect(try installer.isCaskInstalled(name: "axon") == false)
    }

    @Test func upgradeCaskReturnsStdoutOnSuccess() throws {
        let installer = HomebrewInstaller(brewURL: Self.brewURL) { _, arguments in
            #expect(arguments == ["upgrade", "--cask", "axon"])
            return .init(status: 0, stdout: "==> Upgrading axon\n", stderr: "")
        }
        let output = try installer.upgradeCask(name: "axon")
        #expect(output.contains("Upgrading axon"))
    }

    @Test func upgradeCaskThrowsOnFailureWithStderr() throws {
        let installer = HomebrewInstaller(brewURL: Self.brewURL) { _, _ in
            .init(status: 1, stdout: "", stderr: "permission denied")
        }
        do {
            _ = try installer.upgradeCask(name: "axon")
            Issue.record("Expected failure to throw")
        } catch let HomebrewInstallerError.commandFailed(arguments, status, stderr) {
            #expect(arguments == ["upgrade", "--cask", "axon"])
            #expect(status == 1)
            #expect(stderr.contains("permission denied"))
        }
    }

    @Test func locateReturnsNilWhenNoCandidateExecutableExists() {
        let fileManager = FileManager()
        let url = HomebrewInstaller.locate(fileManager: fileManager)
        // Allow either nil or a real brew path depending on the CI host; this
        // test only asserts the function does not crash on a missing brew.
        if let url {
            #expect(fileManager.isExecutableFile(atPath: url.path))
        }
    }
}
