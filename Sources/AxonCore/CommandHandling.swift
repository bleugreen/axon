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
            let longRequest = request.method == "run"
                || request.method == "wait_for_value"
                || request.method == "wait_for_stability"
            return try SocketClient(
                path: path,
                responseTimeoutSeconds: longRequest
                    ? SocketClient.defaultRunResponseTimeoutSeconds
                    : SocketClient.defaultResponseTimeoutSeconds
            ).send(request)
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
