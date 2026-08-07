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
        Doctor.warmUp()
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
                params: .object(try waitForStabilityParams(arguments: arguments))
            ))
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

        embedding lifecycle:
          daemon install    register this executable to start at login, then wait for health
          daemon uninstall  stop the daemon and remove the registration
          daemon restart    restart the registered daemon and wait for health
          shutdown          stop the running daemon, leaving the registration in place
          status [--json]   describe daemon, registration, session, permissions, capabilities
          version           print the product version

        `daemon install` registers the path of the executable you invoked, so run it from a
        permanent location. Installing from a build directory registers a path that disappears.

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

private func waitForStabilityParams(arguments: [String]) throws -> [String: JSONValue] {
    guard arguments.count >= 2 else { throw CLIError.missingArguments("wait_for_stability requires an app") }
    var params: [String: JSONValue] = ["app": .string(arguments[1])]
    var index = 2
    while index < arguments.count {
        let key: String
        switch arguments[index] {
        case "--condition": key = "condition"
        case "--stable-ms": key = "stableMs"
        case "--timeout-ms": key = "timeoutMs"
        case "--interval-ms": key = "intervalMs"
        default: throw CLIError.missingArguments("unexpected wait_for_stability argument: \(arguments[index])")
        }
        guard index + 1 < arguments.count else { throw CLIError.missingArguments("wait_for_stability \(arguments[index]) requires a value") }
        if key == "condition" {
            params[key] = .string(arguments[index + 1])
        } else if let value = Int(arguments[index + 1]) {
            params[key] = .int(value)
        } else {
            throw CLIError.missingArguments("wait_for_stability \(arguments[index]) requires an integer")
        }
        index += 2
    }
    return params
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
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--app":
            guard index + 1 < arguments.count else {
                throw CLIError.missingArguments("keyboard --app requires an app")
            }
            params["app"] = .string(arguments[index + 1])
            index += 2
        case "--text", "--key":
            let option = String(arguments[index].dropFirst(2))
            guard index + 1 < arguments.count else {
                throw CLIError.missingArguments("keyboard --\(option) requires a value")
            }
            guard params[option] == nil else {
                throw CLIError.missingArguments("keyboard --\(option) may only be provided once")
            }
            params[option] = .string(arguments[index + 1])
            index += 2
        default:
            throw CLIError.missingArguments("unexpected keyboard argument: \(arguments[index]); use --text or --key")
        }
    }
    guard (params["text"] == nil) != (params["key"] == nil) else {
        throw CLIError.missingArguments("keyboard requires exactly one of --text or --key")
    }
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

/// The CLI-managed embedding lifecycle: a LaunchAgent whose program is this executable.
///
/// There is one registration truth. Earlier versions copied the binary into an Application Support
/// bundle and registered the copy, which meant the path a consumer installed and the path macOS
/// launched could drift apart, and an upgrade in place left the old copy running. The agent now
/// points at the invoking executable, which is why callers must invoke it from a permanent path.
private func handleDaemonCommand(arguments: [String]) throws {
    guard let subcommand = arguments.dropFirst().first else {
        throw CLIError.missingArguments("daemon requires install, uninstall, or restart")
    }
    let manager = LaunchAgentManager(configuration: try launchAgentConfiguration())
    switch subcommand {
    case "install":
        warnAboutEphemeralInstall(manager.configuration.executablePath)
        try manager.start()
        let report = try waitForDaemonReport()
        print("registered \(manager.configuration.label) -> \(manager.configuration.executablePath)")
        print("daemon ready (pid \(report.processId), version \(report.version))")
    case "restart":
        try manager.stop()
        try manager.start()
        let report = try waitForDaemonReport()
        print("restarted \(manager.configuration.label) (pid \(report.processId), version \(report.version))")
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
        let response = try SocketClient(path: socketPath, responseTimeoutSeconds: statusResponseTimeoutSeconds)
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
/// Long enough to outlast a genuinely busy daemon, short enough that describing a stuck one stays
/// a fast operation. A daemon that is simply absent fails at connect and costs nothing.
private let statusResponseTimeoutSeconds: TimeInterval = 10

private func connectFailed(_ error: SocketError) -> Bool {
    if case let .operationFailed(operation) = error {
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
        executablePath: try resolvedExecutablePath(),
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

private enum CLIError: Error, CustomStringConvertible {
    case missingArgument(String)
    case missingArguments(String)
    case invalidArguments(String)
    case operationFailed(String)

    var description: String {
        switch self {
        case let .missingArgument(command):
            return "\(command) requires an app argument"
        case let .missingArguments(message):
            return message
        case let .invalidArguments(message):
            return message
        case let .operationFailed(message):
            return message
        }
    }

    /// The shared exit-code contract: 2 means the command was used wrongly, 1 means it was used
    /// correctly and could not be completed. Anything a consumer scripts against depends on the
    /// difference, so it is stated once here rather than at each throw site.
    var exitCode: Int32 {
        switch self {
        case .missingArgument, .missingArguments:
            return 2
        case .invalidArguments, .operationFailed:
            return 1
        }
    }
}
