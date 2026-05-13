import Darwin
import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case operationFailed(String)
    case connectionClosed
    case readTimedOut
    case messageTooLarge(Int)

    public var description: String {
        switch self {
        case let .pathTooLong(path):
            return "Unix socket path is too long: \(path)"
        case let .operationFailed(operation):
            return "\(operation) failed: \(String(cString: strerror(errno)))"
        case .connectionClosed:
            return "Connection closed before a full response was received"
        case .readTimedOut:
            return "Timed out waiting for a newline-delimited socket message"
        case let .messageTooLarge(maxBytes):
            return "Socket message exceeded \(maxBytes) bytes"
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

func readLineData(
    from descriptor: Int32,
    timeoutSeconds: TimeInterval = 5.0,
    maxBytes: Int = 1_048_576
) throws -> Data {
    var data = Data()
    var byte = UInt8(0)

    while true {
        try waitUntilReadable(descriptor, timeoutSeconds: timeoutSeconds)
        let count = Darwin.read(descriptor, &byte, 1)
        if count == 0 {
            throw SocketError.connectionClosed
        }
        guard count > 0 else {
            if errno == EINTR {
                continue
            }
            throw SocketError.operationFailed("read")
        }
        if byte == 0x0A {
            return data
        }
        guard data.count < maxBytes else {
            throw SocketError.messageTooLarge(maxBytes)
        }
        data.append(byte)
    }
}

func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else {
            return
        }
        var sent = 0
        while sent < data.count {
            let count = Darwin.write(descriptor, base.advanced(by: sent), data.count - sent)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw SocketError.operationFailed("write")
            }
            sent += count
        }
    }
}

private func waitUntilReadable(_ descriptor: Int32, timeoutSeconds: TimeInterval) throws {
    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let timeoutMilliseconds = Int32(max(0, timeoutSeconds * 1000))

    while true {
        let result = poll(&pollDescriptor, 1, timeoutMilliseconds)
        if result > 0 {
            return
        }
        if result == 0 {
            throw SocketError.readTimedOut
        }
        if errno == EINTR {
            continue
        }
        throw SocketError.operationFailed("poll")
    }
}
