import Darwin
import Foundation

/// One launchd job as launchd and the disk describe it, for `axon status`.
public struct JobState: Codable, Equatable, Sendable {
    public let label: String
    /// Whether launchd has the job loaded in the GUI domain.
    public let loaded: Bool
    /// The job's running process, when it has one.
    public let processId: Int?
    /// The program the plist on disk names, or nil when there is no plist.
    public let path: String?

    public init(label: String, loaded: Bool, processId: Int?, path: String?) {
        self.label = label
        self.loaded = loaded
        self.processId = processId
        self.path = path
    }
}

public enum SupervisionError: Error, CustomStringConvertible, Equatable {
    /// `daemon install` from a CLI that is not inside Axon.app.
    case unbundled(cliPath: String)
    /// The bundle is missing an executable one of the jobs runs.
    case incompleteBundle(String)
    /// An install step failed and the previous registration was put back.
    case installRolledBack(step: String, reason: String, restoreFailures: [String])

    public var description: String {
        switch self {
        case let .unbundled(cliPath):
            return """
            \(cliPath) is not inside Axon.app, and the macOS daemon ships only inside Axon.app. \
            Run scripts/package-app and install from its bundle, or for development run \
            `cargo run -p axon-mac -- serve` with AXON_SOCKET_PATH set.
            """
        case let .incompleteBundle(detail):
            return "this Axon.app cannot be registered: \(detail). Reinstall Axon."
        case let .installRolledBack(step, reason, restoreFailures):
            let restored = restoreFailures.isEmpty
                ? "The previous registration was restored."
                : "Restoring the previous registration also failed: \(restoreFailures.joined(separator: "; "))"
            return "daemon install failed to \(step): \(reason). \(restored)"
        }
    }
}

/// What `axon start` does, decided from the registration on disk.
public enum StartPlan: Equatable, Sendable {
    /// Nothing usable is registered for this copy: register both jobs.
    case install
    /// This copy is registered completely: load whichever job is not loaded, then start the menu.
    case resume
    /// Another copy is registered: change nothing, start its menu, and say how to switch.
    case elsewhere(registeredPath: String)
    /// This CLI is not in a bundle and nothing is registered.
    case nothingRegistered
}

/// The two jobs a bundled Axon install registers, managed as one unit.
///
/// The daemon (`dev.axon.daemon`) is the bundle's main executable and the only TCC subject; the
/// menu (`dev.axon.menu`) is the nested `Axon Menu.app`, which holds no grant. They are separate
/// jobs so each is its own responsible process, but they are installed, restarted, stopped, and
/// removed together, because a daemon without its menu has no visible presence and a menu without
/// its daemon shows only an error.
public struct Supervision {
    public let daemon: LaunchAgentManager
    public let menu: LaunchAgentManager

    private let fileManager: FileManager

    public init(daemon: LaunchAgentManager, menu: LaunchAgentManager, fileManager: FileManager = .default) {
        self.daemon = daemon
        self.menu = menu
        self.fileManager = fileManager
    }

    /// The two jobs for the bundle at `bundlePath`, whose main executable `program` is.
    public static func bundled(
        program: DaemonProgram,
        bundlePath: String,
        socketPath: String = AxonEnvironment.defaultSocketPath,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        launchAgentsDirectory: URL? = nil,
        fileManager: FileManager = .default,
        runProcess: @escaping ([String]) throws -> ProcessResult = LaunchAgentManager.runLaunchctl(arguments:)
    ) -> Supervision {
        let daemonConfiguration = LaunchAgentConfiguration(program: program, socketPath: socketPath, environment: environment)
        let menuConfiguration = LaunchAgentConfiguration.menu(bundlePath: bundlePath, socketPath: socketPath)
        return Supervision(
            daemon: LaunchAgentManager(
                configuration: daemonConfiguration,
                plistPath: launchAgentsDirectory?.appendingPathComponent("\(daemonConfiguration.label).plist"),
                fileManager: fileManager,
                runProcess: runProcess
            ),
            menu: LaunchAgentManager(
                configuration: menuConfiguration,
                plistPath: launchAgentsDirectory?.appendingPathComponent("\(menuConfiguration.label).plist"),
                fileManager: fileManager,
                runProcess: runProcess
            ),
            fileManager: fileManager
        )
    }

    /// The two jobs as they are registered, whatever copy is asking.
    ///
    /// For the verbs that act on the installed registration and never write it — restart, stop,
    /// uninstall, status — so running them from a build directory or another copy cannot repoint
    /// anything. Each job's program is read back from its plist.
    public static func registered(
        socketPath: String = AxonEnvironment.defaultSocketPath,
        launchAgentsDirectory: URL? = nil,
        fileManager: FileManager = .default,
        runProcess: @escaping ([String]) throws -> ProcessResult = LaunchAgentManager.runLaunchctl(arguments:)
    ) -> Supervision {
        let directory = launchAgentsDirectory
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents")
        func job(_ label: String) -> LaunchAgentManager {
            let plist = directory.appendingPathComponent("\(label).plist")
            let program = LaunchAgentManager.registration(atPlistPath: plist).path ?? ""
            return LaunchAgentManager(
                configuration: LaunchAgentConfiguration(
                    label: label,
                    program: DaemonProgram(executablePath: program, identity: .executablePath),
                    socketPath: socketPath,
                    environment: [:]
                ),
                plistPath: plist,
                fileManager: fileManager,
                runProcess: runProcess
            )
        }
        return Supervision(
            daemon: job(LaunchAgentConfiguration.daemonLabel),
            menu: job(LaunchAgentConfiguration.menuLabel),
            fileManager: fileManager
        )
    }

    /// Whether a health report comes from the daemon at `program`.
    ///
    /// A report without provenance comes from a release that published none, which is accepted:
    /// what it cannot say it cannot contradict.
    public static func report(_ report: DaemonReport, isFrom program: String) -> Bool {
        guard let provenance = report.provenance else { return true }
        return samePath(provenance.executablePath, program)
    }

    // MARK: - Install

    /// Registers both jobs as one transaction, returning the daemon's first health report.
    ///
    /// Both plists are written before either job is touched, the menu goes out before the daemon
    /// it presents, and the daemon is proven ready before the menu comes back, so the menu never
    /// starts against the daemon being replaced. Any failure puts back the plists that were there
    /// and reloads whatever was loaded before, so a failed install leaves the previous
    /// registration working rather than half-replaced.
    @discardableResult
    public func install(waitUntilReady: () throws -> DaemonReport) throws -> DaemonReport {
        for (job, name) in [(daemon, "daemon"), (menu, "menu")] {
            let path = job.configuration.program.executablePath
            guard fileManager.isExecutableFile(atPath: path) else {
                throw SupervisionError.incompleteBundle("the \(name) executable \(path) is missing")
            }
        }
        let snapshots = [daemon, menu].map { RegistrationSnapshot(of: $0, fileManager: fileManager) }
        var step = "write the daemon registration"
        do {
            try daemon.install()
            step = "write the menu registration"
            try menu.install()
            step = "stop the menu"
            try menu.stop()
            step = "stop the daemon"
            try daemon.stop()
            step = "start the daemon"
            try daemon.load()
            step = "wait for the daemon to become ready"
            let report = try waitUntilReady()
            step = "start the menu"
            try menu.load()
            return report
        } catch {
            let failures = restore(snapshots)
            throw SupervisionError.installRolledBack(
                step: step,
                reason: String(describing: error),
                restoreFailures: failures
            )
        }
    }

    /// Puts back the plists as they were and reloads the jobs that were loaded, daemon first.
    private func restore(_ snapshots: [RegistrationSnapshot]) -> [String] {
        var failures: [String] = []
        for job in [menu, daemon] {
            do { try job.stop() } catch { failures.append("stop \(job.configuration.label): \(error)") }
        }
        for snapshot in snapshots {
            do { try snapshot.restorePlist(fileManager: fileManager) } catch {
                failures.append("restore \(snapshot.manager.plistPath.path): \(error)")
            }
        }
        for snapshot in snapshots where snapshot.wasLoaded {
            do { try snapshot.manager.load() } catch {
                failures.append("reload \(snapshot.manager.configuration.label): \(error)")
            }
        }
        return failures
    }

    // MARK: - Restart, stop, remove

    /// Bounces each job whose plist exists, without rewriting either.
    ///
    /// A registration written by a release that had no menu job has only the daemon's plist, and
    /// restarting it must still work; restarting never adds a job, because that would make
    /// whichever CLI asked the registered one.
    @discardableResult
    public func restart(waitUntilReady: () throws -> DaemonReport) throws -> DaemonReport {
        guard daemon.plistExists else {
            throw LaunchAgentError.notRegistered(daemon.configuration.label)
        }
        let bounceMenu = menu.plistExists
        if bounceMenu {
            try menu.stop()
        }
        try daemon.stop()
        try daemon.load()
        let report = try waitUntilReady()
        if bounceMenu {
            try menu.load()
        }
        return report
    }

    /// Unloads both jobs, menu first, and leaves both plists in place.
    public func stop() throws {
        try menu.stop()
        try daemon.stop()
    }

    /// Unloads and removes both jobs.
    public func uninstall() throws {
        try menu.uninstall()
        try daemon.uninstall()
    }

    public func jobStates() -> [JobState] {
        [daemon.jobState(), menu.jobState()]
    }

    // MARK: - Start

    /// What `axon start` should do for the bundle whose main executable is `mainExecutable`, or
    /// for a CLI outside any bundle when it is nil.
    public func startPlan(mainExecutable: String?) -> StartPlan {
        guard let daemonPlist = daemon.registeredPropertyList(),
              let registered = (daemonPlist["ProgramArguments"] as? [String])?.first
        else {
            return mainExecutable == nil ? .nothingRegistered : .install
        }
        guard let mainExecutable, Self.samePath(registered, mainExecutable) else {
            return .elsewhere(registeredPath: registered)
        }
        if Self.isStale(daemonPlist: daemonPlist) {
            return .install
        }
        guard let menuProgram = (menu.registeredPropertyList()?["ProgramArguments"] as? [String])?.first,
              Self.samePath(menuProgram, menu.configuration.program.executablePath)
        else {
            return .install
        }
        return .resume
    }

    /// Loads whichever job is registered but not loaded, daemon first, then starts the menu if it
    /// is not running. `kickstart` without `-k` leaves a running menu alone, so this is what
    /// brings back a menu someone quit and does nothing to one that is up.
    public func resume() throws {
        for job in [daemon, menu] where job.plistExists && !job.jobState().loaded {
            try job.load()
        }
        try menu.kickstart()
    }

    /// Starts the registered menu of another copy without changing its registration.
    public func startRegisteredMenu() throws {
        guard menu.plistExists else { return }
        if !menu.jobState().loaded {
            try menu.load()
        }
        try menu.kickstart()
    }

    /// A daemon plist this release would not write: an argument after the program (the retired
    /// `serve` registration) or no launchd-managed key, without which the main executable takes
    /// the launcher path instead of serving.
    static func isStale(daemonPlist: [String: Any]) -> Bool {
        let arguments = daemonPlist["ProgramArguments"] as? [String] ?? []
        let environment = daemonPlist["EnvironmentVariables"] as? [String: String] ?? [:]
        return arguments.count != 1 || environment[AxonEnvironment.launchdManagedKey] != "1"
    }

    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: rhs).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// A job's plist and load state before an install touched it.
private struct RegistrationSnapshot {
    let manager: LaunchAgentManager
    let plist: Data?
    let wasLoaded: Bool

    init(of manager: LaunchAgentManager, fileManager: FileManager) {
        self.manager = manager
        plist = fileManager.contents(atPath: manager.plistPath.path)
        wasLoaded = manager.jobState().loaded
    }

    func restorePlist(fileManager: FileManager) throws {
        if let plist {
            try plist.write(to: manager.plistPath, options: .atomic)
        } else if fileManager.fileExists(atPath: manager.plistPath.path) {
            try fileManager.removeItem(at: manager.plistPath)
        }
    }
}

extension LaunchAgentManager {
    public var plistExists: Bool {
        fileManager.fileExists(atPath: plistPath.path)
    }

    /// The plist on disk, decoded.
    func registeredPropertyList() -> [String: Any]? {
        guard let data = fileManager.contents(atPath: plistPath.path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    /// Loads the plist already on disk, booting out a stale load of the same label once if
    /// launchd refuses.
    public func load() throws {
        let domain = Self.launchctlDomain()
        if try runProcess(["bootstrap", domain, plistPath.path]).exitCode == 0 {
            return
        }
        _ = try runProcess(["bootout", "\(domain)/\(configuration.label)"])
        let retry = try runProcess(["bootstrap", domain, plistPath.path])
        guard retry.exitCode == 0 else {
            throw LaunchAgentError.commandFailed("launchctl bootstrap \(configuration.label)", retry)
        }
    }

    /// Starts the loaded job if it is not running; leaves a running one alone.
    public func kickstart() throws {
        let result = try runProcess(["kickstart", "\(Self.launchctlDomain())/\(configuration.label)"])
        guard result.exitCode == 0 else {
            throw LaunchAgentError.commandFailed("launchctl kickstart \(configuration.label)", result)
        }
    }

    public func jobState() -> JobState {
        let path = (registeredPropertyList()?["ProgramArguments"] as? [String])?.first
        guard let result = try? runProcess(["print", "\(Self.launchctlDomain())/\(configuration.label)"]),
              result.exitCode == 0
        else {
            return JobState(label: configuration.label, loaded: false, processId: nil, path: path)
        }
        return JobState(
            label: configuration.label,
            loaded: true,
            processId: Self.processIdentifier(inPrintOutput: result.output),
            path: path
        )
    }

    /// The `pid = N` line of `launchctl print`, present only while the job's process runs.
    static func processIdentifier(inPrintOutput output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = "), let pid = Int(trimmed.dropFirst("pid = ".count)) {
                return pid
            }
        }
        return nil
    }
}
