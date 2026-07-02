import ApplicationServices
import Foundation

public struct ReadableAXState: Equatable, Sendable {
    public let fields: [String: String]

    public init(fields: [String: String]) {
        self.fields = fields.filter { !$0.value.isEmpty }
    }

    public init(element: AXUIElement) {
        self.init(fields: [
            "value": Self.stringAttribute(kAXValueAttribute, from: element),
            "title": Self.stringAttribute(kAXTitleAttribute, from: element),
            "description": Self.stringAttribute(kAXDescriptionAttribute, from: element),
            "identifier": Self.stringAttribute("AXIdentifier", from: element),
            "help": Self.stringAttribute(kAXHelpAttribute, from: element)
        ].compactMapValues { $0 })
    }

    public var jsonValue: JSONValue {
        .object(fields.mapValues(JSONValue.string))
    }

    public func firstMatch(using predicate: WaitValuePredicate) -> WaitValueMatch? {
        for field in Self.matchFieldOrder {
            guard let value = fields[field], predicate.matches(value) else {
                continue
            }
            return WaitValueMatch(field: field, value: value)
        }
        for field in fields.keys.sorted() where !Self.matchFieldOrder.contains(field) {
            guard let value = fields[field], predicate.matches(value) else {
                continue
            }
            return WaitValueMatch(field: field, value: value)
        }
        return nil
    }

    private static let matchFieldOrder = ["value", "title", "description", "identifier", "help"]

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw
        else {
            return nil
        }
        if let string = raw as? String {
            return string
        }
        if let number = raw as? NSNumber {
            return number.stringValue
        }
        return String(describing: raw)
    }
}

public enum WaitValuePredicate: Equatable, Sendable {
    case contains(String)
    case equals(String)
    case matches(String)

    public var jsonValue: JSONValue {
        switch self {
        case let .contains(value):
            return .object(["contains": .string(value)])
        case let .equals(value):
            return .object(["equals": .string(value)])
        case let .matches(value):
            return .object(["matches": .string(value)])
        }
    }

    public func matches(_ value: String) -> Bool {
        switch self {
        case let .contains(needle):
            return value.localizedStandardContains(needle)
        case let .equals(expected):
            return value == expected
        case let .matches(pattern):
            return value.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

public struct WaitValueMatch: Equatable, Sendable {
    public let field: String
    public let value: String

    public var jsonValue: JSONValue {
        .object([
            "field": .string(field),
            "value": .string(value)
        ])
    }
}
