import Darwin
import Foundation

public struct SocketClient {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    public func send(_ request: JSONRPCRequest) throws -> JSONRPCResponse {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SocketError.operationFailed("socket")
        }
        defer { close(descriptor) }

        try withSocketAddress(path: path) { pointer, length in
            guard connect(descriptor, pointer, length) == 0 else {
                throw SocketError.operationFailed("connect")
            }
        }

        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        try payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < payload.count {
                let count = Darwin.write(descriptor, base.advanced(by: sent), payload.count - sent)
                guard count > 0 else {
                    throw SocketError.operationFailed("write")
                }
                sent += count
            }
        }

        let responseData = try readLineData(from: descriptor)
        return try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
    }
}

