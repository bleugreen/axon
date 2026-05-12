import Testing
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
    #expect(snapshot.handle(for: 3)?.rawValue == "snapshot:snap-test:3")
}

@Test func nodeCanReportTruncationReason() {
    let node = AXNode(role: "AXGroup", truncationReason: "children limited to 25")

    #expect(node.truncationReason == "children limited to 25")
    #expect(node.jsonValue["truncationReason"] == .string("children limited to 25"))
}

@Test func defaultCaptureDepthReachesTypicalWebViewContent() {
    #expect(AXSnapshotCapturer.defaultMaxDepth >= 8)
}

@Test func snapshotHandleParsesSnapshotIdAndNodeIndex() throws {
    let handle = try SnapshotHandle("snapshot:snap-test:42")

    #expect(handle.snapshotID == SnapshotID("snap-test"))
    #expect(handle.nodeIndex == 42)
}

@Test func snapshotHandleRejectsMalformedValues() {
    #expect(throws: SnapshotHandle.ParseError.self) {
        try SnapshotHandle("snap-test:42")
    }
}
