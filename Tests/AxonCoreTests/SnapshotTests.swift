@testable import AxonClient
import Testing
@testable import AxonCore

@Test func replacingSnapshotNodePreservesSharedSemanticFields() {
    let node = AXNode(role: "Edit", label: "Recipient", editable: true)
    let replacement = node.replacing(
        actions: ["SetValue"],
        children: [AXNode(role: "Text", title: "child")]
    )

    #expect(replacement.label == "Recipient")
    #expect(replacement.editable == true)
    #expect(replacement.actions == ["SetValue"])
    #expect(replacement.children.map(\.title) == ["child"])
}

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
