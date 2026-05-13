import Testing
@testable import AxonCore

@Test func commandRouterRecordsCallsWithSessionParentLinks() {
    let history = ActionHistoryStore()
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            click: { target in
                PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
            },
            setValue: { target, _ in
                PrimitiveActionResult(action: "set_value", target: target, strategy: "test", success: true)
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
        method: "set_value",
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
    #expect(records[1].method == "set_value")
}

@Test func exportScriptOmitsReadsByDefaultAndWritesActionBatch() {
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
        method: "snapshot",
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
        method: "export_script",
        params: .object(["sessionId": .string("thread-a")])
    ))

    #expect(response.error == nil)
    let script = response.result?["script"]?.stringValue
    #expect(script?.hasPrefix("version: 1\nactions:") == true)
    #expect(script?.contains("actions:") == true)
    #expect(script?.contains("tool: click") == true)
    #expect(script?.contains("tool: get_app_state") == false)
    #expect(response.result?["actionCount"] == JSONValue.int(1))
}

@Test func exportScriptCanIncludeReadsWhenAsked() {
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
        method: "snapshot",
        params: .object([
            "_session": .string("thread-a"),
            "app": .string("Example")
        ])
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("export"),
        method: "export_script",
        params: .object([
            "sessionId": .string("thread-a"),
            "includeReads": .bool(true)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["script"]?.stringValue?.contains("tool: get_app_state") == true)
    #expect(response.result?["actionCount"] == JSONValue.int(1))
}

private extension JSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }
}
