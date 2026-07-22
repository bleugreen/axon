import AppKit
import Foundation
import AxonCore

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "bootstrap"
let socketPath = AxonEnvironment.socketPath()
let jsonEncoder = JSONEncoder()
let jsonDecoder = JSONDecoder()
let axonAppBundleIdentifier = "com.bleugreen.axon"
let axonEditorBundleIdentifier = "com.bleugreen.axon.editor"

do {
    switch command {
    case "doctor":
        let report = Doctor.run()
        print("Accessibility: \(report.accessibility.status.rawValue)")
        exit(report.isReady ? 0 : 1)

    case "serve":
        ScreenCaptureRuntime.bootstrapSynchronously()
        print("axon serving on \(socketPath)")
        fflush(stdout)
        serveUntilTerminated(socketPath: socketPath)

    case "mcp":
        try MCPStdioServer().run()

    case "start":
        try launchAxonApp()
        print("started Axon.app")

    case "edit":
        try openAxnEditor(arguments: arguments)

    case "status":
        try printHumanStatus()

    case "bootstrap", "setup":
        try runSetup()

    case "quit":
        quitAxonApp()
        print("quit Axon.app")

    case "restart":
        quitAxonApp()
        Thread.sleep(forTimeInterval: 0.5)
        try launchAxonApp()
        print("restarted Axon.app")

    case "daemon":
        try handleDaemonCommand(arguments: arguments)

    case "health":
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(id: .string("health"), method: "health"))
        try printResponse(response)

    case "permit":
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(id: .string("permit"), method: "permit"))
        try printResponse(response)

    case "refresh-secrets":
        try refreshSecrets(arguments: arguments)

    case "look":
        let look = try lookCommand(arguments: arguments)
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
        guard arguments.count >= 3 else {
            throw CLIError.missingArguments("find requires an app and locator JSON")
        }
        let locator = try decodeJSONValue(arguments.dropFirst(2).joined(separator: " "))
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(
                id: .string("find"),
                method: "find",
                params: .object([
                    "app": .string(arguments[1]),
                    "locator": locator
                ])
        ))
        try printResponse(response)

    case "wait_for_value":
        let response = try SocketClient(path: socketPath, responseTimeoutSeconds: SocketClient.defaultRunResponseTimeoutSeconds)
            .send(JSONRPCRequest(
                id: .string("wait_for_value"),
                method: "wait_for_value",
                params: .object(try waitForValueParams(arguments: arguments))
            ))
        try printResponse(response)

    case "run":
        let command = try runCommand(arguments: arguments)
        let response = try SocketClient(path: socketPath, responseTimeoutSeconds: SocketClient.defaultRunResponseTimeoutSeconds)
            .send(JSONRPCRequest(
                id: .string(command.method),
                method: command.method,
                params: .object(command.params)
            ))
        try printResponse(response)

    case "save":
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(
                id: .string("save"),
                method: "save",
                params: .object(try saveParams(arguments: arguments))
            ))
        try printResponse(response)

    case "click":
        let target = try requiredArgument(after: command, in: arguments)
        try sendAction(method: "click", params: ["target": targetArgument(target)])

    case "scroll":
        try sendAction(method: "scroll", params: scrollParams(arguments: arguments))

    case "drag":
        try sendAction(method: "drag", params: dragParams(arguments: arguments))

    case "invoke":
        guard arguments.count >= 3 else {
            throw CLIError.missingArguments("invoke requires a target and action name")
        }
        try sendAction(method: "invoke", params: [
            "target": .string(arguments[1]),
            "name": .string(arguments[2])
        ])

    case "type":
        guard arguments.count >= 3 else {
            throw CLIError.missingArguments("type requires a target and value")
        }
        try sendAction(method: "type", params: [
            "target": .string(arguments[1]),
            "value": .string(arguments.dropFirst(2).joined(separator: " "))
        ])

    case "keyboard":
        try sendAction(method: "keyboard", params: try keyboardParams(arguments: arguments))

    case "help", "--help", "-h":
        print("""
        usage: axon [command]

        commands:
          axon     launch Axon.app and request permissions when needed
          doctor   check local permissions
          serve    run the local daemon socket server
          mcp      run an MCP stdio facade backed by the daemon socket
          start    launch the installed Axon.app menu bar service
          edit <path.axn>
                  open an axn file in the visual editor
          status   print app-backed daemon status
          setup    launch Axon.app and request permissions when needed
          quit     quit the installed Axon.app service
          restart  restart the installed Axon.app service
          daemon <install|start|stop|status|uninstall>
          health   request daemon health over the local socket
          permit   ask macOS to approve the running daemon identity
          refresh-secrets [--json]
                   refresh the active credential redaction index from 1Password
          \(ToolSurfaceSpec.cliUsageBlock.replacingOccurrences(of: "\n", with: "\n          "))
        """)

    default:
        throw CLIError.missingArguments("unknown command: \(command)")
    }
} catch {
    fputs("axon: \(error)\n", stderr)
    exit(1)
}

private func requiredArgument(after command: String, in arguments: [String]) throws -> String {
    guard arguments.count >= 2 else {
        throw CLIError.missingArgument(command)
    }
    return arguments[1]
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

private func targetArgument(_ argument: String) -> JSONValue {
    (try? decodeJSONValue(argument)) ?? .string(argument)
}

private func lookCommand(arguments: [String]) throws -> (params: [String: JSONValue], frames: Bool, json: Bool, details: Bool) {
    var params: [String: JSONValue] = [:]
    var frames = false
    var json = false
    var details = false
    var target: String?
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--since":
            guard index + 1 < arguments.count else {
                throw CLIError.missingArguments("look --since requires a snapshot id")
            }
            params["since"] = .string(arguments[index + 1])
            index += 2
        case "--screenshot":
            params["screenshot"] = .bool(true)
            index += 1
        case "--screen-text":
            params["screenText"] = .bool(true)
            index += 1
        case "--frames":
            frames = true
            index += 1
        case "--json":
            json = true
            index += 1
        case "--details", "--debug":
            details = true
            json = arguments[index] == "--debug"
            params["all"] = .bool(true)
            if arguments[index] == "--debug" {
                params["format"] = .string("debug")
            }
            index += 1
        case "--no-tree":
            params["tree"] = .bool(false)
            index += 1
        case "--offset":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                throw CLIError.missingArguments("look --offset requires an integer")
            }
            params["offset"] = .int(value)
            index += 2
        case "--limit":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                throw CLIError.missingArguments("look --limit requires an integer")
            }
            params["limit"] = .int(value)
            index += 2
        case "--depth":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                throw CLIError.missingArguments("look --depth requires an integer")
            }
            params["depth"] = .int(value)
            index += 2
        default:
            if target == nil {
                target = arguments[index]
                index += 1
            } else {
                throw CLIError.missingArguments("unexpected look argument: \(arguments[index])")
            }
        }
    }
    if let target {
        params["target"] = .string(target)
    }
    return (params, frames, json, details)
}

private func lookDepth(in params: [String: JSONValue]) -> Int? {
    guard case let .int(depth)? = params["depth"] else {
        return nil
    }
    return max(0, depth)
}

private func waitForValueParams(arguments: [String]) throws -> [String: JSONValue] {
    guard arguments.count >= 4 else {
        throw CLIError.missingArguments("wait_for_value requires a target JSON and exactly one predicate")
    }
    var params: [String: JSONValue] = ["target": try decodeJSONValue(arguments[1])]
    var index = 2
    while index < arguments.count {
        switch arguments[index] {
        case "--contains":
            guard index + 1 < arguments.count else { throw CLIError.missingArguments("wait_for_value --contains requires text") }
            params["contains"] = .string(arguments[index + 1])
            index += 2
        case "--equals":
            guard index + 1 < arguments.count else { throw CLIError.missingArguments("wait_for_value --equals requires text") }
            params["equals"] = .string(arguments[index + 1])
            index += 2
        case "--matches":
            guard index + 1 < arguments.count else { throw CLIError.missingArguments("wait_for_value --matches requires a regex") }
            params["matches"] = .string(arguments[index + 1])
            index += 2
        case "--timeout-ms":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                throw CLIError.missingArguments("wait_for_value --timeout-ms requires an integer")
            }
            params["timeoutMs"] = .int(value)
            index += 2
        case "--interval-ms":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                throw CLIError.missingArguments("wait_for_value --interval-ms requires an integer")
            }
            params["intervalMs"] = .int(value)
            index += 2
        default:
            throw CLIError.missingArguments("unexpected wait_for_value argument: \(arguments[index])")
        }
    }
    return params
}

private func keyboardParams(arguments: [String]) throws -> [String: JSONValue] {
    var params: [String: JSONValue] = [:]
    var keys: [String] = []
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--app":
            guard index + 1 < arguments.count else {
                throw CLIError.missingArguments("keyboard --app requires an app")
            }
            params["app"] = .string(arguments[index + 1])
            index += 2
        default:
            keys.append(arguments[index])
            index += 1
        }
    }
    guard !keys.isEmpty else {
        throw CLIError.missingArguments("keyboard requires keys or text")
    }
    params["keys"] = .string(keys.joined(separator: " "))
    return params
}

private func scrollParams(arguments: [String]) throws -> [String: JSONValue] {
    var params: [String: JSONValue] = [:]
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--app":
            guard index + 1 < arguments.count else {
                throw CLIError.missingArguments("scroll --app requires an app")
            }
            params["app"] = .string(arguments[index + 1])
            index += 2
        case "--target":
            guard index + 1 < arguments.count else {
                throw CLIError.missingArguments("scroll --target requires target JSON or handle")
            }
            params["target"] = targetArgument(arguments[index + 1])
            index += 2
        case "--dx":
            guard index + 1 < arguments.count, let value = Double(arguments[index + 1]) else {
                throw CLIError.missingArguments("scroll --dx requires a number")
            }
            params["deltaX"] = .double(value)
            index += 2
        case "--dy":
            guard index + 1 < arguments.count, let value = Double(arguments[index + 1]) else {
                throw CLIError.missingArguments("scroll --dy requires a number")
            }
            params["deltaY"] = .double(value)
            index += 2
        default:
            throw CLIError.missingArguments("unexpected scroll argument: \(arguments[index])")
        }
    }
    return params
}

private func dragParams(arguments: [String]) throws -> [String: JSONValue] {
    var params: [String: JSONValue] = [:]
    var endpoints: [JSONValue] = []
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--app":
            guard index + 1 < arguments.count else {
                throw CLIError.missingArguments("drag --app requires an app")
            }
            params["app"] = .string(arguments[index + 1])
            index += 2
        case "--duration-ms":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                throw CLIError.missingArguments("drag --duration-ms requires an integer")
            }
            params["durationMs"] = .int(value)
            index += 2
        default:
            endpoints.append(targetArgument(arguments[index]))
            index += 1
        }
    }
    guard endpoints.count == 2 else {
        throw CLIError.missingArguments("drag requires from-json and to-json")
    }
    params["from"] = endpoints[0]
    params["to"] = endpoints[1]
    return params
}

private func saveParams(arguments: [String]) throws -> [String: JSONValue] {
    var params: [String: JSONValue] = [:]
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--session":
            guard index + 1 < arguments.count else {
                throw CLIError.missingArguments("save --session requires an id")
            }
            params["sessionId"] = .string(arguments[index + 1])
            index += 2
        case "--from":
            guard index + 1 < arguments.count else {
                throw CLIError.missingArguments("save --from requires a call id")
            }
            params["from"] = .string(arguments[index + 1])
            index += 2
        case "--to":
            guard index + 1 < arguments.count else {
                throw CLIError.missingArguments("save --to requires a call id")
            }
            params["to"] = .string(arguments[index + 1])
            index += 2
        case "--path":
            guard index + 1 < arguments.count else {
                throw CLIError.missingArguments("save --path requires a file path")
            }
            params["path"] = .string(arguments[index + 1])
            index += 2
        case "--include-reads":
            params["includeReads"] = .bool(true)
            index += 1
        default:
            throw CLIError.missingArguments("unexpected save argument: \(arguments[index])")
        }
    }
    return params
}

private func decodeJSONValue(_ rawValue: String) throws -> JSONValue {
    try jsonDecoder.decode(JSONValue.self, from: Data(rawValue.utf8))
}

private func printResponse(_ response: JSONRPCResponse) throws {
    let data = try jsonEncoder.encode(response)
    print(String(decoding: data, as: UTF8.self))
}

private func runSetup() throws {
    try launchAxonApp()
    _ = try? waitForDaemonHealth(socketPath: socketPath, timeoutSeconds: 5)
    let health = try SocketClient(path: socketPath, responseTimeoutSeconds: 2)
        .send(JSONRPCRequest(id: .string("setup-health"), method: "health"))
    if health.result?["accessibility"].flatMap(stringValue) != PermissionStatus.trusted.rawValue {
        _ = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(id: .string("permit"), method: "permit"))
    }
    try printSetupStatus()
}

private func printHumanStatus() throws {
    do {
        let health = try SocketClient(path: socketPath, responseTimeoutSeconds: 2)
            .send(JSONRPCRequest(id: .string("status"), method: "health"))
        let accessibility = health.result?["accessibility"].flatMap(stringValue) ?? "unknown"
        print("Axon.app: \(isAxonAppRunning() ? "running" : "not running")")
        print("Socket: \(socketPath)")
        print("Accessibility: \(accessibility)")
    } catch {
        print("Axon.app: \(isAxonAppRunning() ? "running" : "not running")")
        print("Socket: unreachable at \(socketPath)")
        print("Error: \(error)")
        exit(1)
    }
}

private func printSetupStatus() throws {
    let health = try SocketClient(path: socketPath, responseTimeoutSeconds: 2)
        .send(JSONRPCRequest(id: .string("setup-health"), method: "health"))
    let accessibility = health.result?["accessibility"].flatMap(stringValue)
        ?? "unknown"
    print("Axon.app: \(isAxonAppRunning() ? "running" : "not running")")
    print("Socket: \(socketPath)")
    print("Accessibility: \(accessibility)")
    if accessibility == PermissionStatus.trusted.rawValue {
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

private func quitAxonApp() {
    for app in runningAxonApps() {
        app.terminate()
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
        let sibling = daemonURL
            .deletingLastPathComponent()
            .appendingPathComponent("Axon Editor.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: axonEditorBundleIdentifier)
}

private func bundledAxonAppURL() -> URL? {
    guard let executable = try? resolvedExecutablePath() else {
        return nil
    }
    var url = URL(fileURLWithPath: executable).deletingLastPathComponent()
    while url.path != "/" {
        if url.pathExtension == "app" {
            return url
        }
        url.deleteLastPathComponent()
    }
    return nil
}

private func runCommand(arguments: [String]) throws -> (method: String, params: [String: JSONValue]) {
    var params: [String: JSONValue] = [:]
    var index = 1
    var path: String?
    var argValues: [String: JSONValue] = [:]

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--continue-on-error":
            params["continueOnError"] = .bool(true)
            index += 1
        case "--dry-run":
            params["dryRun"] = .bool(true)
            index += 1
        case "--arg":
            guard index + 1 < arguments.count else {
                throw CLIError.missingArguments("run --arg requires name=value")
            }
            let assignment = arguments[index + 1]
            guard let separator = assignment.firstIndex(of: "="), separator > assignment.startIndex else {
                throw CLIError.missingArguments("run --arg requires name=value")
            }
            let name = String(assignment[..<separator])
            let value = String(assignment[assignment.index(after: separator)...])
            argValues[name] = .string(value)
            index += 2
        default:
            if path == nil {
                path = argument
                index += 1
            } else {
                throw CLIError.missingArguments("unexpected run argument: \(argument)")
            }
        }
    }

    guard let path else {
        throw CLIError.missingArguments("run requires a path")
    }
    params["path"] = .string(path)
    if !argValues.isEmpty {
        params["argValues"] = .object(argValues)
    }

    return ("run", params)
}

private func handleDaemonCommand(arguments: [String]) throws {
    let subcommand = arguments.dropFirst().first ?? "status"
    let manager = LaunchAgentManager(configuration: try launchAgentConfiguration())
    let installer = try daemonBinaryInstaller()
    switch subcommand {
    case "install":
        let installedURL = try installer.install()
        try manager.install()
        print("installed \(manager.configuration.label) at \(manager.plistPath.path)")
        print("installed daemon binary at \(installedURL.path)")
    case "start":
        try installer.install()
        try manager.start()
        let health = try waitForDaemonHealth(socketPath: socketPath)
        let accessibility = health.result?["accessibility"].flatMap(stringValue) ?? "unknown"
        print("started \(manager.configuration.label) (accessibility: \(accessibility))")
    case "stop":
        try manager.stop()
        print("stopped \(manager.configuration.label)")
    case "status":
        let status = try manager.status()
        print(status)
    case "uninstall":
        try manager.uninstall()
        try installer.uninstall()
        print("uninstalled \(manager.configuration.label)")
    default:
        throw CLIError.missingArguments("daemon requires install, start, stop, status, or uninstall")
    }
}

private func launchAgentConfiguration() throws -> LaunchAgentConfiguration {
    LaunchAgentConfiguration(
        executablePath: DaemonBinaryInstaller.defaultInstallURL.path,
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
            try server.run()
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

private func daemonBinaryInstaller() throws -> DaemonBinaryInstaller {
    DaemonBinaryInstaller(sourcePath: try resolvedExecutablePath())
}

/// The real path of the running executable, with every symlink resolved.
///
/// Resolution matters because the Homebrew cask installs `axon` as a symlink into the app
/// bundle. Callers copy this path into the daemon bundle and walk it to find the enclosing
/// `.app`; an unresolved link breaks both.
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

private func waitForDaemonHealth(socketPath: String, timeoutSeconds: TimeInterval = 3) throws -> JSONRPCResponse {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var lastError: Error?

    while Date() < deadline {
        do {
            return try SocketClient(path: socketPath)
                .send(JSONRPCRequest(id: .string("health"), method: "health"))
        } catch {
            lastError = error
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    if let lastError {
        throw lastError
    }
    throw SocketError.connectionClosed
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

private enum CLIError: Error, CustomStringConvertible {
    case missingArgument(String)
    case missingArguments(String)
    case invalidArguments(String)

    var description: String {
        switch self {
        case let .missingArgument(command):
            return "\(command) requires an app argument"
        case let .missingArguments(message):
            return message
        case let .invalidArguments(message):
            return message
        }
    }
}
