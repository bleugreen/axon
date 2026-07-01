import Foundation
import Yams

public enum AxnParseError: Error, CustomStringConvertible, Equatable {
    case invalidFormat(String)

    public var description: String {
        switch self {
        case let .invalidFormat(message):
            return message
        }
    }
}

public struct Axn: Equatable, Sendable {
    public var version: Int
    public var args: [AxnArgument]
    public var blocks: [AxnBlock]
    public var editorMetadata: AxnEditorMetadata
    public var unknownTopLevelFields: [String: JSONValue]

    public init(
        version: Int = 1,
        args: [AxnArgument] = [],
        blocks: [AxnBlock] = [],
        editorMetadata: AxnEditorMetadata = AxnEditorMetadata(),
        unknownTopLevelFields: [String: JSONValue] = [:]
    ) {
        self.version = version
        self.args = args
        self.blocks = blocks
        self.editorMetadata = editorMetadata
        self.unknownTopLevelFields = unknownTopLevelFields
    }

    public init(source: String) throws {
        let editorMetadata = AxnEditorMetadata.parseLeadingComment(in: source)
        let value = try AxnDocumentCodec.parseSource(source)
        try self.init(jsonValue: value, editorMetadata: editorMetadata)
    }

    public init(
        jsonValue: JSONValue,
        editorMetadata: AxnEditorMetadata = AxnEditorMetadata()
    ) throws {
        guard case var .object(object) = jsonValue else {
            throw AxnParseError.invalidFormat("axn file must be an object")
        }
        let version: Int
        switch object.removeValue(forKey: "version") {
        case let .int(value):
            version = value
        case let .string(value):
            guard let parsed = Int(value) else {
                throw AxnParseError.invalidFormat("version must be an integer")
            }
            version = parsed
        case nil:
            version = 1
        default:
            throw AxnParseError.invalidFormat("version must be an integer")
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

    public mutating func insertRecordedBlocks(_ recordedBlocks: [AxnBlock], beforeBlockID: String?) {
        let originalIDs = Set(blocks.compactMap(\.id))
        var usedIDs = originalIDs
        var nextID = 1
        var idMap: [String: String] = [:]
        var remappedBlocks: [AxnBlock] = []

        for var block in recordedBlocks {
            if let id = block.id {
                if usedIDs.contains(id) {
                    let replacement = nextAvailableBlockID(prefix: blockIDPrefix(id), usedIDs: &usedIDs, nextID: &nextID)
                    idMap[id] = replacement
                    block.id = replacement
                } else {
                    usedIDs.insert(id)
                }
            } else {
                block.id = nextAvailableBlockID(prefix: "a", usedIDs: &usedIDs, nextID: &nextID)
            }
            remappedBlocks.append(block)
        }

        if !idMap.isEmpty {
            remappedBlocks = remappedBlocks.map { Self.remappingReferences(in: $0, idMap: idMap) }
        }

        let insertionIndex: Int
        if let beforeBlockID,
           let index = blocks.firstIndex(where: { $0.id == beforeBlockID }) {
            insertionIndex = index
        } else {
            insertionIndex = blocks.endIndex
        }
        blocks.insert(contentsOf: remappedBlocks, at: insertionIndex)
    }

    private func nextAvailableBlockID(prefix: String, usedIDs: inout Set<String>, nextID: inout Int) -> String {
        while true {
            let id = "\(prefix)\(String(format: "%03d", nextID))"
            nextID += 1
            if !usedIDs.contains(id) {
                usedIDs.insert(id)
                return id
            }
        }
    }

    private func blockIDPrefix(_ id: String) -> String {
        let prefix = id.prefix { !$0.isNumber }
        return prefix.isEmpty ? "a" : String(prefix)
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
        output += try AxnDocumentCodec.yamlString(from: jsonValue, context: .topLevel)
        return output
    }

    private static func parseArgs(_ value: JSONValue?) throws -> [AxnArgument] {
        guard let value, value != .null else {
            return []
        }
        guard case let .array(values) = value else {
            throw AxnParseError.invalidFormat("args must be an array")
        }
        return try values.enumerated().map { index, value in
            guard case let .object(object) = value else {
                throw AxnParseError.invalidFormat("args[\(index)] must be an object")
            }
            return AxnArgument(fields: object)
        }
    }

    private static func parseBlocks(_ value: JSONValue?) throws -> [AxnBlock] {
        guard let value, value != .null else {
            return []
        }
        guard case let .array(values) = value else {
            throw AxnParseError.invalidFormat("actions must be an array")
        }
        return try values.enumerated().map { index, value in
            guard case let .object(object) = value else {
                throw AxnParseError.invalidFormat("actions[\(index)] must be an object")
            }
            if object["tool"] == nil, object["note"] != nil {
                return .note(AxnNote(fields: object))
            }
            return .action(AxnAction(fields: object))
        }
    }

    private static func remappingReferences(
        in block: AxnBlock,
        idMap: [String: String]
    ) -> AxnBlock {
        switch block {
        case var .action(action):
            action.fields = remappingReferences(in: action.fields, idMap: idMap)
            return .action(action)
        case var .note(note):
            note.fields = remappingReferences(in: note.fields, idMap: idMap)
            return .note(note)
        }
    }

    private static func remappingReferences(
        in object: [String: JSONValue],
        idMap: [String: String]
    ) -> [String: JSONValue] {
        var remapped = object
        if case let .array(requires)? = object["requires"] {
            remapped["requires"] = .array(requires.map { value in
                guard case let .string(reference) = value else {
                    return value
                }
                return .string(remappedReference(reference, idMap: idMap))
            })
        }
        if case let .array(expects)? = object["expects"] {
            remapped["expects"] = .array(expects.map { value in
                guard case var .object(fact) = value,
                      case let .string(id)? = fact["id"]
                else {
                    return value
                }
                fact["id"] = .string(remappedReference(id, idMap: idMap))
                return .object(fact)
            })
        }
        return remapped
    }

    private static func remappedReference(_ value: String, idMap: [String: String]) -> String {
        for (oldID, newID) in idMap {
            if value == oldID {
                return newID
            }
            if value.hasPrefix("\(oldID).") {
                return newID + value.dropFirst(oldID.count)
            }
        }
        return value
    }
}

public struct AxnArgument: Equatable, Sendable {
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

    public var argumentType: AxnArgumentType? {
        type.flatMap(AxnArgumentType.init(rawValue:))
    }

    public var defaultValue: JSONValue? {
        let value = fields["default"]
        return value == .null ? nil : value
    }

    public var source: String? {
        string("source")
    }

    public var sourceURL: URL? {
        source.flatMap(URL.init(string:))
    }

    public var jsonValue: JSONValue {
        .object(fields)
    }

    public static func validated(_ arguments: [AxnArgument]) throws -> [AxnArgument] {
        var seenNames: Set<String> = []
        return try arguments.enumerated().map { index, argument in
            guard let name = argument.name, isValidName(name) else {
                throw AxnRunError.invalidParams("args[\(index)] requires snake_case name")
            }
            guard seenNames.insert(name).inserted else {
                throw AxnRunError.invalidParams("duplicate arg: \(name)")
            }
            guard argument.argumentType != nil else {
                throw AxnRunError.invalidParams("args[\(index)] requires type")
            }
            if argument.argumentType == .secret, argument.defaultValue != nil {
                throw AxnRunError.invalidParams("secret arg cannot have default: \(name)")
            }
            if let sourceValue = argument.fields["source"], sourceValue != .null {
                guard case let .string(rawSource) = sourceValue,
                      let url = URL(string: rawSource),
                      url.scheme != nil
                else {
                    throw AxnRunError.invalidParams("arg \(name) source must be a URL")
                }
                _ = url
            }
            return argument
        }
    }

    private static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first >= "a",
              first <= "z"
        else {
            return false
        }
        return name.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "_"
        }
    }

    private func string(_ key: String) -> String? {
        guard case let .string(value)? = fields[key], !value.isEmpty else {
            return nil
        }
        return value
    }
}

public enum AxnBlock: Equatable, Sendable {
    case action(AxnAction)
    case note(AxnNote)

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

public struct AxnAction: Equatable, Sendable {
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

public struct AxnNote: Equatable, Sendable {
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

public struct AxnEditorMetadata: Equatable, Sendable {
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

    public static func parseLeadingComment(in source: String) -> AxnEditorMetadata {
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }
            guard trimmed.hasPrefix("#") else {
                return AxnEditorMetadata()
            }
            guard let range = trimmed.range(of: "axon-editor:") else {
                continue
            }
            let metadataSource = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return parse(metadataSource)
        }
        return AxnEditorMetadata()
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

    private static func parse(_ source: String) -> AxnEditorMetadata {
        let value: JSONValue?
        if let data = source.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            value = decoded
        } else if let loaded = try? Yams.load(yaml: source),
                  let decoded = try? AxnDocumentCodec.jsonValue(from: loaded) {
            value = decoded
        } else {
            value = nil
        }
        guard case var .object(object)? = value else {
            return AxnEditorMetadata()
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

        return AxnEditorMetadata(
            breakpoints: breakpoints,
            notes: notes,
            unknownFields: object
        )
    }
}
