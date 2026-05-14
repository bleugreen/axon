import CryptoKit
import Foundation
import Security

public protocol ActiveCredentialFilter: Sendable {
    func match(for value: String) -> ActiveCredentialMatch?
    func entry(for fingerprint: ActiveCredentialFingerprint) -> ActiveCredentialIndexEntry?
    func fingerprint(for value: String) -> ActiveCredentialFingerprint?
}

public extension ActiveCredentialFilter {
    func mightContain(_ value: String) -> Bool {
        match(for: value) != nil
    }

    func entry(for fingerprint: ActiveCredentialFingerprint) -> ActiveCredentialIndexEntry? {
        nil
    }

    func fingerprint(for value: String) -> ActiveCredentialFingerprint? {
        nil
    }
}

public struct ActiveCredentialFingerprint: Codable, Equatable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

public struct ActiveCredentialIndexEntry: Codable, Equatable, Sendable {
    public let provider: String
    public let references: [String]

    public init(provider: String, references: [String]) {
        self.provider = provider
        self.references = references
    }

    func merged(with other: ActiveCredentialIndexEntry) -> ActiveCredentialIndexEntry {
        ActiveCredentialIndexEntry(
            provider: provider == other.provider ? provider : "multiple",
            references: Array(Set(references + other.references)).sorted()
        )
    }
}

public struct ActiveCredentialMatch: Equatable, Sendable {
    public let fingerprint: ActiveCredentialFingerprint
    public let entry: ActiveCredentialIndexEntry

    public init(fingerprint: ActiveCredentialFingerprint, entry: ActiveCredentialIndexEntry) {
        self.fingerprint = fingerprint
        self.entry = entry
    }
}

public enum ActiveCredentialFilterError: Error, CustomStringConvertible {
    case invalidHMACKey
    case invalidIndex(String)
    case keychain(String)

    public var description: String {
        switch self {
        case .invalidHMACKey:
            return "Active credential index HMAC key is empty"
        case let .invalidIndex(message):
            return "Invalid active credential index cache: \(message)"
        case let .keychain(message):
            return "Active credential index keychain error: \(message)"
        }
    }
}

public struct EmptyActiveCredentialFilter: ActiveCredentialFilter {
    public init() {}

    public func match(for value: String) -> ActiveCredentialMatch? {
        nil
    }
}

public struct ActiveCredentialIndexCache: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let provider: String
    public let createdAt: Date
    public let secretCount: Int
    public let entries: [String: ActiveCredentialIndexEntry]

    public init(
        version: Int = Self.currentVersion,
        provider: String,
        createdAt: Date,
        secretCount: Int,
        entries: [String: ActiveCredentialIndexEntry]
    ) {
        self.version = version
        self.provider = provider
        self.createdAt = createdAt
        self.secretCount = secretCount
        self.entries = entries
    }
}

public struct ActiveCredentialIndex: ActiveCredentialFilter, Sendable {
    private static let domainSeparator = Data("axon-active-credential-index-v1\0".utf8)

    public let provider: String
    public let createdAt: Date
    public let secretCount: Int
    public let entries: [String: ActiveCredentialIndexEntry]

    private let hmacKey: Data

    public init(
        secrets: some Sequence<ActiveCredentialSecret>,
        hmacKey: Data,
        provider: String,
        createdAt: Date = Date()
    ) throws {
        guard !hmacKey.isEmpty else {
            throw ActiveCredentialFilterError.invalidHMACKey
        }

        var entries: [String: ActiveCredentialIndexEntry] = [:]
        var seenSecrets = Set<String>()
        for secret in secrets {
            guard !secret.value.isEmpty else {
                continue
            }
            seenSecrets.insert(secret.value)
            let fingerprint = Self.fingerprint(for: secret.value, hmacKey: hmacKey)
            let entry = ActiveCredentialIndexEntry(
                provider: secret.provider,
                references: secret.reference.map { [$0] } ?? []
            )
            entries[fingerprint.value] = entries[fingerprint.value].map { $0.merged(with: entry) } ?? entry
        }

        self.init(
            provider: provider,
            createdAt: createdAt,
            secretCount: seenSecrets.count,
            entries: entries,
            hmacKey: hmacKey
        )
    }

    public init(
        values: some Sequence<String>,
        hmacKey: Data,
        provider: String,
        createdAt: Date = Date()
    ) throws {
        try self.init(
            secrets: values.map { ActiveCredentialSecret(value: $0, provider: provider, reference: nil) },
            hmacKey: hmacKey,
            provider: provider,
            createdAt: createdAt
        )
    }

    public init(cache: ActiveCredentialIndexCache, hmacKey: Data) throws {
        guard !hmacKey.isEmpty else {
            throw ActiveCredentialFilterError.invalidHMACKey
        }
        guard cache.version == ActiveCredentialIndexCache.currentVersion else {
            throw ActiveCredentialFilterError.invalidIndex("unsupported version \(cache.version)")
        }
        self.init(
            provider: cache.provider,
            createdAt: cache.createdAt,
            secretCount: cache.secretCount,
            entries: cache.entries,
            hmacKey: hmacKey
        )
    }

    private init(
        provider: String,
        createdAt: Date,
        secretCount: Int,
        entries: [String: ActiveCredentialIndexEntry],
        hmacKey: Data
    ) {
        self.provider = provider
        self.createdAt = createdAt
        self.secretCount = secretCount
        self.entries = entries
        self.hmacKey = hmacKey
    }

    public var cache: ActiveCredentialIndexCache {
        ActiveCredentialIndexCache(
            provider: provider,
            createdAt: createdAt,
            secretCount: secretCount,
            entries: entries
        )
    }

    public func match(for value: String) -> ActiveCredentialMatch? {
        guard let fingerprint = fingerprint(for: value),
              let entry = entry(for: fingerprint)
        else {
            return nil
        }
        return ActiveCredentialMatch(fingerprint: fingerprint, entry: entry)
    }

    public func entry(for fingerprint: ActiveCredentialFingerprint) -> ActiveCredentialIndexEntry? {
        entries[fingerprint.value]
    }

    public func fingerprint(for value: String) -> ActiveCredentialFingerprint? {
        guard !value.isEmpty else {
            return nil
        }
        return Self.fingerprint(for: value, hmacKey: hmacKey)
    }

    private static func fingerprint(for value: String, hmacKey: Data) -> ActiveCredentialFingerprint {
        var payload = domainSeparator
        payload.append(Data(value.utf8))
        let digest = HMAC<SHA256>.authenticationCode(
            for: payload,
            using: SymmetricKey(data: hmacKey)
        )
        return ActiveCredentialFingerprint(Data(digest).base64EncodedString())
    }
}

public struct ActiveCredentialIndexCacheStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = AxonEnvironment.activeCredentialIndexCacheURL()) {
        self.fileURL = fileURL
    }

    public func loadCache() throws -> ActiveCredentialIndexCache? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(ActiveCredentialIndexCache.self, from: data)
    }

    public func loadFilter(hmacKey: Data) throws -> ActiveCredentialIndex? {
        guard let cache = try loadCache() else {
            return nil
        }
        return try ActiveCredentialIndex(cache: cache, hmacKey: hmacKey)
    }

    public func save(_ cache: ActiveCredentialIndexCache) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)
        try data.write(to: fileURL, options: [.atomic])
    }
}

public protocol ActiveCredentialKeyStore: Sendable {
    func hmacKey() throws -> Data
}

public struct StaticActiveCredentialKeyStore: ActiveCredentialKeyStore {
    private let key: Data

    public init(key: Data) {
        self.key = key
    }

    public func hmacKey() throws -> Data {
        guard !key.isEmpty else {
            throw ActiveCredentialFilterError.invalidHMACKey
        }
        return key
    }
}

public struct KeychainActiveCredentialKeyStore: ActiveCredentialKeyStore {
    private let service: String
    private let account: String

    public init(
        service: String = "com.bleugreen.axon.active-credential-index",
        account: String = "hmac-key-v1"
    ) {
        self.service = service
        self.account = account
    }

    public func hmacKey() throws -> Data {
        if let existing = try loadExistingKey() {
            return existing
        }
        return try createKey()
    }

    private func loadExistingKey() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ActiveCredentialFilterError.keychain("SecItemCopyMatching failed with status \(status)")
        }
        guard let data = item as? Data, !data.isEmpty else {
            throw ActiveCredentialFilterError.keychain("stored HMAC key was empty or unreadable")
        }
        return data
    }

    private func createKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ActiveCredentialFilterError.keychain("SecRandomCopyBytes failed with status \(status)")
        }
        let data = Data(bytes)

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem, let existing = try loadExistingKey() {
            return existing
        }
        guard addStatus == errSecSuccess else {
            throw ActiveCredentialFilterError.keychain("SecItemAdd failed with status \(addStatus)")
        }
        return data
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public struct ActiveCredentialFilterLoader: Sendable {
    private let cacheStore: ActiveCredentialIndexCacheStore
    private let keyStore: any ActiveCredentialKeyStore

    public init(
        cacheStore: ActiveCredentialIndexCacheStore = ActiveCredentialIndexCacheStore(),
        keyStore: any ActiveCredentialKeyStore = KeychainActiveCredentialKeyStore()
    ) {
        self.cacheStore = cacheStore
        self.keyStore = keyStore
    }

    public func load() throws -> ActiveCredentialIndex? {
        guard try cacheStore.loadCache() != nil else {
            return nil
        }
        return try cacheStore.loadFilter(hmacKey: keyStore.hmacKey())
    }

    public func loadOrEmpty() -> any ActiveCredentialFilter {
        (try? load()) ?? EmptyActiveCredentialFilter()
    }
}

public struct ActiveSecretRedaction: Equatable, Sendable {
    public let value: String
    public let reason: String
    public let provider: String?
    public let references: [String]

    public init(
        value: String = "<redacted: active-credential>",
        reason: String = "active-credential",
        provider: String? = nil,
        references: [String] = []
    ) {
        self.value = value
        self.reason = reason
        self.provider = provider
        self.references = references
    }
}

public struct ActiveSecretRedactor: Sendable {
    private let filter: any ActiveCredentialFilter

    public init(
        filter: any ActiveCredentialFilter = EmptyActiveCredentialFilter()
    ) {
        self.filter = filter
    }

    public func redaction(for value: String) -> ActiveSecretRedaction? {
        guard !value.isEmpty, let match = filter.match(for: value) else {
            return nil
        }
        return ActiveSecretRedaction(
            provider: match.entry.provider,
            references: match.entry.references
        )
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    mutating func addActiveSecretRedactedString(
        _ key: String,
        _ value: String?,
        activeSecretRedactor: ActiveSecretRedactor
    ) -> Bool {
        guard let value else {
            self[key] = .null
            return false
        }
        guard let redaction = activeSecretRedactor.redaction(for: value) else {
            return false
        }
        self[key] = .string(redaction.value)
        addActiveSecretRedactionMetadata(field: key, redaction: redaction)
        return true
    }

    mutating func addActiveSecretRedactionMetadata(field: String, redaction: ActiveSecretRedaction) {
        var fields: [JSONValue] = []
        var reasons: [String: JSONValue] = [:]
        var providers: [String: JSONValue] = [:]
        var references: [String: JSONValue] = [:]

        if case let .object(existing)? = self["redaction"] {
            if case let .array(existingFields)? = existing["fields"] {
                fields = existingFields
            }
            if case let .object(existingReasons)? = existing["reasons"] {
                reasons = existingReasons
            }
            if case let .object(existingProviders)? = existing["providers"] {
                providers = existingProviders
            }
            if case let .object(existingReferences)? = existing["references"] {
                references = existingReferences
            }
        }

        if !fields.contains(.string(field)) {
            fields.append(.string(field))
        }
        reasons[field] = .string(redaction.reason)
        if let provider = redaction.provider {
            providers[field] = .string(provider)
        }
        references[field] = .array(redaction.references.map(JSONValue.string))
        self["redaction"] = .object([
            "fields": .array(fields),
            "reasons": .object(reasons),
            "providers": .object(providers),
            "references": .object(references)
        ])
    }
}

public extension JSONValue {
    func containsActiveCredentialRedaction() -> Bool {
        switch self {
        case let .object(object):
            if object["redaction"]?.containsActiveCredentialReason() == true {
                return true
            }
            return object.values.contains { $0.containsActiveCredentialRedaction() }
        case let .array(values):
            return values.contains { $0.containsActiveCredentialRedaction() }
        case .string, .int, .double, .bool, .null:
            return false
        }
    }

    private func containsActiveCredentialReason() -> Bool {
        switch self {
        case let .object(object):
            if case let .object(reasons)? = object["reasons"],
               reasons.values.contains(.string("active-credential")) {
                return true
            }
            return object.values.contains { $0.containsActiveCredentialReason() }
        case let .array(values):
            return values.contains { $0.containsActiveCredentialReason() }
        case .string, .int, .double, .bool, .null:
            return false
        }
    }
}

extension AxonEnvironment {
    public static func applicationSupportDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Axon", isDirectory: true)
    }

    public static func activeCredentialIndexCacheURL() -> URL {
        applicationSupportDirectory()
            .appendingPathComponent("active-credential-index.json", isDirectory: false)
    }
}
