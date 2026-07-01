import Foundation
import Testing
@testable import AxonCore

@Test func runExecutesToolShapedActionsInOrder() {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
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
                "tool": .string("type"),
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
    #expect(batch["trace"]?[0]?["tool"] == .string("type"))
    #expect(batch["trace"]?[1]?["tool"] == .string("click"))
    #expect(requests.map(\.method) == ["type", "click"])
    #expect(requests[0].params?["value"] == .string("Mitch"))
}

@Test func runStripsVerificationMetadataBeforeDispatch() {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
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

@Test func runFailsWhenPrimitiveActionReportsFailure() {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
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

@Test func runWaitsForChangedExpectationBeforeNextAction() {
    var snapshots = [
        changeFactSnapshot(title: "Before"),
        changeFactSnapshot(title: "Before"),
        changeFactSnapshot(title: "After")
    ]
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner(
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

@Test func runDoesNotEvaluateRevealResolutionBeforeDispatch() {
    let surface = scrollSurfaceTarget()
    let link = articleLinkTarget()
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner(
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

@Test func runTreatsRevealResolutionAsDispatchMetadata() {
    let link = articleLinkTarget()
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner(
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

@Test func runVerifiesExpectedFactAndLaterRequirement() {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner(
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
                "tool": .string("type"),
                "target": .string("s1:2"),
                "value": .string("Mitch"),
                "expects": .array([fact])
            ]),
            .object([
                "id": .string("a002"),
                "tool": .string("keyboard"),
                "app": .string("Example"),
                "keys": .string("Return"),
                "requires": .array([.string("a001.value.0")])
            ])
    ])
    let batch = try! executor.run(params: ["actions": actions])

    #expect(batch["success"] == JSONValue.bool(true))
    #expect(requests.map(\.method) == ["type", "keyboard"])
    #expect(requests[0].params?["id"] == nil)
    #expect(requests[0].params?["expects"] == nil)
}

@Test func runAllowsRecordedValueContainmentFacts() {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner(
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
                "tool": .string("type"),
                "target": .string("s1:2"),
                "value": .string("wikipedia.com"),
                "expects": .array([fact])
            ]),
            .object([
                "id": .string("a002"),
                "tool": .string("keyboard"),
                "app": .string("Firefox"),
                "keys": .string("Return"),
                "requires": .array([.string("a001.value.0")])
            ])
        ])
    ])

    #expect(batch["success"] == .bool(true))
    #expect(requests.map(\.method) == ["type", "keyboard"])
}

@Test func runStopsWhenRequiredFactNoLongerVerifies() {
    var snapshotReads = 0
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner(
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
                "tool": .string("type"),
                "target": .string("s1:2"),
                "value": .string("Mitch"),
                "expects": .array([fact])
            ]),
            .object([
                "id": .string("a002"),
                "tool": .string("keyboard"),
                "app": .string("Example"),
                "keys": .string("Return"),
                "requires": .array([.string("a001.value.0")])
            ])
    ])
    let batch = try! executor.run(params: ["actions": actions])

    #expect(batch["success"] == JSONValue.bool(false))
    #expect(requests.map(\.method) == ["type"])
    #expect(batch["trace"]?[1]?["actionId"] == JSONValue.string("a002"))
    #expect(batch["trace"]?[1]?["factId"] == JSONValue.string("a001.value.0"))
}

@Test func runStopsOnFirstFailureByDefault() {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
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

private func debugPauseSnapshot(id: String, app: String) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID(id),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: app, processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXButton", title: "Continue", identifier: "continue")
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

@Test func runCanContinueOnError() {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
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

@Test func runUsesTypedAxnForFileLevelOptionsAndInlineAppend() throws {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
        requests.append(request)
        if request.method == "click" {
            return JSONRPCResponse(id: request.id, error: .invalidParams("blocked"))
        }
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let source = """
    version: 1
    dryRun: false
    continueOnError: true
    owner: local-test
    actions:
      - id: note-1
        note: Preserved in the typed model, skipped by the runner
      - id: a001
        tool: keyboard
        app: Firefox
        keys: Return
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let result = try executor.run(params: [
        "path": .string(path),
        "actions": .array([
            .object([
                "id": .string("a002"),
                "tool": .string("click"),
                "target": .string("s1:2")
            ])
        ])
    ])

    #expect(result["success"] == .bool(false))
    #expect(result["continueOnError"] == .bool(true))
    #expect(result["trace"]?.arrayValue?.count == 2)
    #expect(result["trace"]?[0]?["index"] == .int(1))
    #expect(result["trace"]?[1]?["index"] == .int(2))
    #expect(requests.map(\.method) == ["keyboard", "click"])
}

@Test func runLoadsPathAndAppendsInlineActions() throws {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let source = """
    version: 1
    actions:
      - tool: keyboard
        app: Firefox
        keys: Return
    """
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-\(UUID().uuidString).axn")
        .path
    try source.write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let batch = try executor.run(params: [
        "path": .string(path),
        "actions": .array([
            .object([
                "tool": .string("click"),
                "target": .string("s1:2")
            ])
        ])
    ])

    #expect(batch["success"] == .bool(true))
    #expect(requests == [
        JSONRPCRequest(
            id: .string("run.0.keyboard"),
            method: "keyboard",
            params: .object([
                "app": .string("Firefox"),
                "keys": .string("Return")
            ])
        ),
        JSONRPCRequest(
            id: .string("run.1.click"),
            method: "click",
            params: .object([
                "target": .string("s1:2")
            ])
        )
    ])
}

@Test func runSubstitutesCallerArgumentsIntoActionValues() throws {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let source = """
    version: 1
    args:
      - name: recipient
        type: email
    actions:
      - tool: type
        target: s1:2
        value: "Hello {{recipient}}"
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let batch = try executor.run(params: [
        "path": .string(path),
        "argValues": .object(["recipient": .string("mitch@example.com")])
    ])

    #expect(batch["success"] == .bool(true))
    #expect(requests.count == 1)
    #expect(requests[0].params?["value"] == .string("Hello mitch@example.com"))
}

@Test func runFailsBeforeDispatchWhenRequiredArgumentIsMissing() throws {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let source = """
    version: 1
    args:
      - name: recipient
        type: email
    actions:
      - tool: type
        target: s1:2
        value: "{{recipient}}"
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
        _ = try executor.run(params: ["path": .string(path)])
        Issue.record("missing required argument should fail")
    } catch let error as AxnRunError {
        #expect(error.description == "missing required arg: recipient")
    }
    #expect(requests.isEmpty)
}

@Test func runRejectsUndeclaredParameterReferencesBeforeDispatch() throws {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let source = """
    version: 1
    actions:
      - tool: type
        target: s1:2
        value: "{{recipient}}"
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
        _ = try executor.run(params: ["path": .string(path)])
        Issue.record("undeclared parameter reference should fail")
    } catch let error as AxnRunError {
        #expect(error.description == "undeclared arg reference: recipient")
    }
    #expect(requests.isEmpty)
}

@Test func runRejectsInlineSourceReferencesBeforeDispatch() throws {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let source = """
    version: 1
    actions:
      - tool: type
        target: s1:2
        value: "{{env://HOME}}"
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
        _ = try executor.run(params: ["path": .string(path)])
        Issue.record("inline source reference should fail")
    } catch let error as AxnRunError {
        #expect(error.description == "invalid arg reference syntax: {{env://HOME}}")
    }
    #expect(requests.isEmpty)
}

@Test func runResolvesDeclaredSourceArguments() throws {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner(
        commandHandler: { request in
            requests.append(request)
            return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
        },
        parameterSourceResolvers: [
            "env": { source in
                #expect(source.absoluteString == "env://UPLOAD_NAME")
                return "report.csv"
            }
        ]
    )

    let source = """
    version: 1
    args:
      - name: upload_name
        type: string
        source: env://UPLOAD_NAME
    actions:
      - tool: type
        target: s1:2
        value: "{{upload_name}}"
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let batch = try executor.run(params: ["path": .string(path)])

    #expect(batch["success"] == .bool(true))
    #expect(requests[0].params?["value"] == .string("report.csv"))
}

@Test func runRejectsCallerOverrideForSourcedArgument() throws {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner(
        commandHandler: { request in
            requests.append(request)
            return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
        },
        parameterSourceResolvers: [
            "env": { _ in "from-source" }
        ]
    )

    let source = """
    version: 1
    args:
      - name: token
        type: string
        source: env://TOKEN
    actions:
      - tool: type
        target: s1:2
        value: "{{token}}"
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
        _ = try executor.run(params: [
            "path": .string(path),
            "argValues": .object(["token": .string("from-caller")])
        ])
        Issue.record("caller arg should not override a sourced arg")
    } catch let error as AxnRunError {
        #expect(error.description == "caller arg cannot override sourced arg: token")
    }
    #expect(requests.isEmpty)
}

@Test func runRedactsSecretTaintedDryRunParams() throws {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let source = """
    version: 1
    args:
      - name: password
        type: secret
    actions:
      - tool: type
        target: s1:2
        value: "pw={{password}}"
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let batch = try executor.run(params: [
        "path": .string(path),
        "dryRun": .bool(true),
        "argValues": .object(["password": .string("s3cr3t!")])
    ])

    #expect(batch["success"] == .bool(true))
    #expect(batch["trace"]?[0]?["params"]?["value"] == .string("<redacted: contains-secret>"))
    #expect(requests.isEmpty)
}

@Test func runRedactsSecretTaintedTraceResults() throws {
    let executor = AxnRunner { request in
        JSONRPCResponse(id: request.id, result: [
            "action": .object([
                "success": .bool(true),
                "echo": request.params?["value"] ?? .null
            ])
        ])
    }

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

    let batch = try executor.run(params: [
        "path": .string(path),
        "argValues": .object(["password": .string("s3cr3t!")])
    ])

    #expect(batch["success"] == .bool(true))
    #expect(batch["trace"]?[0]?["result"] == .string("<redacted: contains-secret>"))
}

@Test func runRedactsSecretTaintedJSONRPCErrors() throws {
    let executor = AxnRunner { request in
        let value = request.params?["value"]?.stringValue ?? "missing"
        return JSONRPCResponse(id: request.id, error: .invalidParams("failed with \(value)"))
    }

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

    let batch = try executor.run(params: [
        "path": .string(path),
        "argValues": .object(["password": .string("s3cr3t!")])
    ])

    #expect(batch["success"] == .bool(false))
    #expect(batch["trace"]?[0]?["error"] == .string("<redacted: contains-secret>"))
}

@Test func runRejectsParameterReferencesInNonStringValueFieldsBeforeDispatch() throws {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let source = """
    version: 1
    args:
      - name: recipient
        type: string
    actions:
      - tool: type
        target: s1:2
        value:
          - "{{recipient}}"
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
        _ = try executor.run(params: [
            "path": .string(path),
            "argValues": .object(["recipient": .string("Ada")])
        ])
        Issue.record("non-string value parameter reference should fail before dispatch")
    } catch let error as AxnRunError {
        #expect(error.description == "parameter references are only supported in string value fields: actions[0].value")
    }
    #expect(requests.isEmpty)
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
        method: "run",
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

@Test func commandRouterRunsFactsThroughAxnSnapshotProvider() {
    var types: [(String, String)] = []
    var axnSnapshotApps: [String] = []
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            Issue.record("Axn fact verification should not use compact snapshot capture")
            return valueFactSnapshot(value: "Wrong")
        },
        axnSnapshotProvider: { app in
            axnSnapshotApps.append(app)
            return valueFactSnapshot(value: "Mitch")
        },
        actions: PrimitiveActionHandlers(
            type: { target, value in
                types.append((target, value))
                return PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("batch"),
        method: "run",
        params: .object([
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("type"),
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
    #expect(types.count == 1)
    #expect(axnSnapshotApps == ["Example"])
}

@Test func commandRouterDebugStartPausesBeforeSelectedBlock() {
    var requests: [String] = []
    let router = CommandRouter(actions: PrimitiveActionHandlers(
        click: { target in
            requests.append("click:\(target)")
            return PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
        },
        type: { target, value in
            requests.append("type:\(target):\(value)")
            return PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true)
        }
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("debug-start"),
        method: "debug.start",
        params: .object([
            "pauseBefore": .string("a002"),
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("click"),
                    "target": .string("s1:2")
                ]),
                .object([
                    "id": .string("a002"),
                    "tool": .string("type"),
                    "target": .string("s1:3"),
                    "value": .string("Mitch")
                ])
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["debug"]?["state"] == .string("paused"))
    #expect(response.result?["debug"]?["currentActionId"] == .string("a002"))
    #expect(response.result?["debug"]?["trace"]?[0]?["actionId"] == .string("a001"))
    #expect(requests == ["click:s1:2"])
}

@Test func commandRouterDebugStartCarriesCallerDocumentID() {
    let router = CommandRouter(actions: PrimitiveActionHandlers())

    let response = router.handle(JSONRPCRequest(
        id: .string("debug-start"),
        method: "debug.start",
        params: .object([
            "documentId": .string("doc-123"),
            "actions": .array([])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["debug"]?["documentId"] == .string("doc-123"))
}

@Test func commandRouterDebugCreateDoesNotRunActions() {
    var requests: [String] = []
    let router = CommandRouter(actions: PrimitiveActionHandlers(
        click: { target in
            requests.append("click:\(target)")
            return PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
        }
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("debug-create"),
        method: "debug.create",
        params: .object([
            "breakpoints": .array([.string("a002")]),
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("click"),
                    "target": .string("s1:1")
                ])
            ])
        ])
    ))

    let debug = response.result?["debug"]
    #expect(response.error == nil)
    #expect(debug?["state"] == .string("paused"))
    #expect(debug?["cursorBlockId"] == .string("a001"))
    #expect(debug?["lastActionId"] == .null)
    #expect(debug?["pauseReason"] == .string("start"))
    #expect(debug?["availableActions"]?.arrayValue?.contains(.string("runTo")) == true)
    #expect(requests == [])
}

@Test func commandRouterDebugRunToPausesBeforeSelectedBlock() {
    var requests: [String] = []
    let router = CommandRouter(actions: PrimitiveActionHandlers(
        click: { target in
            requests.append("click:\(target)")
            return PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
        },
        type: { target, value in
            requests.append("type:\(target):\(value)")
            return PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true)
        }
    ))

    let start = router.handle(JSONRPCRequest(
        id: .string("debug-create"),
        method: "debug.create",
        params: .object([
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("click"),
                    "target": .string("s1:1")
                ]),
                .object([
                    "id": .string("a002"),
                    "tool": .string("type"),
                    "target": .string("s1:2"),
                    "value": .string("Ada")
                ])
            ])
        ])
    ))
    guard case let .string(sessionID)? = start.result?["debug"]?["sessionId"] else {
        Issue.record("debug.create should return a session id")
        return
    }

    let runTo = router.handle(JSONRPCRequest(
        id: .string("debug-run-to"),
        method: "debug.runTo",
        params: .object([
            "sessionId": .string(sessionID),
            "blockId": .string("a002")
        ])
    ))

    let debug = runTo.result?["debug"]
    #expect(runTo.error == nil)
    #expect(debug?["state"] == .string("paused"))
    #expect(debug?["cursorBlockId"] == .string("a002"))
    #expect(debug?["lastActionId"] == .string("a001"))
    #expect(debug?["pauseReason"] == .string("runTo"))
    #expect(requests == ["click:s1:1"])
}

@Test func commandRouterDebugSetBreakpointsUpdatesLiveSession() {
    var requests: [String] = []
    let router = CommandRouter(actions: PrimitiveActionHandlers(
        click: { target in
            requests.append("click:\(target)")
            return PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
        }
    ))

    let start = router.handle(JSONRPCRequest(
        id: .string("debug-create"),
        method: "debug.create",
        params: .object([
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("click"),
                    "target": .string("s1:1")
                ]),
                .object([
                    "id": .string("a002"),
                    "tool": .string("click"),
                    "target": .string("s1:2")
                ])
            ])
        ])
    ))
    guard case let .string(sessionID)? = start.result?["debug"]?["sessionId"] else {
        Issue.record("debug.create should return a session id")
        return
    }

    let updated = router.handle(JSONRPCRequest(
        id: .string("debug-set-breakpoints"),
        method: "debug.setBreakpoints",
        params: .object([
            "sessionId": .string(sessionID),
            "breakpoints": .array([.string("a002")])
        ])
    ))
    let resumed = router.handle(JSONRPCRequest(
        id: .string("debug-resume"),
        method: "debug.resume",
        params: .object(["sessionId": .string(sessionID)])
    ))

    #expect(updated.error == nil)
    #expect(updated.result?["debug"]?["breakpoints"] == .array([.string("a002")]))
    #expect(resumed.error == nil)
    #expect(resumed.result?["debug"]?["state"] == .string("paused"))
    #expect(resumed.result?["debug"]?["cursorBlockId"] == .string("a002"))
    #expect(resumed.result?["debug"]?["pauseReason"] == .string("breakpoint"))
    #expect(requests == ["click:s1:1"])
}

@Test func commandRouterDebugStartCapturesSnapshotForPauseBefore() {
    var snapshotApps: [String] = []
    let router = CommandRouter(
        axnSnapshotProvider: { app in
            snapshotApps.append(app)
            return debugPauseSnapshot(id: "pause-snapshot", app: app)
        },
        actions: PrimitiveActionHandlers()
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("debug-start"),
        method: "debug.start",
        params: .object([
            "pauseBefore": .string("a001"),
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("click"),
                    "app": .string("Example"),
                    "target": .string("s1:1")
                ])
            ])
        ])
    ))

    #expect(response.error == nil)
    let debug = response.result?["debug"]
    let pauseSnapshot = debug?["pauseSnapshot"]
    #expect(debug?["state"] == JSONValue.string("paused"))
    #expect(pauseSnapshot?["reason"] == JSONValue.string("pauseBefore"))
    #expect(pauseSnapshot?["snapshotId"] == JSONValue.string("pause-snapshot"))
    #expect(pauseSnapshot?["app"]?["name"] == JSONValue.string("Example"))
    #expect(snapshotApps == ["Example"])
}

@Test func commandRouterDebugStepDoesNotCaptureSnapshotForOrdinaryStepPause() {
    var snapshotApps: [String] = []
    let router = CommandRouter(
        axnSnapshotProvider: { app in
            snapshotApps.append(app)
            return debugPauseSnapshot(id: "unexpected", app: app)
        },
        actions: PrimitiveActionHandlers(
            click: { target in
                PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
            }
        )
    )

    let start = router.handle(JSONRPCRequest(
        id: .string("debug-start"),
        method: "debug.start",
        params: .object([
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("click"),
                    "app": .string("Example"),
                    "target": .string("s1:1")
                ]),
                .object([
                    "id": .string("a002"),
                    "tool": .string("click"),
                    "app": .string("Example"),
                    "target": .string("s1:1")
                ])
            ])
        ])
    ))
    guard case let .string(sessionID)? = start.result?["debug"]?["sessionId"] else {
        Issue.record("debug.start should return a session id")
        return
    }

    let stepped = router.handle(JSONRPCRequest(
        id: .string("debug-step"),
        method: "debug.step",
        params: .object(["sessionId": .string(sessionID)])
    ))

    #expect(stepped.error == nil)
    let debug = stepped.result?["debug"]
    #expect(debug?["state"] == JSONValue.string("paused"))
    #expect(debug?["currentActionId"] == JSONValue.string("a002"))
    #expect(debug?["pauseSnapshot"] == nil)
    #expect(snapshotApps == [])
}

@Test func commandRouterDebugContinuePausesAtNextBreakpoint() {
    var requests: [String] = []
    let router = CommandRouter(actions: PrimitiveActionHandlers(
        click: { target in
            requests.append("click:\(target)")
            return PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
        },
        type: { target, value in
            requests.append("type:\(target):\(value)")
            return PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true)
        }
    ))

    let start = router.handle(JSONRPCRequest(
        id: .string("debug-start"),
        method: "debug.start",
        params: .object([
            "breakpoints": .array([.string("a003")]),
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("click"),
                    "target": .string("s1:1")
                ]),
                .object([
                    "id": .string("a002"),
                    "tool": .string("type"),
                    "target": .string("s1:2"),
                    "value": .string("Ada")
                ]),
                .object([
                    "id": .string("a003"),
                    "tool": .string("click"),
                    "target": .string("s1:3")
                ])
            ])
        ])
    ))
    guard case let .string(sessionID)? = start.result?["debug"]?["sessionId"] else {
        Issue.record("debug.start should return a session id")
        return
    }

    let continued = router.handle(JSONRPCRequest(
        id: .string("debug-continue"),
        method: "debug.continue",
        params: .object(["sessionId": .string(sessionID)])
    ))

    #expect(continued.error == nil)
    #expect(continued.result?["debug"]?["state"] == .string("paused"))
    #expect(continued.result?["debug"]?["currentActionId"] == .string("a003"))
    #expect(requests == ["click:s1:1", "type:s1:2:Ada"])
}

@Test func commandRouterDebugContinueCapturesSnapshotAtBreakpoint() {
    var snapshotApps: [String] = []
    let router = CommandRouter(
        axnSnapshotProvider: { app in
            snapshotApps.append(app)
            return debugPauseSnapshot(id: "breakpoint-snapshot", app: app)
        },
        actions: PrimitiveActionHandlers(
            click: { target in
                PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
            }
        )
    )

    let start = router.handle(JSONRPCRequest(
        id: .string("debug-start"),
        method: "debug.start",
        params: .object([
            "breakpoints": .array([.string("a002")]),
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("click"),
                    "app": .string("Example"),
                    "target": .string("s1:1")
                ]),
                .object([
                    "id": .string("a002"),
                    "tool": .string("click"),
                    "app": .string("Example"),
                    "target": .string("s1:1")
                ])
            ])
        ])
    ))
    guard case let .string(sessionID)? = start.result?["debug"]?["sessionId"] else {
        Issue.record("debug.start should return a session id")
        return
    }

    let continued = router.handle(JSONRPCRequest(
        id: .string("debug-continue"),
        method: "debug.continue",
        params: .object(["sessionId": .string(sessionID)])
    ))

    #expect(continued.error == nil)
    let debug = continued.result?["debug"]
    let pauseSnapshot = debug?["pauseSnapshot"]
    #expect(debug?["state"] == JSONValue.string("paused"))
    #expect(pauseSnapshot?["reason"] == JSONValue.string("breakpoint"))
    #expect(pauseSnapshot?["snapshotId"] == JSONValue.string("breakpoint-snapshot"))
    #expect(snapshotApps == ["Example"])
}

@Test func commandRouterDebugStepExecutesCurrentActionAndAdvances() {
    var requests: [String] = []
    let router = CommandRouter(actions: PrimitiveActionHandlers(
        click: { target in
            requests.append("click:\(target)")
            return PrimitiveActionResult(action: "click", target: target, strategy: "test", success: true)
        },
        type: { target, value in
            requests.append("type:\(target):\(value)")
            return PrimitiveActionResult(action: "type", target: target, strategy: "test", success: true)
        }
    ))

    let start = router.handle(JSONRPCRequest(
        id: .string("debug-start"),
        method: "debug.start",
        params: .object([
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("click"),
                    "target": .string("s1:1")
                ]),
                .object([
                    "id": .string("a002"),
                    "tool": .string("type"),
                    "target": .string("s1:2"),
                    "value": .string("Ada")
                ])
            ])
        ])
    ))
    guard case let .string(sessionID)? = start.result?["debug"]?["sessionId"] else {
        Issue.record("debug.start should return a session id")
        return
    }

    let stepped = router.handle(JSONRPCRequest(
        id: .string("debug-step"),
        method: "debug.step",
        params: .object(["sessionId": .string(sessionID)])
    ))

    #expect(stepped.error == nil)
    #expect(stepped.result?["debug"]?["state"] == .string("paused"))
    #expect(stepped.result?["debug"]?["currentActionId"] == .string("a002"))
    #expect(stepped.result?["debug"]?["trace"]?[0]?["actionId"] == .string("a001"))
    #expect(requests == ["click:s1:1"])
}

@Test func commandRouterDebugFailureCapturesSnapshotAndCanRetry() {
    var attempts = 0
    var snapshotApps: [String] = []
    let router = CommandRouter(
        axnSnapshotProvider: { app in
            let id = "failure-snapshot-\(snapshotApps.count + 1)"
            snapshotApps.append(app)
            return debugPauseSnapshot(id: id, app: app)
        },
        actions: PrimitiveActionHandlers(
            click: { target in
                attempts += 1
                return PrimitiveActionResult(
                    action: "click",
                    target: target,
                    strategy: "test",
                    success: attempts > 1,
                    message: attempts > 1 ? nil : "blocked"
                )
            }
        )
    )

    let start = router.handle(JSONRPCRequest(
        id: .string("debug-start"),
        method: "debug.start",
        params: .object([
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("click"),
                    "app": .string("Example"),
                    "target": .string("s1:1")
                ])
            ])
        ])
    ))
    guard case let .string(sessionID)? = start.result?["debug"]?["sessionId"] else {
        Issue.record("debug.start should return a session id")
        return
    }

    let failed = router.handle(JSONRPCRequest(
        id: .string("debug-step"),
        method: "debug.step",
        params: .object(["sessionId": .string(sessionID)])
    ))
    let retried = router.handle(JSONRPCRequest(
        id: .string("debug-retry"),
        method: "debug.retry",
        params: .object(["sessionId": .string(sessionID)])
    ))

    #expect(failed.error == nil)
    let failedDebug = failed.result?["debug"]
    let failureSnapshot = failedDebug?["pauseSnapshot"]
    #expect(failedDebug?["state"] == JSONValue.string("failed"))
    #expect(failedDebug?["currentActionId"] == JSONValue.string("a001"))
    #expect(failureSnapshot?["reason"] == JSONValue.string("failure"))
    #expect(failureSnapshot?["snapshotId"] == JSONValue.string("failure-snapshot-1"))
    #expect(retried.error == nil)
    #expect(retried.result?["debug"]?["state"] == JSONValue.string("completed"))
    #expect(attempts == 2)
    #expect(snapshotApps == ["Example"])
}

@Test func runSkipsFirstClassNoteBlocks() throws {
    var requests: [JSONRPCRequest] = []
    let executor = AxnRunner { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let source = """
    version: 1
    actions:
      - id: n001
        note: Prepare the app state
      - id: a001
        tool: type
        target: s1:2
        value: Hello
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let batch = try executor.run(params: ["path": .string(path)])

    #expect(batch["success"] == .bool(true))
    #expect(batch["trace"]?.arrayValue?.count == 1)
    #expect(batch["trace"]?[0]?["index"] == .int(1))
    #expect(batch["trace"]?[0]?["actionId"] == .string("a001"))
    #expect(requests.map(\.method) == ["type"])
}

@Test func documentationBatchExamplesParse() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let examplesDirectory = packageRoot.appendingPathComponent("docs/examples")

    for name in ["open-menu.yaml", "read-and-click.yaml", "scroll.yaml"] {
        let source = try String(contentsOf: examplesDirectory.appendingPathComponent(name), encoding: .utf8)
        let batch = try AxnRunner.parseSource(source)
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

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }
}

private func temporaryAxnFile(_ source: String) throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-\(UUID().uuidString).axn")
        .path
    try source.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

@Test func runRejectsImpossibleISODateBeforeDispatch() throws {
    var requests: [JSONRPCRequest] = []
    let runner = AxnRunner { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let source = """
    version: 1
    args:
      - name: report_date
        type: date
    actions:
      - tool: type
        target: s1:2
        value: "{{report_date}}"
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
        _ = try runner.run(params: [
            "path": .string(path),
            "argValues": .object(["report_date": .string("2026-02-30")])
        ])
        Issue.record("impossible ISO-shaped date should fail before dispatch")
    } catch let error as AxnRunError {
        #expect(error.description == "arg report_date must be an ISO date, today, or yesterday")
    }
    #expect(requests.isEmpty)
}

@Test func runKeepsSecretTaintScopedAcrossContinueOnError() throws {
    var requests: [JSONRPCRequest] = []
    let runner = AxnRunner { request in
        requests.append(request)
        if request.method == "type" {
            let value = request.params?["value"]?.stringValue ?? "missing"
            return JSONRPCResponse(id: request.id, error: .invalidParams("failed with \(value)"))
        }
        return JSONRPCResponse(id: request.id, result: [
            "action": .object([
                "success": .bool(true),
                "target": request.params?["target"] ?? .null
            ])
        ])
    }

    let source = """
    version: 1
    args:
      - name: password
        type: secret
    actions:
      - tool: type
        target: s1:2
        value: "{{password}}"
      - tool: click
        target: s1:3
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let result = try runner.run(params: [
        "path": .string(path),
        "continueOnError": .bool(true),
        "argValues": .object(["password": .string("s3cr3t!")])
    ])

    #expect(result["success"] == .bool(false))
    #expect(result["trace"]?[0]?["success"] == .bool(false))
    #expect(result["trace"]?[0]?["error"] == .string("<redacted: contains-secret>"))
    #expect(result["trace"]?[1]?["success"] == .bool(true))
    #expect(result["trace"]?[1]?["result"]?["target"] == .string("s1:3"))
    #expect(requests.map(\.method) == ["type", "click"])
    #expect(requests[0].params?["value"] == .string("s3cr3t!"))
}

@Test func runAppendedActionsShareDeclaredArgumentsAndSecretTaint() throws {
    var requests: [JSONRPCRequest] = []
    let runner = AxnRunner { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: [
            "action": .object([
                "success": .bool(true),
                "echo": request.params ?? .null
            ])
        ])
    }

    let source = """
    version: 1
    args:
      - name: password
        type: secret
    actions:
      - tool: click
        target: s1:1
    """
    let path = try temporaryAxnFile(source)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let result = try runner.run(params: [
        "path": .string(path),
        "actions": .array([
            .object([
                "tool": .string("type"),
                "target": .string("s1:2"),
                "value": .string("pw={{password}}")
            ])
        ]),
        "argValues": .object(["password": .string("s3cr3t!")])
    ])

    #expect(result["success"] == .bool(true))
    #expect(requests.map(\.method) == ["click", "type"])
    #expect(requests[1].params?["value"] == .string("pw=s3cr3t!"))
    #expect(result["trace"]?[0]?["result"]?["echo"]?["target"] == .string("s1:1"))
    #expect(result["trace"]?[1]?["result"] == .string("<redacted: contains-secret>"))
}

@Test func commandRouterDebugPauseSnapshotRedactsActiveCredentials() throws {
    let secret = "correct horse battery staple"
    let router = CommandRouter(
        axnSnapshotProvider: { app in
            AppSnapshot(
                id: SnapshotID("debug-redaction"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: app, processIdentifier: 42),
                windows: [
                    AXNode(role: "AXWindow", title: "Main", children: [
                        AXNode(role: "AXTextField", value: secret)
                    ])
                ],
                screenshot: nil
            )
        },
        actions: PrimitiveActionHandlers(),
        activeCredentialFilter: try axnActiveCredentialFilter(values: [secret])
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("debug-start"),
        method: "debug.start",
        params: .object([
            "pauseBefore": .string("a001"),
            "actions": .array([
                .object([
                    "id": .string("a001"),
                    "tool": .string("click"),
                    "app": .string("Example"),
                    "target": .string("s1:1")
                ])
            ])
        ])
    ))
    let encoded = String(decoding: try JSONEncoder().encode(JSONValue.object(response.result ?? [:])), as: UTF8.self)

    #expect(response.error == nil)
    #expect(encoded.contains(secret) == false)
    #expect(encoded.contains("<redacted: active-credential>") == true)
}

private func axnActiveCredentialFilter(values: [String]) throws -> ActiveCredentialIndex {
    try ActiveCredentialIndex(
        secrets: values.map {
            ActiveCredentialSecret(value: $0, provider: "test", reference: "op://Axn/Active/secret")
        },
        hmacKey: Data(repeating: 0x3C, count: 32),
        provider: "test",
        createdAt: Date(timeIntervalSince1970: 1_775_000_000)
    )
}
