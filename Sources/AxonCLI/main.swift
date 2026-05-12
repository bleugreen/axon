import Foundation
import AxonCore

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let socketPath = ProcessInfo.processInfo.environment["AXON_SOCKET_PATH"] ?? "/tmp/axon.sock"
let jsonEncoder = JSONEncoder()

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

    case "health":
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(id: .string("health"), method: "health"))
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

    case "screenshot":
        let app = try requiredArgument(after: command, in: arguments)
        let identity = try AppResolver().resolveIdentity(app)
        let screenshot = ScreenshotCapturer().capture(app: identity)
            ?? EncodedScreenshot(mediaType: "image/png", base64Data: "", width: 0, height: 0)
        let data = try jsonEncoder.encode(screenshot.jsonValue)
        print(String(decoding: data, as: UTF8.self))

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
          health   request daemon health over the local socket
          apps     list running apps
          snapshot <app>    print an indexed AX tree for a running app
          screenshot <app>  print embedded screenshot JSON for a running app
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

private func printResponse(_ response: JSONRPCResponse) throws {
    let data = try jsonEncoder.encode(response)
    print(String(decoding: data, as: UTF8.self))
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
