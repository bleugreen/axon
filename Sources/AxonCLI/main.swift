import AxonCore
import Foundation

let command = CommandLine.arguments.dropFirst().first ?? "help"
let socketPath = ProcessInfo.processInfo.environment["AXON_SOCKET_PATH"] ?? "/tmp/axon.sock"

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
        let data = try JSONEncoder().encode(response)
        print(String(decoding: data, as: UTF8.self))

    default:
        print("""
        usage: axon <command>

        commands:
          doctor   check local permissions
          serve    run the local daemon socket server
          health   request daemon health over the local socket
        """)
    }
} catch {
    fputs("axon: \(error)\n", stderr)
    exit(1)
}

