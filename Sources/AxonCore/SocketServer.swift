import Darwin
import Foundation

public struct SocketServer: @unchecked Sendable {
    public static let defaultClientReadTimeoutSeconds: TimeInterval = 5.0
    public static let defaultMaxRequestBytes = 1_048_576

    private let path: String
    private let router: any JSONRPCCommandHandling
    private let clientReadTimeoutSeconds: TimeInterval
    private let maxRequestBytes: Int
    private let clientQueue = DispatchQueue(label: "dev.axon.socket-clients", attributes: .concurrent)

    public init(
        path: String,
        router: any JSONRPCCommandHandling = CommandRouter(
            activeCredentialFilterProvider: { ActiveCredentialFilterLoader().loadOrEmpty() }
        ),
        clientReadTimeoutSeconds: TimeInterval = Self.defaultClientReadTimeoutSeconds,
        maxRequestBytes: Int = Self.defaultMaxRequestBytes
    ) {
        self.path = path
        self.router = router
        self.clientReadTimeoutSeconds = clientReadTimeoutSeconds
        self.maxRequestBytes = maxRequestBytes
    }

    public func runOnce() throws {
        let descriptor = try makeListeningSocket()
        defer {
            close(descriptor)
            unlink(path)
        }

        try acceptOneClient(on: descriptor)
    }

    public func run() throws {
        let descriptor = try makeListeningSocket()
        defer {
            close(descriptor)
            unlink(path)
        }

        while true {
            let client = try acceptClient(on: descriptor)
            clientQueue.async {
                try? handleClient(client)
            }
        }
    }

    private func acceptOneClient(on descriptor: Int32) throws {
        try handleClient(try acceptClient(on: descriptor))
    }

    private func acceptClient(on descriptor: Int32) throws -> Int32 {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else {
            throw SocketError.operationFailed("accept")
        }
        setNoSigPipe(client)
        return client
    }

    private func handleClient(_ client: Int32) throws {
        defer { close(client) }

        let requestData = try readLineData(
            from: client,
            timeoutSeconds: clientReadTimeoutSeconds,
            maxBytes: maxRequestBytes
        )
        let response: JSONRPCResponse
        do {
            let request = try JSONDecoder().decode(JSONRPCRequest.self, from: requestData)
            response = router.handle(request)
        } catch {
            response = JSONRPCResponse(id: nil, error: .parseError(error.localizedDescription))
        }

        let responseData = try JSONEncoder().encode(response) + Data([0x0A])
        try writeAll(responseData, to: client)
    }

    private func makeListeningSocket() throws -> Int32 {
        try clearStaleSocket()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SocketError.operationFailed("socket")
        }
        setNoSigPipe(descriptor)

        do {
            try withSocketAddress(path: path) { pointer, length in
                guard bind(descriptor, pointer, length) == 0 else {
                    throw SocketError.operationFailed("bind")
                }
            }
            // The socket lives in world-writable /tmp, so its own mode is the access control.
            // This matches the DACL'd pipe on Windows and the mode-0600 socket on Linux: Axon's
            // trust boundary is the local user, and nothing weaker.
            guard chmod(path, 0o600) == 0 else {
                throw SocketError.operationFailed("chmod")
            }
            guard listen(descriptor, 16) == 0 else {
                throw SocketError.operationFailed("listen")
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Removes a leftover socket file, but never one a live daemon is still serving.
    ///
    /// Binding unconditionally would let a second daemon silently steal the endpoint from a
    /// running one: the first keeps its listening descriptor and never sees another connection,
    /// so both processes believe they are the daemon and clients reach whichever bound last.
    /// Refusing here is what makes "the daemon answered" mean one specific process.
    private func clearStaleSocket() throws {
        guard access(path, F_OK) == 0 else {
            return
        }
        if isServed() {
            throw SocketError.addressInUse(path)
        }
        unlink(path)
    }

    private func isServed() -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else {
            return false
        }
        defer { close(probe) }
        let connected = (try? withSocketAddress(path: path) { pointer, length in
            connect(probe, pointer, length) == 0
        }) ?? false
        return connected
    }
}
