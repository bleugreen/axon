import Foundation

public struct DaemonBinaryInstaller {
    public static let defaultSigningIdentifier = "dev.axon.daemon"

    public static var defaultInstallURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Axon/bin/axon")
    }

    public let sourceURL: URL
    public let installURL: URL
    public let signingIdentifier: String

    private let fileManager: FileManager
    private let runCodesign: ([String]) throws -> ProcessResult

    public init(
        sourcePath: String,
        installURL: URL = Self.defaultInstallURL,
        signingIdentifier: String = Self.defaultSigningIdentifier,
        fileManager: FileManager = .default,
        runCodesign: @escaping ([String]) throws -> ProcessResult = DaemonBinaryInstaller.runCodesign(arguments:)
    ) {
        self.sourceURL = URL(fileURLWithPath: sourcePath)
        self.installURL = installURL
        self.signingIdentifier = signingIdentifier
        self.fileManager = fileManager
        self.runCodesign = runCodesign
    }

    @discardableResult
    public func install() throws -> URL {
        try fileManager.createDirectory(
            at: installURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: installURL.path) {
            try fileManager.removeItem(at: installURL)
        }
        try fileManager.copyItem(at: sourceURL, to: installURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installURL.path)

        let result = try runCodesign([
            "--force",
            "--sign",
            "-",
            "--identifier",
            signingIdentifier,
            installURL.path
        ])
        guard result.exitCode == 0 else {
            throw DaemonBinaryInstallError.signingFailed(result)
        }
        return installURL
    }

    public func uninstall() throws {
        if fileManager.fileExists(atPath: installURL.path) {
            try fileManager.removeItem(at: installURL)
        }
    }

    public static func runCodesign(arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return ProcessResult(exitCode: process.terminationStatus, output: output, error: error)
    }
}

public enum DaemonBinaryInstallError: Error, CustomStringConvertible {
    case signingFailed(ProcessResult)

    public var description: String {
        switch self {
        case let .signingFailed(result):
            return "codesign failed with exit code \(result.exitCode): \(result.combinedOutput)"
        }
    }
}
