import AppKit
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
        let report = Doctor.run()
        print("Accessibility: \(report.accessibility.status.rawValue)")
        exit(report.isReady ? 0 : 1)

    case "serve":
        ScreenCaptureRuntime.bootstrapSynchronously()
        Doctor.warmUp()
        serveUntilTerminated(socketPath: socketPath)

    case "mcp":
        try MCPStdioServer().run()

    case "start":
        try launchAxonApp()
        print("started Axon.app")

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
        try refreshSecrets(arguments: arguments)

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
          daemon install    register this executable to start at login, then wait for health
          daemon uninstall  stop the daemon and remove the registration
          daemon restart    restart the registered daemon and wait for health
          shutdown          stop the running daemon, leaving the registration in place
          status [--json]   describe daemon, registration, session, permissions, capabilities
          version           print the product version

        `daemon install` registers this install's daemon: the enclosing Axon.app when the CLI is
        inside one, so permissions ride the app bundle and survive upgrades, and otherwise the
        invoking executable itself. Run it from a permanent location either way — installing from
        a build directory registers a path that disappears.

        commands:
          axon     launch Axon.app and request permissions when needed
          doctor   check local permissions
          serve    run the local daemon socket server
          mcp      run an MCP stdio facade backed by the daemon socket
          start    launch the installed Axon.app menu bar service
          edit <path.axn>
                  open an axn file in the visual editor
          setup    launch Axon.app and request permissions when needed
          permit   ask macOS to approve the running daemon identity
          refresh-secrets [--json]
                   refresh the active credential redaction index from 1Password
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

private func sendAction(method: String, params: [String: JSONValue]) throws {
    let response = try SocketClient(path: socketPath)
        .send(JSONRPCRequest(id: .string(method), method: method, params: .object(params)))
    try printResponse(response)
}

private func refreshSecrets(arguments: [String]) throws {
    let json = arguments.dropFirst().contains("--json")
    let unexpected = arguments.dropFirst().first { $0 != "--json" }
    if let unexpected {
        throw CLIError.missingArguments("unexpected refresh-secrets argument: \(unexpected)")
    }

    let result = try ActiveCredentialRefreshService().refresh()
    let cachePath = ActiveCredentialIndexCacheStore().fileURL.path
    let createdAt = ISO8601DateFormatter().string(from: result.cache.createdAt)
    if json {
        let response = JSONValue.object([
            "provider": .string(result.cache.provider),
            "secretCount": .int(result.cache.secretCount),
            "entryCount": .int(result.cache.entries.count),
            "createdAt": .string(createdAt),
            "cachePath": .string(cachePath)
        ])
        let data = try jsonEncoder.encode(response)
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("refreshed active credential index")
        print("Provider: \(result.cache.provider)")
        print("Secrets indexed: \(result.cache.secretCount)")
        print("Index entries: \(result.cache.entries.count)")
        print("Created: \(createdAt)")
        print("Cache: \(cachePath)")
    }
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
    try launchAxonApp()
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
    print("Axon.app: \(isAxonAppRunning() ? "running" : "not running")")
    print("Socket: \(socketPath)")
    print("Accessibility: \(accessibility?.granted == true ? "granted" : "not granted")")
    if accessibility?.granted == true {
        print("")
        print("Register with an MCP client:")
        print("  claude mcp add axon -- axon mcp")
        print("  codex mcp add axon -- axon mcp")
    }
}

private func launchAxonApp() throws {
    if isAxonAppRunning() {
        return
    }
    guard let appURL = axonAppURL() else {
        throw CLIError.missingArguments("Could not find Axon.app. Install with Homebrew cask or run scripts/package-app first.")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [appURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CLIError.missingArguments("Could not open Axon.app at \(appURL.path)")
    }
}

private func openAxnEditor(arguments: [String]) throws {
    guard arguments.count == 2 else {
        throw CLIError.missingArguments("edit requires a path")
    }
    let fileURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let editURL = AxonEditorURL.url(forEditing: fileURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let editorURL = axonEditorAppURL() {
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

private func isAxonAppRunning() -> Bool {
    !runningAxonApps().isEmpty
}

private func runningAxonApps() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: axonAppBundleIdentifier)
}

private func axonAppURL() -> URL? {
    if let bundled = bundledAxonAppURL() {
        return bundled
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: axonAppBundleIdentifier)
}

private func axonEditorAppURL() -> URL? {
    if let daemonURL = bundledAxonAppURL() {
        return AppBundle.pairedEditorURL(beside: daemonURL)
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: axonEditorBundleIdentifier)
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

/// The CLI-managed embedding lifecycle: a LaunchAgent whose program is this install's daemon.
///
/// There is one registration truth. Earlier versions copied the binary into an Application Support
/// bundle and registered the copy, which meant the path a consumer installed and the path macOS
/// launched could drift apart, and an upgrade in place left the old copy running. The agent now
/// points inside the invoking install, which is why callers must invoke it from a permanent path.
/// `DaemonProgram` decides which executable of that install is registered.
private func handleDaemonCommand(arguments: [String]) throws {
    guard let subcommand = arguments.dropFirst().first else {
        throw CLIError.missingArguments("daemon requires install, uninstall, or restart")
    }
    let manager = LaunchAgentManager(configuration: try launchAgentConfiguration())
    switch subcommand {
    case "install":
        let program = manager.configuration.program
        warnAboutEphemeralInstall(program.executablePath)
        try manager.start()
        let report = try waitForDaemonReport()
        print("registered \(manager.configuration.label) -> \(program.executablePath)")
        // Which of the two TCC rules this registration follows is the thing a consumer cannot see
        // from the path alone, and it decides whether the next upgrade needs a human in
        // System Settings.
        print("identity: \(program.identityDescription)")
        print("daemon ready (pid \(report.processId), version \(report.version))")
    case "restart":
        // Restart deliberately does not re-register. It restarts the daemon that is installed,
        // whatever binary is asking, so restarting from a build directory cannot repoint a
        // working installation at a path that is about to disappear.
        let registration = manager.registration()
        try manager.restart()
        let report = try waitForDaemonReport()
        print("restarted \(manager.configuration.label) -> \(registration.path ?? manager.configuration.program.executablePath)")
        print("daemon ready (pid \(report.processId), version \(report.version))")
    case "uninstall":
        try manager.uninstall()
        print("unregistered \(manager.configuration.label)")
    default:
        throw CLIError.missingArguments("daemon requires install, uninstall, or restart")
    }
}

/// Stops the running daemon while leaving start-at-login registration in place.
///
/// Who is running is asked first, because unloading the agent terminates the daemon and there
/// would be nothing left to ask afterwards. The agent is then unloaded before the shutdown
/// request, since `KeepAlive` would otherwise relaunch the daemon in the gap between it
/// acknowledging the request and actually exiting.
private func shutdownDaemon() throws {
    let running = currentStatus().daemon
    let runningProcessID = running.running ? running.processId : nil

    let manager = LaunchAgentManager(configuration: try launchAgentConfiguration())
    try manager.stop()

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
        line("Registration:", status.registration.registered ? status.registration.path ?? "registered" : "not registered")
        line("Session:", status.session.graphical
            ? "graphical"
            : "\(status.session.interactive ? "interactive, no desktop" : "not interactive") (\(status.session.reason ?? HealthReason.unknown))")
        for permission in status.permissions {
            line("\(permission.name):", permission.granted ? "granted" : "not granted")
        }
        let unusable = status.capabilities.filter { !$0.usable }.map(\.capability)
        line("Unusable:", unusable.isEmpty ? "none" : unusable.joined(separator: ", "))
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
    let manager = try? LaunchAgentManager(configuration: launchAgentConfiguration())
    let registration = manager?.registration() ?? .absent(mechanism: .launchd)

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
                session: Doctor.currentSession(),
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
        session: Doctor.currentSession(),
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

private func launchAgentConfiguration() throws -> LaunchAgentConfiguration {
    LaunchAgentConfiguration(
        program: DaemonProgram.resolved(invokedExecutable: try resolvedExecutablePath()),
        socketPath: socketPath,
        environment: ProcessInfo.processInfo.environment
    )
}

/// Serves the socket with the accept loop off the main thread, leaving main to run AppKit.
///
/// Actions reach the main queue for AppKit work — the target badge overlay is drawn there, and it
/// is enabled unless `AXON_VISUAL_OVERLAY` explicitly disables it. Accepting connections on the
/// main thread parks it in `accept()`, so that hop never completes and every element action hangs
/// until the caller times out, while `health` and `look` keep answering from worker threads.
///
/// `AxonDaemonApp` has always run the server this way; `serve` now matches it.
@MainActor
private func serveUntilTerminated(socketPath: String) -> Never {
    let server = SocketServer(path: socketPath)
    let accepting = Thread {
        do {
            try server.run {
                // Announced from here rather than before the call, because ownership of the
                // socket is exclusive and this process may not get it. Printing first would
                // claim a role it is about to be refused.
                print("axon serving on \(socketPath) (pid \(getpid()))")
                fflush(stdout)
            }
            fail("socket server stopped accepting connections")
        } catch {
            fail("socket server failed: \(error)")
        }
    }
    accepting.name = "dev.axon.socket-accept"
    accepting.start()

    // An accessory-policy NSApplication, not a bare run loop: the overlay draws NSPanels, which
    // need a real AppKit event loop rather than only a draining main queue.
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.run()
    fail("AppKit event loop exited")
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("axon: \(message)\n".utf8))
    exit(1)
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
/// process bound it, which is exactly the state a half-started daemon leaves behind.
private func waitForDaemonReport(timeoutSeconds: TimeInterval = 30) throws -> DaemonReport {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var lastError: Error = SocketError.connectionClosed

    while Date() < deadline {
        do {
            let response = try SocketClient(path: socketPath, responseTimeoutSeconds: 2)
                .send(JSONRPCRequest(id: .string("health"), method: "health"))
            if let error = response.error {
                throw CLIError.operationFailed(error.message)
            }
            return try DaemonReport(jsonObject: response.result ?? [:])
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
