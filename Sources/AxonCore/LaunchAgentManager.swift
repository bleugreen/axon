import Darwin
import Foundation

/// What launchd runs, and whose privacy grants it therefore inherits.
///
/// macOS records a TCC grant against the bundle identity of a bundle's *main* executable, and
/// against the absolute path of anything else — including a helper binary inside
/// `Contents/Resources`. Axon installs every release at its own versioned path, so registering the
/// CLI minted a fresh Accessibility identity on each upgrade and demanded a new human approval,
/// while the Screen Recording grant held by the app bundle carried across untouched. Registering
/// the bundle's main executable makes every TCC grant ride `CFBundleIdentifier`, where it survives
/// upgrades and moves alike. Code signing is not involved in this: the designated requirements were
/// already stable across releases.
///
/// The app is a complete daemon in its own right — the same `SocketServer` and `CommandRouter` on
/// the same socket, plus the menu bar — so it needs no arguments. A CLI outside any bundle, which
/// is what a dev build from `.build/` is, is registered as itself with `serve` and keeps the
/// path-keyed identity that implies.
public struct DaemonProgram: Equatable, Sendable {
    /// Who macOS thinks is asking, when the registered program requests a privacy grant.
    public enum Identity: Equatable, Sendable {
        /// A bundle's main executable: grants follow the bundle identifier across paths. The
        /// identifier is the whole identity — two installs of the same app at different versioned
        /// paths are the same TCC subject, which is the property this change exists to hold.
        case appBundle(identifier: String)
        /// Any other executable: grants are keyed to this absolute path and are re-approved when
        /// it changes.
        case executablePath
    }

    public let executablePath: String
    public let identity: Identity

    public init(executablePath: String, identity: Identity) {
        self.executablePath = executablePath
        self.identity = identity
    }

    /// The arguments launchd passes. Derived from the identity rather than stored, because the two
    /// answers are the same fact: the app daemon is launched argument-less, and the CLI needs the
    /// verb that turns it into one.
    public var arguments: [String] {
        switch identity {
        case .appBundle:
            return []
        case .executablePath:
            return ["serve"]
        }
    }

    /// How `daemon install` names the identity it registered, so a consumer can see which of the
    /// two rules its permissions will follow rather than having to know this contract.
    public var identityDescription: String {
        switch identity {
        case let .appBundle(identifier):
            return "\(identifier) (app bundle; permissions persist across upgrades)"
        case .executablePath:
            return "\(executablePath) (executable path; permissions must be granted again if it moves)"
        }
    }

    /// The program to register on behalf of a CLI running at `invokedExecutable`.
    ///
    /// Only Axon's own app bundle is adopted. Merely sitting inside some `.app` proves nothing: the
    /// embedding contract invites a consumer to ship the CLI inside *their* application, and that
    /// layout is indistinguishable from Axon's own by shape alone. Registering whatever bundle
    /// encloses the CLI would hand launchd a foreign application with `RunAtLoad` and `KeepAlive`
    /// set on it — relaunched at every login, serving nothing, and impossible to quit — so the
    /// identifier has to match. Nothing is lost by being strict, because the grants worth
    /// inheriting are recorded against Axon's identifier and no other.
    ///
    /// Everything that is not Axon's app falls back to the invoking CLI, including a bundle whose
    /// `Info.plist` is missing or names a main executable that is not there. A registration that
    /// starts a daemon with a path-keyed identity is worth more than one that starts nothing.
    public static func resolved(
        invokedExecutable: String,
        fileManager: FileManager = .default
    ) -> DaemonProgram {
        guard
            let bundle = AppBundle.enclosing(invokedExecutable, fileManager: fileManager),
            bundle.identifier == AppBundle.axonDaemonIdentifier,
            let mainExecutable = bundle.mainExecutablePath
        else {
            return DaemonProgram(executablePath: invokedExecutable, identity: .executablePath)
        }
        return DaemonProgram(
            executablePath: mainExecutable,
            identity: .appBundle(identifier: AppBundle.axonDaemonIdentifier)
        )
    }
}

public struct LaunchAgentConfiguration: Equatable, Sendable {
    public let label: String
    public let program: DaemonProgram
    public let socketPath: String
    public let environmentVariables: [String: String]
    public let standardOutPath: String
    public let standardErrorPath: String

    public init(
        label: String = "dev.axon.daemon",
        program: DaemonProgram,
        socketPath: String = AxonEnvironment.defaultSocketPath,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.label = label
        self.program = program
        self.socketPath = socketPath

        var daemonEnvironment: [String: String] = [
            "AXON_SOCKET_PATH": socketPath,
            AxonEnvironment.launchdManagedKey: "1"
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
            "ProgramArguments": [program.executablePath] + program.arguments,
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
/// `daemon install` registers where the invoking install lives — the enclosing app bundle's main
/// executable, or the CLI itself when there is no bundle — so installing from a build directory or
/// an unpacked temporary copy registers a path that disappears. Mirrored by
/// `ephemeral_path_warning` in `rust/axon-core/src/lifecycle.rs`.
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
