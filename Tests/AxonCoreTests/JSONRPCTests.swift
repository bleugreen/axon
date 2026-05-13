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

@Test func requestAccessibilityReturnsPromptStatus() {
    let response = CommandRouter(requestAccessibility: { true }).handle(JSONRPCRequest(
        id: .string("accessibility"),
        method: "request_accessibility"
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

@Test func listAppsRequestReturnsRunningApps() {
    let router = CommandRouter(
        listApps: {
            [AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7)]
        },
        captureSnapshot: { _, _ in
            Issue.record("snapshot capture should not be called")
            return emptySnapshot
        }
    )

    let response = router.handle(JSONRPCRequest(id: .string("apps"), method: "list_apps"))

    #expect(response.result?["apps"]?[0]?["name"] == .string("Example"))
}

@Test func snapshotRequestReturnsCapturedSnapshot() {
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
        method: "snapshot",
        params: .object(["app": .string("Finder"), "screenshot": .bool(true)])
    )

    let response = router.handle(request)

    #expect(response.result?["snapshot"]?["id"] == .string("snap-router"))
    #expect(response.error == nil)
}

@Test func snapshotRequestDefaultsToNoScreenshot() {
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
        method: "snapshot",
        params: .object(["app": .string("com.example.App")])
    ))

    #expect(response.error == nil)
    #expect(response.result?["snapshot"]?["screenshot"] == .null)
}

@Test func changedSinceReportsCoarseWindowChanges() {
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
        method: "snapshot",
        params: .object(["app": .string("com.example.App"), "screenshot": .bool(false)])
    ))
    let changedResponse = router.handle(JSONRPCRequest(
        id: .string("changed"),
        method: "changed_since",
        params: .object(["snapshotId": .string("initial")])
    ))

    #expect(snapshotResponse.error == nil)
    #expect(changedResponse.error == nil)
    #expect(changedResponse.result?["changed"] == .bool(true))
    #expect(changedResponse.result?["reason"] == .string("window_signature_changed"))
    #expect(changedResponse.result?["currentSnapshotId"] == .string("current"))
}

@Test func changedSinceReportsMissingAppAsChanged() {
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
        method: "changed_since",
        params: .object(["snapshotId": .string("initial")])
    ))

    #expect(changedResponse.error == nil)
    #expect(changedResponse.result?["changed"] == .bool(true))
    #expect(changedResponse.result?["reason"] == .string("app_missing"))
    #expect(changedResponse.result?["current"] == .null)
}

@Test func changedSinceTreatsObservedEventsAsRecaptureHints() {
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
        method: "snapshot",
        params: .object(["app": .string("com.example.App"), "screenshot": .bool(false)])
    ))
    tracker.recordChange(app: app, reason: "AXFocusedWindowChanged")
    let changedResponse = router.handle(JSONRPCRequest(
        id: .string("changed"),
        method: "changed_since",
        params: .object(["snapshotId": .string("initial")])
    ))

    #expect(snapshotResponse.error == nil)
    #expect(captureCount == 2)
    #expect(changedResponse.error == nil)
    #expect(changedResponse.result?["changed"] == .bool(false))
    #expect(changedResponse.result?["reason"] == .string("unchanged"))
    #expect(changedResponse.result?["current"] != .null)
    #expect(changedResponse.result?["observedChanges"]?[0]?["reason"] == .string("AXFocusedWindowChanged"))
}

@Test func changedSinceReportsSurfaceChangesAfterObservedEvents() {
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
        method: "snapshot",
        params: .object(["app": .string("com.example.App"), "screenshot": .bool(false)])
    ))
    tracker.recordChange(app: app, reason: "AXWindowCreated")
    let changedResponse = router.handle(JSONRPCRequest(
        id: .string("changed"),
        method: "changed_since",
        params: .object(["snapshotId": .string("initial")])
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
