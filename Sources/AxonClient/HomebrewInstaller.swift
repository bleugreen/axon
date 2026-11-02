import Foundation

public enum HomebrewInstallerError: Error, CustomStringConvertible {
    case brewNotFound
    case caskNotInstalled(name: String)
    case commandFailed(arguments: [String], status: Int32, stderr: String)

    public var description: String {
        switch self {
        case .brewNotFound:
            return "Homebrew (brew) is not installed on this system."
        case let .caskNotInstalled(name):
            return "The Homebrew cask '\(name)' is not installed."
        case let .commandFailed(arguments, status, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = trimmed.isEmpty ? "" : ": \(trimmed)"
            return "brew \(arguments.joined(separator: " ")) failed with status \(status)\(suffix)"
        }
    }
}

public struct HomebrewInstaller: Sendable {
    public struct ProcessResult: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String

        public init(status: Int32, stdout: String, stderr: String) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public typealias Runner = @Sendable (URL, [String]) throws -> ProcessResult

    public let brewURL: URL
    private let runner: Runner

    public init(brewURL: URL, runner: @escaping Runner = HomebrewInstaller.defaultRunner) {
        self.brewURL = brewURL
        self.runner = runner
    }

    public static func locate(fileManager: FileManager = .default) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func isCaskInstalled(name: String) throws -> Bool {
        let result = try runner(brewURL, ["list", "--cask", name])
        return result.status == 0
    }

    @discardableResult
    public func upgradeCask(name: String) throws -> String {
        let arguments = ["upgrade", "--cask", name]
        let result = try runner(brewURL, arguments)
        guard result.status == 0 else {
            throw HomebrewInstallerError.commandFailed(
                arguments: arguments,
                status: result.status,
                stderr: result.stderr
            )
        }
        return result.stdout
    }

    public static let defaultRunner: Runner = { brewURL, arguments in
        let process = Process()
        process.executableURL = brewURL
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [existing]).joined(separator: ":")
        process.environment = env

        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("axon-homebrew-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: captureDirectory) }

        let stdoutURL = captureDirectory.appendingPathComponent("stdout")
        let stderrURL = captureDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()

        let stdoutData = try Data(contentsOf: stdoutURL)
        let stderrData = try Data(contentsOf: stderrURL)

        return HomebrewInstaller.ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}
