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

    /// The sidecar file whose advisory lock represents ownership of `socketPath`.
    ///
    /// Public so that a caller cleaning up after a socket — a test, a packaging script — removes
    /// the whole endpoint rather than half of it.
    public static func lockPath(for socketPath: String) -> String {
        socketPath + ".lock"
    }

    /// Serves exactly one client, then releases the socket.
    ///
    /// `onListening` runs once the socket is bound and accepting, which is the earliest moment a
    /// caller may honestly announce that it is serving. Ownership is exclusive, so a server that
    /// loses the endpoint returns from here instead.
    public func runOnce(onListening: () -> Void = {}) throws {
        let ownership = try SocketOwnership.acquire(path: path)
        defer { ownership.release() }
        onListening()

        try acceptOneClient(on: ownership.listener)
    }

    public func run(onListening: () -> Void = {}) throws {
        let ownership = try SocketOwnership.acquire(path: path)
        defer { ownership.release() }
        onListening()

        while true {
            let client = try acceptClient(on: ownership.listener)
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
            throw SocketError.failed("accept")
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
}

/// Exclusive ownership of one socket pathname, held for as long as a server listens on it.
///
/// The socket file cannot represent ownership on its own. A pathname says nothing about whether a
/// process is still behind it, and asking — connect, and unlink if nobody answers — is a race
/// rather than an answer: two servers starting together both find no peer, both unlink, and both
/// bind, leaving the loser holding a listening descriptor no client can ever arrive on. An
/// advisory lock on a sidecar file is decided by the kernel instead, once, before anything touches
/// the path, and is held for exactly as long as the listener it authorizes.
private struct SocketOwnership {
    let listener: Int32
    private let path: String
    private let lock: Int32
    /// The socket this server created, identified by inode rather than by name, so cleanup can
    /// tell its own endpoint from one another server has since put at the same path.
    private let identity: FileIdentity

    static func acquire(path: String) throws -> SocketOwnership {
        let lockPath = SocketServer.lockPath(for: path)
        let lock = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            throw SocketError.failed("open \(lockPath)")
        }

        // `flock` is held by the open file description, not by the process, so this excludes a
        // second server in this same process exactly as it excludes one in another. The lock file
        // is never unlinked: recreating it would hand two servers locks on two different inodes.
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            // Read the incumbent out of the lock file rather than asking the socket, which
            // reports nothing for a server that is wedged — precisely when an operator most needs
            // to be told which process to stop.
            let owner = recordedOwner(of: lock)
            close(lock)
            guard code == EWOULDBLOCK else {
                throw SocketError.failed("flock \(lockPath)", code: code)
            }
            throw SocketError.socketAlreadyServed(path: path, pid: owner)
        }

        do {
            try record(processIdentifier: Int(getpid()), in: lock)

            // Holding the lock means no lock-aware server is serving, so anything still at the
            // path is debris from a process that is gone — with one exception. A server from a
            // build older than this lock holds no lock at all, and during an upgrade in place it
            // is still serving. Ask the pathname before removing it, so an old daemon is refused
            // rather than quietly replaced. Behind the lock the question is no longer a race:
            // every server that understands the lock is already excluded.
            if isServed(path: path) {
                throw SocketError.socketAlreadyServed(path: path, pid: nil)
            }
            unlink(path)

            let listener = try makeListeningSocket(path: path)
            guard let identity = FileIdentity(path: path) else {
                close(listener)
                unlink(path)
                throw SocketError.failed("stat \(path)")
            }
            return SocketOwnership(listener: listener, path: path, lock: lock, identity: identity)
        } catch {
            close(lock)
            throw error
        }
    }

    func release() {
        close(listener)
        // Remove this server's own socket and nothing else. An orphan shutting down late must not
        // delete the pathname a newer server has since bound — that is a takeover with extra
        // steps, and the inode is the only thing that tells the two sockets apart.
        if FileIdentity(path: path) == identity {
            unlink(path)
        }
        // Release the lock last, so the next server cannot begin acquiring until this one's
        // socket is already gone.
        close(lock)
    }

    private static func makeListeningSocket(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SocketError.failed("socket")
        }
        setNoSigPipe(descriptor)

        do {
            try withSocketAddress(path: path) { pointer, length in
                guard bind(descriptor, pointer, length) == 0 else {
                    throw SocketError.failed("bind")
                }
            }
            // The socket lives in world-writable /tmp, so its own mode is the access control.
            // This matches the DACL'd pipe on Windows and the mode-0600 socket on Linux: Axon's
            // trust boundary is the local user, and nothing weaker.
            guard chmod(path, 0o600) == 0 else {
                throw SocketError.failed("chmod")
            }
            guard listen(descriptor, 16) == 0 else {
                throw SocketError.failed("listen")
            }
            return descriptor
        } catch {
            let failure = error
            close(descriptor)
            // Safe because the lock is held: whatever is at the path is either this half-bound
            // socket or debris, never a live server's endpoint.
            unlink(path)
            throw failure
        }
    }

    /// Whether some process is still answering on `path`.
    private static func isServed(path: String) -> Bool {
        guard access(path, F_OK) == 0 else {
            return false
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else {
            return false
        }
        defer { close(probe) }
        return (try? withSocketAddress(path: path) { pointer, length in
            connect(probe, pointer, length) == 0
        }) ?? false
    }

    private static func record(processIdentifier: Int, in lock: Int32) throws {
        guard ftruncate(lock, 0) == 0 else {
            throw SocketError.failed("ftruncate lock file")
        }
        let bytes = Array("\(processIdentifier)\n".utf8)
        guard pwrite(lock, bytes, bytes.count, 0) == bytes.count else {
            throw SocketError.failed("write lock file")
        }
    }

    private static func recordedOwner(of lock: Int32) -> Int? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(lock, &buffer, buffer.count, 0)
        guard count > 0 else {
            return nil
        }
        let recorded = String(decoding: buffer[0..<count], as: UTF8.self)
        return Int(recorded.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// A file by what it is rather than by what it is called.
private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(path: String) {
        var status = stat()
        // `lstat`, so a symlink dropped in place of the socket is not followed to something else.
        guard lstat(path, &status) == 0 else {
            return nil
        }
        device = status.st_dev
        inode = status.st_ino
    }
}
