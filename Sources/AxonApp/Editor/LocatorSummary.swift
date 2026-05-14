import AxonCore
import SwiftUI

struct LocatorSummary: Equatable {
    let intentName: String?
    let contextLine: String?
    let provenance: String?

    init(target: JSONValue?) {
        guard let target else {
            intentName = nil
            contextLine = nil
            provenance = nil
            return
        }

        switch target {
        case let .string(value):
            intentName = value.nilIfEmpty
            contextLine = value.nilIfEmpty
            provenance = nil
        case let .object(object):
            let app = object.stringValue("app")
            if case let .object(locator)? = object["locator"] {
                let locatorSummary = Self.locatorSummary(locator)
                intentName = locatorSummary.intentName
                contextLine = [app, locatorSummary.contextName].compactMap { $0?.nilIfEmpty }.joined(separator: " - ").nilIfEmpty
                provenance = locatorSummary.provenance
            } else if case let .object(point)? = object["point"] {
                let pointName = "point \(point["x"]?.compactLiteral ?? "?"), \(point["y"]?.compactLiteral ?? "?")"
                intentName = pointName
                contextLine = [app, pointName].compactMap { $0?.nilIfEmpty }.joined(separator: " - ").nilIfEmpty
                provenance = nil
            } else if case let .object(location)? = object["location"] {
                let locationName = location.stringValue("text") ?? "text location"
                intentName = locationName
                contextLine = [location.stringValue("app") ?? app, locationName].compactMap { $0?.nilIfEmpty }.joined(separator: " - ").nilIfEmpty
                provenance = nil
            } else {
                intentName = target.compactDescription
                contextLine = app
                provenance = nil
            }
        default:
            intentName = target.compactDescription
            contextLine = target.compactDescription
            provenance = nil
        }
    }

    private static func locatorSummary(_ locator: [String: JSONValue]) -> (intentName: String?, contextName: String?, provenance: String?) {
        let role = locator.stringValue("role")
        let noun = role.map(roleNoun)
        let namedValue = firstMatcherValue(in: locator, keys: ["label", "title", "value", "identifier", "description"])
        let intentName: String?
        if let namedValue, let noun {
            intentName = "\(namedValue) \(noun)"
        } else {
            intentName = namedValue ?? noun
        }

        var provenanceParts: [String] = []
        if let role {
            provenanceParts.append(role)
        }
        for key in ["label", "title", "value", "identifier", "description"] {
            if let description = matcherDescription(locator[key], key: key) {
                provenanceParts.append(description)
                break
            }
        }

        return (
            intentName: intentName,
            contextName: intentName,
            provenance: provenanceParts.isEmpty ? nil : "Captured locator: \(provenanceParts.joined(separator: ", "))"
        )
    }

    private static func roleNoun(_ role: String) -> String {
        switch role {
        case "AXButton":
            return "button"
        case "AXTextField", "AXTextArea":
            return "field"
        case "AXMenuButton":
            return "menu button"
        case "AXMenuItem":
            return "menu item"
        case "AXLink":
            return "link"
        case "AXCheckBox":
            return "checkbox"
        case "AXRadioButton":
            return "radio button"
        case "AXPopUpButton":
            return "popup"
        case "AXWindow":
            return "window"
        default:
            if role.hasPrefix("AX") {
                return String(role.dropFirst(2)).splitBeforeCapitals().lowercased()
            }
            return role
        }
    }

    private static func firstMatcherValue(in locator: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = matcherValue(locator[key]) {
                return value
            }
        }
        return nil
    }

    private static func matcherValue(_ value: JSONValue?) -> String? {
        guard let value else {
            return nil
        }
        switch value {
        case let .string(text):
            return text.nilIfEmpty
        case let .object(object):
            for key in ["equals", "contains", "prefix", "suffix", "regex"] {
                if case let .string(text)? = object[key], !text.isEmpty {
                    return text
                }
            }
            return nil
        default:
            return value.compactLiteral.nilIfEmpty
        }
    }

    private static func matcherDescription(_ value: JSONValue?, key: String) -> String? {
        guard let value else {
            return nil
        }
        switch value {
        case let .string(text):
            return text.isEmpty ? nil : "\(key) \(text)"
        case let .object(object):
            for matcher in ["equals", "contains", "prefix", "suffix", "regex"] {
                if case let .string(text)? = object[matcher], !text.isEmpty {
                    return "\(key) \(matcher) \(text)"
                }
            }
            return nil
        default:
            let literal = value.compactLiteral
            return literal.isEmpty ? nil : "\(key) \(literal)"
        }
    }
}

struct LocatorSummaryView: View {
    let title: String
    let target: JSONValue?
    var optional = false

    var body: some View {
        let summary = LocatorSummary(target: target)
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "scope")
                    .foregroundStyle(.secondary)
                Text(summary.contextLine ?? (optional ? "No specific target" : "Missing target"))
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let provenance = summary.provenance {
                DisclosureGroup("Recorded locator") {
                    Text(provenance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
                .font(.caption)
            }
        }
    }
}
