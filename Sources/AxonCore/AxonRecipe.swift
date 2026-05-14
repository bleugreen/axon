import Foundation
import Yams

public enum AxonRecipeError: Error, CustomStringConvertible, Equatable {
    case invalidFormat(String)

    public var description: String {
        switch self {
        case let .invalidFormat(message):
            return message
        }
    }
}

public struct AxonRecipe: Equatable, Sendable {
    public var version: Int
    public var args: [AxonRecipeArgument]
    public var blocks: [AxonRecipeBlock]
    public var editorMetadata: AxonRecipeEditorMetadata
    public var unknownTopLevelFields: [String: JSONValue]

    public init(
        version: Int = 1,
        args: [AxonRecipeArgument] = [],
        blocks: [AxonRecipeBlock] = [],
        editorMetadata: AxonRecipeEditorMetadata = AxonRecipeEditorMetadata(),
        unknownTopLevelFields: [String: JSONValue] = [:]
    ) {
        self.version = version
        self.args = args
        self.blocks = blocks
        self.editorMetadata = editorMetadata
        self.unknownTopLevelFields = unknownTopLevelFields
    }

    public init(source: String) throws {
        let editorMetadata = AxonRecipeEditorMetadata.parseLeadingComment(in: source)
        let value = try ActionBatchExecutor.parseSource(source)
        try self.init(jsonValue: value, editorMetadata: editorMetadata)
    }

    public init(
        jsonValue: JSONValue,
        editorMetadata: AxonRecipeEditorMetadata = AxonRecipeEditorMetadata()
    ) throws {
        guard case var .object(object) = jsonValue else {
            throw AxonRecipeError.invalidFormat("recipe must be an object")
        }
        let version: Int
        switch object.removeValue(forKey: "version") {
        case let .int(value):
            version = value
        case let .string(value):
            guard let parsed = Int(value) else {
                throw AxonRecipeError.invalidFormat("version must be an integer")
            }
            version = parsed
        case nil:
            version = 1
        default:
            throw AxonRecipeError.invalidFormat("version must be an integer")
        }

        let args = try Self.parseArgs(object.removeValue(forKey: "args"))
        let blocks = try Self.parseBlocks(object.removeValue(forKey: "actions"))

        self.init(
            version: version,
            args: args,
            blocks: blocks,
            editorMetadata: editorMetadata,
            unknownTopLevelFields: object
        )
    }

    public mutating func assignMissingBlockIDs(prefix: String = "b") {
        var usedIDs = Set(blocks.compactMap(\.id))
        var nextID = 1

        for index in blocks.indices where blocks[index].id == nil {
            var id: String
            repeat {
                id = "\(prefix)\(String(format: "%03d", nextID))"
                nextID += 1
            } while usedIDs.contains(id)
            blocks[index].id = id
            usedIDs.insert(id)
        }
    }

    public var jsonValue: JSONValue {
        var object = unknownTopLevelFields
        object["version"] = .int(version)
        if !args.isEmpty {
            object["args"] = .array(args.map(\.jsonValue))
        }
        object["actions"] = .array(blocks.map(\.jsonValue))
        return .object(object)
    }

    public func yamlString(includeEditorMetadata: Bool = true) throws -> String {
        var output = ""
        if includeEditorMetadata, let comment = editorMetadata.commentLine() {
            output += comment
            output += "\n"
        }
        output += try Yams.serialize(node: Self.yamlNode(from: jsonValue, context: .topLevel), sortKeys: false)
        return output
    }

    private static func parseArgs(_ value: JSONValue?) throws -> [AxonRecipeArgument] {
        guard let value, value != .null else {
            return []
        }
        guard case let .array(values) = value else {
            throw AxonRecipeError.invalidFormat("args must be an array")
        }
        return try values.enumerated().map { index, value in
            guard case let .object(object) = value else {
                throw AxonRecipeError.invalidFormat("args[\(index)] must be an object")
            }
            return AxonRecipeArgument(fields: object)
        }
    }

    private static func parseBlocks(_ value: JSONValue?) throws -> [AxonRecipeBlock] {
        guard let value, value != .null else {
            return []
        }
        guard case let .array(values) = value else {
            throw AxonRecipeError.invalidFormat("actions must be an array")
        }
        return try values.enumerated().map { index, value in
            guard case let .object(object) = value else {
                throw AxonRecipeError.invalidFormat("actions[\(index)] must be an object")
            }
            if object["tool"] == nil, object["note"] != nil {
                return .note(AxonRecipeNote(fields: object))
            }
            return .action(AxonRecipeAction(fields: object))
        }
    }
}

public struct AxonRecipeArgument: Equatable, Sendable {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public var name: String? {
        string("name")
    }

    public var type: String? {
        string("type")
    }

    public var source: String? {
        string("source")
    }

    public var jsonValue: JSONValue {
        .object(fields)
    }

    private func string(_ key: String) -> String? {
        guard case let .string(value)? = fields[key], !value.isEmpty else {
            return nil
        }
        return value
    }
}

public enum AxonRecipeBlock: Equatable, Sendable {
    case action(AxonRecipeAction)
    case note(AxonRecipeNote)

    public var id: String? {
        get {
            switch self {
            case let .action(action):
                return action.id
            case let .note(note):
                return note.id
            }
        }
        set {
            switch self {
            case var .action(action):
                action.id = newValue
                self = .action(action)
            case var .note(note):
                note.id = newValue
                self = .note(note)
            }
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case let .action(action):
            return action.jsonValue
        case let .note(note):
            return note.jsonValue
        }
    }
}

public struct AxonRecipeAction: Equatable, Sendable {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public var id: String? {
        get {
            string("id")
        }
        set {
            setOptionalString(newValue, forKey: "id")
        }
    }

    public var tool: String? {
        string("tool")
    }

    public var jsonValue: JSONValue {
        .object(fields)
    }

    private func string(_ key: String) -> String? {
        guard case let .string(value)? = fields[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    private mutating func setOptionalString(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty {
            fields[key] = .string(value)
        } else {
            fields.removeValue(forKey: key)
        }
    }
}

public struct AxonRecipeNote: Equatable, Sendable {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public var id: String? {
        get {
            string("id")
        }
        set {
            setOptionalString(newValue, forKey: "id")
        }
    }

    public var text: String? {
        get {
            string("note")
        }
        set {
            setOptionalString(newValue, forKey: "note")
        }
    }

    public var jsonValue: JSONValue {
        .object(fields)
    }

    private func string(_ key: String) -> String? {
        guard case let .string(value)? = fields[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    private mutating func setOptionalString(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty {
            fields[key] = .string(value)
        } else {
            fields.removeValue(forKey: key)
        }
    }
}

public struct AxonRecipeEditorMetadata: Equatable, Sendable {
    public var breakpoints: [String]
    public var notes: [String: String]
    public var unknownFields: [String: JSONValue]

    public init(
        breakpoints: [String] = [],
        notes: [String: String] = [:],
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.breakpoints = breakpoints
        self.notes = notes
        self.unknownFields = unknownFields
    }

    public var isEmpty: Bool {
        breakpoints.isEmpty && notes.isEmpty && unknownFields.isEmpty
    }

    public static func parseLeadingComment(in source: String) -> AxonRecipeEditorMetadata {
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }
            guard trimmed.hasPrefix("#") else {
                return AxonRecipeEditorMetadata()
            }
            guard let range = trimmed.range(of: "axon-editor:") else {
                continue
            }
            let metadataSource = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return parse(metadataSource)
        }
        return AxonRecipeEditorMetadata()
    }

    public func commentLine() -> String? {
        guard !isEmpty else {
            return nil
        }
        var object = unknownFields
        if !breakpoints.isEmpty {
            object["breakpoints"] = .array(breakpoints.map(JSONValue.string))
        }
        if !notes.isEmpty {
            object["notes"] = .object(notes.mapValues(JSONValue.string))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(object)),
              let encoded = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return "# axon-editor: \(encoded)"
    }

    private static func parse(_ source: String) -> AxonRecipeEditorMetadata {
        let value: JSONValue?
        if let data = source.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            value = decoded
        } else if let loaded = try? Yams.load(yaml: source),
                  let decoded = try? AxonRecipeYAML.jsonValue(from: loaded) {
            value = decoded
        } else {
            value = nil
        }
        guard case var .object(object)? = value else {
            return AxonRecipeEditorMetadata()
        }

        let breakpoints: [String]
        if case let .array(values)? = object.removeValue(forKey: "breakpoints") {
            breakpoints = values.compactMap { value in
                guard case let .string(string) = value, !string.isEmpty else {
                    return nil
                }
                return string
            }
        } else {
            breakpoints = []
        }

        let notes: [String: String]
        if case let .object(noteValues)? = object.removeValue(forKey: "notes") {
            notes = noteValues.compactMapValues { value in
                guard case let .string(string) = value else {
                    return nil
                }
                return string
            }
        } else {
            notes = [:]
        }

        return AxonRecipeEditorMetadata(
            breakpoints: breakpoints,
            notes: notes,
            unknownFields: object
        )
    }
}

private enum AxonRecipeYAML {
    enum Context {
        case topLevel
        case argument
        case block
        case generic
    }

    static func jsonValue(from value: Any?) throws -> JSONValue {
        guard let value else {
            return .null
        }
        switch value {
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .int(value)
        case let value as Double:
            return .double(value)
        case let value as [Any?]:
            return .array(try value.map(jsonValue(from:)))
        case let value as [Any]:
            return .array(try value.map { try jsonValue(from: $0) })
        case let value as [String: Any?]:
            return .object(try value.mapValues { try jsonValue(from: $0) })
        case let value as [String: Any]:
            return .object(try value.mapValues { try jsonValue(from: $0) })
        default:
            throw AxonRecipeError.invalidFormat("unsupported YAML value: \(type(of: value))")
        }
    }
}

private extension AxonRecipe {
    static func yamlNode(from value: JSONValue, context: AxonRecipeYAML.Context = .generic) -> Node {
        switch value {
        case let .string(value):
            return .scalar(value.represented())
        case let .int(value):
            return .scalar(value.represented())
        case let .double(value):
            return .scalar(value.represented())
        case let .bool(value):
            return .scalar(value.represented())
        case .null:
            return .scalar(NSNull().represented())
        case let .array(values):
            return Node(values.map { child in
                yamlNode(from: child, context: context)
            }, Tag(.seq))
        case let .object(object):
            return Node(orderedKeys(for: object, context: context).map { key in
                let childContext: AxonRecipeYAML.Context
                switch (context, key) {
                case (.topLevel, "args"):
                    childContext = .argument
                case (.topLevel, "actions"):
                    childContext = .block
                default:
                    childContext = .generic
                }
                return (Node(key), yamlNode(from: object[key] ?? .null, context: childContext))
            }, Tag(.map))
        }
    }

    static func orderedKeys(for object: [String: JSONValue], context: AxonRecipeYAML.Context) -> [String] {
        object.keys.sorted { lhs, rhs in
            let lhsPriority = keyPriority(lhs, context: context)
            let rhsPriority = keyPriority(rhs, context: context)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs < rhs
        }
    }

    static func keyPriority(_ key: String, context: AxonRecipeYAML.Context) -> Int {
        switch context {
        case .topLevel:
            switch key {
            case "version":
                return 0
            case "args":
                return 1
            case "actions":
                return 2
            default:
                return 100
            }
        case .argument:
            switch key {
            case "name":
                return 0
            case "type":
                return 1
            case "description":
                return 2
            case "default":
                return 3
            case "source":
                return 4
            default:
                return 100
            }
        case .block:
            switch key {
            case "id":
                return 0
            case "note":
                return 1
            case "tool":
                return 2
            case "app":
                return 3
            case "target", "from", "to":
                return 4
            case "locator":
                return 5
            case "name", "value", "keys":
                return 6
            case "deltaX", "deltaY", "durationMs":
                return 7
            case "requires":
                return 8
            case "expects":
                return 9
            case "observed":
                return 10
            case "warnings":
                return 11
            case "resolve":
                return 12
            default:
                return 100
            }
        case .generic:
            return 100
        }
    }
}
