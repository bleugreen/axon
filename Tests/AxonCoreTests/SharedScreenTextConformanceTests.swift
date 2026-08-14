import Foundation
import Testing
@testable import AxonCore

private func screenTextFixture() throws -> JSONValue {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("schema/fixtures/screen-text.json")
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

@Test func compactObservationMatchesSharedScreenTextFixture() throws {
    let fixture = try screenTextFixture()
    #expect(fixture["maxItems"] == .int(100))
    guard case let .array(cases)? = fixture["cases"] else { Issue.record("screenText fixture must carry cases"); return }
    for fixtureCase in cases {
        let name = if case let .string(value)? = fixtureCase["name"] { value } else { "unnamed fixture" }
        let snapshot: JSONValue = .object(["id": .string("screen-text-fixture"), "app": .object(["name": .string("Fixture"), "processIdentifier": .int(1)]), "windows": .array([]), "screenText": fixtureCase["input"] ?? .array([])])
        let observation = SnapshotObservationFormatter().observation(from: snapshot, frames: fixtureCase["frames"] == .bool(true))
        #expect(observation["screenText"] == fixtureCase["expected"], "\(name)")
    }
}
