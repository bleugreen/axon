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
/// The bundle's main executable is the Rust daemon (`axon-mac`), launched argument-less: with the
/// launchd-managed key in its environment it serves. Only Axon's own bundle can be registered; a CLI
/// outside one resolves to `.executablePath`, which `daemon install` refuses, because the CLI is a
/// client and has no daemon to run.
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
    /// Everything that is not Axon's app resolves to the invoking CLI with `.executablePath`,
    /// including a bundle whose `Info.plist` is missing or names a main executable that is not
    /// there; `daemon install` refuses that answer rather than registering a client.
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

/// When launchd restarts a job that exits.
public enum KeepAlive: Equatable, Sendable {
    /// Always: the daemon is supervised, and any exit is a failure to recover from.
    case always
    /// Never: a one-shot job, which would loop forever on a failure it cannot fix.
    case never
    /// Only after a non-zero exit: the menu shell, where Quit exits 0 and means it, and a crash
    /// brings the menu back.
    case onFailure

    /// The `KeepAlive` value launchd reads.
    public var propertyListValue: Any {
        switch self {
        case .always: return true
        case .never: return false
        case .onFailure: return ["SuccessfulExit": false]
        }
    }
}

public struct LaunchAgentConfiguration: Equatable, Sendable {
    /// The launchd label of the daemon job.
    ///
    /// This is the identity `launchctl` takes, and it is not the bundle identifier every
    /// operator-facing surface shows. Anyone reaching for `launchctl bootout` needs this string, so
    /// `axon status` prints it.
    public static let daemonLabel = "dev.axon.daemon"

    /// The launchd label of the one-shot job that finishes an update.
    public static let updateFinisherLabel = "dev.axon.updater"

    /// The launchd label of the menu shell's job.
    ///
    /// A job of its own rather than a child of the daemon, so each process is its own responsible
    /// process and neither inherits the other's privacy attribution.
    public static let menuLabel = "dev.axon.menu"

    public let label: String
    public let program: DaemonProgram
    public let socketPath: String
    public let environmentVariables: [String: String]
    public let standardOutPath: String
    public let standardErrorPath: String
    /// Everything after the program path in `ProgramArguments`.
    public let arguments: [String]
    /// Whether launchd restarts the job when it exits.
    public let keepAlive: KeepAlive

    public init(
        label: String = LaunchAgentConfiguration.daemonLabel,
        program: DaemonProgram,
        socketPath: String = AxonEnvironment.defaultSocketPath,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.label = label
        self.program = program
        self.socketPath = socketPath
        self.arguments = []
        self.keepAlive = .always

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

    private init(
        label: String,
        program: DaemonProgram,
        arguments: [String],
        keepAlive: KeepAlive,
        socketPath: String,
        environmentVariables: [String: String],
        standardOutPath: String,
        standardErrorPath: String
    ) {
        self.label = label
        self.program = program
        self.arguments = arguments
        self.keepAlive = keepAlive
        self.socketPath = socketPath
        self.environmentVariables = environmentVariables
        self.standardOutPath = standardOutPath
        self.standardErrorPath = standardErrorPath
    }

    /// The one-shot job that re-registers the daemon from a newly placed bundle.
    ///
    /// Re-registration means booting out `dev.axon.daemon`, and the app performing the update *is*
    /// that job's process: it cannot survive its own bootout to issue the follow-up bootstrap. A
    /// separate launchd job is precisely the thing that outlives it. It runs the new bundle's CLI
    /// with `daemon install`, which is the operation the field report proved carries both privacy
    /// grants across with no prompt, and it is emphatically not kept alive — it runs once and is
    /// reaped by the successor it started.
    public static func updateFinisher(
        cliPath: String,
        socketPath: String = AxonEnvironment.defaultSocketPath
    ) -> LaunchAgentConfiguration {
        let logDirectory = "\(NSHomeDirectory())/Library/Logs/Axon"
        return LaunchAgentConfiguration(
            label: updateFinisherLabel,
            program: DaemonProgram(executablePath: cliPath, identity: .executablePath),
            arguments: ShellContract.finisherArguments,
            keepAlive: .never,
            socketPath: socketPath,
            environmentVariables: ["AXON_SOCKET_PATH": socketPath],
            standardOutPath: "\(logDirectory)/updater.out.log",
            standardErrorPath: "\(logDirectory)/updater.err.log"
        )
    }

    /// The menu shell's job: `Axon Menu.app` nested in the bundle at `bundlePath`.
    ///
    /// Restarted only after a crash. Quit exits 0 and launchd leaves it stopped, which is the
    /// difference from the daemon: quitting a menu is a person's decision, while the daemon
    /// exiting is always a failure. `Supervision` registers it beside the daemon.
    public static func menu(
        bundlePath: String,
        socketPath: String = AxonEnvironment.defaultSocketPath
    ) -> LaunchAgentConfiguration {
        let logDirectory = "\(NSHomeDirectory())/Library/Logs/Axon"
        let executable = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent(AppBundle.nestedMenuRelativePath)
            .appendingPathComponent("Contents/MacOS/AxonMenu")
            .path
        return LaunchAgentConfiguration(
            label: menuLabel,
            program: DaemonProgram(executablePath: executable, identity: .executablePath),
            arguments: [],
            keepAlive: .onFailure,
            socketPath: socketPath,
            environmentVariables: ["AXON_SOCKET_PATH": socketPath],
            standardOutPath: "\(logDirectory)/menu.out.log",
            standardErrorPath: "\(logDirectory)/menu.err.log"
        )
    }

    public var propertyListObject: [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [program.executablePath] + arguments,
            "EnvironmentVariables": environmentVariables,
            "RunAtLoad": true,
            "KeepAlive": keepAlive.propertyListValue,
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

    let fileManager: FileManager
    let runProcess: ([String]) throws -> ProcessResult

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

    /// A manager for the one-shot update finisher, sharing this type's plist and launchctl paths.
    public static func updateFinisher(
        cliPath: String,
        socketPath: String = AxonEnvironment.defaultSocketPath,
        plistPath: URL? = nil,
        fileManager: FileManager = .default,
        runProcess: @escaping ([String]) throws -> ProcessResult = LaunchAgentManager.runLaunchctl(arguments:)
    ) -> LaunchAgentManager {
        LaunchAgentManager(
            configuration: LaunchAgentConfiguration.updateFinisher(cliPath: cliPath, socketPath: socketPath),
            plistPath: plistPath,
            fileManager: fileManager,
            runProcess: runProcess
        )
    }

    /// Hands the rest of the update to launchd and returns.
    ///
    /// The caller does not terminate itself afterwards. `daemon install` bootstraps, boots out, and
    /// bootstraps again; that bootout is what retires this process, at the moment its successor is
    /// ready to take the socket.
    public static func armUpdateFinisher(
        cliPath: String,
        socketPath: String = AxonEnvironment.defaultSocketPath
    ) throws {
        try updateFinisher(cliPath: cliPath, socketPath: socketPath).start()
    }

    /// Clears the finisher job, which the menu calls when it starts.
    ///
    /// Idempotent and harmless when nothing is registered: the scaffolding of an update is the
    /// successor's to tidy, and a job that never ran leaves nothing behind to find. It takes no
    /// program, because retiring a job needs only its label.
    ///
    /// A finisher that is still running is left alone. Its `daemon install` starts the menu before
    /// it finishes, so the menu reaching here is the normal case rather than a leftover, and booting
    /// the job out would kill the install part-way through. The finisher removes its own plist
    /// when it is done (`retireUpdateFinisher(ownedBy:)`).
    public static func reapUpdateFinisher(
        plistPath: URL? = nil,
        fileManager: FileManager = .default,
        runProcess: ([String]) throws -> ProcessResult = LaunchAgentManager.runLaunchctl(arguments:)
    ) {
        let label = LaunchAgentConfiguration.updateFinisherLabel
        if let printed = try? runProcess(["print", "\(launchctlDomain())/\(label)"]),
           printed.exitCode == 0,
           processIdentifier(inPrintOutput: printed.output) != nil {
            return
        }
        _ = try? runProcess(["bootout", "\(launchctlDomain())/\(label)"])
        let path = plistPath ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        try? fileManager.removeItem(at: path)
    }

    /// Removes the finisher's plist when this process is the finisher, so it never runs again at
    /// the next login. The job itself stays loaded and exited until the menu next reaps it; a job
    /// cannot boot itself out without being killed by it.
    public static func retireUpdateFinisher(
        ownedBy processIdentifier: Int32,
        plistPath: URL? = nil,
        fileManager: FileManager = .default,
        runProcess: ([String]) throws -> ProcessResult = LaunchAgentManager.runLaunchctl(arguments:)
    ) {
        let label = LaunchAgentConfiguration.updateFinisherLabel
        guard let printed = try? runProcess(["print", "\(launchctlDomain())/\(label)"]),
              printed.exitCode == 0,
              Self.processIdentifier(inPrintOutput: printed.output) == Int(processIdentifier)
        else {
            return
        }
        let path = plistPath ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        try? fileManager.removeItem(at: path)
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
        Self.registration(atPlistPath: plistPath)
    }

    /// The daemon registration as it exists on disk, without needing a program to describe.
    ///
    /// A reader asking "what is registered" — the menu bar checking whether it is the copy launchd
    /// runs, `axon status` naming orphaned installs — has no business resolving a program of its
    /// own first, because doing so answers a different question.
    public static func daemonRegistration(label: String = LaunchAgentConfiguration.daemonLabel) -> RegistrationHealth {
        registration(atPlistPath: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist"))
    }

    public static func registration(atPlistPath plistPath: URL) -> RegistrationHealth {
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

    static func launchctlDomain() -> String {
        "gui/\(getuid())"
    }

    private func launchctlDomain() -> String {
        Self.launchctlDomain()
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
