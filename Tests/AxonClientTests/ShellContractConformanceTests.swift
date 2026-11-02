@testable import AxonClient
import Foundation
import Testing

/// The shell's models against `schema/fixtures/shell`, which the Rust daemon's own code produces
/// (`rust/axon-core/tests/shell_contract.rs`). Each fixture must decode, and re-encode to the same
/// JSON: a field the shell silently drops is a contract it was never told about.
private let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("schema/fixtures/shell")

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureDirectory.appendingPathComponent(name))
}

private func jsonObject(_ data: Data) throws -> NSObject {
    try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! NSObject
}

@discardableResult
private func roundTrips<T: Codable>(_ type: T.Type, _ name: String) throws -> T {
    let data = try fixtureData(name)
    let decoded = try JSONDecoder().decode(T.self, from: data)
    let reencoded = try JSONEncoder().encode(decoded)
    #expect(try jsonObject(reencoded) == jsonObject(data), "\(name) does not round-trip")
    return decoded
}

@Test func everyShellFixtureIsCoveredHere() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path).sorted()
    #expect(names == [
        "automation-request-no-browser.json",
        "automation-request.json",
        "automation-status.json",
        "daemon-report.json",
        "error-accessibility-denied.json",
        "error-consent-in-progress.json",
        "error-recording-active.json",
        "error-recording-inactive.json",
        "permit.json",
        "recording-start-all.request.json",
        "recording-start-application.request.json",
        "recording-status-application.json",
        "recording-status-editor.json",
        "recording-status-idle.json",
        "recording-stop.json"
    ])
}

@Test func theDaemonReportCarriesTheContractThisShellSpeaks() throws {
    let report = try roundTrips(DaemonReport.self, "daemon-report.json")
    #expect(report.shellContract == ShellContract.version)
    #expect(report.provenance?.backend == "rust-axon-mac")
}

@Test func recordingShapesRoundTrip() throws {
    #expect(try roundTrips(RecordingStatus.self, "recording-status-idle.json") == .idle)
    let application = try roundTrips(RecordingStatus.self, "recording-status-application.json")
    #expect(application.scope == .application(RecordingApp(name: "Calculator", bundleIdentifier: "com.apple.calculator")))
    let editor = try roundTrips(RecordingStatus.self, "recording-status-editor.json")
    #expect(editor.destination == RecordingDestination(documentId: "doc-7F3A", beforeBlockId: "block-12"))
    let stopped = try roundTrips(RecordingResult.self, "recording-stop.json")
    #expect(stopped.destination == nil)
    #expect(stopped.actionCount == 1)
}

/// What the shell sends is what the daemon was pinned accepting.
@Test func theShellSendsThePinnedStartRequests() throws {
    for (name, scope) in [
        ("recording-start-application.request.json", RecordingScope.application(RecordingApp(name: "Calculator", bundleIdentifier: "com.apple.calculator"))),
        ("recording-start-all.request.json", .allApplications)
    ] {
        let pinned = try JSONDecoder().decode(JSONRPCRequest.self, from: fixtureData(name))
        let sent = SentRequests()
        let client = DaemonClient(socketPath: "/tmp/test.sock") { request, timeout in
            sent.append(request, timeout)
            return JSONRPCResponse(id: request.id, result: ["recording": .bool(true)])
        }
        _ = try client.startRecording(scope: scope)
        #expect(sent.requests.first?.method == pinned.method)
        #expect(sent.requests.first?.params == pinned.params, "\(name)")
        #expect(sent.timeouts.first == ShellContract.Timeout.action)
    }
}

@Test func permissionShapesRoundTrip() throws {
    #expect(try roundTrips(PermitResult.self, "permit.json").accessibility == .trusted)
    let status = try roundTrips(AutomationStatusReport.self, "automation-status.json")
    #expect(status.need == .request)
    #expect(status.browsers[1].status == nil)
    #expect(try roundTrips(AutomationRequestReport.self, "automation-request.json").outcomes.first?.granted == true)
    #expect(try roundTrips(AutomationRequestReport.self, "automation-request-no-browser.json").outcomes.isEmpty)
}

@Test func theRefusalsTheShellRendersAreRecognized() throws {
    for (name, refusal) in [
        ("error-accessibility-denied.json", DaemonRefusal.accessibilityDenied),
        ("error-recording-active.json", .recordingActive),
        ("error-recording-inactive.json", .recordingInactive),
        ("error-consent-in-progress.json", .consentInProgress)
    ] {
        let error = try roundTrips(JSONRPCError.self, name)
        #expect(DaemonRefusal(error) == refusal, "\(name)")
        #expect(DaemonCallError.rejected(error).refusal == refusal)
    }
}

@Test func anAbsentSocketReadsAsNotRunning() throws {
    let client = DaemonClient(socketPath: "/tmp/axon-shell-contract-absent-\(UUID().uuidString).sock")
    #expect(throws: DaemonCallError.notRunning(socketPath: client.socketPath)) {
        try client.health()
    }
}

@Test func eachCallUsesItsContractTimeout() throws {
    let sent = SentRequests()
    let client = DaemonClient(socketPath: "/tmp/test.sock") { request, timeout in
        sent.append(request, timeout)
        return JSONRPCResponse(id: request.id, error: JSONRPCError(code: -32601, message: "x"))
    }
    _ = try? client.health()
    _ = try? client.recordingStatus()
    _ = try? client.automationStatus()
    _ = try? client.permit()
    _ = try? client.stopRecording()
    _ = try? client.requestAutomation()
    #expect(sent.requests.map(\.method) == ["health", "recording.status", "automation.status", "permit", "recording.stop", "automation.request"])
    #expect(sent.timeouts == [2, 2, 2, 30, 30, 300])
}

private final class SentRequests: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [JSONRPCRequest] = []
    private(set) var timeouts: [TimeInterval] = []

    func append(_ request: JSONRPCRequest, _ timeout: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        timeouts.append(timeout)
    }
}
