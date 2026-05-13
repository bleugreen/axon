import Foundation
import AxonCore

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let socketPath = AxonEnvironment.socketPath()
let jsonEncoder = JSONEncoder()
let jsonDecoder = JSONDecoder()

do {
    switch command {
    case "doctor":
        let report = Doctor.run()
        print("Accessibility: \(report.accessibility.status.rawValue)")
        exit(report.isReady ? 0 : 1)

    case "serve":
        print("axon serving on \(socketPath)")
        fflush(stdout)
        try SocketServer(path: socketPath).run()

    case "mcp":
        try MCPStdioServer().run()

    case "daemon":
        try handleDaemonCommand(arguments: arguments)

    case "health":
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(id: .string("health"), method: "health"))
        try printResponse(response)

    case "request-accessibility":
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(id: .string("request_accessibility"), method: "request_accessibility"))
        try printResponse(response)

    case "apps":
        for app in AppResolver().runningApps() {
            let bundle = app.bundleIdentifier.map { " \($0)" } ?? ""
            print("\(app.processIdentifier)\t\(app.name)\(bundle)")
        }

    case "snapshot":
        let app = try requiredArgument(after: command, in: arguments)
        let snapshot = try AXSnapshotCapturer().capture(app: app, includeScreenshot: true)
        print(SnapshotTextFormatter().format(snapshot))

    case "snapshot-json":
        let app = try requiredArgument(after: command, in: arguments)
        let includeTree = !arguments.contains("--compact")
        let includeScreenshot = !arguments.contains("--no-screenshot")
        let snapshot = try AXSnapshotCapturer().capture(app: app, includeScreenshot: includeScreenshot)
        let data = try jsonEncoder.encode(snapshot.jsonValue(includeTree: includeTree))
        print(String(decoding: data, as: UTF8.self))

    case "screenshot":
        let app = try requiredArgument(after: command, in: arguments)
        let identity = try AppResolver().resolveIdentity(app)
        let screenshot = ScreenshotCapturer().capture(app: identity)
            ?? EncodedScreenshot(mediaType: "image/png", base64Data: "", width: 0, height: 0)
        let data = try jsonEncoder.encode(screenshot.jsonValue)
        print(String(decoding: data, as: UTF8.self))

    case "resolve":
        guard arguments.count >= 3 else {
            throw CLIError.missingArguments("resolve requires an app and locator JSON")
        }
        let locator = try decodeJSONValue(arguments.dropFirst(2).joined(separator: " "))
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(
                id: .string("resolve"),
                method: "resolve",
                params: .object([
                    "app": .string(arguments[1]),
                    "locator": locator
                ])
            ))
        try printResponse(response)

    case "click":
        let target = try requiredArgument(after: command, in: arguments)
        try sendAction(method: "click", params: ["target": .string(target)])

    case "perform-action":
        guard arguments.count >= 3 else {
            throw CLIError.missingArguments("perform-action requires a target and action")
        }
        try sendAction(method: "perform_action", params: [
            "target": .string(arguments[1]),
            "action": .string(arguments[2])
        ])

    case "set-value":
        guard arguments.count >= 3 else {
            throw CLIError.missingArguments("set-value requires a target and value")
        }
        try sendAction(method: "set_value", params: [
            "target": .string(arguments[1]),
            "value": .string(arguments.dropFirst(2).joined(separator: " "))
        ])

    case "type-text":
        guard arguments.count >= 3 else {
            throw CLIError.missingArguments("type-text requires an app and text")
        }
        try sendAction(method: "type_text", params: [
            "app": .string(arguments[1]),
            "text": .string(arguments.dropFirst(2).joined(separator: " "))
        ])

    case "press-key":
        guard arguments.count >= 3 else {
            throw CLIError.missingArguments("press-key requires an app and key")
        }
        try sendAction(method: "press_key", params: [
            "app": .string(arguments[1]),
            "key": .string(arguments[2])
        ])

    default:
        print("""
        usage: axon <command>

        commands:
          doctor   check local permissions
          serve    run the local daemon socket server
          mcp      run an MCP stdio facade backed by the daemon socket
          daemon <install|start|stop|status|uninstall>
          health   request daemon health over the local socket
          request-accessibility   ask macOS to approve the running daemon identity
          apps     list running apps
          snapshot <app>    print an indexed AX tree for a running app
          snapshot-json <app> [--compact] [--no-screenshot]
          screenshot <app>  print embedded screenshot JSON for a running app
          resolve <app> <locator-json>
          click <handle>    click a retained snapshot element through the daemon
          perform-action <handle> <action>
          set-value <handle> <value>
          type-text <app> <text>
          press-key <app> <key>
        """)
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

private func decodeJSONValue(_ rawValue: String) throws -> JSONValue {
    try jsonDecoder.decode(JSONValue.self, from: Data(rawValue.utf8))
}

private func printResponse(_ response: JSONRPCResponse) throws {
    let data = try jsonEncoder.encode(response)
    print(String(decoding: data, as: UTF8.self))
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

private func daemonBinaryInstaller() throws -> DaemonBinaryInstaller {
    DaemonBinaryInstaller(sourcePath: try resolvedExecutablePath())
}

private func resolvedExecutablePath() throws -> String {
    let rawPath = CommandLine.arguments[0]
    if rawPath.hasPrefix("/") {
        return rawPath
    }
    if !rawPath.contains("/"), let pathExecutable = executablePathFromPATH(rawPath) {
        return pathExecutable
    }
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return currentDirectory.appendingPathComponent(rawPath).standardizedFileURL.path
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

private func waitForDaemonHealth(socketPath: String) throws -> JSONRPCResponse {
    let deadline = Date().addingTimeInterval(3)
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
    guard case let .string(string) = value else {
        return nil
    }
    return string
}

private enum CLIError: Error, CustomStringConvertible {
    case missingArgument(String)
    case missingArguments(String)

    var description: String {
        switch self {
        case let .missingArgument(command):
            return "\(command) requires an app argument"
        case let .missingArguments(message):
            return message
        }
    }
}
