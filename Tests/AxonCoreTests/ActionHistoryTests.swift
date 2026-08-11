import Foundation
import Testing
@testable import AxonCore

@Test func commandRouterRecordsCallsWithSessionParentLinks() {
    let history = ActionHistoryStore()
    let router = CommandRouter(
        resolveLocator: historyResolveLocator,
        actions: PrimitiveActionHandlers(
            click: { target, _ in
                PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
            },
            type: { target, _, _ in
                PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true)
            }
        ),
        semanticNameRegistry: historySemanticRegistry,
        history: history
    )

    _ = router.handle(JSONRPCRequest(
        id: .string("one"),
        method: "click",
        params: .object([
            "_session": .string("thread-a"),
            "target": semanticTarget("s1:2")
        ])
    ))
    _ = router.handle(JSONRPCRequest(
        id: .string("two"),
        method: "type",
        params: .object([
            "_session": .string("thread-a"),
            "target": semanticTarget("s1:3"),
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

@Test func saveOmitsReadsByDefaultAndWritesAxnFile() {
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
        resolveLocator: historyResolveLocator,
        actions: PrimitiveActionHandlers(
            click: { target, _ in
                PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
            }
        ),
        semanticNameRegistry: historySemanticRegistry,
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
            "target": semanticTarget("s-read:1")
        ])
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("export"),
        method: "save",
        params: .object(["sessionId": .string("thread-a")])
    ))

    #expect(response.error == nil)
    let script = response.result?["script"]?.stringValue
    #expect(script?.hasPrefix("version: 2\nactions:") == true)
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
        semanticNameRegistry: historySemanticRegistry,
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
        resolveLocator: historyResolveLocator,
        actions: PrimitiveActionHandlers(
            type: { target, value, _ in
                PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true, details: [
                    "value": .string(value)
                ])
            }
        ),
        semanticNameRegistry: historySemanticRegistry,
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
                    "target": replayTarget("s1:2"),
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

@Test func saveRangeIsSessionScopedAndInclusiveAcrossInterleavedCalls() {
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
        resolveLocator: historyResolveLocator,
        actions: PrimitiveActionHandlers(
            click: { target, _ in
                PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
            },
            type: { target, value, _ in
                PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true, details: [
                    "value": .string(value)
                ])
            }
        ),
        semanticNameRegistry: historySemanticRegistry,
        history: history
    )

    _ = router.handle(JSONRPCRequest(
        id: .string("a1"),
        method: "click",
        params: .object([
            "_session": .string("thread-a"),
            "target": semanticTarget("s-a:1")
        ])
    ))
    _ = router.handle(JSONRPCRequest(
        id: .string("b1"),
        method: "type",
        params: .object([
            "_session": .string("thread-b"),
            "target": semanticTarget("s-b:1"),
            "value": .string("Thread B")
        ])
    ))
    _ = router.handle(JSONRPCRequest(
        id: .string("a2"),
        method: "type",
        params: .object([
            "_session": .string("thread-a"),
            "target": semanticTarget("s-a:2"),
            "value": .string("Thread A")
        ])
    ))
    _ = router.handle(JSONRPCRequest(
        id: .string("a-read"),
        method: "look",
        params: .object([
            "_session": .string("thread-a"),
            "app": .string("Example")
        ])
    ))

    let writeOnly = router.handle(JSONRPCRequest(
        id: .string("export-write"),
        method: "save",
        params: .object([
            "sessionId": .string("thread-a"),
            "from": .string("c1"),
            "to": .string("c4")
        ])
    ))
    let withReads = router.handle(JSONRPCRequest(
        id: .string("export-read"),
        method: "save",
        params: .object([
            "sessionId": .string("thread-a"),
            "from": .string("c1"),
            "to": .string("c4"),
            "includeReads": .bool(true)
        ])
    ))

    let writeOnlyScript = writeOnly.result?["script"]?.stringValue ?? ""
    let withReadsScript = withReads.result?["script"]?.stringValue ?? ""
    #expect(writeOnly.error == nil)
    #expect(writeOnly.result?["recordCount"] == .int(3))
    #expect(writeOnly.result?["actionCount"] == .int(2))
    #expect(writeOnlyScript.contains("s-a:1"))
    #expect(writeOnlyScript.contains("Thread A"))
    #expect(writeOnlyScript.contains("Thread B") == false)
    #expect(writeOnlyScript.contains("tool: look") == false)
    #expect(withReads.error == nil)
    #expect(withReads.result?["recordCount"] == .int(3))
    #expect(withReads.result?["actionCount"] == .int(3))
    #expect(withReadsScript.contains("tool: look"))
    #expect(withReadsScript.contains("Thread B") == false)
}

@Test func saveRedactsDirectSensitiveValuesBeforePersistingOrExporting() throws {
    let activeSecret = "correct horse battery staple"
    let token = "sk-proj-abcdef1234567890SECRET"
    let history = ActionHistoryStore()
    var typedValues: [String] = []
    var keyedValues: [String] = []
    let router = CommandRouter(
        resolveLocator: historyResolveLocator,
        actions: PrimitiveActionHandlers(
            type: { target, value, _ in
                typedValues.append(value)
                return PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true, details: [
                    "value": .string(value)
                ])
            },
            keyboard: { app, intent, _ in
                guard case let .text(text) = intent else { return PrimitiveActionResult(action: "keyboard", target: "invalid", strategy: "test", success: false) }
                keyedValues.append(text)
                return PrimitiveActionResult(action: "keyboard", target: app ?? "frontmost", strategy: "test", success: true, details: [
                    "text": .string(text)
                ])
            }
        ),
        semanticNameRegistry: historySemanticRegistry,
        history: history,
        activeCredentialFilter: try historyActiveCredentialFilter(values: [activeSecret])
    )

    _ = router.handle(JSONRPCRequest(
        id: .string("direct-active"),
        method: "type",
        params: .object([
            "_session": .string("thread-a"),
            "target": semanticTarget("s1:2"),
            "value": .string(activeSecret)
        ])
    ))
    _ = router.handle(JSONRPCRequest(
        id: .string("direct-token"),
        method: "keyboard",
        params: .object([
            "_session": .string("thread-a"),
            "app": .string("Example"),
            "text": .string("paste \(token)")
        ])
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("export"),
        method: "save",
        params: .object(["sessionId": .string("thread-a")])
    ))
    let script = response.result?["script"]?.stringValue ?? ""

    #expect(response.error == nil)
    #expect(typedValues == [activeSecret])
    #expect(keyedValues == ["paste \(token)"])
    #expect(history.records(sessionID: "thread-a").containsSecretLiteral(activeSecret) == false)
    #expect(history.records(sessionID: "thread-a").containsSecretLiteral(token) == false)
    #expect(script.contains(activeSecret) == false)
    #expect(script.contains(token) == false)
    #expect(script.contains("<redacted: active-credential>"))
    #expect(script.contains("<redacted: auth-credential>"))
}

@Test func saveRejectsUnknownRangeBoundariesInsteadOfWideningExport() {
    let history = ActionHistoryStore()
    let router = CommandRouter(
        resolveLocator: historyResolveLocator,
        actions: PrimitiveActionHandlers(
            click: { target, _ in
                PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
            },
            type: { target, value, _ in
                PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true, details: [
                    "value": .string(value)
                ])
            }
        ),
        semanticNameRegistry: historySemanticRegistry,
        history: history
    )

    _ = router.handle(JSONRPCRequest(
        id: .string("one"),
        method: "click",
        params: .object([
            "_session": .string("thread-a"),
            "target": semanticTarget("s1:1")
        ])
    ))
    _ = router.handle(JSONRPCRequest(
        id: .string("two"),
        method: "type",
        params: .object([
            "_session": .string("thread-a"),
            "target": semanticTarget("s1:2"),
            "value": .string("Hello")
        ])
    ))

    let missingFrom = router.handle(JSONRPCRequest(
        id: .string("save-missing-from"),
        method: "save",
        params: .object([
            "sessionId": .string("thread-a"),
            "from": .string("missing")
        ])
    ))
    let missingTo = router.handle(JSONRPCRequest(
        id: .string("save-missing-to"),
        method: "save",
        params: .object([
            "sessionId": .string("thread-a"),
            "to": .string("missing")
        ])
    ))
    let reversed = router.handle(JSONRPCRequest(
        id: .string("save-reversed"),
        method: "save",
        params: .object([
            "sessionId": .string("thread-a"),
            "from": .string("c2"),
            "to": .string("c1")
        ])
    ))

    #expect(missingFrom.error?.code == -32602)
    #expect(missingFrom.error?.message == "Unknown history range boundary: from missing")
    #expect(missingFrom.result?["script"] == nil)
    #expect(missingTo.error?.code == -32602)
    #expect(missingTo.error?.message == "Unknown history range boundary: to missing")
    #expect(missingTo.result?["script"] == nil)
    #expect(reversed.error?.code == -32602)
    #expect(reversed.error?.message == "History range starts after it ends: from c2 to c1")
    #expect(reversed.result?["script"] == nil)
}

@Test func runHistoryDoesNotPersistSecretArgumentValues() throws {
    let history = ActionHistoryStore()
    var typedValues: [String] = []
    let router = CommandRouter(
        resolveLocator: historyResolveLocator,
        actions: PrimitiveActionHandlers(
            type: { target, value, _ in
                typedValues.append(value)
                return PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true)
            }
        ),
        semanticNameRegistry: historySemanticRegistry,
        history: history
    )

    let source = """
    version: 2
    args:
      - name: password
        type: secret
    actions:
      - tool: type
        target:
          app: Example
          name: password-field
          locator:
            role: AXTextField
            identifier: password
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

@Test func saveReplacesSnapshotHandlesWithDurableLocatorsAndNumbersSteps() {
    let history = ActionHistoryStore()
    let router = observingRouter(
        history: history,
        observer: StubActionStateObserver(elementReads: [
            buttonState(focused: false),
            buttonState(focused: true),
            buttonState(focused: true)
        ])
    )

    _ = router.handle(clickRequest(target: "s1:2"))
    let script = savedScript(router)

    #expect(script.contains("id: a001"))
    #expect(script.contains("app: Example"))
    #expect(script.contains("role: AXButton"))
    #expect(script.contains("title: Submit"))
    #expect(script.contains("s1:2") == false)
    #expect(script.contains("warnings") == false)
}

@Test func saveNumbersEveryStepSequentially() {
    let history = ActionHistoryStore()
    let router = observingRouter(history: history, observer: StubActionStateObserver())

    _ = router.handle(clickRequest(target: "s1:2"))
    _ = router.handle(clickRequest(target: "s1:3"))
    let script = savedScript(router)

    #expect(script.contains("id: a001"))
    #expect(script.contains("id: a002"))
}

@Test func saveCarriesAnObservedFocusTransitionAsAPostcondition() {
    let history = ActionHistoryStore()
    let router = observingRouter(
        history: history,
        observer: StubActionStateObserver(elementReads: [
            buttonState(focused: false),
            buttonState(focused: true),
            buttonState(focused: true)
        ])
    )

    _ = router.handle(clickRequest(target: "s1:2"))
    let script = savedScript(router)

    #expect(script.contains("expects:"))
    #expect(script.contains("id: a001.focused.0"))
    #expect(script.contains("kind: focused"))
}

@Test func saveNeverAssertsATypedValueBackAtTheFieldItWasTypedInto() {
    let history = ActionHistoryStore()
    let field: [String: JSONValue] = ["role": .string("AXTextField"), "identifier": .string("name")]
    let router = observingRouter(
        history: history,
        observer: StubActionStateObserver(elementReads: [
            buttonState(role: "AXTextField", locator: field, value: ""),
            buttonState(role: "AXTextField", locator: field, value: "Ada Lovelace")
        ])
    )

    _ = router.handle(JSONRPCRequest(
        id: .string("type"),
        method: "type",
        params: .object([
            "_session": .string("thread-a"),
            "target": semanticTarget("s1:2"),
            "value": .string("Ada Lovelace")
        ])
    ))
    let script = savedScript(router)

    #expect(script.contains("value: Ada Lovelace"))
    #expect(script.contains("expects") == false)
}

@Test func saveKeepsAnActionWithNoSafeFactAsAValidUnverifiedStep() {
    let history = ActionHistoryStore()
    let steady = buttonState(focused: true)
    let router = observingRouter(
        history: history,
        observer: StubActionStateObserver(elementReads: [steady, steady, steady])
    )

    _ = router.handle(clickRequest(target: "s1:2"))
    let script = savedScript(router)

    #expect(script.contains("tool: click"))
    #expect(script.contains("expects") == false)
}

@Test func saveOmitsAnActionWhenReplayEvidenceIsUnavailable() {
    let history = ActionHistoryStore()
    let ephemeral = buttonState(locator: nil, focused: true)
    let router = observingRouter(
        history: history,
        observer: StubActionStateObserver(elementReads: [buttonState(locator: nil, focused: false), ephemeral, ephemeral])
    )

    _ = router.handle(clickRequest(target: "s1:2"))
    let script = savedScript(router)

    #expect(script.contains("tool: click") == false)
    #expect(script.contains("s1:2") == false)
    #expect(script.contains("warnings") == false)
    #expect(script.contains("expects") == false)
}

@Test func aSavedWorkflowVerifiesItsDerivedPostconditionOnReplay() throws {
    let history = ActionHistoryStore()
    let router = observingRouter(
        history: history,
        observer: StubActionStateObserver(elementReads: [
            buttonState(focused: false),
            buttonState(focused: true),
            buttonState(focused: true)
        ])
    )
    _ = router.handle(clickRequest(target: "s1:2"))
    let path = try temporaryAxnFile(savedScript(router))
    defer { try? FileManager.default.removeItem(atPath: path) }

    let runner = AxnRunner(
        commandHandler: { request in
            JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
        },
        snapshotProvider: { _ in submitButtonSnapshot(focused: true) }
    )
    let result = try runner.run(params: ["path": .string(path)])

    #expect(result["success"] == .bool(true))
}

@Test func aSavedWorkflowFailsWhenItsDerivedPostconditionDoesNotHold() throws {
    let history = ActionHistoryStore()
    let router = observingRouter(
        history: history,
        observer: StubActionStateObserver(elementReads: [
            buttonState(focused: false),
            buttonState(focused: true),
            buttonState(focused: true)
        ])
    )
    _ = router.handle(clickRequest(target: "s1:2"))
    let path = try temporaryAxnFile(savedScript(router))
    defer { try? FileManager.default.removeItem(atPath: path) }

    let runner = AxnRunner(
        commandHandler: { request in
            JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
        },
        snapshotProvider: { _ in submitButtonSnapshot(focused: false) }
    )
    let result = try runner.run(params: ["path": .string(path)])

    #expect(result["success"] == .bool(false))
    #expect(result["trace"]?[0]?["factId"] == .string("a001.focused.0"))
}

private func observingRouter(
    history: ActionHistoryStore,
    observer: StubActionStateObserver
) -> CommandRouter {
    CommandRouter(
        resolveLocator: historyResolveLocator,
        actions: PrimitiveActionHandlers(
            click: { target, _ in
                PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
            },
            type: { target, value, _ in
                PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true, details: [
                    "value": .string(value)
                ])
            }
        ),
        semanticNameRegistry: historySemanticRegistry,
        history: history,
        actionStateObserver: observer,
        sleepMilliseconds: { _ in }
    )
}

private func clickRequest(target: String) -> JSONRPCRequest {
    JSONRPCRequest(
        id: .string("click-\(target)"),
        method: "click",
        params: .object([
            "_session": .string("thread-a"),
            "target": semanticTarget(target)
        ])
    )
}

private func savedScript(_ router: CommandRouter) -> String {
    router.handle(JSONRPCRequest(
        id: .string("export"),
        method: "save",
        params: .object(["sessionId": .string("thread-a")])
    )).result?["script"]?.stringValue ?? ""
}

private func submitButtonSnapshot(focused: Bool) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("saved-replay-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXButton", title: "Submit", focused: focused)
            ])
        ],
        screenshot: nil
    )
}


private let historySemanticRegistry: SemanticNameRegistry = {
    SemanticNameRegistry()
}()

private let historyResolveLocator: CommandRouter.LocatorResolutionProvider = { _, locator, _ in
    let snapshotID = SnapshotID("history-semantic")
    return LocatorResolution(
        status: .unique,
        snapshotID: snapshotID,
        best: LocatorCandidate(
            index: 2,
            handle: SnapshotHandle(snapshotID: snapshotID, nodeIndex: 2),
            role: locator.role ?? "AXButton",
            title: "Submit",
            score: 1_000,
            reasons: []
        ),
        candidates: []
    )
}

private func semanticTarget(_ name: String) -> JSONValue {
    historySemanticRegistry.registerReplayEvidence(
        app: "Example",
        name: name,
        locator: AXLocator(role: "AXButton", title: .exact("Submit"))
    )
    return .object([
        "app": .string("Example"),
        "name": .string(name)
    ])
}

private func replayTarget(_ name: String) -> JSONValue {
    guard case var .object(target) = semanticTarget(name) else { preconditionFailure() }
    target["locator"] = .object([
        "role": .string("AXButton"),
        "title": .string("Submit")
    ])
    return .object(target)
}

private extension JSONValue {
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

private func historyActiveCredentialFilter(values: [String]) throws -> ActiveCredentialIndex {
    try ActiveCredentialIndex(
        secrets: values.map {
            ActiveCredentialSecret(value: $0, provider: "test", reference: "op://History/Active/secret")
        },
        hmacKey: Data(repeating: 0x7B, count: 32),
        provider: "test",
        createdAt: Date(timeIntervalSince1970: 1_775_000_000)
    )
}
