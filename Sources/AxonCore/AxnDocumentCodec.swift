import Foundation
import Yams

enum AxnDocumentCodec {
    enum Context {
        case topLevel
        case argument
        case block
        case generic
    }

    static func parseSource(_ source: String) throws -> JSONValue {
        if let data = source.data(using: .utf8),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return json
        }
        let loaded = try Yams.load(yaml: source)
        return try jsonValue(from: loaded)
    }

    static func yamlString(from value: JSONValue, context: Context = .topLevel) throws -> String {
        try Yams.serialize(node: yamlNode(from: value, context: context), sortKeys: false)
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

    static func yamlNode(from value: JSONValue, context: Context = .generic) -> Node {
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
                let childContext: Context
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

    static func orderedKeys(for object: [String: JSONValue], context: Context) -> [String] {
        object.keys.sorted { lhs, rhs in
            let lhsPriority = keyPriority(lhs, context: context)
            let rhsPriority = keyPriority(rhs, context: context)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs < rhs
        }
    }

    static func keyPriority(_ key: String, context: Context) -> Int {
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
