import Darwin
import Foundation

public struct SocketServer: @unchecked Sendable {
    public static let defaultClientReadTimeoutSeconds: TimeInterval = 5.0
    public static let defaultMaxRequestBytes = 1_048_576

    private let path: String
    private let router: CommandRouter
    private let clientReadTimeoutSeconds: TimeInterval
    private let maxRequestBytes: Int
    private let clientQueue = DispatchQueue(label: "dev.axon.socket-clients", attributes: .concurrent)

    public init(
        path: String,
        router: CommandRouter = CommandRouter(),
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
        unlink(path)
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
            guard listen(descriptor, 16) == 0 else {
                throw SocketError.operationFailed("listen")
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }
}
