import Foundation
import Testing
@testable import AxonCore

@Test func userRecordingTranslatorExportMatchesPinnedSwiftV2Fixtures() throws {
    let cleanTarget = fixtureTarget(
        name: "clean-search-field",
        locator: [
            "role": .string("AXTextField"),
            "identifier": .string("search"),
            "title": .string("Search")
        ]
    )
    let proposedTarget = fixtureTarget(
        name: "proposed-submit-button",
        locator: [
            "role": .string("AXButton"),
            "identifier": .string("submit-v1"),
            "title": .string("Submit report")
        ]
    )
    let haltedTarget = fixtureTarget(
        name: "halted-row-action",
        locator: [
            "role": .string("AXButton"),
            "title": .string("Open")
        ]
    )
    let groups = [
        RecordedUserEventGroup(action: .typeText(
            app: "Example",
            text: "Send {{report_path}}/{{report_date}} to {{recipient}} <{{recipient_email}}> after {{retry_count}} tries"
        )),
        RecordedUserEventGroup(action: .setValue(target: cleanTarget, value: "{{api_token}}")),
        RecordedUserEventGroup(action: .pressKey(app: "Example", key: "Return")),
        RecordedUserEventGroup(action: .click(target: proposedTarget)),
        RecordedUserEventGroup(action: .click(target: haltedTarget))
    ]
    let arguments = fixtureArguments()
    let translator = UserRecordingTranslator()

    let yaml = try translator.yaml(from: groups, arguments: arguments)
    let json = try JSONEncoder.swiftFixtureEncoder.encode(
        translator.axnDocument(from: groups, arguments: arguments)
    )
    if ProcessInfo.processInfo.environment["UPDATE_SWIFT_EXPORT_FIXTURES"] == "1" {
        try Data(yaml.utf8).write(to: fixtureURL("swift-user-recording-v2.yaml"))
        try json.write(to: fixtureURL("swift-user-recording-v2.json"))
    }
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

    let export = try history.exportScript(
        sessionID: "swift-fixture",
        arguments: fixtureArguments()
    )

    if ProcessInfo.processInfo.environment["UPDATE_SWIFT_EXPORT_FIXTURES"] == "1" {
        try Data(export.script.utf8).write(to: fixtureURL("swift-action-history-v2.yaml"))
    }
    let expectedYAML = try fixtureData("swift-action-history-v2.yaml")
    #expect(export.actionCount == 1)
    #expect(export.recordCount == 1)
    #expect(Data(export.script.utf8) == expectedYAML)
}

private func fixtureArguments() -> [AxnArgument] {
    [
        AxnArgument(fields: ["name": .string("recipient"), "type": .string("string")]),
        AxnArgument(fields: [
            "name": .string("api_token"),
            "type": .string("secret"),
            "source": .string("op://Engineering/Axon/token")
        ]),
        AxnArgument(fields: [
            "name": .string("report_date"),
            "type": .string("date"),
            "default": .string("2026-08-12")
        ]),
        AxnArgument(fields: [
            "name": .string("recipient_email"),
            "type": .string("email"),
            "default": .string("owner@example.com")
        ]),
        AxnArgument(fields: [
            "name": .string("retry_count"),
            "type": .string("number"),
            "default": .int(3)
        ]),
        AxnArgument(fields: [
            "name": .string("report_path"),
            "type": .string("path"),
            "source": .string("env://AXON_REPORT_PATH")
        ])
    ]
}

private func fixtureTarget(name: String, locator: [String: JSONValue]) -> JSONValue {
    .object([
        "app": .string("Example"),
        "name": .string(name),
        "locator": .object(locator)
    ])
}

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../rust/axon-core/fixtures")
        .appendingPathComponent(name)
        .standardizedFileURL
}

private extension JSONEncoder {
    static var swiftFixtureEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
