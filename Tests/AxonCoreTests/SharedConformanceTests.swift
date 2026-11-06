@testable import AxonClient
import Foundation
import Testing
@testable import AxonCore

private struct SharedLookRequestControls: Decodable {
    struct Format: Decodable {
        let acceptedValues: [String]
    }
    let format: Format
    let nonnegative: [String]
}

@Test func sharedLookRequestControlsMatchGeneratedSchema() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../schema/fixtures/look-request-controls.json")
        .standardizedFileURL
    let fixture = try JSONDecoder().decode(SharedLookRequestControls.self, from: Data(contentsOf: fixtureURL))
    guard case let .array(tools)? = ToolSurfaceSchema.normalizedArtifactJSONValue()["tools"] else {
        Issue.record("the tool surface artifact has no tools array")
        return
    }
    let look = try #require(tools.first { $0["name"] == .string("look") })
    let properties = try #require(look["inputSchema"]?["properties"])

    #expect(properties["format"]?["enum"] == .array(fixture.format.acceptedValues.map(JSONValue.string)))
    for name in fixture.nonnegative {
        #expect(properties[name]?["minimum"] == .int(0), Comment(rawValue: name))
    }
}

private struct SharedLookObservationNotes: Decodable {
    struct Case: Decodable {
        let name: String
        let windowCount: Int
        let note: String?
    }

    let noWindows: String
    let cases: [Case]
}

@Test func sharedLookObservationNotesFixture() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../schema/fixtures/look-observation-notes.json")
        .standardizedFileURL
    let fixture = try JSONDecoder().decode(SharedLookObservationNotes.self, from: Data(contentsOf: fixtureURL))
    #expect(fixture.noWindows == ObservationNote.noWindows)

    let formatter = SnapshotObservationFormatter()
    for testCase in fixture.cases {
        let snapshot = AppSnapshot(
            id: SnapshotID("obs"),
            app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
            windows: (0..<testCase.windowCount).map { AXNode(role: "AXWindow", title: "Window \($0)") },
            screenshot: nil
        )
        let observation = formatter.observation(from: snapshot.wireFixture, frames: false)

        #expect(observation["note"]?.stringValue == testCase.note, Comment(rawValue: testCase.name))
    }
}
