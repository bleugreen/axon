import Foundation
import Testing
@testable import AxonCore

@Test func snapshotConvertsToJSONValueObject() {
    let snapshot = AppSnapshot(
        id: SnapshotID("snap-json"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(
                role: "AXWindow",
                title: "Main",
                frame: AXFrame(x: 1, y: 2, width: 300, height: 200),
                actions: ["AXRaise"]
            )
        ],
        screenshot: EncodedScreenshot(mediaType: "image/png", base64Data: "abc", width: 300, height: 200)
    )

    let json = snapshot.jsonValue

    #expect(json["id"] == .string("snap-json"))
    #expect(json["app"]?["bundleIdentifier"] == .string("com.example.App"))
    #expect(json["windows"]?[0]?["role"] == .string("AXWindow"))
    #expect(json["windows"]?[0]?["frame"]?["width"] == .double(300))
    #expect(json["screenshot"]?["mediaType"] == .string("image/png"))
}

@Test func compactSnapshotJSONOmitsNestedWindowsButKeepsIndexedHandles() {
    let snapshot = AppSnapshot(
        id: SnapshotID("snap-compact"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(
                role: "AXWindow",
                title: "Main",
                children: [
                    AXNode(
                        role: "AXButton",
                        title: "Run",
                        value: "ready",
                        description: "Run task",
                        frame: AXFrame(x: 10, y: 20, width: 30, height: 40),
                        actions: ["AXPress"]
                    )
                ]
            )
        ],
        screenshot: nil
    )

    let json = snapshot.jsonValue(includeTree: false)

    #expect(json["windows"] == nil)
    #expect(json["indexedNodes"]?[1]?["handle"] == .string("snapshot:snap-compact:1"))
    #expect(json["indexedNodes"]?[1]?["title"] == .string("Run"))
    #expect(json["indexedNodes"]?[1]?["value"] == .string("ready"))
    #expect(json["indexedNodes"]?[1]?["description"] == .string("Run task"))
    #expect(json["indexedNodes"]?[1]?["actions"]?[0] == .string("AXPress"))
    #expect(json["indexedNodes"]?[1]?["frame"]?["width"] == .double(30))
}
