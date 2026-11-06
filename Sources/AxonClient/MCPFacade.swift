import Darwin
import Foundation

/// `axon mcp` on macOS: the Rust daemon's own MCP facade, reached by replacing this process with
/// the enclosing Axon.app's main executable.
///
/// The facade belongs to the daemon binary (`Contents/MacOS/Axon mcp`, `Entry::Mcp` in
/// `rust/axon-mac`), which builds `initialize`, `tools/list`, and every tool result from the same
/// shared spec and envelope the Windows and Linux facades use. The CLI execs it rather than answering
/// MCP itself or proxying bytes, because any Swift layer between a client and that facade is a second
/// implementation of the MCP surface: the Swift router that shipped through 0.4.0 re-derived tool
/// lists, defaults, and result shapes, and macOS clients saw a surface no other platform had.
///
/// `execv` keeps the process's stdio and environment, so the client's pipes and `AXON_SOCKET_PATH`
/// (and the bench's `AXON_MAC_SOCKET`) reach the facade unchanged.
public enum MCPFacade {
    public enum Plan: Equatable, Sendable {
        /// Replace this process with `executable`, passing `arguments` as its whole argv.
        case exec(executable: String, arguments: [String])
        /// There is no daemon facade to run; the message says why and what to run instead.
        case refuse(String)
    }

    /// What `axon mcp <arguments>` does for a CLI running at `invokedExecutable`.
    ///
    /// The facade is the main executable of the Axon.app enclosing the CLI, found by the same rule
    /// `daemon install` uses, so the CLI can only ever hand a client to the daemon it shipped with.
    /// A CLI outside Axon's own bundle refuses: there is no facade beside it, and guessing at another
    /// install's would pair a client with a daemon of unknown version.
    public static func plan(
        invokedExecutable: String,
        arguments: [String] = [],
        fileManager: FileManager = .default
    ) -> Plan {
        let program = DaemonProgram.resolved(invokedExecutable: invokedExecutable, fileManager: fileManager)
        guard case .appBundle = program.identity else {
            return .refuse("""
            axon mcp runs the Axon daemon's MCP facade, which ships inside Axon.app, and this CLI \
            (\(invokedExecutable)) is not inside Axon.app. Run Axon.app/Contents/Resources/bin/axon mcp; \
            from a source checkout, run `cargo run -p axon-mac -- mcp` in rust/.
            """)
        }
        return .exec(executable: program.executablePath, arguments: [program.executablePath, "mcp"] + arguments)
    }

    /// Replaces this process with `executable`. Returns only when `execv` fails, with its `errno`.
    public static func execute(_ executable: String, arguments: [String]) -> Int32 {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        execv(executable, &argv)
        return errno
    }
}
