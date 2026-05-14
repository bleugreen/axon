import Foundation

public enum OnePasswordError: Error, CustomStringConvertible {
    case commandFailed(arguments: [String], status: Int32, stderr: String)
    case invalidOutput(String)

    public var description: String {
        switch self {
        case let .commandFailed(arguments, status, stderr):
            return "op \(arguments.joined(separator: " ")) failed with status \(status): \(stderr)"
        case let .invalidOutput(message):
            return "Invalid 1Password output: \(message)"
        }
    }
}

public protocol OnePasswordCommandRunning: Sendable {
    func run(arguments: [String]) throws -> Data
}

public struct OnePasswordCLI: OnePasswordCommandRunning {
    private let executablePath: String

    public init(executablePath: String = "/usr/bin/env") {
        self.executablePath = executablePath
    }

    public func run(arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = executablePath == "/usr/bin/env" ? ["op"] + arguments : arguments

        let outputURL = temporaryOutputURL(label: "stdout")
        let errorURL = temporaryOutputURL(label: "stderr")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        process.standardOutput = outputHandle
        process.standardError = errorHandle

        try process.run()
        process.waitUntilExit()

        try outputHandle.close()
        try errorHandle.close()
        let output = try Data(contentsOf: outputURL)
        let errorData = try Data(contentsOf: errorURL)
        guard process.terminationStatus == 0 else {
            throw OnePasswordError.commandFailed(
                arguments: arguments,
                status: process.terminationStatus,
                stderr: String(decoding: errorData, as: UTF8.self)
            )
        }
        return output
    }

    private func temporaryOutputURL(label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("axon-op-\(label)-\(UUID().uuidString)", isDirectory: false)
    }

    public func read(reference: String) throws -> String {
        let data = try run(arguments: ["read", "-n", reference])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}

public struct ActiveCredentialSecret: Equatable, Sendable {
    public let value: String
    public let provider: String
    public let reference: String?

    public init(value: String, provider: String, reference: String? = nil) {
        self.value = value
        self.provider = provider
        self.reference = reference
    }
}

public protocol ActiveCredentialSecretProvider: Sendable {
    func readSecretValues() throws -> [String]
    func readSecrets() throws -> [ActiveCredentialSecret]
}

public extension ActiveCredentialSecretProvider {
    func readSecretValues() throws -> [String] {
        try readSecrets().map(\.value)
    }

    func readSecrets() throws -> [ActiveCredentialSecret] {
        try readSecretValues().map {
            ActiveCredentialSecret(value: $0, provider: "unknown", reference: nil)
        }
    }
}

public struct OnePasswordSecretProvider: ActiveCredentialSecretProvider {
    private let runner: any OnePasswordCommandRunning
    private let extractor: OnePasswordSecretExtractor
    private let maxConcurrentItemReads: Int

    public init(
        runner: any OnePasswordCommandRunning = OnePasswordCLI(),
        extractor: OnePasswordSecretExtractor = OnePasswordSecretExtractor(),
        maxConcurrentItemReads: Int = 8
    ) {
        self.runner = runner
        self.extractor = extractor
        self.maxConcurrentItemReads = max(1, maxConcurrentItemReads)
    }

    public func readSecrets() throws -> [ActiveCredentialSecret] {
        let listData = try runner.run(arguments: ["item", "list", "--format", "json"])
        return try readSecretsPerItem(listData: listData)
    }

    private func secretRecords(from data: Data) throws -> [ActiveCredentialSecret] {
        let item = try JSONDecoder().decode(JSONValue.self, from: data)
        return extractor.secretRecords(from: item)
    }

    private func readSecretsPerItem(listData: Data) throws -> [ActiveCredentialSecret] {
        let summaries = try JSONDecoder().decode([OnePasswordItemSummary].self, from: listData)
        let itemIDs = summaries.compactMap(\.itemID)
        let accumulator = OnePasswordSecretAccumulator()
        let semaphore = DispatchSemaphore(value: maxConcurrentItemReads)
        let group = DispatchGroup()

        for itemID in itemIDs {
            semaphore.wait()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    semaphore.signal()
                    group.leave()
                }

                do {
                    let itemData = try runner.run(arguments: [
                        "item",
                        "get",
                        itemID,
                        "--fields",
                        "type=concealed",
                        "--format",
                        "json"
                    ])
                    accumulator.append(try secretRecords(from: itemData))
                } catch let error as OnePasswordError where error.isMissingConcealedFields {
                    return
                } catch {
                    accumulator.record(error)
                }
            }
        }

        group.wait()
        return try accumulator.result()
    }
}

public struct OnePasswordSecretExtractor: Sendable {
    private static let secretLabels = [
        "api key",
        "apikey",
        "access key",
        "credential",
        "private key",
        "secret",
        "token",
        "password",
        "passcode"
    ]

    public init() {}

    public func secretValues(from item: JSONValue) -> [String] {
        secretRecords(from: item).map(\.value)
    }

    public func secretRecords(from item: JSONValue) -> [ActiveCredentialSecret] {
        var seen = Set<String>()
        var values: [ActiveCredentialSecret] = []
        appendSecretRecords(from: item, inheritedLabels: [], seen: &seen, values: &values)
        return values
    }

    private func appendSecretRecords(
        from value: JSONValue,
        inheritedLabels: [String],
        seen: inout Set<String>,
        values: inout [ActiveCredentialSecret]
    ) {
        switch value {
        case let .object(object):
            let labels = inheritedLabels + labelHints(in: object)
            if let candidate = secretCandidate(in: object, labels: labels) {
                let key = "\(candidate.value)\u{0}\(candidate.reference ?? "")"
                if seen.insert(key).inserted {
                    values.append(candidate)
                }
            }
            for child in object.values {
                appendSecretRecords(from: child, inheritedLabels: labels, seen: &seen, values: &values)
            }
        case let .array(items):
            for item in items {
                appendSecretRecords(from: item, inheritedLabels: inheritedLabels, seen: &seen, values: &values)
            }
        case .string, .int, .double, .bool, .null:
            return
        }
    }

    private func secretCandidate(in object: [String: JSONValue], labels: [String]) -> ActiveCredentialSecret? {
        guard case let .string(rawValue)? = object["value"] else {
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 4 else {
            return nil
        }

        let type = lowerString("type", in: object)
        let purpose = lowerString("purpose", in: object)
        let designation = lowerString("designation", in: object)
        let metadata = ([type, purpose, designation].compactMap { $0 } + labels).joined(separator: " ")
        let reference = string("reference", in: object)

        if type == "concealed" || type == "password" || type == "otp" {
            return ActiveCredentialSecret(value: value, provider: "1password", reference: reference)
        }
        if purpose == "password" || purpose == "credential" || designation == "password" {
            return ActiveCredentialSecret(value: value, provider: "1password", reference: reference)
        }
        if Self.secretLabels.contains(where: { metadata.contains($0) }), value.count >= 8 {
            return ActiveCredentialSecret(value: value, provider: "1password", reference: reference)
        }
        return nil
    }

    private func labelHints(in object: [String: JSONValue]) -> [String] {
        ["label", "id", "name", "title", "section"]
            .compactMap { lowerString($0, in: object) }
    }

    private func lowerString(_ key: String, in object: [String: JSONValue]) -> String? {
        guard case let .string(value)? = object[key], !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private func string(_ key: String, in object: [String: JSONValue]) -> String? {
        guard case let .string(value)? = object[key], !value.isEmpty else {
            return nil
        }
        return value
    }
}

private final class OnePasswordSecretAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<String>()
    private var values: [ActiveCredentialSecret] = []
    private var firstError: Error?

    func append(_ newValues: [ActiveCredentialSecret]) {
        lock.lock()
        defer { lock.unlock() }
        for value in newValues {
            let key = "\(value.value)\u{0}\(value.reference ?? "")"
            if seen.insert(key).inserted {
                values.append(value)
            }
        }
    }

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if firstError == nil {
            firstError = error
        }
    }

    func result() throws -> [ActiveCredentialSecret] {
        lock.lock()
        defer { lock.unlock() }
        if let firstError {
            throw firstError
        }
        return values
    }
}

private extension OnePasswordError {
    var isMissingConcealedFields: Bool {
        guard case let .commandFailed(_, _, stderr) = self else {
            return false
        }
        return Self.isMissingConcealedFields(stderr: stderr)
    }

    static func isMissingConcealedFields(stderr: String) -> Bool {
        stderr.contains("doesn't have any fields of the following types") ||
            stderr.contains("does not have any fields of the following types")
    }
}

private struct OnePasswordItemSummary: Decodable {
    let id: String?
    let uuid: String?

    var itemID: String? {
        id ?? uuid
    }
}

public struct ActiveCredentialRefreshResult: Sendable {
    public let index: ActiveCredentialIndex
    public let cache: ActiveCredentialIndexCache

    public init(index: ActiveCredentialIndex, cache: ActiveCredentialIndexCache) {
        self.index = index
        self.cache = cache
    }
}

public struct ActiveCredentialRefreshService: Sendable {
    private let provider: any ActiveCredentialSecretProvider
    private let cacheStore: ActiveCredentialIndexCacheStore
    private let keyStore: any ActiveCredentialKeyStore
    private let now: @Sendable () -> Date

    public init(
        provider: any ActiveCredentialSecretProvider = OnePasswordSecretProvider(),
        cacheStore: ActiveCredentialIndexCacheStore = ActiveCredentialIndexCacheStore(),
        keyStore: any ActiveCredentialKeyStore = KeychainActiveCredentialKeyStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.cacheStore = cacheStore
        self.keyStore = keyStore
        self.now = now
    }

    public func refresh() throws -> ActiveCredentialRefreshResult {
        let secrets = try provider.readSecrets()
        let index = try ActiveCredentialIndex(
            secrets: secrets,
            hmacKey: keyStore.hmacKey(),
            provider: "1password",
            createdAt: now()
        )
        let cache = index.cache
        try cacheStore.save(cache)
        return ActiveCredentialRefreshResult(index: index, cache: cache)
    }
}
