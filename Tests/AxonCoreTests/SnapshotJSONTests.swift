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

