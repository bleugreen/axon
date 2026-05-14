import Foundation
import Testing
@testable import AxonCore

@Test func commandRouterRecordsCallsWithSessionParentLinks() {
    let history = ActionHistoryStore()
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            click: { target in
                PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
            },
            type: { target, _ in
                PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true)
            }
        ),
        history: history
    )

    _ = router.handle(JSONRPCRequest(
        id: .string("one"),
        method: "click",
        params: .object([
            "_session": .string("thread-a"),
            "target": .string("s1:2")
        ])
    ))
    _ = router.handle(JSONRPCRequest(
        id: .string("two"),
        method: "type",
        params: .object([
            "_session": .string("thread-a"),
            "target": .string("s1:3"),
            "value": .string("Mitch")
        ])
    ))

    let records = history.records(sessionID: "thread-a")
    #expect(records.count == 2)
    #expect(records[0].parentID == nil)
    #expect(records[1].parentID == records[0].id)
    #expect(records[0].method == "click")
    #expect(records[1].method == "type")
}

@Test func saveOmitsReadsByDefaultAndWritesActionBatch() {
    let history = ActionHistoryStore()
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            AppSnapshot(
                id: SnapshotID("s-read"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [],
                screenshot: nil
            )
        },
        actions: PrimitiveActionHandlers(
            click: { target in
                PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
            }
        ),
        history: history
    )

    _ = router.handle(JSONRPCRequest(
        id: .string("read"),
        method: "look",
        params: .object([
            "_session": .string("thread-a"),
            "app": .string("Example")
        ])
    ))
    _ = router.handle(JSONRPCRequest(
        id: .string("click"),
        method: "click",
        params: .object([
            "_session": .string("thread-a"),
            "target": .string("s-read:1")
        ])
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("export"),
        method: "save",
        params: .object(["sessionId": .string("thread-a")])
    ))

    #expect(response.error == nil)
    let script = response.result?["script"]?.stringValue
    #expect(script?.hasPrefix("version: 1\nactions:") == true)
    #expect(script?.contains("actions:") == true)
    #expect(script?.contains("tool: click") == true)
    #expect(script?.contains("tool: look") == false)
    #expect(response.result?["actionCount"] == JSONValue.int(1))
}

@Test func saveCanIncludeReadsWhenAsked() {
    let history = ActionHistoryStore()
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            AppSnapshot(
                id: SnapshotID("s-read"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [],
                screenshot: nil
            )
        },
        history: history
    )

    _ = router.handle(JSONRPCRequest(
        id: .string("read"),
        method: "look",
        params: .object([
            "_session": .string("thread-a"),
            "app": .string("Example")
        ])
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("export"),
        method: "save",
        params: .object([
            "sessionId": .string("thread-a"),
            "includeReads": .bool(true)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["script"]?.stringValue?.contains("tool: look") == true)
    #expect(response.result?["actionCount"] == JSONValue.int(1))
}

@Test func saveIncludesPrimitiveActionsExecutedInsideRun() {
    let history = ActionHistoryStore()
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            type: { target, value in
                PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true, details: [
                    "value": .string(value)
                ])
            }
        ),
        history: history
    )

    _ = router.handle(JSONRPCRequest(
        id: .string("batch"),
        method: "run",
        params: .object([
            "_session": .string("thread-a"),
            "actions": .array([
                .object([
                    "tool": .string("type"),
                    "target": .string("s1:2"),
                    "value": .string("Hello")
                ])
            ])
        ])
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("export"),
        method: "save",
        params: .object(["sessionId": .string("thread-a")])
    ))

    #expect(response.error == nil)
    #expect(response.result?["actionCount"] == .int(1))
    #expect(response.result?["script"]?.stringValue?.contains("tool: type") == true)
    #expect(response.result?["script"]?.stringValue?.contains("value: Hello") == true)
}

@Test func runHistoryDoesNotPersistSecretArgumentValues() throws {
    let history = ActionHistoryStore()
    var typedValues: [String] = []
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            type: { target, value in
                typedValues.append(value)
                return PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true)
            }
        ),
        history: history
    )

    let source = """
    version: 1
    args:
      - name: password
        type: secret
    actions:
      - tool: type
        target: s1:2
        value: "{{password}}"
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let response = router.handle(JSONRPCRequest(
        id: .string("batch"),
        method: "run",
        params: .object([
            "_session": .string("thread-a"),
            "path": .string(path),
            "argValues": .object(["password": .string("s3cr3t!")])
        ])
    ))

    #expect(response.error == nil)
    #expect(typedValues == ["s3cr3t!"])
    #expect(history.records(sessionID: "default").isEmpty)
    #expect(history.records(sessionID: "thread-a").containsSecretLiteral("s3cr3t!") == false)
}

private extension JSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    func containsString(_ needle: String) -> Bool {
        switch self {
        case let .string(value):
            return value.contains(needle)
        case let .array(values):
            return values.contains { $0.containsString(needle) }
        case let .object(object):
            return object.values.contains { $0.containsString(needle) }
        default:
            return false
        }
    }
}

private extension Array where Element == ActionHistoryRecord {
    func containsSecretLiteral(_ value: String) -> Bool {
        contains { record in
            record.params.values.contains { $0.containsString(value) }
        }
    }
}

private func temporaryAxnFile(_ source: String) throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-\(UUID().uuidString).axn")
        .path
    try source.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}
