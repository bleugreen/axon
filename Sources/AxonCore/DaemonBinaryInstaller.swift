import Foundation

public struct DaemonBinaryInstaller {
    public static let defaultSigningIdentifier = "dev.axon.daemon"

    public static var defaultInstallURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Axon/Axon Daemon.app/Contents/MacOS/axon")
    }

    public static var defaultBundleURL: URL {
        defaultInstallURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var legacyInstallURL: URL {
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
        try writeInfoPlist()
        if fileManager.fileExists(atPath: installURL.path) {
            try fileManager.removeItem(at: installURL)
        }
        try fileManager.copyItem(at: sourceURL, to: installURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installURL.path)
        try removeLegacyInstallIfNeeded()

        let result = try runCodesign([
            "--force",
            "--sign",
            "-",
            bundleURL.path
        ])
        guard result.exitCode == 0 else {
            throw DaemonBinaryInstallError.signingFailed(result)
        }
        return installURL
    }

    public func uninstall() throws {
        if fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.removeItem(at: bundleURL)
        }
        try removeLegacyInstallIfNeeded()
    }

    private func writeInfoPlist() throws {
        let contentsURL = installURL.deletingLastPathComponent().deletingLastPathComponent()
        try fileManager.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "axon",
            "CFBundleIdentifier": signingIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Axon Daemon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "LSBackgroundOnly": true
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
    }

    private var bundleURL: URL {
        installURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func removeLegacyInstallIfNeeded() throws {
        let legacyURL = Self.legacyInstallURL
        if legacyURL.path != installURL.path, fileManager.fileExists(atPath: legacyURL.path) {
            try fileManager.removeItem(at: legacyURL)
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
