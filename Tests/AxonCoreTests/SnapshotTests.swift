import Testing
import ApplicationServices
@testable import AxonCore

@Test func snapshotIndexesTreeDepthFirstAndCreatesHandles() {
    let root = AXNode(
        role: "AXWindow",
        title: "Main",
        children: [
            AXNode(role: "AXButton", title: "One"),
            AXNode(
                role: "AXGroup",
                title: "Group",
                children: [
                    AXNode(role: "AXStaticText", title: "Nested")
                ]
            )
        ]
    )

    let snapshot = AppSnapshot(
        id: SnapshotID("snap-test"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 123),
        windows: [root],
        screenshot: nil
    )

    #expect(snapshot.indexedNodes.map(\.node.role) == ["AXWindow", "AXButton", "AXGroup", "AXStaticText"])
    #expect(snapshot.handle(for: 3)?.rawValue == "snap-test:3")
}

@Test func nodeCanReportTruncationReason() {
    let node = AXNode(role: "AXGroup", truncationReason: "children limited to 25")

    #expect(node.truncationReason == "children limited to 25")
    #expect(node.jsonValue["truncationReason"] == .string("children limited to 25"))
}

@Test func defaultCaptureDepthReachesTypicalBrowserContent() {
    #expect(AXSnapshotCapturer.defaultMaxDepth >= 14)
}

@Test func snapshotHandleParsesSnapshotIdAndNodeIndex() throws {
    let handle = try SnapshotHandle("snap-test:42")

    #expect(handle.snapshotID == SnapshotID("snap-test"))
    #expect(handle.nodeIndex == 42)
}

@Test func snapshotHandleRejectsMalformedAndLegacyValues() {
    #expect(throws: SnapshotHandle.ParseError.self) {
        try SnapshotHandle("42")
    }
    #expect(throws: SnapshotHandle.ParseError.self) {
        try SnapshotHandle("snapshot:snap-test:42")
    }
}

@Test func elementStoreEvictsOldestSnapshotsWhenCapacityIsExceeded() throws {
    let store = AXElementStore(maxSnapshots: 2)
    let element = AXUIElementCreateSystemWide()

    store.store(snapshotID: SnapshotID("one"), elements: [element])
    store.store(snapshotID: SnapshotID("two"), elements: [element])
    store.store(snapshotID: SnapshotID("three"), elements: [element])

    #expect(throws: AXElementStoreError.self) {
        try store.element(for: SnapshotHandle(snapshotID: SnapshotID("one"), nodeIndex: 0))
    }
    _ = try store.element(for: SnapshotHandle(snapshotID: SnapshotID("two"), nodeIndex: 0))
    _ = try store.element(for: SnapshotHandle(snapshotID: SnapshotID("three"), nodeIndex: 0))
}

@Test func elementStoreRefreshesSnapshotRetentionOrder() throws {
    let store = AXElementStore(maxSnapshots: 2)
    let element = AXUIElementCreateSystemWide()

    store.store(snapshotID: SnapshotID("one"), elements: [element])
    store.store(snapshotID: SnapshotID("two"), elements: [element])
    store.store(snapshotID: SnapshotID("one"), elements: [element])
    store.store(snapshotID: SnapshotID("three"), elements: [element])

    _ = try store.element(for: SnapshotHandle(snapshotID: SnapshotID("one"), nodeIndex: 0))
    #expect(throws: AXElementStoreError.self) {
        try store.element(for: SnapshotHandle(snapshotID: SnapshotID("two"), nodeIndex: 0))
    }
    _ = try store.element(for: SnapshotHandle(snapshotID: SnapshotID("three"), nodeIndex: 0))
}

@Test func snapshotSummaryReportsUnchangedMatchingWindowSignatures() {
    let before = AppSnapshot(
        id: SnapshotID("before"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 1),
        windows: [
            AXNode(role: "AXWindow", title: "Main", frame: AXFrame(x: 10.2, y: 20.7, width: 300.1, height: 200.9))
        ],
        screenshot: nil
    )
    let current = AppSnapshot(
        id: SnapshotID("current"),
        app: before.app,
        windows: [
            AXNode(role: "AXWindow", title: "Main", frame: AXFrame(x: 10.4, y: 20.2, width: 300.4, height: 200.5))
        ],
        screenshot: nil
    )

    let change = SnapshotSummary(snapshot: before).change(comparedTo: SnapshotSummary(snapshot: current))

    #expect(change.changed == false)
    #expect(change.reason == "unchanged")
}

@Test func snapshotSummaryReportsChangedWindowSignatures() {
    let before = AppSnapshot(
        id: SnapshotID("before"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 1),
        windows: [
            AXNode(role: "AXWindow", title: "Main")
        ],
        screenshot: nil
    )
    let current = AppSnapshot(
        id: SnapshotID("current"),
        app: before.app,
        windows: [
            AXNode(role: "AXWindow", title: "Settings")
        ],
        screenshot: nil
    )

    let change = SnapshotSummary(snapshot: before).change(comparedTo: SnapshotSummary(snapshot: current))

    #expect(change.changed)
    #expect(change.reason == "window_signature_changed")
}

@Test func appChangeTrackerReportsChangesAfterToken() {
    let tracker = AppChangeTracker()
    let app = AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 10)
    let token = tracker.token(for: app)

    tracker.recordChange(app: app, reason: "AXFocusedWindowChanged")

    #expect(tracker.changes(since: token, app: app) == [
        ObservedAppChange(sequence: token + 1, reason: "AXFocusedWindowChanged")
    ])
}

@Test func screenCaptureRuntimeDoesNotBlockFromBackgroundThread() {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        ScreenCaptureRuntime.bootstrapSynchronously()
        done.signal()
    }

    #expect(done.wait(timeout: .now() + 2.0) == .success)
}

@Test func screenshotTargetPixelSizeDownscalesLongEdge() {
    let size = ScreenshotCapturer.targetPixelSize(width: 3262, height: 2018, maxDimension: 1600)

    #expect(size.width == 1600)
    #expect(size.height == 990)
}

@Test func screenshotTargetPixelSizeDoesNotUpscaleSmallImages() {
    let size = ScreenshotCapturer.targetPixelSize(width: 800, height: 600, maxDimension: 1600)

    #expect(size.width == 800)
    #expect(size.height == 600)
}
