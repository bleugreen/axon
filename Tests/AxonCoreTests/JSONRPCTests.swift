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
        captureSnapshot: { app, includeScreenshot in
            #expect(app == "Finder")
            #expect(includeScreenshot)
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
        params: .object(["app": .string("Finder"), "includeScreenshot": .bool(true)])
    )

    let response = router.handle(request)

    #expect(response.result?["snapshot"]?["id"] == .string("snap-router"))
    #expect(response.error == nil)
}

private let emptySnapshot = AppSnapshot(
    id: SnapshotID("empty"),
    app: AppIdentity(bundleIdentifier: nil, name: "Empty", processIdentifier: 0),
    windows: [],
    screenshot: nil
)
