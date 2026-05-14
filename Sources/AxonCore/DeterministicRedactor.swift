import Foundation

public struct DeterministicRedactionContext: Equatable, Sendable {
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let description: String?
    public let help: String?
    public let identifier: String?

    public init(
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        help: String? = nil,
        identifier: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.help = help
        self.identifier = identifier
    }

    public init(node: AXNode) {
        self.init(
            role: node.role,
            subrole: node.subrole,
            title: node.title,
            value: node.value,
            description: node.description,
            help: node.help,
            identifier: node.identifier
        )
    }
}

public struct DeterministicRuleMatch: Equatable, Sendable {
    public let rule: String
    public let version: Int
    public let tag: String

    public init(rule: String, version: Int, tag: String) {
        self.rule = rule
        self.version = version
        self.tag = tag
    }

    public var jsonValue: JSONValue {
        .object([
            "rule": .string(rule),
            "version": .int(version),
            "tag": .string(tag)
        ])
    }
}

public struct DeterministicRedaction: Equatable, Sendable {
    public let value: String
    public let displayTag: String
    public let matches: [DeterministicRuleMatch]

    public init(displayTag: String, matches: [DeterministicRuleMatch]) {
        self.value = "<redacted: \(displayTag)>"
        self.displayTag = displayTag
        self.matches = matches
    }
}

public struct DeterministicRedactor: Sendable {
    public static let standard = DeterministicRedactor()
    public static let ruleLibraryVersion = "deterministic-redaction-v1"

    public init() {}

    public func redaction(
        for field: String,
        value: String,
        context: DeterministicRedactionContext = DeterministicRedactionContext()
    ) -> DeterministicRedaction? {
        guard !value.isEmpty else {
            return nil
        }

        var matches = roleMatches(for: field, context: context)
        matches.append(contentsOf: patternMatches(in: value))
        guard !matches.isEmpty else {
            return nil
        }
        return DeterministicRedaction(
            displayTag: strongestTag(in: matches),
            matches: matches
        )
    }

    private func roleMatches(
        for field: String,
        context: DeterministicRedactionContext
    ) -> [DeterministicRuleMatch] {
        guard field == "value" else {
            return []
        }
        var matches: [DeterministicRuleMatch] = []
        if context.role == "AXSecureTextField" || context.role?.localizedCaseInsensitiveContains("secure") == true {
            matches.append(DeterministicRuleMatch(
                rule: "ax-secure-text-field",
                version: 1,
                tag: RedactionTag.authCredential.rawValue
            ))
        }
        if hasSecretLabel(in: context) {
            matches.append(DeterministicRuleMatch(
                rule: "secret-label-value",
                version: 1,
                tag: RedactionTag.authCredential.rawValue
            ))
        }
        return matches
    }

    private func patternMatches(in value: String) -> [DeterministicRuleMatch] {
        var matches: [DeterministicRuleMatch] = []
        for rule in Self.regexRules where rule.matches(value) {
            matches.append(DeterministicRuleMatch(
                rule: rule.name,
                version: rule.version,
                tag: rule.tag.rawValue
            ))
        }
        if containsLuhnValidCard(value) {
            matches.append(DeterministicRuleMatch(
                rule: "luhn-credit-card",
                version: 1,
                tag: RedactionTag.financialData.rawValue
            ))
        }
        return matches
    }

    private func strongestTag(in matches: [DeterministicRuleMatch]) -> String {
        matches
            .map(\.tag)
            .max { lhs, rhs in tagStrength(lhs) < tagStrength(rhs) }
            ?? RedactionTag.piiIdentifier.rawValue
    }

    private func tagStrength(_ tag: String) -> Int {
        switch tag {
        case RedactionTag.authCredential.rawValue:
            return 3
        case RedactionTag.financialData.rawValue:
            return 2
        case RedactionTag.piiIdentifier.rawValue:
            return 1
        default:
            return 0
        }
    }

    private func hasSecretLabel(in context: DeterministicRedactionContext) -> Bool {
        [
            context.title,
            context.description,
            context.help,
            context.identifier
        ]
            .compactMap { $0?.normalizedRedactionLabel }
            .contains { label in
                Self.secretLabelNeedles.contains { label.contains($0) }
            }
    }

    private func containsLuhnValidCard(_ value: String) -> Bool {
        Self.cardCandidateRegex.matches(in: value).contains { range in
            let candidate = String(value[range])
            let digits = candidate.filter(\.isNumber)
            guard (13...19).contains(digits.count), !isObviouslyMasked(candidate) else {
                return false
            }
            return luhnValid(digits)
        }
    }

    private func isObviouslyMasked(_ value: String) -> Bool {
        value.contains("*") || value.contains("\u{2022}") || value.localizedCaseInsensitiveContains("x")
    }

    private func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var doubleDigit = false
        for digit in digits.reversed() {
            guard var value = digit.wholeNumberValue else {
                return false
            }
            if doubleDigit {
                value *= 2
                if value > 9 {
                    value -= 9
                }
            }
            sum += value
            doubleDigit.toggle()
        }
        return sum > 0 && sum % 10 == 0
    }

    private static let secretLabelNeedles = [
        "password",
        "passcode",
        "secret",
        "token",
        "private key",
        "recovery code",
        "recovery key",
        "api key",
        "seed phrase",
        "credential",
        "access key",
        "auth key"
    ]

    private static let regexRules: [RegexRule] = [
        RegexRule(
            name: "ssn",
            version: 1,
            tag: .piiIdentifier,
            pattern: #"\b\d{3}-\d{2}-\d{4}\b"#
        ),
        RegexRule(
            name: "phone-number",
            version: 1,
            tag: .piiIdentifier,
            pattern: #"(?<!\d)(?:\+1[\s.-]?)?(?:\([2-9]\d{2}\)|[2-9]\d{2})[\s.-]?[2-9]\d{2}[\s.-]?\d{4}(?!\d)"#
        ),
        RegexRule(
            name: "email-address",
            version: 1,
            tag: .piiIdentifier,
            pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            options: [.caseInsensitive]
        ),
        RegexRule(
            name: "github-token",
            version: 1,
            tag: .authCredential,
            pattern: #"\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,})\b"#
        ),
        RegexRule(
            name: "openai-api-key",
            version: 1,
            tag: .authCredential,
            pattern: #"\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}\b"#
        ),
        RegexRule(
            name: "slack-token",
            version: 1,
            tag: .authCredential,
            pattern: #"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"#
        ),
        RegexRule(
            name: "aws-access-key",
            version: 1,
            tag: .authCredential,
            pattern: #"\bAKIA[0-9A-Z]{16}\b"#
        ),
        RegexRule(
            name: "jwt",
            version: 1,
            tag: .authCredential,
            pattern: #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#
        ),
        RegexRule(
            name: "pem-private-key",
            version: 1,
            tag: .authCredential,
            pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#
        ),
        RegexRule(
            name: "long-hex-secret",
            version: 1,
            tag: .authCredential,
            pattern: #"\b[A-Fa-f0-9]{32,}\b"#
        ),
        RegexRule(
            name: "long-token",
            version: 1,
            tag: .authCredential,
            pattern: #"\b(?=[A-Za-z0-9_+/=-]{40,}\b)(?=[A-Za-z0-9_+/=-]*[A-Za-z])(?=[A-Za-z0-9_+/=-]*\d)(?:[A-Za-z0-9_+/=-]*[_+/=-]|[A-Za-z0-9_+/=-]{48,})[A-Za-z0-9_+/=-]*\b"#
        )
    ]

    private static let cardCandidateRegex = CompiledRegex(#"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#)
}

private enum RedactionTag: String, Sendable {
    case authCredential = "auth-credential"
    case financialData = "financial-data"
    case piiIdentifier = "pii-identifier"
}

private struct RegexRule: Sendable {
    let name: String
    let version: Int
    let tag: RedactionTag
    let regex: CompiledRegex

    init(
        name: String,
        version: Int,
        tag: RedactionTag,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) {
        self.name = name
        self.version = version
        self.tag = tag
        self.regex = CompiledRegex(pattern, options: options)
    }

    func matches(_ value: String) -> Bool {
        regex.firstMatch(in: value) != nil
    }
}

private final class CompiledRegex: @unchecked Sendable {
    private let regex: NSRegularExpression

    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        self.regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func firstMatch(in value: String) -> Range<String.Index>? {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let stringRange = Range(match.range, in: value)
        else {
            return nil
        }
        return stringRange
    }

    func matches(in value: String) -> [Range<String.Index>] {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex
            .matches(in: value, range: range)
            .compactMap { Range($0.range, in: value) }
    }
}

private extension String {
    var normalizedRedactionLabel: String {
        lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    @discardableResult
    mutating func addRedactedString(
        _ key: String,
        _ value: String?,
        activeSecretRedactor: ActiveSecretRedactor = ActiveSecretRedactor(),
        deterministicRedactor: DeterministicRedactor = DeterministicRedactor.standard,
        redactionContext: DeterministicRedactionContext = DeterministicRedactionContext(),
        redactionScope _: String? = nil
    ) -> Bool {
        guard let value else {
            self[key] = .null
            return false
        }
        if addActiveSecretRedactedString(
            key,
            value,
            activeSecretRedactor: activeSecretRedactor
        ) {
            return true
        }
        guard let redaction = deterministicRedactor.redaction(
            for: key,
            value: value,
            context: redactionContext
        ) else {
            self[key] = .string(value)
            return false
        }
        self[key] = .string(redaction.value)
        addDeterministicRedactionMetadata(field: key, redaction: redaction)
        return true
    }

    mutating func addDeterministicRedactionMetadata(field: String, redaction: DeterministicRedaction) {
        var fields: [JSONValue] = []
        var reasons: [String: JSONValue] = [:]
        var matched: [String: JSONValue] = [:]
        var metadata: [String: JSONValue] = [:]

        if case let .object(existing)? = self["redaction"] {
            metadata = existing
            if case let .array(existingFields)? = existing["fields"] {
                fields = existingFields
            }
            if case let .object(existingReasons)? = existing["reasons"] {
                reasons = existingReasons
            }
            if case let .object(existingMatched)? = existing["matched"] {
                matched = existingMatched
            }
        }

        if !fields.contains(.string(field)) {
            fields.append(.string(field))
        }
        reasons[field] = .string(redaction.displayTag)
        matched[field] = .array(redaction.matches.map(\.jsonValue))
        metadata["fields"] = .array(fields)
        metadata["reasons"] = .object(reasons)
        metadata["matched"] = .object(matched)
        metadata["ruleLibrary"] = .string(DeterministicRedactor.ruleLibraryVersion)
        self["redaction"] = .object(metadata)
    }
}
