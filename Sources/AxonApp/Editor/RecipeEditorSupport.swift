import AxonCore
import Foundation

func parameterTokenNames(in value: String) -> [String] {
    let pattern = #"\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.matches(in: value, range: range).compactMap { match in
        guard let nameRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[nameRange])
    }
}

extension AxonRecipeAction {
    mutating func setEditableString(value: String, forKey key: String) {
        if value.isEmpty {
            fields.removeValue(forKey: key)
            return
        }

        switch fields[key] {
        case .int:
            fields[key] = Int(value).map(JSONValue.int) ?? .string(value)
        case .double:
            fields[key] = Double(value).map(JSONValue.double) ?? .string(value)
        case .bool:
            if value == "true" {
                fields[key] = .bool(true)
            } else if value == "false" {
                fields[key] = .bool(false)
            } else {
                fields[key] = .string(value)
            }
        default:
            fields[key] = .string(value)
        }
    }
}

extension AxonRecipe {
    var inputNames: [String] {
        args.compactMap { arg in
            guard case let .string(name)? = arg.fields["name"], !name.isEmpty else {
                return nil
            }
            return name
        }
    }

    var primaryAppName: String? {
        var apps: Set<String> = []
        for block in blocks {
            guard case let .action(action) = block else {
                continue
            }
            apps.formUnion(action.knownApps)
        }
        return apps.sorted().first
    }
}

extension AxonRecipeAction {
    var knownApps: Set<String> {
        var apps: Set<String> = []
        for key in ["app"] {
            if case let .string(app)? = fields[key], !app.isEmpty {
                apps.insert(app)
            }
        }
        for key in ["target", "from", "to", "locator"] {
            if let app = fields[key]?.embeddedAppName {
                apps.insert(app)
            }
        }
        return apps
    }
}

extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else {
            return nil
        }
        return values
    }

    var editableString: String {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case .null:
            return ""
        case .array, .object:
            return compactDescription
        }
    }

    var compactLiteral: String {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case .null:
            return ""
        case .array, .object:
            return compactDescription
        }
    }

    var compactDescription: String {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case .null:
            return "null"
        case let .array(values):
            return "[\(values.map(\.compactDescription).joined(separator: ", "))]"
        case let .object(object):
            return "{\(object.keys.sorted().joined(separator: ", "))}"
        }
    }

    var embeddedAppName: String? {
        guard case let .object(object) = self else {
            return nil
        }
        if case let .string(app)? = object["app"], !app.isEmpty {
            return app
        }
        if case let .object(location)? = object["location"],
           case let .string(app)? = location["app"],
           !app.isEmpty {
            return app
        }
        return nil
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(_ key: String) -> String? {
        guard case let .string(value)? = self[key], !value.isEmpty else {
            return nil
        }
        return value
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    func splitBeforeCapitals() -> String {
        var output = ""
        for character in self {
            if character.isUppercase, !output.isEmpty {
                output.append(" ")
            }
            output.append(character)
        }
        return output
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
