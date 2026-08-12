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

public enum AxonEnvironment {
    public static let defaultSocketPath = "/tmp/axon.sock"

    /// Set in the registered daemon's environment to tell it that launchd will restart it.
    ///
    /// The daemon behaves differently depending on whether anything is supervising it, and it
    /// cannot infer that from the process alone.
    public static let launchdManagedKey = "AXON_DAEMON_MANAGED_BY_LAUNCHD"

    public static func socketPath(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["AXON_SOCKET_PATH"] ?? defaultSocketPath
    }

    public static func isLaunchdManaged(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[launchdManagedKey] == "1"
    }

    /// Whether this process must arrange its own replacement after an in-app update.
    ///
    /// A launchd-managed daemon already has `KeepAlive`; launching the app independently as well
    /// races that supervisor and can leave a second menu-bar process contending for the socket.
    public static func requiresIndependentRelaunch(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !isLaunchdManaged(environment)
    }
}
