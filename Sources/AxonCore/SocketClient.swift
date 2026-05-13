import Darwin
import Foundation

public struct SocketClient {
    public static let defaultResponseTimeoutSeconds: TimeInterval = 30.0
    public static let defaultMaxResponseBytes = 64 * 1_048_576

    private let path: String
    private let responseTimeoutSeconds: TimeInterval
    private let maxResponseBytes: Int

    public init(
        path: String,
        responseTimeoutSeconds: TimeInterval = Self.defaultResponseTimeoutSeconds,
        maxResponseBytes: Int = Self.defaultMaxResponseBytes
    ) {
        self.path = path
        self.responseTimeoutSeconds = responseTimeoutSeconds
        self.maxResponseBytes = maxResponseBytes
    }

    public func send(_ request: JSONRPCRequest) throws -> JSONRPCResponse {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SocketError.operationFailed("socket")
        }
        setNoSigPipe(descriptor)
        defer { close(descriptor) }

        try withSocketAddress(path: path) { pointer, length in
            guard connect(descriptor, pointer, length) == 0 else {
                throw SocketError.operationFailed("connect")
            }
        }

        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        try writeAll(payload, to: descriptor)

        let responseData = try readLineData(
            from: descriptor,
            timeoutSeconds: responseTimeoutSeconds,
            maxBytes: maxResponseBytes
        )
        return try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
    }
}
