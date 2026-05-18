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

@Test func snapshotJSONSuppressesAXUIElementPointerLabelsWithoutMutatingSnapshot() {
    let pointerLabel = "<AXUIElement 0x9df1e63d0> {pid=695}"
    let snapshot = AppSnapshot(
        id: SnapshotID("snap-pointer"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(
                role: "AXWindow",
                title: "Main",
                value: pointerLabel,
                children: [
                    AXNode(role: "AXGroup", description: pointerLabel)
                ]
            )
        ],
        screenshot: nil
    )

    let json = snapshot.jsonValue

    #expect(snapshot.windows[0].value == pointerLabel)
    #expect(json["windows"]?[0]?["value"] == .null)
    #expect(json["windows"]?[0]?["children"]?[0]?["description"] == .null)
    #expect(json["indexedNodes"]?[0]?["value"] == .null)
    #expect(json["indexedNodes"]?[1]?["description"] == .null)
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

@Test func snapshotDeterministicRedactionRedactsRoleAndPatternMatchesWithoutOptIn() throws {
    let apiToken = "not-shaped-but-labeled-secret"
    let ssn = "123-45-6789"
    let phone = "(415) 555-1212"
    let email = "mitch@example.com"
    let card = "4242 4242 4242 4242"
    let token = "sk-proj-abcdef1234567890SECRET"
    let snapshot = AppSnapshot(
        id: SnapshotID("snap-deterministic"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(
                    role: "AXSecureTextField",
                    value: "hunter2"
                ),
                AXNode(
                    role: "AXTextField",
                    title: "API Token",
                    value: apiToken
                ),
                AXNode(role: "AXStaticText", title: "SSN \(ssn)"),
                AXNode(role: "AXStaticText", title: "Call \(phone)"),
                AXNode(role: "AXStaticText", title: "Email \(email)"),
                AXNode(role: "AXStaticText", title: "Card \(card)"),
                AXNode(role: "AXStaticText", title: "Generated key \(token)")
            ])
        ],
        screenshot: EncodedScreenshot(mediaType: "image/png", base64Data: "raw-image", width: 300, height: 200)
    )

    let json = snapshot.jsonValue(includeTree: true)
    let encoded = try encodedJSONString(json)

    #expect(json["redaction"] == nil)
    #expect(json["screenshot"]?["base64Data"] == .string("raw-image"))
    #expect(json["indexedNodes"]?[1]?["value"] == .string("<redacted: auth-credential>"))
    #expect(json["indexedNodes"]?[1]?["redaction"]?["matched"]?["value"]?[0]?["rule"] == .string("ax-secure-text-field"))
    #expect(json["indexedNodes"]?[2]?["title"] == .string("API Token"))
    #expect(json["indexedNodes"]?[2]?["value"] == .string("<redacted: auth-credential>"))
    #expect(json["indexedNodes"]?[2]?["redaction"]?["matched"]?["value"]?[0]?["rule"] == .string("secret-label-value"))
    #expect(json["indexedNodes"]?[3]?["title"] == .string("<redacted: pii-identifier>"))
    #expect(json["indexedNodes"]?[4]?["title"] == .string("<redacted: pii-identifier>"))
    #expect(json["indexedNodes"]?[5]?["title"] == .string("<redacted: pii-identifier>"))
    #expect(json["indexedNodes"]?[6]?["title"] == .string("<redacted: financial-data>"))
    #expect(json["indexedNodes"]?[7]?["title"] == .string("<redacted: auth-credential>"))
    #expect(json["indexedNodes"]?[7]?["redaction"]?["reasons"]?["title"] == .string("auth-credential"))
    #expect(encoded.contains("hunter2") == false)
    #expect(encoded.contains(apiToken) == false)
    #expect(encoded.contains(ssn) == false)
    #expect(encoded.contains(phone) == false)
    #expect(encoded.contains(email) == false)
    #expect(encoded.contains(card) == false)
    #expect(encoded.contains("SECRET") == false)
    #expect(encoded.contains("raw-image"))
}

@Test func snapshotDeterministicRedactionKeepsPlainValuesWithoutRuleMatches() {
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

    let json = snapshot.jsonValue(includeTree: false)

    #expect(json["indexedNodes"]?[1]?["value"] == .string("hunter2"))
    #expect(json["indexedNodes"]?[1]?["redaction"] == nil)
}

@Test func snapshotDeterministicRedactionKeepsAllRuleMatchesAndUsesStrongestTag() {
    let snapshot = AppSnapshot(
        id: SnapshotID("snap-multiple-rules"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXStaticText", title: "token sk-proj-abcdef1234567890SECRET for 123-45-6789")
            ])
        ],
        screenshot: nil
    )

    let json = snapshot.jsonValue(includeTree: false)
    let redaction = json["indexedNodes"]?[1]?["redaction"]

    #expect(json["indexedNodes"]?[1]?["title"] == .string("<redacted: auth-credential>"))
    #expect(redaction?["reasons"]?["title"] == .string("auth-credential"))
    #expect(redaction?["matched"]?["title"]?[0]?["rule"] == .string("ssn"))
    #expect(redaction?["matched"]?["title"]?[0]?["tag"] == .string("pii-identifier"))
    #expect(redaction?["matched"]?["title"]?[1]?["rule"] == .string("openai-api-key"))
    #expect(redaction?["matched"]?["title"]?[1]?["tag"] == .string("auth-credential"))
}

@Test func screenTextDeterministicRedactionCatchesTokenShapes() throws {
    let token = "ghp_abcdefghijklmnopqrstuvwxyz1234567890"
    let item = ScreenTextItem(
        text: "Generated token \(token)",
        frame: AXFrame(x: 1, y: 2, width: 3, height: 4)
    )

    let json = item.jsonValue
    let encoded = try encodedJSONString(json)

    #expect(json["text"] == .string("<redacted: auth-credential>"))
    #expect(json["redaction"]?["matched"]?["text"]?[0]?["rule"] == .string("github-token"))
    #expect(encoded.contains(token) == false)
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
