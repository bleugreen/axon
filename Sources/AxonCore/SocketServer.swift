import Darwin
import Foundation

public struct SocketServer {
    private let path: String
    private let router: CommandRouter

    public init(path: String, router: CommandRouter = CommandRouter()) {
        self.path = path
        self.router = router
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
            try acceptOneClient(on: descriptor)
        }
    }

    private func acceptOneClient(on descriptor: Int32) throws {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else {
            throw SocketError.operationFailed("accept")
        }
        defer { close(client) }

        let requestData = try readLineData(from: client)
        let response: JSONRPCResponse
        do {
            let request = try JSONDecoder().decode(JSONRPCRequest.self, from: requestData)
            response = router.handle(request)
        } catch {
            response = JSONRPCResponse(id: nil, error: .parseError(error.localizedDescription))
        }

        let responseData = try JSONEncoder().encode(response) + Data([0x0A])
        responseData.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            _ = Darwin.write(client, base, responseData.count)
        }
    }

    private func makeListeningSocket() throws -> Int32 {
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SocketError.operationFailed("socket")
        }

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
