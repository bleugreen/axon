@testable import AxonClient
import Darwin
import Foundation
import Testing

// `axon mcp` is the daemon's facade, reached by exec. These pin both halves: which executable the
// verb chooses, and that the shipped CLI really replaces itself with it, stdio and environment intact.

@Test func mcpExecsTheMainExecutableOfTheEnclosingAxonApp() throws {
    let root = try temporaryDirectory("axon-mcp-plan")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Axon.app")
    try makeAxonApp(at: bundle, main: Data())
    let cli = bundle.appendingPathComponent(AppBundle.bundledCLIRelativePath).path
    let main = bundle.appendingPathComponent("Contents/MacOS/Axon").path

    #expect(MCPFacade.plan(invokedExecutable: cli) == .exec(executable: main, arguments: [main, "mcp"]))
    #expect(
        MCPFacade.plan(invokedExecutable: cli, arguments: ["--flag"])
            == .exec(executable: main, arguments: [main, "mcp", "--flag"])
    )
}

@Test func mcpRefusesOutsideAxonApp() throws {
    let root = try temporaryDirectory("axon-mcp-refuse")
    defer { try? FileManager.default.removeItem(at: root) }
    let foreign = root.appendingPathComponent("Other.app")
    try makeAxonApp(at: foreign, main: Data(), identifier: "com.example.other")

    for cli in [
        "/Users/dev/axon/.build/debug/axon",
        foreign.appendingPathComponent(AppBundle.bundledCLIRelativePath).path
    ] {
        guard case let .refuse(message) = MCPFacade.plan(invokedExecutable: cli) else {
            Issue.record("\(cli) should refuse")
            continue
        }
        #expect(message.contains(cli))
        #expect(message.contains("not inside Axon.app"))
    }
}

/// Runs the built `axon` from inside a fake Axon.app whose main executable reports what it received.
@Test func theBundledCLIReplacesItselfWithTheDaemonFacade() throws {
    let root = try temporaryDirectory("axon-mcp-exec")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Axon.app")
    let script = """
    #!/bin/sh
    printf 'program:%s\\n' "$0"
    printf 'argv:%s\\n' "$*"
    printf 'socket:%s\\n' "$AXON_SOCKET_PATH"
    cat
    """
    try makeAxonApp(at: bundle, main: Data(script.utf8))
    let cli = bundle.appendingPathComponent(AppBundle.bundledCLIRelativePath)
    try FileManager.default.copyItem(at: try builtCLI(), to: cli)

    let run = try runProcess(cli, arguments: ["mcp", "--extra"], stdin: "{\"jsonrpc\":\"2.0\",\"id\":1}\n")

    #expect(run.status == 0, Comment(rawValue: run.stderr))
    let main = bundle.appendingPathComponent("Contents/MacOS/Axon").resolvingSymlinksInPath().path
    #expect(run.stdout == """
    program:\(main)
    argv:mcp --extra
    socket:/tmp/axon-mcp-exec-test.sock
    {"jsonrpc":"2.0","id":1}

    """)
}

@Test func theCLIOutsideAxonAppRefusesMCP() throws {
    let root = try temporaryDirectory("axon-mcp-unbundled")
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = root.appendingPathComponent("axon")
    try FileManager.default.copyItem(at: try builtCLI(), to: cli)

    let run = try runProcess(cli, arguments: ["mcp"], stdin: "")

    #expect(run.status == 1)
    #expect(run.stdout.isEmpty)
    #expect(run.stderr.contains("not inside Axon.app"))
}

private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeAxonApp(at bundle: URL, main: Data, identifier: String = AppBundle.axonDaemonIdentifier) throws {
    let fileManager = FileManager.default
    let macOS = bundle.appendingPathComponent("Contents/MacOS")
    try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
    try fileManager.createDirectory(
        at: bundle.appendingPathComponent(AppBundle.bundledCLIRelativePath).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Axon"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    fileManager.createFile(
        atPath: macOS.appendingPathComponent("Axon").path,
        contents: main,
        attributes: [.posixPermissions: 0o755]
    )
}

/// The `axon` product `swift test` built beside this test bundle.
///
/// Found from this image's own path: Swift Testing loads the bundle's executable from a helper
/// process, so it is not among the process's loaded `Bundle`s.
private func builtCLI() throws -> URL {
    var info = Dl_info()
    try #require(dladdr(#dsohandle, &info) != 0 && info.dli_fname != nil, "cannot locate the test image")
    var bundle = URL(fileURLWithPath: String(cString: info.dli_fname)).resolvingSymlinksInPath()
    while bundle.pathExtension != "xctest", bundle.path != "/" {
        bundle.deleteLastPathComponent()
    }
    try #require(bundle.pathExtension == "xctest", "the test image is not inside an .xctest bundle")
    let cli = bundle.deletingLastPathComponent().appendingPathComponent("axon")
    try #require(FileManager.default.isExecutableFile(atPath: cli.path), "swift test did not build \(cli.path)")
    return cli
}

private func runProcess(_ executable: URL, arguments: [String], stdin: String) throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ["AXON_SOCKET_PATH": "/tmp/axon-mcp-exec-test.sock", "PATH": "/usr/bin:/bin"]
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(decoding: stdout, as: UTF8.self),
        String(decoding: stderr, as: UTF8.self)
    )
}
