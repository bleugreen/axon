import Foundation
import Testing
@testable import AxonCore

@Test func userRecordingTranslatorExportMatchesPinnedSwiftV2Fixtures() throws {
    let target: JSONValue = .object([
        "app": .string("Example"),
        "name": .string("search-field"),
        "locator": .object([
            "role": .string("AXTextField"),
            "identifier": .string("search")
        ])
    ])
    let groups = [
        RecordedUserEventGroup(action: .setValue(target: target, value: "Axon")),
        RecordedUserEventGroup(action: .pressKey(app: "Example", key: "Return"))
    ]
    let translator = UserRecordingTranslator()

    let yaml = try translator.yaml(from: groups)
    let json = try JSONEncoder.swiftFixtureEncoder.encode(translator.axnDocument(from: groups))
    let expectedYAML = try fixtureData("swift-user-recording-v2.yaml")
    let expectedJSON = try fixtureData("swift-user-recording-v2.json")

    #expect(Data(yaml.utf8) == expectedYAML)
    #expect(json == expectedJSON)
}

@Test func actionHistoryExportMatchesPinnedSwiftV2Fixture() throws {
    let history = ActionHistoryStore()
    let request = JSONRPCRequest(
        id: .string("fixture-click"),
        method: "click",
        params: .object([
            "target": .object([
                "app": .string("Example"),
                "name": .string("submit-button")
            ])
        ])
    )
    history.record(
        request: request,
        response: JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])]),
        sessionID: "swift-fixture",
        semanticTargetLocator: { app, name in
            guard app == "Example", name == "submit-button" else { return nil }
            return AXLocator(role: "AXButton", title: .exact("Submit"))
        }
    )

    let export = try history.exportScript(sessionID: "swift-fixture")

    let expectedYAML = try fixtureData("swift-action-history-v2.yaml")
    #expect(export.actionCount == 1)
    #expect(export.recordCount == 1)
    #expect(Data(export.script.utf8) == expectedYAML)
}

private func fixtureData(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../rust/axon-core/fixtures")
        .appendingPathComponent(name)
        .standardizedFileURL
    return try Data(contentsOf: url)
}

private extension JSONEncoder {
    static var swiftFixtureEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}