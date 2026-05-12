import Foundation

public protocol JSONRPCCommandHandling {
    func handle(_ request: JSONRPCRequest) -> JSONRPCResponse
}

extension CommandRouter: JSONRPCCommandHandling {}

public struct SocketCommandRouter: JSONRPCCommandHandling {
    private let path: String
    private let sendRequest: (JSONRPCRequest) throws -> JSONRPCResponse

    public init(path: String = AxonEnvironment.socketPath()) {
        self.path = path
        self.sendRequest = { request in
            try SocketClient(path: path).send(request)
        }
    }

    public init(path: String, sendRequest: @escaping (JSONRPCRequest) throws -> JSONRPCResponse) {
        self.path = path
        self.sendRequest = sendRequest
    }

    public func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        do {
            return try sendRequest(request)
        } catch {
            return JSONRPCResponse(
                id: request.id,
                error: .internalError("Axon daemon request failed at \(path): \(error)")
            )
        }
    }
}

public enum AxonEnvironment {
    public static let defaultSocketPath = "/tmp/axon.sock"

    public static func socketPath(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["AXON_SOCKET_PATH"] ?? defaultSocketPath
    }
}
