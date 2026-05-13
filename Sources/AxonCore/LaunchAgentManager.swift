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
            "AXON_VISUAL_OVERLAY_PLANNED_MS",
            "AXON_VISUAL_OVERLAY_RESULT_MS"
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

    public var description: String {
        switch self {
        case let .commandFailed(command, result):
            return "\(command) failed with exit code \(result.exitCode): \(result.combinedOutput)"
        }
    }
}
