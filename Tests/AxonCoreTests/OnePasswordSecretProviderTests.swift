import Foundation
import Testing
@testable import AxonCore

@Test func onePasswordSecretExtractorPullsConcealedFieldsRecursively() {
    let item = JSONValue.object([
        "fields": .array([
            .object([
                "id": .string("username"),
                "purpose": .string("USERNAME"),
                "type": .string("STRING"),
                "value": .string("mitch@example.com")
            ]),
            .object([
                "id": .string("password"),
                "purpose": .string("PASSWORD"),
                "type": .string("CONCEALED"),
                "value": .string("correct horse battery staple")
            ])
        ]),
        "sections": .array([
            .object([
                "label": .string("Developer"),
                "fields": .array([
                    .object([
                        "label": .string("API token"),
                        "type": .string("STRING"),
                        "value": .string("sk-proj-abcdef1234567890")
                    ])
                ])
            ])
        ])
    ])

    let values = OnePasswordSecretExtractor().secretValues(from: item)

    #expect(values.contains("correct horse battery staple"))
    #expect(values.contains("sk-proj-abcdef1234567890"))
    #expect(values.contains("mitch@example.com") == false)
}

@Test func onePasswordSecretExtractorPreservesFieldReferences() {
    let item = JSONValue.object([
        "fields": .array([
            .object([
                "label": .string("password"),
                "type": .string("CONCEALED"),
                "value": .string("correct horse battery staple"),
                "reference": .string("op://Private/Example/password")
            ])
        ])
    ])

    let records = OnePasswordSecretExtractor().secretRecords(from: item)

    #expect(records == [
        ActiveCredentialSecret(
            value: "correct horse battery staple",
            provider: "1password",
            reference: "op://Private/Example/password"
        )
    ])
}

@Test func onePasswordSecretProviderReadsConcealedFieldsPerItem() throws {
    let listData = Data(#"[{"id":"item-a"},{"id":"item-b"}]"#.utf8)
    let runner = FakeOnePasswordRunner(responses: [
        ["item", "list", "--format", "json"]: listData,
        ["item", "get", "item-a", "--fields", "type=concealed", "--format", "json"]: Data(#"[{"type":"CONCEALED","value":"correct horse battery staple","reference":"op://Private/Example/password"}]"#.utf8),
        ["item", "get", "item-b", "--fields", "type=concealed", "--format", "json"]: Data(#"[{"label":"API token","value":"sk-proj-abcdef1234567890","reference":"op://Private/Example/token"}]"#.utf8)
    ])
    let provider = OnePasswordSecretProvider(runner: runner, maxConcurrentItemReads: 1)

    let records = try provider.readSecrets()

    #expect(records == [
        ActiveCredentialSecret(
            value: "correct horse battery staple",
            provider: "1password",
            reference: "op://Private/Example/password"
        ),
        ActiveCredentialSecret(
            value: "sk-proj-abcdef1234567890",
            provider: "1password",
            reference: "op://Private/Example/token"
        )
    ])
    #expect(runner.calls == [
        ["item", "list", "--format", "json"],
        ["item", "get", "item-a", "--fields", "type=concealed", "--format", "json"],
        ["item", "get", "item-b", "--fields", "type=concealed", "--format", "json"]
    ])
}

@Test func onePasswordSecretProviderSkipsItemsWithoutConcealedFields() throws {
    let listData = Data(#"[{"id":"item-a"},{"id":"item-b"}]"#.utf8)
    let missingFields = OnePasswordError.commandFailed(
        arguments: ["item", "get", "item-a", "--fields", "type=concealed", "--format", "json"],
        status: 1,
        stderr: #"item "item-a" doesn't have any fields of the following types: "concealed""#
    )
    let runner = FakeOnePasswordRunner(results: [
        ["item", "list", "--format", "json"]: .success(listData),
        ["item", "get", "item-a", "--fields", "type=concealed", "--format", "json"]: .failure(missingFields),
        ["item", "get", "item-b", "--fields", "type=concealed", "--format", "json"]: .success(Data(#"[{"label":"API token","value":"sk-proj-abcdef1234567890"}]"#.utf8))
    ])
    let provider = OnePasswordSecretProvider(runner: runner, maxConcurrentItemReads: 1)

    let values = try provider.readSecretValues()

    #expect(values == ["sk-proj-abcdef1234567890"])
    #expect(runner.calls == [
        ["item", "list", "--format", "json"],
        ["item", "get", "item-a", "--fields", "type=concealed", "--format", "json"],
        ["item", "get", "item-b", "--fields", "type=concealed", "--format", "json"]
    ])
}

@Test func activeCredentialRefreshServiceWritesKeyedIndexCache() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-active-index-\(UUID().uuidString)", isDirectory: true)
    let cacheURL = temporaryDirectory.appendingPathComponent("active-credential-index.json")
    let cacheStore = ActiveCredentialIndexCacheStore(fileURL: cacheURL)
    let key = Data(repeating: 0xAB, count: 32)
    let service = ActiveCredentialRefreshService(
        provider: StaticSecretProvider(values: ["correct horse battery staple"]),
        cacheStore: cacheStore,
        keyStore: StaticActiveCredentialKeyStore(key: key),
        now: { Date(timeIntervalSince1970: 1_775_000_000) }
    )

    let result = try service.refresh()
    let encoded = String(decoding: try Data(contentsOf: cacheURL), as: UTF8.self)
    let loaded = try cacheStore.loadFilter(hmacKey: key)

    #expect(result.index.mightContain("correct horse battery staple"))
    #expect(loaded?.mightContain("correct horse battery staple") == true)
    #expect(encoded.contains("correct horse battery staple") == false)
    #expect(encoded.contains(key.base64EncodedString()) == false)
    #expect(result.cache.provider == "1password")
    #expect(result.cache.secretCount == 1)
    #expect(result.cache.entries.count == 1)
}

private final class FakeOnePasswordRunner: OnePasswordCommandRunning, @unchecked Sendable {
    private let responses: [[String]: Result<Data, Error>]
    private(set) var calls: [[String]] = []

    init(responses: [[String]: Data]) {
        self.responses = responses.mapValues { .success($0) }
    }

    init(results: [[String]: Result<Data, Error>]) {
        self.responses = results
    }

    func run(arguments: [String]) throws -> Data {
        calls.append(arguments)
        guard let response = responses[arguments] else {
            throw OnePasswordError.commandFailed(
                arguments: arguments,
                status: 1,
                stderr: "unexpected command"
            )
        }
        return try response.get()
    }
}

private struct StaticSecretProvider: ActiveCredentialSecretProvider {
    let values: [String]

    func readSecretValues() throws -> [String] {
        values
    }
}
