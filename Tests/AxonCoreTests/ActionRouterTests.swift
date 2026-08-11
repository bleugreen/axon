import Foundation
import Testing
@testable import AxonCore

@Test func clickRequestReturnsActionResult() {
    let registry = SemanticNameRegistry()
    registry.registerReplayEvidence(
        app: "Example",
        name: "primary-button",
        locator: AXLocator(role: "AXButton", title: .exact("Primary"))
    )
    let router = CommandRouter(
        resolveLocator: { _, _, _ in
            let snapshotID = SnapshotID("snap")
            return LocatorResolution(
                status: .unique,
                snapshotID: snapshotID,
                best: LocatorCandidate(index: 1, handle: SnapshotHandle(snapshotID: snapshotID, nodeIndex: 1), role: "AXButton", title: "Primary", score: 1_000, reasons: []),
                candidates: []
            )
        },
        actions: PrimitiveActionHandlers(
            click: { target, _ in
                #expect(target == "snap:1")
                return PrimitiveActionResult(action: "click", target: target, strategy: "AXPress", success: true)
            }
        ),
        semanticNameRegistry: registry
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("click-1"),
        method: "click",
        params: .object(["target": .object(["app": .string("Example"), "name": .string("primary-button")])])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["strategy"] == .string("AXPress"))
}

@Test func waitForStabilityIgnoresSubToleranceFrameJitter() {
    var nowMs = 0
    var captures = 0
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            captures += 1
            let frame = AXFrame(x: Double(captures) * 0.4, y: 0, width: 100, height: 20)
            return AppSnapshot(
                id: SnapshotID("jitter-\(captures)"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [AXNode(role: "AXWindow", title: "Ready", frame: frame)],
                screenshot: nil
            )
        },
        now: { Date(timeIntervalSince1970: Double(nowMs) / 1_000) },
        sleepMilliseconds: { nowMs += $0 }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("jitter"), method: "wait_for_stability",
        params: .object(["app": .string("Example"), "stableMs": .int(200), "timeoutMs": .int(500), "intervalMs": .int(100)])
    ))

    #expect(response.result?["wait"]?["success"] == .bool(true))
    #expect(response.result?["wait"]?["elapsedMs"] == .int(200))
}

private func stabilitySnapshot(id: String, title: String) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID(id),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [AXNode(role: "AXWindow", title: title)],
        screenshot: nil
    )
}

@Test func waitForStabilityReturnsAfterBoundedUnchangedWindow() {
    var nowMs = 0
    var sleeps: [Int] = []
    var captures = 0
    let router = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "Example")
            #expect(screenshot == false)
            captures += 1
            return stabilitySnapshot(id: "stable-\(captures)", title: "Ready")
        },
        now: { Date(timeIntervalSince1970: Double(nowMs) / 1_000) },
        sleepMilliseconds: { milliseconds in sleeps.append(milliseconds); nowMs += milliseconds }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("stable"), method: "wait_for_stability",
        params: .object(["app": .string("Example"), "stableMs": .int(200), "timeoutMs": .int(500), "intervalMs": .int(100)])
    ))

    #expect(response.error == nil)
    #expect(response.result?["wait"]?["success"] == .bool(true))
    #expect(response.result?["wait"]?["elapsedMs"] == .int(200))
    #expect(response.result?["wait"]?["finalObservation"]?["id"] == .string("stable-3"))
    #expect(sleeps == [100, 100])
}

@Test func waitForStabilityChangedConditionReturnsChangedObservation() {
    var nowMs = 0
    var captures = 0
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            captures += 1
            return stabilitySnapshot(id: "change-\(captures)", title: captures < 2 ? "Loading" : "Ready")
        },
        now: { Date(timeIntervalSince1970: Double(nowMs) / 1_000) },
        sleepMilliseconds: { nowMs += $0 }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("changed"), method: "wait_for_stability",
        params: .object(["app": .string("Example"), "condition": .string("changed"), "timeoutMs": .int(500), "intervalMs": .int(100)])
    ))

    #expect(response.result?["wait"]?["success"] == .bool(true))
    #expect(response.result?["wait"]?["elapsedMs"] == .int(100))
    #expect(response.result?["wait"]?["finalObservation"]?["id"] == .string("change-2"))
}

@Test func waitForStabilityTimeoutReturnsFinalObservationAndCapsLastSleep() {
    var nowMs = 0
    var captures = 0
    var sleeps: [Int] = []
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            captures += 1
            return stabilitySnapshot(id: "timeout-\(captures)", title: "State \(captures)")
        },
        now: { Date(timeIntervalSince1970: Double(nowMs) / 1_000) },
        sleepMilliseconds: { sleeps.append($0); nowMs += $0 }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("timeout"), method: "wait_for_stability",
        params: .object(["app": .string("Example"), "stableMs": .int(200), "timeoutMs": .int(250), "intervalMs": .int(100)])
    ))

    #expect(response.result?["wait"]?["success"] == .bool(false))
    #expect(response.result?["wait"]?["elapsedMs"] == .int(250))
    #expect(response.result?["wait"]?["finalObservation"]?["id"] == .string("timeout-4"))
    #expect(sleeps == [100, 100, 50])
}

@Test func keyboardRejectsUnknownMixedAndAbsentIntent() {
    let router = CommandRouter(actions: PrimitiveActionHandlers())
    let requests: [[String: JSONValue]] = [
        ["key": .string("DefinitelyNotAKey")],
        ["key": .string("Return"), "text": .string("hello")],
        [:]
    ]

    for (index, params) in requests.enumerated() {
        let response = router.handle(JSONRPCRequest(
            id: .int(index),
            method: "keyboard",
            params: .object(params)
        ))
        #expect(response.error?.code == JSONRPCError.invalidParams("").code)
    }
}

@Test func clickRequestAcceptsPointTarget() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            clickPoint: { point, _ in
                #expect(point.x == 25)
                #expect(point.y == 40)
                return PrimitiveActionResult(
                    action: "click",
                    target: "point:25,40",
                    strategy: "CGEvent",
                    success: true,
                    details: ["point": point.jsonValue]
                )
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("click-point"),
        method: "click",
        params: .object([
            "target": .object([
                "point": .object([
                    "x": .int(25),
                    "y": .int(40)
                ])
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["target"] == .string("point:25,40"))
    #expect(response.result?["action"]?["point"]?["x"] == .double(25))
}

@Test func findRequestReturnsLocatorResolution() {
    let router = CommandRouter(
        resolveLocator: { app, locator, scrollToVisible in
            #expect(app == "com.example.App")
            #expect(locator.role == "AXButton")
            #expect(locator.title?.matches("NEW") == true)
            #expect(scrollToVisible == false)
            return LocatorResolution(
                status: .unique,
                snapshotID: SnapshotID("live-locator"),
                best: LocatorCandidate(
                    index: 2,
                    handle: SnapshotHandle(snapshotID: SnapshotID("live-locator"), nodeIndex: 2),
                    role: "AXButton",
                    title: "NEW",
                    score: 2,
                    reasons: []
                ),
                candidates: []
            )
        }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("resolve-1"),
        method: "find",
        params: .object([
            "app": .string("com.example.App"),
            "locator": .object([
                "role": .string("AXButton"),
                "title": .object(["exact": .string("NEW")]),
                "actions": .array([.string("AXPress")])
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["resolution"]?["status"] == .string("unique"))
    #expect(response.result?["resolution"]?["best"]?["handle"] == .string("live-locator:2"))
}

@Test func waitForValueSucceedsWhenDescriptionMatches() {
    var nowMs = 0
    var sleeps: [Int] = []
    var reads = 0
    let registry = SemanticNameRegistry()
    registry.registerReplayEvidence(
        app: "Firefox",
        name: "site-information-button",
        locator: AXLocator(role: "AXButton")
    )
    let router = CommandRouter(
        resolveLocator: { app, locator, scrollToVisible in
            #expect(app == "Firefox")
            #expect(locator.role == "AXButton")
            #expect(scrollToVisible == false)
            return waitUniqueResolution()
        },
        readableAXState: { handle in
            #expect(handle.rawValue == "wait:0")
            reads += 1
            return ReadableAXState(fields: [
                "title": "",
                "description": reads < 2 ? "Loading" : "View site information"
            ])
        },
        now: { Date(timeIntervalSince1970: Double(nowMs) / 1_000) },
        sleepMilliseconds: { milliseconds in
            sleeps.append(milliseconds)
            nowMs += milliseconds
        },
        semanticNameRegistry: registry
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("wait-description"),
        method: "wait_for_value",
        params: .object([
            "target": .object([
                "app": .string("Firefox"),
                "name": .string("site-information-button")
            ]),
            "contains": .string("View site information"),
            "timeoutMs": .int(500),
            "intervalMs": .int(100)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["wait"]?["success"] == .bool(true))
    #expect(response.result?["wait"]?["status"] == .string("satisfied"))
    #expect(response.result?["wait"]?["matched"]?["field"] == .string("description"))
    #expect(response.result?["wait"]?["matched"]?["value"] == .string("View site information"))
    #expect(response.result?["wait"]?["elapsedMs"] == .int(100))
    #expect(sleeps == [100])
}

@Test func waitForValueTimesOutWithLastObservedState() {
    var nowMs = 0
    let registry = SemanticNameRegistry()
    registry.registerReplayEvidence(
        app: "Firefox",
        name: "address-field",
        locator: AXLocator(role: "AXComboBox")
    )
    let router = CommandRouter(
        resolveLocator: { _, _, _ in waitUniqueResolution() },
        readableAXState: { _ in ReadableAXState(fields: ["value": "about:blank"]) },
        now: { Date(timeIntervalSince1970: Double(nowMs) / 1_000) },
        sleepMilliseconds: { nowMs += $0 },
        semanticNameRegistry: registry
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("wait-timeout"),
        method: "wait_for_value",
        params: .object([
            "target": .object([
                "app": .string("Firefox"),
                "name": .string("address-field")
            ]),
            "equals": .string("https://example.com/"),
            "timeoutMs": .int(250),
            "intervalMs": .int(100)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["wait"]?["success"] == .bool(false))
    #expect(response.result?["wait"]?["status"] == .string("predicate_timeout"))
    #expect(response.result?["wait"]?["lastObserved"]?["value"] == .string("about:blank"))
    #expect(response.result?["wait"]?["elapsedMs"] == .int(250))
}

@Test func waitForValueTimesOutWhenTargetNeverResolves() {
    var nowMs = 0
    let registry = SemanticNameRegistry()
    registry.registerReplayEvidence(
        app: "Firefox",
        name: "address-field",
        locator: AXLocator(role: "AXComboBox")
    )
    let router = CommandRouter(
        resolveLocator: { _, _, _ in
            LocatorResolution(status: .missing, snapshotID: SnapshotID("wait"), best: nil, candidates: [])
        },
        readableAXState: { _ in
            Issue.record("wait_for_value should not read state when the locator never resolves uniquely")
            return ReadableAXState(fields: [:])
        },
        now: { Date(timeIntervalSince1970: Double(nowMs) / 1_000) },
        sleepMilliseconds: { nowMs += $0 },
        semanticNameRegistry: registry
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("wait-unresolved"),
        method: "wait_for_value",
        params: .object([
            "target": .object([
                "app": .string("Firefox"),
                "name": .string("address-field")
            ]),
            "matches": .string("example\\.com"),
            "timeoutMs": .int(200),
            "intervalMs": .int(100)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["wait"]?["success"] == .bool(false))
    #expect(response.result?["wait"]?["status"] == .string("target_unresolved_timeout"))
    #expect(response.result?["wait"]?["lastObserved"] == .null)
    #expect(response.result?["wait"]?["resolution"]?["status"] == .string("missing"))
}

@Test func clickRequestAcceptsSemanticNameTarget() {
    let registry = SemanticNameRegistry()
    registry.registerReplayEvidence(
        app: "com.example.App",
        name: "new-button",
        locator: AXLocator(role: "AXButton", title: .exact("NEW"))
    )
    let router = CommandRouter(
        resolveLocator: { app, locator, scrollToVisible in
            #expect(app == "com.example.App")
            #expect(locator.role == "AXButton")
            #expect(locator.title?.matches("NEW") == true)
            #expect(scrollToVisible == true)
            return LocatorResolution(
                status: .unique,
                snapshotID: SnapshotID("live-locator"),
                best: LocatorCandidate(index: 0, handle: SnapshotHandle(snapshotID: SnapshotID("live-locator"), nodeIndex: 0), role: "AXButton", title: "NEW", score: 1_000, reasons: []),
                candidates: []
            )
        },
        actions: PrimitiveActionHandlers(
            click: { target, _ in
                #expect(target == "live-locator:0")
                return PrimitiveActionResult(action: "click", target: target, strategy: "AXPress", success: true)
            }
        ),
        semanticNameRegistry: registry
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("click-locator-1"),
        method: "click",
        params: .object([
            "target": .object([
                "app": .string("com.example.App"),
                "name": .string("new-button")
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["target"] == .string("live-locator:0"))
    #expect(response.result?["action"]?["targetResolution"]?["status"] == .string("unique"))
    #expect(response.result?["action"]?["targetResolution"]?["confidence"] == .string("low"))
    #expect(response.result?["action"]?["targetResolution"]?["best"] == nil)
    #expect(response.result?["action"]?["targetResolution"]?["candidates"] == nil)
}

@Test func clickRequestAcceptsTextLocationTarget() {
    let router = CommandRouter(
        captureSnapshot: { _, screenshot in
            #expect(screenshot == false)
            return actionTextLocationFixtureSnapshot(labels: ["Backlog"])
        },
        actions: PrimitiveActionHandlers(
            clickPoint: { point, _ in
                #expect(point == ActionPoint(x: 140, y: 60))
                return PrimitiveActionResult(
                    action: "click",
                    target: point.targetDescription,
                    strategy: "CGEvent",
                    success: true,
                    details: ["point": point.jsonValue]
                )
            }
        ),
        semanticNameRegistry: registry
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("click-location"),
        method: "click",
        params: .object([
            "target": .object([
                "location": .object([
                    "app": .string("com.example.App"),
                    "text": .string("Backlog")
                ])
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["target"] == .string("point:140,60"))
    #expect(response.result?["action"]?["point"]?["x"] == .double(140))
}

@Test func clickRequestAcceptsScreenshotTextLocationTarget() {
    let router = CommandRouter(
        captureSnapshot: { _, screenshot in
            #expect(screenshot == true)
            return actionTextLocationFixtureSnapshot(labels: [], screenshot: EncodedScreenshot(
                mediaType: "image/png",
                base64Data: "fake",
                width: 800,
                height: 600
            ))
        },
        actions: PrimitiveActionHandlers(
            clickPoint: { point, _ in
                #expect(point == ActionPoint(x: 225, y: 200))
                return PrimitiveActionResult(
                    action: "click",
                    target: point.targetDescription,
                    strategy: "CGEvent",
                    success: true,
                    details: ["point": point.jsonValue]
                )
            }
        ),
        recognizeText: { _ in
            [
                RecognizedTextObservation(
                    text: "Backlog",
                    boundingBox: NormalizedTextBoundingBox(x: 0.25, y: 0.60, width: 0.20, height: 0.10),
                    confidence: 0.95
                )
            ]
        }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("click-screenshot-location"),
        method: "click",
        params: .object([
            "target": .object([
                "location": .object([
                    "app": .string("com.example.App"),
                    "text": .string("Backlog"),
                    "source": .string("screenshot")
                ])
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["locationResolutions"]?[0]?["best"]?["source"] == .string("screenshot"))
}

@Test func clickRequestRejectsAmbiguousTextLocationTarget() {
    let router = CommandRouter(
        captureSnapshot: { _, _ in actionTextLocationFixtureSnapshot(labels: ["Backlog", "Backlog"]) },
        actions: PrimitiveActionHandlers(
            clickPoint: { _, _ in
                Issue.record("ambiguous text location should not dispatch a click")
                return PrimitiveActionResult(action: "click", target: "bad", strategy: "bad", success: false)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("click-location-ambiguous"),
        method: "click",
        params: .object([
            "target": .object([
                "location": .object([
                    "app": .string("com.example.App"),
                    "text": .string("Backlog")
                ])
            ])
        ])
    ))

    #expect(response.error?.code == -32602)
    #expect(response.error?.message.contains("Text location did not resolve uniquely: ambiguous") == true)
    #expect(response.error?.message.contains("2 candidates") == true)
}

@Test func clickRequestRedactsDeterministicSecretsInAmbiguousTextLocationError() {
    let token = "sk-proj-abcdef1234567890SECRET"
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            actionTextLocationFixtureSnapshot(labels: [
                "Generated token \(token)",
                "Backup token \(token)"
            ])
        },
        actions: PrimitiveActionHandlers(
            clickPoint: { _, _ in
                Issue.record("ambiguous text location should not dispatch a click")
                return PrimitiveActionResult(action: "click", target: "bad", strategy: "bad", success: false)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("click-location-secret-ambiguous"),
        method: "click",
        params: .object([
            "target": .object([
                "location": .object([
                    "app": .string("com.example.App"),
                    "text": .object(["contains": .string(token)])
                ])
            ])
        ])
    ))

    #expect(response.error?.code == -32602)
    #expect(response.error?.message.contains(token) == false)
    #expect(response.error?.message.contains("<redacted: auth-credential>") == true)
}

@Test func dragRequestRedactsActiveCredentialsInAmbiguousTextLocationError() throws {
    let secret = "correct horse battery staple"
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            actionTextLocationFixtureSnapshot(labels: [
                secret,
                secret,
                "Drop target"
            ])
        },
        actions: PrimitiveActionHandlers(
            drag: { _, _, _, _, _ in
                Issue.record("ambiguous text location should not dispatch a drag")
                return PrimitiveActionResult(action: "drag", target: "bad", strategy: "bad", success: false)
            }
        ),
        activeCredentialFilter: try actionRouterActiveCredentialFilter(values: [secret])
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("drag-location-secret-ambiguous"),
        method: "drag",
        params: .object([
            "from": .object([
                "location": .object([
                    "app": .string("com.example.App"),
                    "text": .string(secret)
                ])
            ]),
            "to": .object([
                "location": .object([
                    "app": .string("com.example.App"),
                    "text": .string("Drop target")
                ])
            ])
        ])
    ))

    #expect(response.error?.code == -32602)
    #expect(response.error?.message.contains(secret) == false)
    #expect(response.error?.message.contains("<redacted: active-credential>") == true)
}

@Test func clickRequestRejectsAmbiguousSemanticNameTarget() {
    let registry = SemanticNameRegistry()
    registry.registerReplayEvidence(
        app: "com.example.App",
        name: "new-button",
        locator: AXLocator(role: "AXButton", title: .exact("NEW"))
    )
    let router = CommandRouter(
        resolveLocator: { _, _, scrollToVisible in
            #expect(scrollToVisible == true)
            return LocatorResolution(
                status: .ambiguous,
                snapshotID: SnapshotID("live-locator"),
                best: nil,
                candidates: []
            )
        },
        actions: PrimitiveActionHandlers(
            click: { _, _ in
                Issue.record("ambiguous locator should not dispatch a click")
                return PrimitiveActionResult(action: "click", target: "bad", strategy: "bad", success: false)
            }
        ),
        semanticNameRegistry: registry
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("click-locator-ambiguous"),
        method: "click",
        params: .object([
            "target": .object([
                "app": .string("com.example.App"),
                "name": .string("new-button")
            ])
        ])
    ))

    #expect(response.error?.code == -32602)
    #expect(response.error?.message == "Locator did not resolve uniquely: ambiguous")
}

@Test func clickRequestReportsStaleSnapshotHandleAsInvalidParams() {
    let router = CommandRouter(elementStore: AXElementStore())

    let response = router.handle(JSONRPCRequest(
        id: .string("click-stale"),
        method: "click",
        params: .object(["target": .string("missing:0")])
    ))

    #expect(response.error?.code == -32602)
    #expect(response.error?.message == "Snapshot is not retained: missing")
}

@Test func invokeRequestPassesActionName() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            invoke: { target, action, _ in
                #expect(target == "snap:2")
                #expect(action == "AXShowMenu")
                return PrimitiveActionResult(action: action, target: target, strategy: "AXAction", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("action-1"),
        method: "invoke",
        params: .object([
            "target": .string("snap:2"),
            "name": .string("AXShowMenu")
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["action"] == .string("AXShowMenu"))
}

@Test func typeRequestPassesValue() {
    let registry = SemanticNameRegistry()
    registry.registerReplayEvidence(
        app: "Example",
        name: "text-field",
        locator: AXLocator(role: "AXTextField")
    )
    let router = CommandRouter(
        resolveLocator: { _, _, _ in
            LocatorResolution(
                status: .unique,
                snapshotID: SnapshotID("snap"),
                best: LocatorCandidate(
                    index: 3,
                    handle: SnapshotHandle(snapshotID: SnapshotID("snap"), nodeIndex: 3),
                    role: "AXTextField",
                    title: nil,
                    score: 1_000,
                    reasons: []
                ),
                candidates: []
            )
        },
        actions: PrimitiveActionHandlers(
            type: { target, value, _ in
                #expect(target == "snap:3")
                #expect(value == "hello")
                return PrimitiveActionResult(action: "type", target: target, strategy: "AXValue", success: true)
            }
        ),
        semanticNameRegistry: registry
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("set-1"),
        method: "type",
        params: .object([
            "target": .object([
                "app": .string("Example"),
                "name": .string("text-field")
            ]),
            "value": .string("hello")
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["success"] == .bool(true))
}

@Test func keyboardTextRequestPassesAppAndText() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            keyboard: { app, intent, _ in
                #expect(app == "com.example.App")
                #expect(intent == .text("hello"))
                return PrimitiveActionResult(action: "keyboard", target: app ?? "frontmost", strategy: "CGEventKeyboard", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("type-1"),
        method: "keyboard",
        params: .object([
            "app": .string("com.example.App"),
            "text": .string("hello")
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["strategy"] == .string("CGEventKeyboard"))
}

@Test func keyboardKeyRequestPassesAppAndKey() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            keyboard: { app, intent, _ in
                #expect(app == "com.example.App")
                #expect(intent == .key("End"))
                return PrimitiveActionResult(action: "keyboard", target: app ?? "frontmost", strategy: "CGEventKeyboard", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("key-1"),
        method: "keyboard",
        params: .object([
            "app": .string("com.example.App"),
            "key": .string("End")
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["target"] == .string("com.example.App"))
}

@Test func scrollRequestPassesPointTargetAndDeltas() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            scroll: { target, app, deltaX, deltaY, _ in
                #expect(target == .point(ActionPoint(x: 10, y: 20)))
                #expect(app == "com.example.App")
                #expect(deltaX == 0)
                #expect(deltaY == -480)
                return PrimitiveActionResult(action: "scroll", target: "point:10,20", strategy: "AXScrollToVisible", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("scroll-point"),
        method: "scroll",
        params: .object([
            "app": .string("com.example.App"),
            "target": .object(["point": .object(["x": .int(10), "y": .int(20)])]),
            "deltaY": .int(-480)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["action"] == .string("scroll"))
}

@Test func scrollRequestResolvesLocatorTarget() {
    let router = CommandRouter(
        resolveLocator: { app, locator, scrollToVisible in
            #expect(app == "com.example.App")
            #expect(locator.role == "AXButton")
            #expect(locator.title?.matches("List") == true)
            #expect(scrollToVisible == true)
            return LocatorResolution(
                status: .unique,
                snapshotID: SnapshotID("live-locator"),
                best: LocatorCandidate(
                    index: 2,
                    handle: SnapshotHandle(snapshotID: SnapshotID("live-locator"), nodeIndex: 2),
                    role: "AXButton",
                    title: "List",
                    score: 2,
                    reasons: []
                ),
                candidates: []
            )
        },
        actions: PrimitiveActionHandlers(
            scroll: { target, _, _, _, _ in
                #expect(target == .handle("live-locator:2"))
                return PrimitiveActionResult(action: "scroll", target: "live-locator:2", strategy: "AXScrollToVisible", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("scroll-locator"),
        method: "scroll",
        params: .object([
            "target": .object([
                "app": .string("com.example.App"),
                "locator": .object([
                    "role": .string("AXButton"),
                    "title": .string("List")
                ])
            ]),
            "deltaY": .int(-120)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["targetResolution"]?["status"] == .string("unique"))
}

@Test func scrollRequestAcceptsTextLocationTarget() {
    let router = CommandRouter(
        captureSnapshot: { _, _ in actionTextLocationFixtureSnapshot(labels: ["Backlog"]) },
        actions: PrimitiveActionHandlers(
            scroll: { target, _, _, _, _ in
                #expect(target == .point(ActionPoint(x: 140, y: 60)))
                return PrimitiveActionResult(action: "scroll", target: "point:140,60", strategy: "AXScrollToVisible", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("scroll-location"),
        method: "scroll",
        params: .object([
            "target": .object([
                "location": .object([
                    "app": .string("com.example.App"),
                    "text": .string("Backlog")
                ])
            ]),
            "deltaY": .int(-120)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["locationResolutions"]?[0]?["best"]?["matchedText"] == .string("Backlog"))
}

@Test func dragRequestPassesPointEndpoints() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            drag: { from, to, app, durationMs, _ in
                #expect(from == .point(ActionPoint(x: 10, y: 20)))
                #expect(to == .point(ActionPoint(x: 90, y: 120)))
                #expect(app == "com.example.App")
                #expect(durationMs == 250)
                return PrimitiveActionResult(action: "drag", target: "point:10,20->point:90,120", strategy: "CGEventDrag", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("drag-points"),
        method: "drag",
        params: .object([
            "app": .string("com.example.App"),
            "from": .object(["point": .object(["x": .int(10), "y": .int(20)])]),
            "to": .object(["point": .object(["x": .int(90), "y": .int(120)])]),
            "durationMs": .int(250)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["action"] == .string("drag"))
}

@Test func dragRequestAcceptsTextLocationEndpoints() {
    let router = CommandRouter(
        captureSnapshot: { _, _ in actionTextLocationFixtureSnapshot(labels: ["Backlog", "Done"]) },
        actions: PrimitiveActionHandlers(
            drag: { from, to, _, _, _ in
                #expect(from == .point(ActionPoint(x: 140, y: 60)))
                #expect(to == .point(ActionPoint(x: 240, y: 60)))
                return PrimitiveActionResult(action: "drag", target: "point:140,60->point:240,60", strategy: "CGEventDrag", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("drag-locations"),
        method: "drag",
        params: .object([
            "from": .object([
                "location": .object([
                    "app": .string("com.example.App"),
                    "text": .string("Backlog")
                ])
            ]),
            "to": .object([
                "location": .object([
                    "app": .string("com.example.App"),
                    "text": .string("Done")
                ])
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["locationResolutions"]?[0]?["best"]?["matchedText"] == .string("Backlog"))
    #expect(response.result?["action"]?["locationResolutions"]?[1]?["best"]?["matchedText"] == .string("Done"))
}

@Test func dragRequestConvertsWindowRelativePointsThroughCapturedWindowFrame() {
    let router = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == false)
            return actionTextLocationFixtureSnapshot(labels: [])
        },
        actions: PrimitiveActionHandlers(
            drag: { from, to, _, _, _ in
                #expect(from == .point(ActionPoint(x: 60, y: 80, coordinateSpace: .screen, app: "com.example.App")))
                #expect(to == .point(ActionPoint(x: 150, y: 260, coordinateSpace: .screen, app: "com.example.App")))
                return PrimitiveActionResult(action: "drag", target: "converted", strategy: "CGEventDrag", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("drag-window-points"),
        method: "drag",
        params: .object([
            "app": .string("com.example.App"),
            "from": .object(["point": .object([
                "x": .int(10),
                "y": .int(20),
                "coordinateSpace": .string("window")
            ])]),
            "to": .object(["point": .object([
                "x": .int(100),
                "y": .int(200),
                "coordinateSpace": .string("window")
            ])])
        ])
    ))

    #expect(response.error == nil)
}

@Test func dragRequestConvertsScreenshotPixelsThroughCapturedWindowFrame() {
    let router = CommandRouter(
        captureSnapshot: { _, screenshot in
            #expect(screenshot == true)
            return actionTextLocationFixtureSnapshot(
                labels: [],
                screenshot: EncodedScreenshot(mediaType: "image/png", base64Data: "", width: 1_000, height: 800)
            )
        },
        actions: PrimitiveActionHandlers(
            drag: { from, to, _, _, _ in
                #expect(from == .point(ActionPoint(x: 100, y: 85, coordinateSpace: .screen, app: "com.example.App")))
                #expect(to == .point(ActionPoint(x: 550, y: 460, coordinateSpace: .screen, app: "com.example.App")))
                return PrimitiveActionResult(action: "drag", target: "converted", strategy: "CGEventDrag", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("drag-screenshot-points"),
        method: "drag",
        params: .object([
            "from": .object(["point": .object([
                "app": .string("com.example.App"),
                "x": .int(100),
                "y": .int(50),
                "coordinateSpace": .string("screenshot")
            ])]),
            "to": .object(["point": .object([
                "app": .string("com.example.App"),
                "x": .int(1_000),
                "y": .int(800),
                "coordinateSpace": .string("screenshot")
            ])])
        ])
    ))

    #expect(response.error == nil)
}

@Test func dragRequestRejectsRelativePointWithoutApp() {
    let router = CommandRouter(actions: PrimitiveActionHandlers(
        drag: { _, _, _, _, _ in
            Issue.record("relative point without app should fail before dispatch")
            return PrimitiveActionResult(action: "drag", target: "bad", strategy: "bad", success: true)
        }
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("drag-relative-no-app"),
        method: "drag",
        params: .object([
            "from": .object(["point": .object([
                "x": .int(10),
                "y": .int(20),
                "coordinateSpace": .string("window")
            ])]),
            "to": .object(["point": .object(["x": .int(30), "y": .int(40)])])
        ])
    ))

    #expect(response.error?.code == -32602)
    #expect(response.error?.message == "from point coordinateSpace window requires app")
}

private func waitUniqueResolution() -> LocatorResolution {
    LocatorResolution(
        status: .unique,
        snapshotID: SnapshotID("wait"),
        best: LocatorCandidate(
            index: 0,
            handle: SnapshotHandle(snapshotID: SnapshotID("wait"), nodeIndex: 0),
            role: "AXButton",
            title: nil,
            score: 1,
            reasons: []
        ),
        candidates: []
    )
}

private func actionLocatorFixtureSnapshot(buttons: [String]) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("action-locator-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(
                role: "AXWindow",
                title: "Main",
                children: [
                    AXNode(
                        role: "AXGroup",
                        title: "Toolbar",
                        children: buttons.map { title in
                            AXNode(role: "AXButton", title: title, actions: ["AXPress"])
                        }
                    )
                ]
            )
        ],
        screenshot: nil
    )
}

private func actionTextLocationFixtureSnapshot(
    labels: [String],
    screenshot: EncodedScreenshot? = nil
) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("action-text-location-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(
                role: "AXWindow",
                title: "Main",
                frame: AXFrame(x: 50, y: 60, width: 500, height: 400),
                children: labels.enumerated().map { index, label in
                    AXNode(
                        role: "AXStaticText",
                        title: label,
                        frame: AXFrame(x: Double(100 + index * 100), y: 50, width: 80, height: 20)
                    )
                }
            )
        ],
        screenshot: screenshot
    )
}

private func actionRouterActiveCredentialFilter(values: [String]) throws -> ActiveCredentialIndex {
    try ActiveCredentialIndex(
        secrets: values.map {
            ActiveCredentialSecret(value: $0, provider: "test", reference: "op://Router/Active/secret")
        },
        hmacKey: Data(repeating: 0x44, count: 32),
        provider: "test",
        createdAt: Date(timeIntervalSince1970: 1_775_000_000)
    )
}
