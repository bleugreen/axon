import Foundation
import Testing
@testable import AxonCore

@Test func healthRequestReturnsDaemonStatus() {
    let request = JSONRPCRequest(id: .string("health-1"), method: "health")

    let response = CommandRouter().handle(request)

    #expect(response.id == .string("health-1"))
    #expect(response.error == nil)
    #expect(response.result?["status"] == .string("ok"))
    #expect(response.result?["accessibility"] != nil)
}

@Test func permitReturnsPromptStatus() {
    let response = CommandRouter(requestAccessibility: { true }).handle(JSONRPCRequest(
        id: .string("accessibility"),
        method: "permit"
    ))

    #expect(response.id == .string("accessibility"))
    #expect(response.error == nil)
    #expect(response.result?["accessibility"] == .string("trusted"))
    #expect(response.result?["prompted"] == .bool(true))
}

@Test func unknownMethodReturnsMethodNotFoundError() {
    let request = JSONRPCRequest(id: .int(42), method: "missing_method")

    let response = CommandRouter().handle(request)

    #expect(response.id == .int(42))
    #expect(response.result == nil)
    #expect(response.error?.code == -32601)
}

@Test func requestRoundTripsThroughJSON() throws {
    let request = JSONRPCRequest(id: .string("abc"), method: "health")

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: data)

    #expect(decoded.jsonrpc == "2.0")
    #expect(decoded.id == .string("abc"))
    #expect(decoded.method == "health")
}

@Test func lookAppsRequestReturnsRunningApps() {
    let router = CommandRouter(
        listApps: {
            [AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7)]
        },
        captureSnapshot: { _, _ in
            Issue.record("snapshot capture should not be called")
            return emptySnapshot
        }
    )

    let response = router.handle(JSONRPCRequest(id: .string("apps"), method: "look"))

    #expect(response.result?["apps"]?[0]?["name"] == .string("Example"))
}

@Test func lookRequestReturnsCapturedSnapshot() {
    let router = CommandRouter(
        listApps: { [] },
        captureSnapshot: { app, screenshot in
            #expect(app == "Finder")
            #expect(screenshot)
            return AppSnapshot(
                id: SnapshotID("snap-router"),
                app: AppIdentity(bundleIdentifier: "com.apple.finder", name: "Finder", processIdentifier: 10),
                windows: [AXNode(role: "AXWindow", title: "Desktop")],
                screenshot: nil
            )
        }
    )

    let request = JSONRPCRequest(
        id: .string("snapshot"),
        method: "look",
        params: .object(["app": .string("Finder"), "screenshot": .bool(true)])
    )

    let response = router.handle(request)

    #expect(response.result?["snapshot"]?["id"] == .string("snap-router"))
    #expect(response.error == nil)
}

@Test func lookRequestDefaultsToNoScreenshot() {
    let router = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == false)
            return AppSnapshot(
                id: SnapshotID("snap-no-image"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [AXNode(role: "AXWindow", title: "Main")],
                screenshot: nil
            )
        }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("snapshot-default"),
        method: "look",
        params: .object(["app": .string("com.example.App")])
    ))

    #expect(response.error == nil)
    #expect(response.result?["snapshot"]?["screenshot"] == .null)
}

@Test func lookRequestTreatsRemovedSensitiveParameterAsInert() {
    let router = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot)
            return AppSnapshot(
                id: SnapshotID("snap-removed-sensitive"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [AXNode(role: "AXWindow", title: "Main")],
                screenshot: EncodedScreenshot(mediaType: "image/png", base64Data: "raw-image", width: 300, height: 200)
            )
        }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("removed-sensitive"),
        method: "look",
        params: .object([
            "app": .string("com.example.App"),
            "sensitive": .bool(true),
            "screenshot": .bool(true)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["snapshot"]?["screenshot"]?["base64Data"] == .string("raw-image"))
}

@Test func lookRequestReturnsDeterministicallyRedactedSnapshotWithoutOptIn() {
    let token = "sk-proj-abcdef1234567890SECRET"
    let router = CommandRouter(
        captureSnapshot: { _, screenshot in
            #expect(screenshot == false)
            return AppSnapshot(
                id: SnapshotID("snap-sensitive-router"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [
                    AXNode(role: "AXWindow", title: "Main", children: [
                        AXNode(role: "AXTextField", value: token)
                    ])
                ],
                screenshot: nil
            )
        }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("deterministic-redaction"),
        method: "look",
        params: .object([
            "app": .string("com.example.App"),
            "tree": .bool(false)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["snapshot"]?["redaction"] == nil)
    #expect(response.result?["snapshot"]?["indexedNodes"]?[1]?["value"] == .string("<redacted: auth-credential>"))
    #expect(response.result?["snapshot"]?["indexedNodes"]?[1]?["redaction"]?["matched"]?["value"]?[0]?["rule"] == .string("openai-api-key"))
}

@Test func lookSinceReportsCoarseWindowChanges() {
    let elementStore = AXElementStore()
    var snapshots = [
        AppSnapshot(
            id: SnapshotID("initial"),
            app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
            windows: [AXNode(role: "AXWindow", title: "Main")],
            screenshot: nil
        ),
        AppSnapshot(
            id: SnapshotID("current"),
            app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
            windows: [AXNode(role: "AXWindow", title: "Settings")],
            screenshot: nil
        )
    ]
    let router = CommandRouter(
        captureSnapshot: { _, _ in snapshots.removeFirst() },
        elementStore: elementStore
    )

    let snapshotResponse = router.handle(JSONRPCRequest(
        id: .string("snapshot"),
        method: "look",
        params: .object(["app": .string("com.example.App"), "screenshot": .bool(false)])
    ))
    let changedResponse = router.handle(JSONRPCRequest(
        id: .string("changed"),
        method: "look",
        params: .object(["since": .string("initial")])
    ))

    #expect(snapshotResponse.error == nil)
    #expect(changedResponse.error == nil)
    #expect(changedResponse.result?["changed"] == .bool(true))
    #expect(changedResponse.result?["reason"] == .string("window_signature_changed"))
    #expect(changedResponse.result?["currentSnapshotId"] == .string("current"))
}

@Test func lookSinceReportsMissingAppAsChanged() {
    let elementStore = AXElementStore()
    let snapshot = AppSnapshot(
        id: SnapshotID("initial"),
        app: AppIdentity(bundleIdentifier: "com.example.Missing", name: "Missing", processIdentifier: 9),
        windows: [AXNode(role: "AXWindow", title: "Main")],
        screenshot: nil
    )
    elementStore.store(summary: SnapshotSummary(snapshot: snapshot))
    let router = CommandRouter(
        captureSnapshot: { app, _ in throw AppResolverError.notFound(app) },
        elementStore: elementStore
    )

    let changedResponse = router.handle(JSONRPCRequest(
        id: .string("changed"),
        method: "look",
        params: .object(["since": .string("initial")])
    ))

    #expect(changedResponse.error == nil)
    #expect(changedResponse.result?["changed"] == .bool(true))
    #expect(changedResponse.result?["reason"] == .string("app_missing"))
    #expect(changedResponse.result?["current"] == .null)
}

@Test func lookSinceTreatsObservedEventsAsRecaptureHints() {
    let elementStore = AXElementStore()
    let tracker = AppChangeTracker()
    let app = AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7)
    var captureCount = 0
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            captureCount += 1
            return AppSnapshot(
                id: SnapshotID("initial"),
                app: app,
                windows: [AXNode(role: "AXWindow", title: "Main")],
                screenshot: nil
            )
        },
        elementStore: elementStore,
        changeObserver: tracker
    )

    let snapshotResponse = router.handle(JSONRPCRequest(
        id: .string("snapshot"),
        method: "look",
        params: .object(["app": .string("com.example.App"), "screenshot": .bool(false)])
    ))
    tracker.recordChange(app: app, reason: "AXFocusedWindowChanged")
    let changedResponse = router.handle(JSONRPCRequest(
        id: .string("changed"),
        method: "look",
        params: .object(["since": .string("initial")])
    ))

    #expect(snapshotResponse.error == nil)
    #expect(captureCount == 2)
    #expect(changedResponse.error == nil)
    #expect(changedResponse.result?["changed"] == .bool(false))
    #expect(changedResponse.result?["reason"] == .string("unchanged"))
    #expect(changedResponse.result?["current"] != .null)
    #expect(changedResponse.result?["observedChanges"]?[0]?["reason"] == .string("AXFocusedWindowChanged"))
}

@Test func lookSinceReportsSurfaceChangesAfterObservedEvents() {
    let elementStore = AXElementStore()
    let tracker = AppChangeTracker()
    let app = AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7)
    var snapshots = [
        AppSnapshot(
            id: SnapshotID("initial"),
            app: app,
            windows: [AXNode(role: "AXWindow", title: "Main")],
            screenshot: nil
        ),
        AppSnapshot(
            id: SnapshotID("current"),
            app: app,
            windows: [AXNode(role: "AXWindow", title: "Settings")],
            screenshot: nil
        )
    ]
    let router = CommandRouter(
        captureSnapshot: { _, _ in snapshots.removeFirst() },
        elementStore: elementStore,
        changeObserver: tracker
    )

    let snapshotResponse = router.handle(JSONRPCRequest(
        id: .string("snapshot"),
        method: "look",
        params: .object(["app": .string("com.example.App"), "screenshot": .bool(false)])
    ))
    tracker.recordChange(app: app, reason: "AXWindowCreated")
    let changedResponse = router.handle(JSONRPCRequest(
        id: .string("changed"),
        method: "look",
        params: .object(["since": .string("initial")])
    ))

    #expect(snapshotResponse.error == nil)
    #expect(changedResponse.error == nil)
    #expect(changedResponse.result?["changed"] == .bool(true))
    #expect(changedResponse.result?["reason"] == .string("window_signature_changed"))
    #expect(changedResponse.result?["currentSnapshotId"] == .string("current"))
    #expect(changedResponse.result?["observedChanges"]?[0]?["reason"] == .string("AXWindowCreated"))
}

private let emptySnapshot = AppSnapshot(
    id: SnapshotID("empty"),
    app: AppIdentity(bundleIdentifier: nil, name: "Empty", processIdentifier: 0),
    windows: [],
    screenshot: nil
)
