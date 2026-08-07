import Darwin
import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    /// Another server already owns this socket path.
    ///
    /// `pid` is the owner as it recorded itself, and is nil only when the owner predates that
    /// record or had not written it yet.
    case socketAlreadyServed(path: String, pid: Int?)
    /// A failed syscall, with the `errno` captured at the moment it failed.
    ///
    /// The code is carried rather than read back later because cleanup closes descriptors before
    /// it throws, and every one of those closes can overwrite the global `errno`. Build these with
    /// `SocketError.failed(_:)` so the capture happens at the call site.
    case operationFailed(String, code: Int32)
    case connectionClosed
    case readTimedOut
    case messageTooLarge(Int)

    /// Captures the current `errno` before any cleanup on the way out can disturb it.
    static func failed(_ operation: String, code: Int32 = errno) -> SocketError {
        .operationFailed(operation, code: code)
    }

    public var description: String {
        switch self {
        case let .pathTooLong(path):
            return "Unix socket path is too long: \(path)"
        case let .socketAlreadyServed(path, pid):
            let owner = pid.map { "pid \($0)" } ?? "an unidentified process"
            return """
            Another Axon server is already serving \(path) (\(owner)). \
            Stop it, or set AXON_SOCKET_PATH to a different path.
            """
        case let .operationFailed(operation, code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .connectionClosed:
            return "Connection closed before a full response was received"
        case .readTimedOut:
            return "Timed out waiting for a newline-delimited socket message"
        case let .messageTooLarge(maxBytes):
            return "Socket message exceeded \(maxBytes) bytes"
        }
    }
}

func setNoSigPipe(_ descriptor: Int32) {
    var value: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value)))
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
            throw SocketError.failed("read")
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
                throw SocketError.failed("write")
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
        throw SocketError.failed("poll")
    }
}
