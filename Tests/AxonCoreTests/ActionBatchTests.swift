import Foundation
import Testing
@testable import AxonCore

@Test func runBatchExecutesToolShapedActionsInOrder() {
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: [
            "action": .object([
                "success": .bool(true),
                "target": request.params?["target"] ?? .null
            ])
        ])
    }

    let batch = try! executor.run(params: [
        "actions": .array([
            .object([
                "tool": .string("set_value"),
                "target": .string("s1:2"),
                "value": .string("Mitch")
            ]),
            .object([
                "tool": .string("click"),
                "target": .string("s1:3")
            ])
        ])
    ])

    #expect(batch["success"] == .bool(true))
    #expect(batch["trace"]?[0]?["tool"] == .string("set_value"))
    #expect(batch["trace"]?[1]?["tool"] == .string("click"))
    #expect(requests.map(\.method) == ["set_value", "click"])
    #expect(requests[0].params?["value"] == .string("Mitch"))
}

@Test func runBatchStripsVerificationMetadataBeforeDispatch() {
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let batch = try! executor.run(params: [
        "actions": .array([
            .object([
                "id": .string("a001"),
                "label": .string("Click Save"),
                "tool": .string("click"),
                "target": .string("s1:2"),
                "expects": .array([]),
                "observed": .array([.object(["kind": .string("raw-event")])]),
                "warnings": .array([.string("point fallback")])
            ])
        ])
    ])

    #expect(batch["success"] == .bool(true))
    #expect(requests.count == 1)
    #expect(requests[0].params?["target"] == .string("s1:2"))
    #expect(requests[0].params?["id"] == nil)
    #expect(requests[0].params?["label"] == nil)
    #expect(requests[0].params?["expects"] == nil)
    #expect(requests[0].params?["observed"] == nil)
    #expect(requests[0].params?["warnings"] == nil)
}

@Test func runBatchFailsWhenPrimitiveActionReportsFailure() {
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: [
            "action": .object([
                "success": .bool(false),
                "message": .string("scroll did not move")
            ])
        ])
    }

    let batch = try! executor.run(params: [
        "actions": .array([
            .object([
                "id": .string("a001"),
                "tool": .string("scroll"),
                "target": .object(["point": .object(["x": .int(10), "y": .int(20)])]),
                "deltaY": .int(-120)
            ]),
            .object([
                "id": .string("a002"),
                "tool": .string("click"),
                "target": .string("never")
            ])
        ])
    ])

    #expect(batch["success"] == .bool(false))
    #expect(batch["trace"]?[0]?["success"] == .bool(false))
    #expect(batch["trace"]?[0]?["actionId"] == .string("a001"))
    #expect(batch["trace"]?[0]?["error"] == .string("scroll did not move"))
    #expect(requests.map(\.method) == ["scroll"])
}

@Test func runBatchWaitsForChangedExpectationBeforeNextAction() {
    var snapshots = [
        changeFactSnapshot(title: "Before"),
        changeFactSnapshot(title: "Before"),
        changeFactSnapshot(title: "After")
    ]
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor(
        commandHandler: { request in
            requests.append(request)
            return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
        },
        snapshotProvider: { _ in snapshots.removeFirst() },
        changePollIntervalMs: 0,
        changeTimeoutMs: 100
    )

    let batch = try! executor.run(params: [
        "actions": .array([
            .object([
                "id": .string("a001"),
                "tool": .string("click"),
                "target": .string("s1:2"),
                "expects": .array([
                    .object([
                        "id": .string("a001.changed.0"),
                        "kind": .string("changed"),
                        "target": .object(["app": .string("Example")])
                    ])
                ])
            ]),
            .object([
                "id": .string("a002"),
                "tool": .string("scroll"),
                "target": .object(["point": .object(["x": .int(10), "y": .int(20)])]),
                "deltaY": .int(-120)
            ])
        ])
    ])

    #expect(batch["success"] == .bool(true))
    #expect(requests.map(\.method) == ["click", "scroll"])
    #expect(snapshots.isEmpty)
}

@Test func runBatchDoesNotEvaluateRevealResolutionBeforeDispatch() {
    let surface = scrollSurfaceTarget()
    let link = articleLinkTarget()
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor(
        commandHandler: { request in
            requests.append(request)
            return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
        },
        snapshotProvider: { _ in
            Issue.record("resolve.reveal metadata should not trigger snapshot evaluation")
            return articleLinkSnapshot()
        },
        changePollIntervalMs: 0,
        changeTimeoutMs: 100
    )

    let batch = try! executor.run(params: [
        "actions": .array([
            .object([
                "id": .string("a001"),
                "tool": .string("click"),
                "target": link,
                "resolve": revealResolution(surface: surface, direction: "down")
            ])
        ])
    ])

    #expect(batch["success"] == .bool(true))
    #expect(requests.map(\.method) == ["click"])
    #expect(requests[0].params?["target"] == link)
    #expect(requests[0].params?["resolve"] == nil)
}

@Test func runBatchTreatsRevealResolutionAsDispatchMetadata() {
    let link = articleLinkTarget()
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor(
        commandHandler: { request in
            requests.append(request)
            return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
        },
        changePollIntervalMs: 0,
        changeTimeoutMs: 100
    )

    let batch = try! executor.run(params: [
        "actions": .array([
            .object([
                "id": .string("a001"),
                "tool": .string("click"),
                "target": link,
                "resolve": revealResolution(surface: scrollSurfaceTarget(), direction: "down")
            ])
        ])
    ])

    #expect(batch["success"] == .bool(true))
    #expect(requests.map(\.method) == ["click"])
    #expect(requests[0].params?["target"] == link)
    #expect(requests[0].params?["resolve"] == nil)
}

@Test func runBatchVerifiesExpectedFactAndLaterRequirement() {
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor(
        commandHandler: { request in
            requests.append(request)
            return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
        },
        snapshotProvider: { app in
            #expect(app == "Example")
            return valueFactSnapshot(value: "Mitch")
        }
    )

    let fact: JSONValue = .object([
        "id": .string("a001.value.0"),
        "kind": .string("value"),
        "target": .object([
            "app": .string("Example"),
            "locator": .object([
                "role": .string("AXTextField"),
                "identifier": .string("name-field")
            ])
        ]),
        "state": .object([
            "value": .object(["equals": .string("Mitch")])
        ])
    ])

    let actions: JSONValue = .array([
            .object([
                "id": .string("a001"),
                "tool": .string("set_value"),
                "target": .string("s1:2"),
                "value": .string("Mitch"),
                "expects": .array([fact])
            ]),
            .object([
                "id": .string("a002"),
                "tool": .string("press_key"),
                "app": .string("Example"),
                "key": .string("Return"),
                "requires": .array([.string("a001.value.0")])
            ])
    ])
    let batch = try! executor.run(params: ["actions": actions])

    #expect(batch["success"] == JSONValue.bool(true))
    #expect(requests.map(\.method) == ["set_value", "press_key"])
    #expect(requests[0].params?["id"] == nil)
    #expect(requests[0].params?["expects"] == nil)
}

@Test func runBatchAllowsRecordedValueContainmentFacts() {
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor(
        commandHandler: { request in
            requests.append(request)
            return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
        },
        snapshotProvider: { _ in
            valueFactSnapshot(value: "wikipedia.com/")
        }
    )

    let fact: JSONValue = .object([
        "id": .string("a001.value.0"),
        "kind": .string("value"),
        "target": .object([
            "app": .string("Firefox"),
            "locator": .object([
                "role": .string("AXTextField"),
                "identifier": .string("name-field")
            ])
        ]),
        "state": .object([
            "value": .object(["contains": .string("wikipedia.com")])
        ])
    ])

    let batch = try! executor.run(params: [
        "actions": .array([
            .object([
                "id": .string("a001"),
                "tool": .string("set_value"),
                "target": .string("s1:2"),
                "value": .string("wikipedia.com"),
                "expects": .array([fact])
            ]),
            .object([
                "id": .string("a002"),
                "tool": .string("press_key"),
                "app": .string("Firefox"),
                "key": .string("Return"),
                "requires": .array([.string("a001.value.0")])
            ])
        ])
    ])

    #expect(batch["success"] == .bool(true))
    #expect(requests.map(\.method) == ["set_value", "press_key"])
}

@Test func runBatchStopsWhenRequiredFactNoLongerVerifies() {
    var snapshotReads = 0
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor(
        commandHandler: { request in
            requests.append(request)
            return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
        },
        snapshotProvider: { _ in
            snapshotReads += 1
            return valueFactSnapshot(value: snapshotReads == 1 ? "Mitch" : "Changed")
        }
    )

    let fact: JSONValue = .object([
        "id": .string("a001.value.0"),
        "kind": .string("value"),
        "target": .object([
            "app": .string("Example"),
            "locator": .object([
                "role": .string("AXTextField"),
                "identifier": .string("name-field")
            ])
        ]),
        "state": .object([
            "value": .object(["equals": .string("Mitch")])
        ])
    ])

    let actions: JSONValue = .array([
            .object([
                "id": .string("a001"),
                "tool": .string("set_value"),
                "target": .string("s1:2"),
                "value": .string("Mitch"),
                "expects": .array([fact])
            ]),
            .object([
                "id": .string("a002"),
                "tool": .string("press_key"),
                "app": .string("Example"),
                "key": .string("Return"),
                "requires": .array([.string("a001.value.0")])
            ])
    ])
    let batch = try! executor.run(params: ["actions": actions])

    #expect(batch["success"] == JSONValue.bool(false))
    #expect(requests.map(\.method) == ["set_value"])
    #expect(batch["trace"]?[1]?["actionId"] == JSONValue.string("a002"))
    #expect(batch["trace"]?[1]?["factId"] == JSONValue.string("a001.value.0"))
}

@Test func runBatchStopsOnFirstFailureByDefault() {
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, error: .invalidParams("bad target"))
    }

    let batch = try! executor.run(params: [
        "actions": .array([
            .object(["tool": .string("click"), "target": .string("missing")]),
            .object(["tool": .string("click"), "target": .string("never")])
        ])
    ])

    #expect(batch["success"] == .bool(false))
    #expect(batch["trace"]?.arrayValue?.count == 1)
    #expect(requests.count == 1)
}

private func valueFactSnapshot(value: String) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("fact-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXTextField", value: value, identifier: "name-field", focused: true)
            ])
        ],
        screenshot: nil
    )
}

private func changeFactSnapshot(title: String) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID(UUID().uuidString),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: title, children: [
                AXNode(role: "AXWebArea", title: title)
            ])
        ],
        screenshot: nil
    )
}

private func scrollSurfaceTarget() -> JSONValue {
    .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXScrollArea")
        ])
    ])
}

private func articleLinkTarget() -> JSONValue {
    .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXLink"),
            "title": .string("Article")
        ])
    ])
}

private func revealResolution(surface: JSONValue, direction: String, deltaY: Double? = nil) -> JSONValue {
    var reveal: [String: JSONValue] = [
            "surface": surface,
            "direction": .string(direction)
    ]
    if let deltaY {
        reveal["deltaY"] = .double(deltaY)
    }
    return .object([
        "reveal": .object(reveal)
    ])
}

private func articleMissingSnapshot(title: String = "Before") -> AppSnapshot {
    articleSnapshot(children: [
        AXNode(role: "AXStaticText", title: title)
    ])
}

private func articleLinkSnapshot() -> AppSnapshot {
    articleSnapshot(children: [
        AXNode(role: "AXLink", title: "Article")
    ])
}

private func articleSnapshot(children: [AXNode]) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID(UUID().uuidString),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXScrollArea", children: children)
            ])
        ],
        screenshot: nil
    )
}

@Test func runBatchCanContinueOnError() {
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor { request in
        requests.append(request)
        if requests.count == 1 {
            return JSONRPCResponse(id: request.id, error: .invalidParams("bad target"))
        }
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let batch = try! executor.run(params: [
        "continueOnError": .bool(true),
        "actions": .array([
            .object(["tool": .string("click"), "target": .string("missing")]),
            .object(["tool": .string("click"), "target": .string("s1:3")])
        ])
    ])

    #expect(batch["success"] == .bool(false))
    #expect(batch["trace"]?.arrayValue?.count == 2)
    #expect(requests.count == 2)
}

@Test func runBatchParsesAxnSource() {
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let source = """
    version: 1
    actions:
      - tool: press_key
        app: Firefox
        key: Return
    """
    let batch = try! executor.run(params: ["source": .string(source)])

    #expect(batch["success"] == .bool(true))
    #expect(requests == [
        JSONRPCRequest(
            id: .string("batch.0.press_key"),
            method: "press_key",
            params: .object([
                "app": .string("Firefox"),
                "key": .string("Return")
            ])
        )
    ])
}

@Test func commandRouterRunsBatch() {
    var clicked: [String] = []
    let router = CommandRouter(actions: PrimitiveActionHandlers(
        click: { target in
            clicked.append(target)
            return PrimitiveActionResult(action: "click", target: "clicked", strategy: "test", success: true)
        }
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("batch"),
        method: "run_batch",
        params: .object([
            "actions": .array([
                .object(["tool": .string("click"), "target": .string("s1:2")])
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["batch"]?["success"] == JSONValue.bool(true))
    #expect(clicked == ["s1:2"])
}

@Test func commandRouterRunsBatchFactsThroughBatchSnapshotProvider() {
    var setValues: [(String, String)] = []
    var batchSnapshotApps: [String] = []
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            Issue.record("batch fact verification should not use compact snapshot capture")
            return valueFactSnapshot(value: "Wrong")
        },
        batchSnapshotProvider: { app in
            batchSnapshotApps.append(app)
            return valueFactSnapshot(value: "Mitch")
        },
        actions: PrimitiveActionHandlers(
            setValue: { target, value in
                setValues.append((target, value))
                return PrimitiveActionResult(action: "set_value", target: target, strategy: "test", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("batch"),
        method: "run_batch",
        params: .object([
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("set_value"),
                    "target": .string("s1:2"),
                    "value": .string("Mitch"),
                    "expects": .array([
                        .object([
                            "id": .string("a001.value.0"),
                            "kind": .string("value"),
                            "target": .object([
                                "app": .string("Example"),
                                "locator": .object([
                                    "role": .string("AXTextField"),
                                    "identifier": .string("name-field")
                                ])
                            ]),
                            "state": .object([
                                "value": .object(["equals": .string("Mitch")])
                            ])
                        ])
                    ])
                ])
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["batch"]?["success"] == .bool(true))
    #expect(setValues.count == 1)
    #expect(batchSnapshotApps == ["Example"])
}

@Test func documentationBatchExamplesParse() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let examplesDirectory = packageRoot.appendingPathComponent("docs/examples")

    for name in ["open-menu.yaml", "read-and-click.yaml", "scroll.yaml"] {
        let source = try String(contentsOf: examplesDirectory.appendingPathComponent(name), encoding: .utf8)
        let batch = try ActionBatchExecutor.parseSource(source)
        guard case let .array(actions)? = batch["actions"] else {
            Issue.record("Batch \(name) is missing actions array")
            continue
        }
        #expect(!actions.isEmpty)
        for action in actions {
            #expect(action["tool"] != nil)
        }
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else {
            return nil
        }
        return values
    }
}
