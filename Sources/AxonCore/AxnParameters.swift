import Foundation

public enum AxnArgumentType: String, Sendable {
    case string
    case secret
    case number
    case date
    case email
    case path
}

public struct ResolvedAxnArgument: Equatable, Sendable {
    public let value: String
    public let isSecret: Bool

    public init(value: String, isSecret: Bool) {
        self.value = value
        self.isSecret = isSecret
    }
}

public struct AxnArgumentReferenceSubstitution: Equatable, Sendable {
    public let value: String
    public let containsSecret: Bool

    public init(value: String, containsSecret: Bool) {
        self.value = value
        self.containsSecret = containsSecret
    }
}

public enum AxnArgumentReferenceSyntax {
    public static let substitutableStringFields: Set<String> = ["value", "keys"]

    private static let parameterReferenceRegex = try! NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}"#
    )
    private static let anyParameterReferenceRegex = try! NSRegularExpression(
        pattern: #"\{\{[^}]*\}\}"#
    )

    public static func containsReferenceSyntax(_ value: JSONValue) -> Bool {
        switch value {
        case let .string(value):
            return value.contains("{{")
                || value.contains("}}")
                || anyParameterReferenceRegex.firstMatch(
                    in: value,
                    range: NSRange(value.startIndex..<value.endIndex, in: value)
                ) != nil
        case let .array(values):
            return values.contains(where: containsReferenceSyntax)
        case let .object(object):
            return object.values.contains(where: containsReferenceSyntax)
        default:
            return false
        }
    }

    public static func substituteReferences(
        in template: String,
        resolved: [String: ResolvedAxnArgument]
    ) throws -> AxnArgumentReferenceSubstitution {
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        let matches = anyParameterReferenceRegex.matches(in: template, range: range)
        guard !matches.isEmpty else {
            if template.contains("{{") || template.contains("}}") {
                throw AxnRunError.invalidParams("invalid arg reference syntax: \(template)")
            }
            return AxnArgumentReferenceSubstitution(value: template, containsSecret: false)
        }

        var output = ""
        var currentIndex = template.startIndex
        var containsSecret = false

        for match in matches {
            guard let matchRange = Range(match.range, in: template),
                  let name = parameterReferenceName(in: String(template[matchRange]))
            else {
                throw AxnRunError.invalidParams("invalid arg reference syntax: \(template)")
            }
            let prefix = template[currentIndex..<matchRange.lowerBound]
            if prefix.contains("{{") || prefix.contains("}}") {
                throw AxnRunError.invalidParams("invalid arg reference syntax: \(template)")
            }
            output += prefix
            guard let parameter = resolved[name] else {
                throw AxnRunError.invalidParams("undeclared arg reference: \(name)")
            }
            output += parameter.value
            containsSecret = containsSecret || parameter.isSecret
            currentIndex = matchRange.upperBound
        }

        let suffix = template[currentIndex..<template.endIndex]
        if suffix.contains("{{") || suffix.contains("}}") {
            throw AxnRunError.invalidParams("invalid arg reference syntax: \(template)")
        }
        output += suffix
        return AxnArgumentReferenceSubstitution(value: output, containsSecret: containsSecret)
    }

    private static func parameterReferenceName(in token: String) -> String? {
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        guard let match = parameterReferenceRegex.firstMatch(in: token, range: range),
              match.range == range,
              let nameRange = Range(match.range(at: 1), in: token)
        else {
            return nil
        }
        return String(token[nameRange])
    }
}

public struct AxnArgumentResolver {
    public typealias SourceResolver = (URL) throws -> String?

    private let sourceResolvers: [String: SourceResolver]

    public init(sourceResolvers: [String: SourceResolver]) {
        self.sourceResolvers = sourceResolvers
    }

    public func resolve(
        _ arguments: [AxnArgument],
        callerArgValues: [String: JSONValue]
    ) throws -> [String: ResolvedAxnArgument] {
        let declarations = try AxnArgument.validated(arguments)
        guard !declarations.isEmpty else {
            if let unknown = callerArgValues.keys.sorted().first {
                throw AxnRunError.invalidParams("unknown arg: \(unknown)")
            }
            return [:]
        }

        let declaredNames = Set(declarations.map(\.name))
        if let unknown = callerArgValues.keys.sorted().first(where: { !declaredNames.contains($0) }) {
            throw AxnRunError.invalidParams("unknown arg: \(unknown)")
        }

        var resolved: [String: ResolvedAxnArgument] = [:]
        for declaration in declarations {
            guard let name = declaration.name, let argumentType = declaration.argumentType else {
                continue
            }
            if declaration.sourceURL != nil, callerArgValues[name] != nil {
                throw AxnRunError.invalidParams("caller arg cannot override sourced arg: \(name)")
            }

            let rawValue: JSONValue?
            if let callerValue = callerArgValues[name] {
                rawValue = callerValue
            } else if let source = declaration.sourceURL {
                rawValue = try resolveSource(source, name: name).map(JSONValue.string)
                    ?? declaration.defaultValue
            } else {
                rawValue = declaration.defaultValue
            }

            guard let rawValue else {
                throw AxnRunError.invalidParams("missing required arg: \(name)")
            }

            resolved[name] = ResolvedAxnArgument(
                value: try AxnArgumentValueCoercer.stringValue(rawValue, type: argumentType, name: name),
                isSecret: argumentType == .secret
            )
        }
        return resolved
    }

    private func resolveSource(_ source: URL, name: String) throws -> String? {
        guard let scheme = source.scheme, !scheme.isEmpty else {
            throw AxnRunError.invalidParams("arg \(name) source requires a scheme")
        }
        guard let resolver = sourceResolvers[scheme] else {
            throw AxnRunError.invalidParams("unsupported source scheme for arg \(name): \(scheme)")
        }
        return try resolver(source)
    }
}

public enum AxnArgumentValueCoercer {
    public static func stringValue(_ value: JSONValue, type: AxnArgumentType, name: String) throws -> String {
        switch type {
        case .string, .secret, .path:
            return try scalarString(value, name: name)
        case .email:
            let string = try scalarString(value, name: name)
            guard isValidEmail(string) else {
                throw AxnRunError.invalidParams("arg \(name) must be an email")
            }
            return string
        case .number:
            return try numberString(value, name: name)
        case .date:
            return try dateString(value, name: name)
        }
    }

    private static func scalarString(_ value: JSONValue, name: String) throws -> String {
        switch value {
        case let .string(value):
            return value
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .bool(value):
            return String(value)
        default:
            throw AxnRunError.invalidParams("arg \(name) must be a scalar")
        }
    }

    private static func numberString(_ value: JSONValue, name: String) throws -> String {
        switch value {
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .string(value):
            guard Double(value) != nil else {
                throw AxnRunError.invalidParams("arg \(name) must be a number")
            }
            return value
        default:
            throw AxnRunError.invalidParams("arg \(name) must be a number")
        }
    }

    private static func dateString(_ value: JSONValue, name: String) throws -> String {
        let string = try scalarString(value, name: name)
        switch string {
        case "today":
            return isoDateString(Date())
        case "yesterday":
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            return isoDateString(yesterday)
        default:
            guard isISODate(string) else {
                throw AxnRunError.invalidParams("arg \(name) must be an ISO date, today, or yesterday")
            }
            return string
        }
    }

    private static func isValidEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2
            && !parts[0].isEmpty
            && parts[1].contains(".")
            && !parts[1].hasPrefix(".")
            && !parts[1].hasSuffix(".")
    }

    private static func isISODate(_ value: String) -> Bool {
        guard value.count == 10 else {
            return false
        }
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2
        else {
            return false
        }
        return parts.allSatisfy { Int($0) != nil }
    }

    private static func isoDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public func axnEnvironmentName(from source: URL) -> String? {
    if let host = source.host, !host.isEmpty {
        return host
    }
    let path = source.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return path.isEmpty ? nil : path
}
