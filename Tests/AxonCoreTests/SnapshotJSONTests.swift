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
    #expect(json["indexedNodes"]?[1]?["handle"] == .string("snap-compact:1"))
    #expect(json["indexedNodes"]?[1]?["title"] == .string("Run"))
    #expect(json["indexedNodes"]?[1]?["value"] == .string("ready"))
    #expect(json["indexedNodes"]?[1]?["description"] == .string("Run task"))
    #expect(json["indexedNodes"]?[1]?["actions"]?[0] == .string("AXPress"))
    #expect(json["indexedNodes"]?[1]?["frame"]?["width"] == .double(30))
}

@Test func childrenPageJSONStartsHandlesAtRetainedBaseIndex() {
    let children = AXChildrenPage(
        snapshotID: SnapshotID("s12"),
        parentHandle: "s12:4",
        offset: 24,
        limit: 2,
        total: 30,
        baseIndex: 42,
        children: [
            AXNode(role: "AXButton", title: "Tab 25", children: [
                AXNode(role: "AXStaticText", title: "Selected")
            ]),
            AXNode(role: "AXButton", title: "Tab 26")
        ]
    )

    let json = children.jsonValue

    #expect(json["snapshot"] == .string("s12"))
    #expect(json["parent"] == .string("s12:4"))
    #expect(json["nextOffset"] == .int(26))
    #expect(json["children"]?[0]?["handle"] == .string("s12:42"))
    #expect(json["children"]?[0]?["children"]?[0]?["handle"] == .string("s12:43"))
    #expect(json["children"]?[1]?["handle"] == .string("s12:44"))
}

@Test func sensitiveSnapshotRedactsValuesAndSecretLikeTextWithPrefixes() throws {
    let rawSecret = "sk-proj-abcdef1234567890SECRET"
    let snapshot = AppSnapshot(
        id: SnapshotID("snap-sensitive"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(
                    role: "AXTextField",
                    title: "API key",
                    value: rawSecret,
                    identifier: "github_pat_11ABCDEFGHijklmnopqrstuvwxyz1234567890"
                ),
                AXNode(
                    role: "AXStaticText",
                    title: "Generated key \(rawSecret)"
                ),
                AXNode(role: "AXButton", title: "Copy", actions: ["AXPress"])
            ])
        ],
        screenshot: EncodedScreenshot(mediaType: "image/png", base64Data: "raw-image", width: 300, height: 200)
    )

    let json = snapshot.jsonValue(includeTree: true, sensitive: true)
    let encoded = try encodedJSONString(json)
    let value = json["indexedNodes"]?[1]?["value"]
    let title = json["indexedNodes"]?[2]?["title"]
    let identifier = json["windows"]?[0]?["children"]?[0]?["identifier"]

    #expect(json["redaction"]?["sensitive"] == .bool(true))
    #expect(json["screenshot"] == .null)
    #expect(value != .string(rawSecret))
    #expect(value == .string("sk-proj-abcd...[redacted]"))
    #expect(title == .string("Generated key sk-proj-abcd...[redacted]"))
    #expect(identifier == .string("github_pat_1...[redacted]"))
    #expect(json["indexedNodes"]?[3]?["title"] == .string("Copy"))
    #expect(json["indexedNodes"]?[1]?["redaction"]?["fields"]?[0] == .string("value"))
    #expect(encoded.contains("SECRET") == false)
    #expect(encoded.contains("raw-image") == false)
}

@Test func sensitiveSnapshotRedactsPlainValuesEvenWhenNotSecretShaped() {
    let snapshot = AppSnapshot(
        id: SnapshotID("snap-value"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXTextField", value: "hunter2")
            ])
        ],
        screenshot: nil
    )

    let json = snapshot.jsonValue(includeTree: false, sensitive: true)

    #expect(json["indexedNodes"]?[1]?["value"] == .string("hu...[redacted]"))
    #expect(json["indexedNodes"]?[1]?["redaction"]?["reasons"]?["value"] == .string("sensitive_value"))
}

@Test func activeSecretSnapshotRedactsValuesWithoutSensitiveMode() throws {
    let rawSecret = "correct horse battery staple"
    let snapshot = AppSnapshot(
        id: SnapshotID("snap-active"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXTextField", title: "Password", value: rawSecret)
            ])
        ],
        screenshot: EncodedScreenshot(mediaType: "image/png", base64Data: "raw-image", width: 300, height: 200)
    )

    let json = snapshot.jsonValue(
        includeTree: true,
        activeSecretRedactor: try activeRedactor(values: [rawSecret])
    )
    let encoded = try encodedJSONString(json)

    #expect(json["indexedNodes"]?[1]?["value"] == .string("<redacted: active-credential>"))
    #expect(json["indexedNodes"]?[1]?["redaction"]?["reasons"]?["value"] == .string("active-credential"))
    #expect(json["indexedNodes"]?[1]?["redaction"]?["references"]?["value"]?[0] == .string("op://Test/Active/secret"))
    #expect(json["indexedNodes"]?[1]?["redaction"]?["providers"]?["value"] == .string("test"))
    #expect(json["windows"]?[0]?["children"]?[0]?["value"] == .string("<redacted: active-credential>"))
    #expect(json.containsActiveCredentialRedaction())
    #expect(encoded.contains(rawSecret) == false)
    #expect(encoded.contains("raw-image"))
}

@Test func activeSecretChildrenPageRedactsTitlesWithoutSensitiveMode() throws {
    let rawSecret = "correct horse battery staple"
    let children = AXChildrenPage(
        snapshotID: SnapshotID("s12"),
        parentHandle: "s12:4",
        offset: 0,
        limit: 1,
        total: 1,
        baseIndex: 42,
        children: [
            AXNode(role: "AXButton", title: rawSecret)
        ]
    )

    let json = children.jsonValue(activeSecretRedactor: try activeRedactor(values: [rawSecret]))
    let encoded = try encodedJSONString(json)

    #expect(json["children"]?[0]?["title"] == .string("<redacted: active-credential>"))
    #expect(json["children"]?[0]?["redaction"]?["reasons"]?["title"] == .string("active-credential"))
    #expect(json["children"]?[0]?["redaction"]?["references"]?["title"]?[0] == .string("op://Test/Active/secret"))
    #expect(encoded.contains(rawSecret) == false)
}

@Test func activeSecretSnapshotSummaryRedactsWindowTitlesWithoutSensitiveMode() throws {
    let rawSecret = "Production Admin Password"
    let summary = SnapshotSummary(
        id: SnapshotID("summary-active"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            WindowSignature(
                role: "AXWindow",
                subrole: nil,
                title: rawSecret,
                frame: FrameSignature(x: 0, y: 0, width: 300, height: 200),
                childCount: 1
            )
        ],
        observationToken: 99
    )

    let json = summary.jsonValue(activeSecretRedactor: try activeRedactor(values: [rawSecret]))
    let encoded = try encodedJSONString(json)

    #expect(json["windows"]?[0]?["title"] == .string("<redacted: active-credential>"))
    #expect(json["windows"]?[0]?["redaction"]?["reasons"]?["title"] == .string("active-credential"))
    #expect(encoded.contains(rawSecret) == false)
}

private func encodedJSONString(_ value: JSONValue) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

private func activeRedactor(values: [String]) throws -> ActiveSecretRedactor {
    ActiveSecretRedactor(
        filter: try ActiveCredentialIndex(
            secrets: values.map { value in
                ActiveCredentialSecret(
                    value: value,
                    provider: "test",
                    reference: "op://Test/Active/secret"
                )
            },
            hmacKey: Data(repeating: 0x5A, count: 32),
            provider: "test",
            createdAt: Date(timeIntervalSince1970: 1_775_000_000)
        )
    )
}
