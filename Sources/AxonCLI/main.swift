import AxonClient
import Darwin
import Foundation
import AxonCore

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "bootstrap"
let socketPath = AxonEnvironment.socketPath()
let jsonEncoder = JSONEncoder()
let axonAppBundleIdentifier = AppBundle.axonDaemonIdentifier
let axonEditorBundleIdentifier = AppBundle.axonEditorIdentifier

do {
    switch command {
    case "doctor":
        try runDoctor()

    case "mcp":
        try runMCPFacade(arguments: Array(arguments.dropFirst()))

    case "start":
        try startAxon()

    case "edit":
        try openAxnEditor(arguments: arguments)

    case "status":
        try printStatus(arguments: arguments)

    case "bootstrap", "setup":
        try runSetup()

    case "daemon":
        try handleDaemonCommand(arguments: arguments)

    case "shutdown":
        try shutdownDaemon()

    case "version", "--version":
        print(AxonVersion.current)

    case "wait_for_stability":
        let response = try SocketClient(path: socketPath, responseTimeoutSeconds: SocketClient.defaultRunResponseTimeoutSeconds)
            .send(JSONRPCRequest(
                id: .string("wait_for_stability"),
                method: "wait_for_stability",
                params: .object(try CLICommandParser.waitForStability(arguments: arguments))
            ))
        try printResponse(response)

    case "permit":
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(id: .string("permit"), method: "permit"))
        try printResponse(response)

    case "refresh-secrets":
        throw CLIError.operationFailed("""
        refresh-secrets was retired in 0.4.0. Axon now redacts only secrets bound to a run's \
        arguments and deterministic credential patterns. To remove the old HMAC key: \
        `security delete-generic-password -s com.bleugreen.axon.active-credential-index -a hmac-key-v1`.
        """)

    case "look":
        let look = try CLICommandParser.look(arguments: arguments)
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(
                id: .string("look"),
                method: "look",
                params: .object(look.params)
            ))
        if let error = response.error {
            throw CLIError.invalidArguments(error.message)
        }
        if case let .array(apps)? = response.result?["apps"] {
            if look.json {
                try printResponse(response)
            } else if look.details {
                for app in apps {
                    let pid = app["processIdentifier"].flatMap(stringValue) ?? "?"
                    let name = app["name"].flatMap(stringValue) ?? "unknown"
                    let bundle = app["bundleIdentifier"].flatMap(stringValue).map { " \($0)" } ?? ""
                    print("\(pid)\t\(name)\(bundle)")
                }
            } else {
                let formatter = AppListFormatter()
                print(formatter.text(from: formatter.observation(from: response.result ?? [:])))
            }
        } else if let snapshot = response.result?["snapshot"] {
            if look.json {
                let data = try jsonEncoder.encode(snapshot)
                print(String(decoding: data, as: UTF8.self))
            } else {
                let formatter = SnapshotObservationFormatter()
                let observation = formatter.observation(
                    from: snapshot,
                    frames: look.frames,
                    maxDepth: lookDepth(in: look.params)
                )
                print(formatter.text(from: observation))
            }
        } else if let children = response.result?["children"] {
            if look.json {
                let data = try jsonEncoder.encode(children)
                print(String(decoding: data, as: UTF8.self))
            } else {
                let formatter = SnapshotObservationFormatter()
                let observation = formatter.children(
                    from: children,
                    frames: look.frames
                )
                print(formatter.text(from: observation))
            }
        } else {
            try printResponse(response)
        }

    case "find":
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(
                id: .string("find"),
                method: "find",
                params: .object(try CLICommandParser.find(arguments: arguments))
        ))
        try printResponse(response)

    case "wait_for_value":
        let response = try SocketClient(path: socketPath, responseTimeoutSeconds: SocketClient.defaultRunResponseTimeoutSeconds)
            .send(JSONRPCRequest(
                id: .string("wait_for_value"),
                method: "wait_for_value",
                params: .object(try CLICommandParser.waitForValue(arguments: arguments))
            ))
        try printResponse(response)

    case "run":
        let response = try SocketClient(path: socketPath, responseTimeoutSeconds: SocketClient.defaultRunResponseTimeoutSeconds)
            .send(JSONRPCRequest(
                id: .string("run"),
                method: "run",
                params: .object(try CLICommandParser.run(arguments: arguments))
            ))
        try printResponse(response)

    case "save":
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(
                id: .string("save"),
                method: "save",
                params: .object(try CLICommandParser.save(arguments: arguments))
            ))
        try printResponse(response)

    case "click":
        try sendAction(method: "click", params: CLICommandParser.click(arguments: arguments))

    case "scroll":
        try sendAction(method: "scroll", params: CLICommandParser.scroll(arguments: arguments))

    case "drag":
        try sendAction(method: "drag", params: CLICommandParser.drag(arguments: arguments))

    case "invoke":
        try sendAction(method: "invoke", params: CLICommandParser.invoke(arguments: arguments))

    case "type":
        try sendAction(method: "type", params: CLICommandParser.type(arguments: arguments))

    case "keyboard":
        try sendAction(method: "keyboard", params: CLICommandParser.keyboard(arguments: arguments))

    case "help", "--help", "-h":
        print("""
        usage: axon [command]

        embedding lifecycle:
          daemon install    register this Axon.app's daemon and menu to start at login, then wait for health
          daemon uninstall  stop the daemon and menu and remove both registrations
          daemon restart    restart the registered daemon and menu and wait for health
          shutdown          stop the daemon and menu, leaving both registrations in place
          status [--json]   describe daemon, registration, session, permissions, capabilities
          version           print the product version

        `daemon install` registers the Axon.app this CLI is inside: its main executable as the
        daemon (`dev.axon.daemon`), so permissions ride the app bundle and survive upgrades, and its
        nested Axon Menu.app as the menu (`dev.axon.menu`). Run it from a permanent location. A CLI
        outside Axon.app cannot install: the macOS daemon ships only inside the bundle.

        commands:
          axon     start Axon and request permissions when needed
          doctor   report the running daemon's permissions
          mcp      run the daemon's MCP stdio facade (this Axon.app's Contents/MacOS/Axon mcp)
          start    register this Axon.app if needed, then start the daemon and its menu
          edit <path.axn>
                  open an axn file in the visual editor
          setup    start Axon and request permissions when needed
          permit   ask macOS to approve the running daemon identity
          \(ToolSurfaceSpec.cliUsageBlock.replacingOccurrences(of: "\n", with: "\n          "))
        """)

    default:
        throw CLIError.missingArguments("unknown command: \(command)")
    }
} catch let error as CLIError {
    fputs("axon: \(error)\n", stderr)
    exit(error.exitCode)
} catch {
    fputs("axon: \(error)\n", stderr)
    exit(1)
}

/// Hands the process to the daemon's own MCP facade; returns only by throwing.
private func runMCPFacade(arguments: [String]) throws {
    switch MCPFacade.plan(invokedExecutable: try resolvedExecutablePath(), arguments: arguments) {
    case let .exec(executable, argv):
        let code = MCPFacade.execute(executable, arguments: argv)
        throw CLIError.operationFailed("could not run \(executable) mcp: \(String(cString: strerror(code)))")
    case let .refuse(message):
        throw CLIError.operationFailed(message)
    }
}

private func sendAction(method: String, params: [String: JSONValue]) throws {
    let response = try SocketClient(path: socketPath)
        .send(JSONRPCRequest(id: .string(method), method: method, params: .object(params)))
    try printResponse(response)
}

/// Reports the running daemon's grants. The daemon is the TCC subject, so it is the one asked; this
/// process's own trust says nothing about what the daemon may do.
private func runDoctor() throws {
    let status = currentStatus()
    guard status.daemon.running else {
        print("Daemon: not running (\(status.daemon.reason ?? HealthReason.unknown))")
        exit(1)
    }
    for permission in status.permissions {
        print("\(permission.name): \(permission.granted ? "granted" : "not granted")")
    }
    let accessibility = status.permissions.first { $0.name == HealthPermission.accessibility }
    exit(accessibility?.granted == true ? 0 : 1)
}

private func lookDepth(in params: [String: JSONValue]) -> Int? {
    guard case let .int(depth)? = params["depth"] else {
        return nil
    }
    return max(0, depth)
}

private func printResponse(_ response: JSONRPCResponse) throws {
    let data = try jsonEncoder.encode(response)
    print(String(decoding: data, as: UTF8.self))
}

private func runSetup() throws {
    try startAxon()
    let report = try? waitForDaemonReport(timeoutSeconds: 5)
    if report?.permissions.first(where: { $0.name == HealthPermission.accessibility })?.granted != true {
        _ = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(id: .string("permit"), method: "permit"))
    }
    printSetupStatus()
}

private func printSetupStatus() {
    let status = currentStatus()
    let accessibility = status.permissions.first { $0.name == HealthPermission.accessibility }
    print("Daemon: \(status.daemon.running ? "running" : "not running")")
    print("Socket: \(socketPath)")
    print("Accessibility: \(accessibility?.granted == true ? "granted" : "not granted")")
    if accessibility?.granted == true {
        print("")
        print("Register with an MCP client:")
        print("  claude mcp add axon -- axon mcp")
        print("  codex mcp add axon -- axon mcp")
    }
}

/// Brings this install up through launchd, registering it first when it has to.
///
/// This is what opening Axon.app runs: the bundle's main executable is the daemon, and an
/// unsupervised open of it calls `start` here and exits. So `start` never opens the outer bundle,
/// which would call back into itself. What it does depends on what is registered (`StartPlan`):
/// nothing, or an incomplete or stale registration of this copy, installs both jobs; a complete one
/// loads whatever is not loaded and starts the menu, which is how a quit menu comes back; another
/// copy's registration is left alone, its menu started, and the way to switch printed.
private func startAxon() throws {
    let bundle = axonBundle()
    let supervision = Supervision.registered(socketPath: socketPath)
    // A bundled CLI decides against its own copy's programs, so a menu registered from another
    // copy reads as incomplete; the registered view would compare that plist with itself.
    let plan = bundle == nil
        ? supervision.startPlan(mainExecutable: nil)
        : try bundledSupervision().startPlan(mainExecutable: bundle?.mainExecutablePath)
    switch plan {
    case .install:
        // Opening a quarantined copy runs it from an App Translocation mount under /var/folders,
        // which disappears; registering that would leave a login item pointing at nothing.
        if let main = bundle?.mainExecutablePath, DaemonRegistrationPath.ephemeralWarning(for: main) != nil {
            throw CLIError.operationFailed(
                "Axon is running from a temporary location (\(main)). Move Axon.app to Applications, then open it again."
            )
        }
        try installDaemon()
    case .resume:
        try bundledSupervision().resume()
        print("Axon is running from \(bundle?.path ?? "this install")")
    case let .elsewhere(registeredPath):
        try supervision.startRegisteredMenu()
        print("Axon is registered from \(registeredPath), which keeps running.")
        if let bundle {
            print("This copy (\(bundle.path)) is not the registered one. To switch to it, choose Use This Copy in its menu, or run:")
            print("  \(URL(fileURLWithPath: bundle.path).appendingPathComponent(AppBundle.bundledCLIRelativePath).path) daemon install")
        }
    case .nothingRegistered:
        throw CLIError.operationFailed(
            "No Axon is registered. Open Axon.app, or run its Contents/Resources/bin/axon daemon install."
        )
    }
}

/// The Axon.app this CLI is inside, when it is inside Axon's own bundle.
private func axonBundle() -> AppBundle? {
    guard let executable = try? resolvedExecutablePath(),
          let bundle = AppBundle.enclosing(executable),
          bundle.identifier == axonAppBundleIdentifier,
          bundle.mainExecutablePath != nil
    else {
        return nil
    }
    return bundle
}

private func openAxnEditor(arguments: [String]) throws {
    guard arguments.count == 2 else {
        throw CLIError.missingArguments("edit requires a path")
    }
    let fileURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let editURL = AxonEditorURL.url(forEditing: fileURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let daemonURL = bundledAxonAppURL() {
        guard let editorURL = AppBundle.pairedEditorURL(beside: daemonURL) else {
            let expected = daemonURL.appendingPathComponent(AppBundle.nestedEditorRelativePath, isDirectory: true)
            throw CLIError.missingArguments(
                "The matching Axon Editor.app was not found at \(expected.path). Reinstall Axon to restore the paired applications."
            )
        }
        process.arguments = ["-a", editorURL.path, editURL.absoluteString]
    } else {
        process.arguments = ["-b", axonEditorBundleIdentifier, editURL.absoluteString]
    }
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CLIError.missingArguments("Could not open axn file editor for \(fileURL.path)")
    }
}

private func bundledAxonAppURL() -> URL? {
    guard
        let executable = try? resolvedExecutablePath(),
        let bundle = AppBundle.enclosing(executable)
    else {
        return nil
    }
    return URL(fileURLWithPath: bundle.path, isDirectory: true)
}

/// The CLI-managed embedding lifecycle: two LaunchAgents, the daemon and its menu, both pointing
/// inside the invoking Axon.app.
///
/// There is one registration truth. Earlier versions copied the binary into an Application Support
/// bundle and registered the copy, which meant the path a consumer installed and the path macOS
/// launched could drift apart, and an upgrade in place left the old copy running. The agents now
/// point inside the invoking install, which is why callers must invoke it from a permanent path.
private func handleDaemonCommand(arguments: [String]) throws {
    guard let subcommand = arguments.dropFirst().first else {
        throw CLIError.missingArguments("daemon requires install, uninstall, or restart")
    }
    switch subcommand {
    case "install":
        try installDaemon()
    case "restart":
        // Restart deliberately does not re-register. It restarts the jobs that are installed,
        // whatever binary is asking, so restarting from a build directory cannot repoint a
        // working installation at a path that is about to disappear.
        let supervision = Supervision.registered(socketPath: socketPath)
        let registered = supervision.daemon.configuration.program.executablePath
        let report = try supervision.restart(waitUntilReady: { try waitForDaemonReport(from: registered) })
        print("restarted \(LaunchAgentConfiguration.daemonLabel) -> \(registered)")
        if supervision.menu.plistExists {
            print("restarted \(LaunchAgentConfiguration.menuLabel) -> \(supervision.menu.configuration.program.executablePath)")
        }
        print("daemon ready (pid \(report.processId), version \(report.version))")
    case "uninstall":
        try Supervision.registered(socketPath: socketPath).uninstall()
        print("unregistered \(LaunchAgentConfiguration.menuLabel) and \(LaunchAgentConfiguration.daemonLabel)")
    default:
        throw CLIError.missingArguments("daemon requires install, uninstall, or restart")
    }
}

/// The two jobs for the Axon.app this CLI is inside.
private func bundledSupervision() throws -> Supervision {
    let invoked = try resolvedExecutablePath()
    let program = DaemonProgram.resolved(invokedExecutable: invoked)
    guard case .appBundle = program.identity, let bundle = AppBundle.enclosing(program.executablePath) else {
        throw SupervisionError.unbundled(cliPath: invoked)
    }
    return Supervision.bundled(
        program: program,
        bundlePath: bundle.path,
        socketPath: socketPath,
        environment: ProcessInfo.processInfo.environment
    )
}

/// `daemon install`: the shell-v1 finisher, and what `start` runs when this copy is not
/// registered completely.
private func installDaemon() throws {
    let supervision = try bundledSupervision()
    let program = supervision.daemon.configuration.program
    warnAboutEphemeralInstall(program.executablePath)
    try stopUnsupervisedDaemon(supervision)
    // Strict for install: the program being registered is this release's daemon, which always says
    // where it runs, and the answer must come from the process launchd just started. A daemon
    // nothing supervises that still holds the socket cannot pass for it.
    let report = try supervision.install(waitUntilReady: {
        try waitForDaemonReport(from: program.executablePath, launchdJob: supervision.daemon)
    })
    print("registered \(supervision.daemon.configuration.label) -> \(program.executablePath)")
    // Which of the two TCC rules this registration follows is the thing a consumer cannot see
    // from the path alone, and it decides whether the next upgrade needs a human in
    // System Settings.
    print("identity: \(program.identityDescription)")
    print("registered \(supervision.menu.configuration.label) -> \(supervision.menu.configuration.program.executablePath)")
    print("daemon ready (pid \(report.processId), version \(report.version))")
    removeRetiredCredentialIndex()
    // Only once this install is proven to answer. Both entry points reach here — the installer
    // script and the in-app update finisher both run `daemon install` — so neither has to carry
    // its own cleanup.
    pruneSupersededInstalls(program: program, registrationPath: supervision.daemon.registration().path)
    LaunchAgentManager.retireUpdateFinisher(ownedBy: getpid())
}

/// Stops a daemon that answers the socket from outside launchd, before anything is written.
///
/// Such a daemon is an earlier Axon that was opened rather than registered, or the 0.3.x app that
/// ran this install as its update finisher and never quit. It holds the socket lock, so the daemon
/// about to be registered could never serve. A rollback cannot bring it back once stopped, which is
/// acceptable: its bundle is the one being replaced.
private func stopUnsupervisedDaemon(_ supervision: Supervision) throws {
    let answering = try? SocketClient(path: socketPath, responseTimeoutSeconds: 2)
        .send(JSONRPCRequest(id: .string("health"), method: "health"))
    let report = answering?.result.flatMap { try? DaemonReport(jsonObject: $0) }
    let launchdPid = Supervision.registered(socketPath: socketPath).daemon.jobState().processId
    guard let incumbent = Supervision.unsupervisedIncumbent(answering: report, launchdPid: launchdPid) else {
        return
    }
    _ = try? SocketClient(path: socketPath, responseTimeoutSeconds: 2)
        .send(JSONRPCRequest(id: .string("shutdown"), method: "shutdown"))
    guard waitUntilDaemonStops(timeoutSeconds: 10) else {
        throw CLIError.operationFailed("""
        Axon \(incumbent.version) (pid \(incumbent.processId)) is running outside launchd and did not stop. \
        Quit it from its menu bar item, then run this again.
        """)
    }
    print("stopped Axon \(incumbent.version) (pid \(incumbent.processId)), which was running outside launchd")
}

/// Deletes the 1Password active-credential index an earlier release left behind.
///
/// It is HMAC digests of secret values and nothing reads it since 0.4.0. The Keychain key that made
/// it meaningful is deliberately left alone: deleting another binary's Keychain item can raise a
/// prompt, which would break a zero-prompt upgrade, so the `refresh-secrets` refusal and the
/// release notes give the command instead.
private func removeRetiredCredentialIndex() {
    let index = AxonEnvironment.retiredActiveCredentialIndexURL()
    guard FileManager.default.fileExists(atPath: index.path) else { return }
    do {
        try FileManager.default.removeItem(at: index)
        print("removed the retired 1Password active-credential index at \(index.path)")
    } catch {
        print("could not remove the retired active-credential index at \(index.path): \(error)")
    }
}

/// Removes install directories this install superseded, once it is serving.
///
/// Applies only to the versioned layout `install.sh` writes, which is the one that accumulates: a
/// bundle at a fixed location is replaced in place and has nothing to leave behind. Failures are
/// reported and never fatal — an install that works must not be undone by a cleanup that does not.
private func pruneSupersededInstalls(program: DaemonProgram, registrationPath: String?) {
    guard let bundle = AppBundle.enclosing(program.executablePath) else {
        return
    }
    let bundleURL = URL(fileURLWithPath: bundle.path, isDirectory: true)
    guard case let .versioned(root, _) = InstallLayout.detect(bundleURL: bundleURL) else {
        return
    }
    let protectedPaths = [bundleURL.path] + (registrationPath.map { [$0] } ?? [])
    for directory in InstallPruning.superseded(root: root, protecting: protectedPaths) {
        do {
            try FileManager.default.removeItem(at: directory)
            print("pruned superseded install \(directory.path)")
        } catch {
            print("could not prune \(directory.path): \(error)")
        }
    }
}

/// Stops the running daemon and its menu while leaving start-at-login registration in place.
///
/// Who is running is asked first, because unloading the agent terminates the daemon and there
/// would be nothing left to ask afterwards. The agents are then unloaded, menu first, before the
/// shutdown request, since `KeepAlive` would otherwise relaunch the daemon in the gap between it
/// acknowledging the request and actually exiting.
private func shutdownDaemon() throws {
    let running = currentStatus().daemon
    let runningProcessID = running.running ? running.processId : nil

    try Supervision.registered(socketPath: socketPath).stop()

    // Anything still answering is a daemon launchd does not own, such as a running Axon.app.
    _ = try? SocketClient(path: socketPath, responseTimeoutSeconds: 2)
        .send(JSONRPCRequest(id: .string("shutdown"), method: "shutdown"))

    guard waitUntilDaemonStops(timeoutSeconds: 5) else {
        throw CLIError.operationFailed("a daemon is still answering at \(socketPath)")
    }
    if let runningProcessID {
        print("stopped daemon (pid \(runningProcessID)); registration left in place")
    } else {
        print("no daemon was running; registration left in place")
    }
}

private func printStatus(arguments: [String]) throws {
    let options = arguments.dropFirst()
    if let unexpected = options.first(where: { $0 != "--json" }) {
        throw CLIError.missingArguments("unexpected status argument: \(unexpected)")
    }
    let status = currentStatus()

    guard options.contains("--json") else {
        func line(_ label: String, _ value: String) {
            print("\(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(value)")
        }
        let daemonState: String
        switch (status.daemon.running, status.daemon.ready) {
        case (true, true):
            daemonState = "ready"
        case (true, false):
            daemonState = "running, not ready (\(status.daemon.reason ?? HealthReason.unknown))"
        default:
            daemonState = "not running (\(status.daemon.reason ?? HealthReason.unknown))"
        }
        line("Version:", status.version)
        line("Daemon:", daemonState)
        line("Endpoint:", status.daemon.endpoint)
        // The launchd label and the bundle identifier are different identities, and only one of
        // them works with `launchctl`. Printing the label beside the path is what saves an operator
        // from guessing `com.bleugreen.axon` — the only identity the product otherwise shows them.
        line("Registration:", status.registration.registered
            ? "\(LaunchAgentConfiguration.daemonLabel) -> \(status.registration.path ?? "registered")"
            : "not registered")
        for job in status.registration.jobs ?? [] {
            let state = job.loaded
                ? (job.processId.map { "loaded, running (pid \($0))" } ?? "loaded, not running")
                : (job.path == nil ? "not registered" : "registered, not loaded")
            line("\(job.label):", job.path.map { "\(state) -> \($0)" } ?? state)
        }
        line("Session:", status.session.graphical
            ? "graphical"
            : "\(status.session.interactive ? "interactive, no desktop" : "not interactive") (\(status.session.reason ?? HealthReason.unknown))")
        for permission in status.permissions {
            line("\(permission.name):", permission.granted ? "granted" : "not granted")
        }
        let unusable = status.capabilities.filter { !$0.usable }.map(\.capability)
        line("Unusable:", unusable.isEmpty ? "none" : unusable.joined(separator: ", "))
        // An install nothing points at is invisible until a client launches its stale CLI, so say
        // it out loud where someone is already looking.
        let orphans = InstallPruning.orphaned(
            root: InstallPruning.defaultRoot,
            referencedPaths: [status.registration.path].compactMap { $0 }
        )
        if !orphans.isEmpty {
            line("Orphaned:", "\(orphans.count) install\(orphans.count == 1 ? "" : "s") nothing points at")
            for orphan in orphans {
                line("", "\(orphan.path) (safe to remove)")
            }
        }
        return
    }
    print(try status.jsonLine())
}

/// Builds the published document.
///
/// A daemon that does not answer is a state to describe, not a failure to report, so every path
/// here produces a schema-valid document. The daemon authors what only it knows; registration is
/// read from disk here because the daemon process does not own that fact.
private func currentStatus() -> HealthStatus {
    let supervision = Supervision.registered(socketPath: socketPath)
    var registration = supervision.daemon.registration()
    registration.jobs = supervision.jobStates()

    do {
        let response = try SocketClient(path: socketPath, responseTimeoutSeconds: StatusProbe.responseTimeoutSeconds)
            .send(JSONRPCRequest(id: .string("status"), method: "health"))
        if let error = response.error {
            return unreachable(registration, HealthReason.daemonUnreachable, error.message)
        }
        do {
            return .running(daemon: try DaemonReport(jsonObject: response.result ?? [:]), registration: registration)
        } catch {
            // A daemon that answers unintelligibly is a running daemon of another version, which
            // is a different machine state from silence and is reported as one.
            return .incompatible(
                endpoint: socketPath,
                registration: registration,
                session: SessionDetection.current(),
                detail: "\(error)"
            )
        }
    } catch let error as SocketError {
        // Failing to connect and failing to get an answer are different machine states, and the
        // difference is the whole point of asking: a socket file with nothing behind it means no
        // daemon, while a daemon that accepts a connection and then says nothing is stuck.
        return unreachable(registration, connectFailed(error) ? HealthReason.daemonNotRunning : HealthReason.daemonUnreachable, error.description)
    } catch {
        return unreachable(registration, HealthReason.daemonUnreachable, "\(error)")
    }
}

/// How long `status` waits for a daemon that accepted the connection to answer.
///
/// Long enough to outlast a genuinely busy daemon — the first permission query against a freshly
/// installed executable makes macOS resolve it against TCC, which has been measured at several
/// seconds — and short enough that describing a stuck one stays a fast operation. A daemon that is
/// simply absent fails at connect and costs nothing.
///
/// Scoped to a type rather than left as a top-level `let`: globals in `main.swift` initialize in
/// statement order, so a plain global read from a function defined above it is silently zero, and
/// a zero timeout makes every read fail instantly. A type's static property is initialized on
/// first use regardless of where it appears in the file.
private enum StatusProbe {
    static let responseTimeoutSeconds: TimeInterval = 10
}

private func connectFailed(_ error: SocketError) -> Bool {
    if case let .operationFailed(operation, _) = error {
        return operation == "connect"
    }
    return false
}

private func unreachable(
    _ registration: RegistrationHealth,
    _ reason: String,
    _ detail: String
) -> HealthStatus {
    .notRunning(
        endpoint: socketPath,
        registration: registration,
        session: SessionDetection.current(),
        reason: reason,
        detail: detail
    )
}

private func warnAboutEphemeralInstall(_ path: String) {
    guard let warning = DaemonRegistrationPath.ephemeralWarning(for: path) else {
        return
    }
    fputs("axon: warning: \(warning)\n", stderr)
}


/// The real path of the running executable, with every symlink resolved.
///
/// Resolution matters because the Homebrew cask installs `axon` as a symlink into the app bundle.
/// This path is what `daemon install` registers with launchd and what callers walk to find the
/// enclosing `.app`; an unresolved link breaks both.
private func resolvedExecutablePath() throws -> String {
    let rawPath = CommandLine.arguments[0]
    let candidate: String
    if rawPath.hasPrefix("/") {
        candidate = rawPath
    } else if !rawPath.contains("/"), let pathExecutable = executablePathFromPATH(rawPath) {
        candidate = pathExecutable
    } else {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidate = currentDirectory.appendingPathComponent(rawPath).standardizedFileURL.path
    }
    return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
}

private func executablePathFromPATH(_ executableName: String) -> String? {
    let fileManager = FileManager.default
    let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    for directory in pathDirectories {
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executableName).path
        if fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// Waits until the daemon answers a health request.
///
/// A successful round trip is the readiness contract: the socket existing proves only that some
/// process bound it, which is exactly the state a half-started daemon leaves behind. With a
/// `program`, the answer must also come from it, so a daemon nothing supervises that still holds
/// the socket cannot pass for the one just registered.
///
/// With a `launchdJob`, the answer must also carry provenance and come from that job's process.
private func waitForDaemonReport(
    from program: String? = nil,
    launchdJob: LaunchAgentManager? = nil,
    timeoutSeconds: TimeInterval = 30
) throws -> DaemonReport {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var lastError: Error = SocketError.connectionClosed

    while Date() < deadline {
        do {
            let response = try SocketClient(path: socketPath, responseTimeoutSeconds: 2)
                .send(JSONRPCRequest(id: .string("health"), method: "health"))
            if let error = response.error {
                throw CLIError.operationFailed(error.message)
            }
            let report = try DaemonReport(jsonObject: response.result ?? [:])
            if let program, !Supervision.report(report, isFrom: program) {
                throw CLIError.operationFailed(
                    "the daemon answering is \(report.provenance?.executablePath ?? "unknown") (pid \(report.processId)), not \(program)"
                )
            }
            if let launchdJob {
                let launchdPid = launchdJob.jobState().processId
                guard report.provenance != nil, launchdPid == report.processId else {
                    throw CLIError.operationFailed(
                        "the daemon answering (pid \(report.processId)) is not \(launchdJob.configuration.label) (pid \(launchdPid.map(String.init) ?? "none"))"
                    )
                }
            }
            return report
        } catch {
            lastError = error
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    throw CLIError.operationFailed("daemon did not become ready at \(socketPath): \(lastError)")
}

private func waitUntilDaemonStops(timeoutSeconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let reachable = (try? SocketClient(path: socketPath, responseTimeoutSeconds: 1)
            .send(JSONRPCRequest(id: .string("health"), method: "health"))) != nil
        if !reachable {
            return true
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return false
}

private func stringValue(_ value: JSONValue) -> String? {
    switch value {
    case let .string(string):
        return string
    case let .int(int):
        return String(int)
    case let .double(double):
        return String(double)
    case let .bool(bool):
        return String(bool)
    case .object, .array, .null:
        return nil
    }
}
