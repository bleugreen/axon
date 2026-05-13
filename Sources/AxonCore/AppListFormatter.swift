import Foundation

public struct AppListFormatter {
    public init() {}

    public func observation(from result: [String: JSONValue]) -> JSONValue {
        observation(from: result["apps"])
    }

    public func observation(from value: JSONValue?) -> JSONValue {
        guard case let .array(apps)? = value else {
            return .object([
                "format": .string("app_list"),
                "count": .int(0),
                "apps": .array([])
            ])
        }

        var orderedNames: [String] = []
        var counts: [String: Int] = [:]
        for app in apps {
            guard case let .object(object) = app,
                  case let .string(name)? = object["name"],
                  !name.isEmpty
            else {
                continue
            }
            if counts[name] == nil {
                orderedNames.append(name)
            }
            counts[name, default: 0] += 1
        }

        let compactApps = orderedNames.map { name in
            var app: [String: JSONValue] = ["name": .string(name)]
            if let count = counts[name], count > 1 {
                app["count"] = .int(count)
            }
            return JSONValue.object(app)
        }

        return .object([
            "format": .string("app_list"),
            "count": .int(apps.count),
            "uniqueCount": .int(compactApps.count),
            "apps": .array(compactApps)
        ])
    }

    public func text(from observation: JSONValue) -> String {
        guard case let .object(object) = observation else {
            return "apps:"
        }

        let count = object["count"]?.scalarText ?? "0"
        let uniqueCount = object["uniqueCount"]?.scalarText
        var lines: [String] = []
        if let uniqueCount, uniqueCount != count {
            lines.append("apps: \(count) running, \(uniqueCount) names")
        } else {
            lines.append("apps: \(count)")
        }

        if case let .array(apps)? = object["apps"] {
            for app in apps {
                guard case let .object(object) = app,
                      case let .string(name)? = object["name"]
                else {
                    continue
                }
                if let count = object["count"]?.scalarText {
                    lines.append("- \(name) (\(count))")
                } else {
                    lines.append("- \(name)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

private extension JSONValue {
    var scalarText: String? {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case .object, .array, .null:
            return nil
        }
    }
}
