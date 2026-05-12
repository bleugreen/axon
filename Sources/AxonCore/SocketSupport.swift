import Darwin
import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case operationFailed(String)
    case connectionClosed

    public var description: String {
        switch self {
        case let .pathTooLong(path):
            return "Unix socket path is too long: \(path)"
        case let .operationFailed(operation):
            return "\(operation) failed: \(String(cString: strerror(errno)))"
        case .connectionClosed:
            return "Connection closed before a full response was received"
        }
    }
}

func withSocketAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)

    let maxLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxLength else {
        throw SocketError.pathTooLong(path)
    }

    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
        rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
        _ = path.withCString { source in
            rawBuffer.baseAddress?.copyMemory(from: source, byteCount: path.utf8.count)
        }
    }

    let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
            try body(socketPointer, length)
        }
    }
}

func readLineData(from descriptor: Int32) throws -> Data {
    var data = Data()
    var byte = UInt8(0)

    while true {
        let count = Darwin.read(descriptor, &byte, 1)
        if count == 0 {
            throw SocketError.connectionClosed
        }
        guard count > 0 else {
            throw SocketError.operationFailed("read")
        }
        if byte == 0x0A {
            return data
        }
        data.append(byte)
    }
}

