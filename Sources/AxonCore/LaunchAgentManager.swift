import Darwin
import Foundation

public struct LaunchAgentConfiguration: Equatable, Sendable {
    public let label: String
    public let executablePath: String
    public let socketPath: String
    public let environmentVariables: [String: String]
    public let standardOutPath: String
    public let standardErrorPath: String

    public init(
        label: String = "dev.axon.daemon",
        executablePath: String,
        socketPath: String = AxonEnvironment.defaultSocketPath,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.label = label
        self.executablePath = executablePath
        self.socketPath = socketPath

        var daemonEnvironment: [String: String] = [
            "AXON_SOCKET_PATH": socketPath
        ]
        for key in [
            "AXON_VISUAL_OVERLAY",
            "AXON_VISUAL_OVERLAY_DELAY_MS",
            "AXON_VISUAL_OVERLAY_WAIT"
        ] {
            if let value = environment[key] {
                daemonEnvironment[key] = value
            }
        }
        self.environmentVariables = daemonEnvironment

        let logDirectory = "\(NSHomeDirectory())/Library/Logs/Axon"
        self.standardOutPath = "\(logDirectory)/daemon.out.log"
        self.standardErrorPath = "\(logDirectory)/daemon.err.log"
    }

    public var propertyListObject: [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [
                executablePath,
                "serve"
            ],
            "EnvironmentVariables": environmentVariables,
            "RunAtLoad": true,
            "KeepAlive": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "StandardOutPath": standardOutPath,
            "StandardErrorPath": standardErrorPath
        ]
    }

    public func propertyListData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: propertyListObject,
            format: .xml,
            options: 0
        )
    }
}

public struct LaunchAgentManager {
    public let configuration: LaunchAgentConfiguration
    public let plistPath: URL

    private let fileManager: FileManager
    private let runProcess: ([String]) throws -> ProcessResult

    public init(
        configuration: LaunchAgentConfiguration,
        plistPath: URL? = nil,
        fileManager: FileManager = .default,
        runProcess: @escaping ([String]) throws -> ProcessResult = LaunchAgentManager.runLaunchctl(arguments:)
    ) {
        self.configuration = configuration
        self.plistPath = plistPath ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(configuration.label).plist")
        self.fileManager = fileManager
        self.runProcess = runProcess
    }

    public func install() throws {
        try fileManager.createDirectory(
            at: plistPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            atPath: (configuration.standardOutPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try configuration.propertyListData().write(to: plistPath, options: .atomic)
    }

    public func start() throws {
        try install()
        let result = try runProcess(["bootstrap", launchctlDomain(), plistPath.path])
        if result.exitCode == 0 {
            return
        }
        _ = try runProcess(["bootout", "\(launchctlDomain())/\(configuration.label)"])
        let retry = try runProcess(["bootstrap", launchctlDomain(), plistPath.path])
        if retry.exitCode == 0 {
            return
        }
        let fallback = try runProcess(["kickstart", "-k", "\(launchctlDomain())/\(configuration.label)"])
        guard fallback.exitCode == 0 else {
            throw LaunchAgentError.commandFailed("launchctl bootstrap", retry)
        }
    }

    /// Reloads the installed agent without rewriting it.
    ///
    /// `start()` writes the plist first, which is right for install and wrong for restart. Restart
    /// must restart the daemon that is registered; rewriting the registration would silently
    /// repoint it at whichever binary happened to invoke the command, which is exactly how an
    /// agent restarting from an ephemeral build directory destroys a working installation.
    public func restart() throws {
        guard fileManager.fileExists(atPath: plistPath.path) else {
            throw LaunchAgentError.notRegistered(configuration.label)
        }
        try stop()
        let result = try runProcess(["bootstrap", launchctlDomain(), plistPath.path])
        guard result.exitCode == 0 else {
            throw LaunchAgentError.commandFailed("launchctl bootstrap", result)
        }
    }

    public func stop() throws {
        let result = try runProcess(["bootout", "\(launchctlDomain())/\(configuration.label)"])
        guard result.exitCode == 0 || isMissingServiceOutput(result.combinedOutput) else {
            throw LaunchAgentError.commandFailed("launchctl bootout", result)
        }
    }

    public func status() throws -> String {
        let result = try runProcess(["print", "\(launchctlDomain())/\(configuration.label)"])
        if result.exitCode == 0 {
            return result.combinedOutput
        }
        return "\(configuration.label) is not loaded\n\(result.combinedOutput)"
    }

    public func uninstall() throws {
        try? stop()
        if fileManager.fileExists(atPath: plistPath.path) {
            try fileManager.removeItem(at: plistPath)
        }
    }

    /// The registration as it exists on disk, for health documents.
    ///
    /// Reports the executable the installed agent actually points at rather than the one this
    /// process would register, so a consumer can see when a registration still points at a build
    /// directory that has since been deleted.
    public func registration() -> RegistrationHealth {
        guard
            let data = try? Data(contentsOf: plistPath),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let arguments = (plist as? [String: Any])?["ProgramArguments"] as? [String],
            let executable = arguments.first
        else {
            return .absent(mechanism: .launchd)
        }
        return .present(mechanism: .launchd, path: executable)
    }

    private func launchctlDomain() -> String {
        "gui/\(getuid())"
    }

    private func isMissingServiceOutput(_ output: String) -> Bool {
        output.contains("No such process") || output.contains("Could not find service")
    }

    public static func runLaunchctl(arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
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

/// Whether a path is somewhere a daemon registration should never point.
///
/// `daemon install` registers the invoking executable, so invoking it from a build directory
/// registers a path that disappears on the next clean. Mirrored by `ephemeral_path_warning` in
/// `rust/axon-core/src/lifecycle.rs`.
public enum DaemonRegistrationPath {
    /// Path fragments that mark a location as temporary or build-scoped.
    static let ephemeralMarkers = [
        "/.build/",
        "/target/debug/",
        "/target/release/",
        "/DerivedData/",
        "/.cairn/build-slots/",
        "/var/folders/",
        "/tmp/"
    ]

    public static func ephemeralWarning(for path: String) -> String? {
        guard let marker = ephemeralMarkers.first(where: { path.contains($0) }) else {
            return nil
        }
        return """
        \(path) looks like a build or temporary location (matched "\(marker)"). \
        Start-at-login will fail once it is cleaned up. Install from a permanent path instead.
        """
    }
}

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let output: String
    public let error: String

    public init(exitCode: Int32, output: String = "", error: String = "") {
        self.exitCode = exitCode
        self.output = output
        self.error = error
    }

    public var combinedOutput: String {
        [output, error].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public enum LaunchAgentError: Error, CustomStringConvertible {
    case commandFailed(String, ProcessResult)
    case notRegistered(String)

    public var description: String {
        switch self {
        case let .commandFailed(command, result):
            return "\(command) failed with exit code \(result.exitCode): \(result.combinedOutput)"
        case let .notRegistered(label):
            return "\(label) is not registered; run `axon daemon install` from the permanent install path first"
        }
    }
}
