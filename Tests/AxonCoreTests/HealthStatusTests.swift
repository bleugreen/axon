import Foundation
import Security
import Testing
@testable import AxonCore

/// Conformance between the Swift health model, the published schema, and the shared fixtures.
///
/// `rust/axon-core/tests/health.rs` runs the equivalent checks against the same files. Both
/// languages parsing the same bytes is what keeps a macOS document and a Linux document one
/// contract rather than two dialects.
private func schemaRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../schema")
        .standardizedFileURL
}

private func fixtures() throws -> [(name: String, data: Data)] {
    let directory = schemaRoot().appendingPathComponent("fixtures/health")
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasSuffix(".json") }
        .sorted()
    #expect(!names.isEmpty)
    return try names.map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) }
}

private func schema() throws -> JSONValue {
    try JSONDecoder().decode(
        JSONValue.self,
        from: Data(contentsOf: schemaRoot().appendingPathComponent("health-v1.schema.json"))
    )
}

@Test func schemaVocabularyMatchesTheCapabilityEnum() throws {
    guard case let .array(published)? = try schema()["$defs"]?["knownCapabilities"]?["enum"] else {
        Issue.record("knownCapabilities is not an enum array")
        return
    }

    #expect(published.compactMap(\.stringValue) == AxonCapability.allCases.map(\.rawValue))
}

@Test func schemaDeclaresTheSupportedMajor() throws {
    #expect(try schema()["properties"]?["schemaVersion"]?["const"]?.stringValue == healthSchemaVersion)
}

@Test func everyFixtureRoundTripsThroughTheModel() throws {
    for fixture in try fixtures() {
        let original = try JSONDecoder().decode(JSONValue.self, from: fixture.data)
        let status = try JSONDecoder().decode(HealthStatus.self, from: fixture.data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let reencoded = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(status))

        // An exact match, not a subset: a field the model silently drops would leave a consumer
        // reading a document the producer never meant to publish.
        #expect(reencoded == original, Comment(rawValue: "\(fixture.name) did not round-trip"))
    }
}

@Test func everyFixtureReportsTheCompleteCapabilityVocabulary() throws {
    for fixture in try fixtures() {
        let status = try JSONDecoder().decode(HealthStatus.self, from: fixture.data)

        #expect(
            status.capabilities.map(\.capability) == AxonCapability.allCases.map(\.rawValue),
            Comment(rawValue: "\(fixture.name) capability map is incomplete")
        )
        for state in status.capabilities where !state.usable {
            #expect(
                state.reason != nil,
                Comment(rawValue: "\(fixture.name): \(state.capability) is unusable without a reason")
            )
        }
    }
}

@Test func aFutureSchemaMajorIsRefused() throws {
    let document = """
    {"schemaVersion":"health-v2","version":"9.0.0","platform":"macos",\
    "daemon":{"running":false,"ready":false,"endpoint":"/tmp/axon.sock"},\
    "registration":{"registered":false,"mechanism":"launchd"},\
    "session":{"interactive":true,"graphical":true},"permissions":[],"capabilities":[]}
    """

    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(HealthStatus.self, from: Data(document.utf8))
    }

    let supported = document.replacingOccurrences(of: "health-v2", with: healthSchemaVersion)
    #expect(throws: Never.self) {
        try JSONDecoder().decode(HealthStatus.self, from: Data(supported.utf8))
    }
}

@Test func unknownFieldsAndCapabilityKeysAreTolerated() throws {
    // Forward compatibility within health-v1: this build must still parse a document from a newer
    // Axon that added fields and capabilities it has never heard of.
    let document = """
    {"schemaVersion":"health-v1","version":"0.9.0","platform":"macos","tenancy":"whatever-comes-next",\
    "daemon":{"running":true,"ready":true,"endpoint":"/tmp/axon.sock","uptimeSeconds":12},\
    "registration":{"registered":true,"mechanism":"launchd"},\
    "session":{"interactive":true,"graphical":true},"permissions":[],\
    "capabilities":[{"capability":"holography","usable":true}]}
    """

    let status = try JSONDecoder().decode(HealthStatus.self, from: Data(document.utf8))

    #expect(status.capabilities.first?.capability == "holography")
}

@Test func statusJSONIsASingleUnescapedLine() throws {
    let status = HealthStatus.notRunning(
        endpoint: "/tmp/axon.sock",
        registration: .absent(),
        session: SessionHealth(interactive: true, graphical: true),
        reason: HealthReason.daemonNotRunning
    )

    let line = try status.jsonLine()

    #expect(!line.contains("\n"))
    // Slash escaping would make the endpoint unreadable to a person reading the raw line.
    #expect(line.contains("\"endpoint\":\"/tmp/axon.sock\""))
}

@Test func aTrustedMacReportsEveryCapabilityUsable() throws {
    let fixture = try Data(
        contentsOf: schemaRoot().appendingPathComponent("fixtures/health/macos-healthy.json")
    )
    let expected = try JSONDecoder().decode(HealthStatus.self, from: fixture)

    let derived = Doctor.capabilities(DoctorReport(
        accessibility: PermissionReport(name: "Accessibility", status: .trusted),
        screenRecording: PermissionReport(name: "Screen Recording", status: .trusted)
    ))

    #expect(derived == expected.capabilities)
}

@Test func deniedAccessibilityLeavesOnlyTheUngatedCapabilities() throws {
    let fixture = try Data(
        contentsOf: schemaRoot().appendingPathComponent("fixtures/health/macos-accessibility-denied.json")
    )
    let expected = try JSONDecoder().decode(HealthStatus.self, from: fixture)
    let report = DoctorReport(
        accessibility: PermissionReport(name: "Accessibility", status: .denied),
        screenRecording: PermissionReport(name: "Screen Recording", status: .trusted)
    )

    #expect(Doctor.capabilities(report) == expected.capabilities)
    #expect(Doctor.permissions(report) == expected.permissions)
    // Listing applications goes through NSWorkspace, and screenshots answer to Screen Recording
    // alone, so neither disappears when Accessibility is denied.
    #expect(Doctor.capabilities(report).filter(\.usable).map(\.capability) == ["enumerate", "screenshot", "serializeHistory"])
}

@Test func deniedScreenRecordingCostsOnlyScreenshots() {
    let capabilities = Doctor.capabilities(DoctorReport(
        accessibility: PermissionReport(name: "Accessibility", status: .trusted),
        screenRecording: PermissionReport(name: "Screen Recording", status: .denied)
    ))

    let unusable = capabilities.filter { !$0.usable }
    #expect(unusable.map(\.capability) == ["screenshot"])
    #expect(unusable.first?.reason == HealthReason.screenRecordingNotGranted)
}

@Test func aConsoleSessionIsInteractiveAndGraphical() {
    let session = Doctor.session(attributes: [.sessionHasGraphicAccess, .sessionHasTTY])

    #expect(session.interactive)
    #expect(session.graphical)
    #expect(session.reason == nil)
}

@Test func anSSHSessionIsInteractiveWithoutADesktop() {
    let session = Doctor.session(attributes: [.sessionHasTTY])

    #expect(session.interactive)
    #expect(!session.graphical)
    #expect(session.reason == HealthReason.noGraphicalSession)
}

@Test func aServiceSessionIsNeitherInteractiveNorGraphical() {
    let session = Doctor.session(attributes: SessionAttributeBits(rawValue: 0))

    #expect(!session.interactive)
    #expect(!session.graphical)
    #expect(session.reason == HealthReason.notInteractiveSession)
}
