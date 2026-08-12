import Foundation

/// The command line's translation from argv into the wire parameters the daemon's router reads.
///
/// This lives beside `ToolSurfaceSpec` rather than inside `AxonCLI` because the two halves describe
/// one surface: the spec states what a tool's parameters are, and this states how a command line
/// spells them. Keeping the mapping in the library is also the only way it can be held to that
/// contract by a test. The router validates params at the wire and rejects a malformed object, but
/// nothing observes what the CLI actually packs, so a divergence between the two is invisible to
/// every MCP-side and router-side test — which is how the semantic-names cutover left `look`,
/// `invoke`, and `type` sending a bare string where the router requires an `{app,name}` object.
///
/// Every entry point takes the full argument vector with the command name still at index 0, which
/// is what `CommandLine.arguments.dropFirst()` yields.
public enum CLICommandParser {
    /// `look`'s parsed form: the wire params plus the flags that only affect local rendering.
    public struct LookCommand: Equatable {
        public let params: [String: JSONValue]
        public let frames: Bool
        public let json: Bool
        public let details: Bool
    }

    // MARK: - Perception

    public static func look(arguments: [String]) throws -> LookCommand {
        var params: [String: JSONValue] = [:]
        var frames = false
        var json = false
        var details = false
        var positional: String?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--since":
                guard index + 1 < arguments.count else {
                    throw CLIError.missingArguments("look --since requires a snapshot id")
                }
                params["since"] = .string(arguments[index + 1])
                index += 2
            case "--screenshot":
                params["screenshot"] = .bool(true)
                index += 1
            case "--no-screenshot":
                params["screenshot"] = .bool(false)
                index += 1
            case "--screen-text":
                params["screenText"] = .bool(true)
                index += 1
            case "--frames":
                frames = true
                index += 1
            case "--json":
                json = true
                index += 1
            case "--details", "--debug":
                details = true
                json = arguments[index] == "--debug"
                params["all"] = .bool(true)
                if arguments[index] == "--debug" {
                    params["format"] = .string("debug")
                }
                index += 1
            case "--no-tree":
                params["tree"] = .bool(false)
                index += 1
            case "--offset":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                    throw CLIError.missingArguments("look --offset requires an integer")
                }
                params["offset"] = .int(value)
                index += 2
            case "--limit":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                    throw CLIError.missingArguments("look --limit requires an integer")
                }
                params["limit"] = .int(value)
                index += 2
            case "--depth":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                    throw CLIError.missingArguments("look --depth requires an integer")
                }
                params["depth"] = .int(value)
                index += 2
            default:
                if positional == nil {
                    positional = arguments[index]
                    index += 1
                } else {
                    throw CLIError.missingArguments("unexpected look argument: \(arguments[index])")
                }
            }
        }
        if let positional {
            // The router reads two different parameters out of what the command line spells as one
            // positional: `app` names an app to observe, while `target` must be an {app,name}
            // object and pages that element's children. The shape of the argument picks which.
            if case let .object(object)? = try? decodeJSON(positional) {
                params["target"] = .object(object)
            } else {
                params["app"] = .string(positional)
            }
        }
        return LookCommand(params: params, frames: frames, json: json, details: details)
    }

    public static func find(arguments: [String]) throws -> [String: JSONValue] {
        guard arguments.count >= 3 else {
            throw CLIError.missingArguments("find requires an app and locator JSON")
        }
        return [
            "app": .string(arguments[1]),
            "locator": try decodeJSON(arguments.dropFirst(2).joined(separator: " "))
        ]
    }

    public static func waitForValue(arguments: [String]) throws -> [String: JSONValue] {
        guard arguments.count >= 4 else {
            throw CLIError.missingArguments("wait_for_value requires a target JSON and exactly one predicate")
        }
        var params: [String: JSONValue] = ["target": try decodeJSON(arguments[1])]
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--contains":
                guard index + 1 < arguments.count else { throw CLIError.missingArguments("wait_for_value --contains requires text") }
                params["contains"] = .string(arguments[index + 1])
                index += 2
            case "--equals":
                guard index + 1 < arguments.count else { throw CLIError.missingArguments("wait_for_value --equals requires text") }
                params["equals"] = .string(arguments[index + 1])
                index += 2
            case "--matches":
                guard index + 1 < arguments.count else { throw CLIError.missingArguments("wait_for_value --matches requires a regex") }
                params["matches"] = .string(arguments[index + 1])
                index += 2
            case "--timeout-ms":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                    throw CLIError.missingArguments("wait_for_value --timeout-ms requires an integer")
                }
                params["timeoutMs"] = .int(value)
                index += 2
            case "--interval-ms":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                    throw CLIError.missingArguments("wait_for_value --interval-ms requires an integer")
                }
                params["intervalMs"] = .int(value)
                index += 2
            default:
                throw CLIError.missingArguments("unexpected wait_for_value argument: \(arguments[index])")
            }
        }
        return params
    }

    public static func waitForStability(arguments: [String]) throws -> [String: JSONValue] {
        guard arguments.count >= 2 else { throw CLIError.missingArguments("wait_for_stability requires an app") }
        var params: [String: JSONValue] = ["app": .string(arguments[1])]
        var index = 2
        while index < arguments.count {
            let key: String
            switch arguments[index] {
            case "--condition": key = "condition"
            case "--stable-ms": key = "stableMs"
            case "--timeout-ms": key = "timeoutMs"
            case "--interval-ms": key = "intervalMs"
            default: throw CLIError.missingArguments("unexpected wait_for_stability argument: \(arguments[index])")
            }
            guard index + 1 < arguments.count else { throw CLIError.missingArguments("wait_for_stability \(arguments[index]) requires a value") }
            if key == "condition" {
                params[key] = .string(arguments[index + 1])
            } else if let value = Int(arguments[index + 1]) {
                params[key] = .int(value)
            } else {
                throw CLIError.missingArguments("wait_for_stability \(arguments[index]) requires an integer")
            }
            index += 2
        }
        return params
    }

    // MARK: - Actions

    public static func click(arguments: [String]) throws -> [String: JSONValue] {
        let (rest, policy) = deliveryPolicy(in: arguments)
        guard rest.count >= 2 else {
            throw CLIError.missingArguments("click requires a target")
        }
        return policy.applied(to: ["target": target(rest[1])])
    }

    public static func invoke(arguments: [String]) throws -> [String: JSONValue] {
        let (rest, policy) = deliveryPolicy(in: arguments)
        guard rest.count >= 3 else {
            throw CLIError.missingArguments("invoke requires a target and action name")
        }
        return policy.applied(to: [
            "target": target(rest[1]),
            "name": .string(rest[2])
        ])
    }

    public static func type(arguments: [String]) throws -> [String: JSONValue] {
        let (rest, policy) = deliveryPolicy(in: arguments)
        guard rest.count >= 3 else {
            throw CLIError.missingArguments("type requires a target and value")
        }
        return policy.applied(to: [
            "target": target(rest[1]),
            "value": .string(rest.dropFirst(2).joined(separator: " "))
        ])
    }

    public static func keyboard(arguments: [String]) throws -> [String: JSONValue] {
        let (arguments, policy) = deliveryPolicy(in: arguments)
        var params: [String: JSONValue] = [:]
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--app":
                guard index + 1 < arguments.count else {
                    throw CLIError.missingArguments("keyboard --app requires an app")
                }
                params["app"] = .string(arguments[index + 1])
                index += 2
            case "--text", "--key":
                let option = String(arguments[index].dropFirst(2))
                guard index + 1 < arguments.count else {
                    throw CLIError.missingArguments("keyboard --\(option) requires a value")
                }
                guard params[option] == nil else {
                    throw CLIError.missingArguments("keyboard --\(option) may only be provided once")
                }
                params[option] = .string(arguments[index + 1])
                index += 2
            default:
                throw CLIError.missingArguments("unexpected keyboard argument: \(arguments[index]); use --text or --key")
            }
        }
        guard (params["text"] == nil) != (params["key"] == nil) else {
            throw CLIError.missingArguments("keyboard requires exactly one of --text or --key")
        }
        return policy.applied(to: params)
    }

    public static func scroll(arguments: [String]) throws -> [String: JSONValue] {
        let (arguments, policy) = deliveryPolicy(in: arguments)
        var params: [String: JSONValue] = [:]
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--app":
                guard index + 1 < arguments.count else {
                    throw CLIError.missingArguments("scroll --app requires an app")
                }
                params["app"] = .string(arguments[index + 1])
                index += 2
            case "--target":
                guard index + 1 < arguments.count else {
                    throw CLIError.missingArguments("scroll --target requires target JSON or handle")
                }
                params["target"] = target(arguments[index + 1])
                index += 2
            case "--dx":
                guard index + 1 < arguments.count, let value = Double(arguments[index + 1]) else {
                    throw CLIError.missingArguments("scroll --dx requires a number")
                }
                params["deltaX"] = .double(value)
                index += 2
            case "--dy":
                guard index + 1 < arguments.count, let value = Double(arguments[index + 1]) else {
                    throw CLIError.missingArguments("scroll --dy requires a number")
                }
                params["deltaY"] = .double(value)
                index += 2
            default:
                throw CLIError.missingArguments("unexpected scroll argument: \(arguments[index])")
            }
        }
        return policy.applied(to: params)
    }

    public static func drag(arguments: [String]) throws -> [String: JSONValue] {
        let (arguments, policy) = deliveryPolicy(in: arguments)
        var params: [String: JSONValue] = [:]
        var endpoints: [JSONValue] = []
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--app":
                guard index + 1 < arguments.count else {
                    throw CLIError.missingArguments("drag --app requires an app")
                }
                params["app"] = .string(arguments[index + 1])
                index += 2
            case "--duration-ms":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                    throw CLIError.missingArguments("drag --duration-ms requires an integer")
                }
                params["durationMs"] = .int(value)
                index += 2
            default:
                endpoints.append(target(arguments[index]))
                index += 1
            }
        }
        guard endpoints.count == 2 else {
            throw CLIError.missingArguments("drag requires from-json and to-json")
        }
        params["from"] = endpoints[0]
        params["to"] = endpoints[1]
        return policy.applied(to: params)
    }

    // MARK: - Sessions

    public static func run(arguments: [String]) throws -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        var index = 1
        var path: String?
        var argValues: [String: JSONValue] = [:]

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--continue-on-error":
                params["continueOnError"] = .bool(true)
                index += 1
            case "--dry-run":
                params["dryRun"] = .bool(true)
                index += 1
            case "--healed-path":
                guard index + 1 < arguments.count else {
                    throw CLIError.missingArguments("run --healed-path requires a file")
                }
                params["healedPath"] = .string(arguments[index + 1])
                index += 2
            case "--arg":
                guard index + 1 < arguments.count else {
                    throw CLIError.missingArguments("run --arg requires name=value")
                }
                let assignment = arguments[index + 1]
                guard let separator = assignment.firstIndex(of: "="), separator > assignment.startIndex else {
                    throw CLIError.missingArguments("run --arg requires name=value")
                }
                let name = String(assignment[..<separator])
                let value = String(assignment[assignment.index(after: separator)...])
                argValues[name] = .string(value)
                index += 2
            default:
                if path == nil {
                    path = argument
                    index += 1
                } else {
                    throw CLIError.missingArguments("unexpected run argument: \(argument)")
                }
            }
        }

        guard let path else {
            throw CLIError.missingArguments("run requires a path")
        }
        params["path"] = .string(path)
        if !argValues.isEmpty {
            params["argValues"] = .object(argValues)
        }
        return params
    }

    public static func save(arguments: [String]) throws -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--session":
                guard index + 1 < arguments.count else {
                    throw CLIError.missingArguments("save --session requires an id")
                }
                params["sessionId"] = .string(arguments[index + 1])
                index += 2
            case "--from":
                guard index + 1 < arguments.count else {
                    throw CLIError.missingArguments("save --from requires a call id")
                }
                params["from"] = .string(arguments[index + 1])
                index += 2
            case "--to":
                guard index + 1 < arguments.count else {
                    throw CLIError.missingArguments("save --to requires a call id")
                }
                params["to"] = .string(arguments[index + 1])
                index += 2
            case "--path":
                guard index + 1 < arguments.count else {
                    throw CLIError.missingArguments("save --path requires a file path")
                }
                params["path"] = .string(arguments[index + 1])
                index += 2
            case "--include-reads":
                params["includeReads"] = .bool(true)
                index += 1
            default:
                throw CLIError.missingArguments("unexpected save argument: \(arguments[index])")
            }
        }
        return params
    }

    // MARK: - Shared packing

    /// Packs a positional target argument. JSON decodes to its own shape; anything else is passed
    /// through as a string so `ToolTarget` authors the rejection rather than the CLI guessing at
    /// one. Since the semantic-names cutover the only accepted element target is `{app,name}`.
    public static func target(_ argument: String) -> JSONValue {
        (try? decodeJSON(argument)) ?? .string(argument)
    }

    private static func decodeJSON(_ rawValue: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(rawValue.utf8))
    }

    /// `--foreground` is the CLI spelling of `deliveryPolicy: foregroundPermitted`.
    ///
    /// It is a per-invocation opt-in like the wire parameter it stands for, and it is stripped
    /// before the remaining arguments are parsed so it may appear anywhere in the command line.
    private struct DeliveryPolicyArgument {
        let permitsForeground: Bool

        func applied(to params: [String: JSONValue]) -> [String: JSONValue] {
            guard permitsForeground else {
                return params
            }
            var params = params
            params["deliveryPolicy"] = .string(DeliveryPolicy.foregroundPermitted.rawValue)
            return params
        }
    }

    private static func deliveryPolicy(in arguments: [String]) -> ([String], DeliveryPolicyArgument) {
        let remaining = arguments.filter { $0 != "--foreground" }
        return (remaining, DeliveryPolicyArgument(permitsForeground: remaining.count != arguments.count))
    }
}
