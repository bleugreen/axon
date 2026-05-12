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
        try SocketServer(path: socketPath).runOnce()

    case "health":
        let response = try SocketClient(path: socketPath)
            .send(JSONRPCRequest(id: .string("health"), method: "health"))
        let data = try jsonEncoder.encode(response)
        print(String(decoding: data, as: UTF8.self))

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

private enum CLIError: Error, CustomStringConvertible {
    case missingArgument(String)

    var description: String {
        switch self {
        case let .missingArgument(command):
            return "\(command) requires an app argument"
        }
    }
}
