import Foundation
import Testing
@testable import AxonCore

@Test func activeCredentialIndexMatchesOriginalValues() throws {
    let index = try testCredentialIndex(values: [
        "correct horse battery staple",
        "sk-proj-abcdef1234567890"
    ])

    #expect(index.mightContain("correct horse battery staple"))
    #expect(index.mightContain("sk-proj-abcdef1234567890"))
    #expect(index.mightContain("not a stored credential") == false)
}

@Test func activeCredentialIndexCacheRoundTripsWithoutSecretOrHMACKeyMaterial() throws {
    let original = try testCredentialIndex(secrets: [
        ActiveCredentialSecret(
            value: "correct horse battery staple",
            provider: "1password",
            reference: "op://Private/Example/password"
        )
    ])
    let cache = original.cache
    let encoded = try JSONEncoder().encode(cache)
    let encodedString = String(decoding: encoded, as: UTF8.self)

    #expect(encodedString.contains("correct horse battery staple") == false)
    #expect(encodedString.contains(testHMACKey.base64EncodedString()) == false)

    let decoded = try JSONDecoder().decode(ActiveCredentialIndexCache.self, from: encoded)
    let restored = try ActiveCredentialIndex(cache: decoded, hmacKey: testHMACKey)

    #expect(restored.mightContain("correct horse battery staple"))
    #expect(restored.mightContain("not a stored credential") == false)
    let fingerprint = try #require(restored.fingerprint(for: "correct horse battery staple"))
    #expect(restored.entry(for: fingerprint)?.references == ["op://Private/Example/password"])
}

@Test func activeCredentialIndexMergesDuplicateSecretReferences() throws {
    let index = try testCredentialIndex(secrets: [
        ActiveCredentialSecret(
            value: "same password value",
            provider: "1password",
            reference: "op://Private/First/password"
        ),
        ActiveCredentialSecret(
            value: "same password value",
            provider: "1password",
            reference: "op://Private/Second/password"
        )
    ])

    let redaction = try #require(ActiveSecretRedactor(filter: index).redaction(for: "same password value"))

    #expect(redaction.provider == "1password")
    #expect(redaction.references == [
        "op://Private/First/password",
        "op://Private/Second/password"
    ])
}

@Test func activeSecretRedactorRedactsExactMatchesWithoutPrefix() throws {
    let filter = try testCredentialIndex(secrets: [
        ActiveCredentialSecret(
            value: "correct horse battery staple",
            provider: "1password",
            reference: "op://Private/Example/password"
        )
    ])
    let redactor = ActiveSecretRedactor(filter: filter)

    let redaction = redactor.redaction(
        for: "correct horse battery staple"
    )

    #expect(redaction?.value == "<redacted: active-credential>")
    #expect(redaction?.reason == "active-credential")
    #expect(redaction?.provider == "1password")
    #expect(redaction?.references == ["op://Private/Example/password"])
}

@Test func activeSecretRedactorIgnoresNonMatches() throws {
    let filter = try testCredentialIndex(values: ["correct horse battery staple"])
    let redactor = ActiveSecretRedactor(filter: filter)

    #expect(redactor.redaction(for: "not a stored credential") == nil)
}

@Test func jsonValueDetectsNestedActiveCredentialRedaction() {
    let json = JSONValue.object([
        "snapshot": .object([
            "indexedNodes": .array([
                .object([
                    "title": .string("Username")
                ]),
                .object([
                    "value": .string("<redacted: active-credential>"),
                    "redaction": .object([
                        "fields": .array([.string("value")]),
                        "reasons": .object([
                            "value": .string("active-credential")
                        ]),
                        "references": .object([
                            "value": .array([.string("op://Private/Example/password")])
                        ])
                    ])
                ])
            ])
        ])
    ])

    #expect(json.containsActiveCredentialRedaction())
    #expect(JSONValue.object(["title": .string("No secret")]).containsActiveCredentialRedaction() == false)
}

@Test func commandRouterIncludesActiveCredentialReferenceInRedactionMetadata() throws {
    let secret = "correct horse battery staple"
    let reference = "op://Private/Example/password"
    let filter = try testCredentialIndex(secrets: [
        ActiveCredentialSecret(value: secret, provider: "1password", reference: reference)
    ])
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            AppSnapshot(
                id: SnapshotID("reference-active"),
                app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
                windows: [
                    AXNode(role: "AXWindow", title: "Main", children: [
                        AXNode(role: "AXTextField", value: secret)
                    ])
                ],
                screenshot: nil
            )
        },
        activeCredentialFilter: filter
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("look"),
        method: "look",
        params: .object(["target": .string("com.example.App")])
    ))
    let redaction = response.result?["snapshot"]?["indexedNodes"]?[1]?["redaction"]
    let encoded = String(decoding: try JSONEncoder().encode(JSONValue.object(response.result ?? [:])), as: UTF8.self)

    #expect(response.error == nil)
    #expect(redaction?["reasons"]?["value"] == JSONValue.string("active-credential"))
    #expect(redaction?["providers"]?["value"] == JSONValue.string("1password"))
    #expect(redaction?["references"]?["value"]?[0] == JSONValue.string(reference))
    #expect(encoded.contains(secret) == false)
}

private let testHMACKey = Data(repeating: 0xA5, count: 32)

private func testCredentialIndex(values: [String]) throws -> ActiveCredentialIndex {
    try ActiveCredentialIndex(
        values: values,
        hmacKey: testHMACKey,
        provider: "test",
        createdAt: Date(timeIntervalSince1970: 1_775_000_000)
    )
}

private func testCredentialIndex(secrets: [ActiveCredentialSecret]) throws -> ActiveCredentialIndex {
    try ActiveCredentialIndex(
        secrets: secrets,
        hmacKey: testHMACKey,
        provider: "test",
        createdAt: Date(timeIntervalSince1970: 1_775_000_000)
    )
}

private extension JSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }
}
