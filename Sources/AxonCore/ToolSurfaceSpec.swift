import Foundation

public enum ToolFacade: String, CaseIterable, Sendable {
    case swift
    case mac
    case windows
    case linux
}

public struct ToolFacadeSet: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let swift = ToolFacadeSet(rawValue: 1 << 0)
    public static let mac = ToolFacadeSet(rawValue: 1 << 1)
    public static let windows = ToolFacadeSet(rawValue: 1 << 2)
    public static let linux = ToolFacadeSet(rawValue: 1 << 3)
    public static let swiftOnly: ToolFacadeSet = [.swift]
    public static let all: ToolFacadeSet = [.swift, .mac, .windows, .linux]

    public func contains(_ facade: ToolFacade) -> Bool {
        switch facade {
        case .swift: contains(.swift)
        case .mac: contains(.mac)
        case .windows: contains(.windows)
        case .linux: contains(.linux)
        }
    }
}

public enum ToolTargetKind: String, CaseIterable, Sendable {
    case semanticName
    case point
    case textLocation

    public var schemaDescription: String {
        switch self {
        case .semanticName:
            return "Semantic element target object with required app and name fields. Run look first to observe canonical names."
        case .point:
            return "Point target object: { point: { x, y, coordinateSpace } } or { x, y, coordinateSpace }. coordinateSpace is screen, window, or screenshot; window and screenshot points require app when no top-level app is provided. Raw points dispatch without element identity or occlusion verification; use a semantic name when fail-closed target validation is required."
        case .textLocation:
            return "Text location target object: { location: { app, text, source? } }. Resolves visible text to a click/drag/scroll point using AX text or screenshot OCR without callers providing coordinates."
        }
    }
}

public struct ToolTargetKindSet: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let semanticName = ToolTargetKindSet(rawValue: 1 << 0)
    public static let point = ToolTargetKindSet(rawValue: 1 << 2)
    public static let textLocation = ToolTargetKindSet(rawValue: 1 << 3)
    public static let element: ToolTargetKindSet = [.semanticName]
    public static let pointer: ToolTargetKindSet = [.semanticName, .point, .textLocation]

    public var orderedKinds: [ToolTargetKind] {
        ToolTargetKind.allCases.filter { contains($0) }
    }

    public func contains(_ kind: ToolTargetKind) -> Bool {
        switch kind {
        case .semanticName:
            return contains(ToolTargetKindSet.semanticName)
        case .point:
            return contains(ToolTargetKindSet.point)
        case .textLocation:
            return contains(ToolTargetKindSet.textLocation)
        }
    }

    public var description: String {
        orderedKinds.map(\.rawValue).joined(separator: ", ")
    }
}

public enum ToolParameterType: Equatable, Sendable {
    case string
    case boolean
    case integer
    case number
    case object
    case array
    case freeformObject
    case locator
    case target(ToolTargetKindSet)
}

public struct ToolParameterSpec: Equatable, Sendable {
    public let name: String
    public let type: ToolParameterType
    public let required: Bool
    public let defaultValue: JSONValue?
    public let description: String

    public init(
        _ name: String,
        _ type: ToolParameterType,
        required: Bool = false,
        default defaultValue: JSONValue? = nil,
        description: String
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
        self.description = description
    }
}

public struct ToolSpec: Equatable, Sendable {
    public let name: String
    public let socketMethod: String
    public let description: String
    public let params: [ToolParameterSpec]
    public let cliUsage: String?
    public let exactlyOneOf: [String]
    public let availability: ToolFacadeSet

    public init(
        name: String,
        socketMethod: String? = nil,
        description: String,
        params: [ToolParameterSpec] = [],
        cliUsage: String? = nil,
        exactlyOneOf: [String] = [],
        availability: ToolFacadeSet
    ) {
        self.name = name
        self.socketMethod = socketMethod ?? name
        self.description = description
        self.params = params
        self.cliUsage = cliUsage
        self.exactlyOneOf = exactlyOneOf
        self.availability = availability
    }

    public var requiredParamNames: [String] {
        params.filter(\.required).map(\.name)
    }
}

public enum ToolSurfaceSpec {
    public static let tools: [ToolSpec] = [
        ToolSpec(
            name: "look",
            description: "Observe Axon's current surface: no app lists apps, app captures state, a semantic target pages children, and since returns a change check.",
            params: [
                ToolParameterSpec("app", .string, description: "Bundle id, pid, app name, or partial app name. Omit with target to list apps."),
                ToolParameterSpec("target", .target(.element), description: "App-scoped semantic name returned by a prior look; pages that element's children."),
                ToolParameterSpec("since", .string, description: "Snapshot id from a prior look response. Returns a coarse change check instead of a tree."),
                ToolParameterSpec("screenshot", .boolean, default: .bool(true), description: "Include a downscaled window screenshot with a full app observation. Defaults to true; since change checks and semantic-target child pages are always imageless."),
                ToolParameterSpec("screenText", .boolean, default: .bool(false), description: "OCR visible text from the app window screenshot and include it as organized screenText. Defaults to false."),
                ToolParameterSpec("tree", .boolean, description: "Include the nested AX tree for app observations. Defaults to true for observation format and false for debug format."),
                ToolParameterSpec("offset", .integer, default: .int(0), description: "Zero-based child offset for a semantic target. Defaults to 0."),
                ToolParameterSpec("limit", .integer, description: "Maximum children for a semantic target. Defaults to Axon's sibling page size."),
                ToolParameterSpec("direct", .boolean, default: .bool(false), description: "For semantic targets, return only direct children without recursively capturing descendants."),
                ToolParameterSpec("childDepth", .integer, description: "Initial child depth for app observations. Use 0 to retain top-level windows only and page children by semantic target."),
                ToolParameterSpec("depth", .integer, description: "Maximum tree depth to display for app observations, with windows at depth 0."),
                ToolParameterSpec("all", .boolean, description: "For no-target app lists, include all running processes. For direct semantic child requests, include all direct children."),
                ToolParameterSpec("format", .string, description: "Defaults to observation. Use debug only when diagnosing Axon internals."),
                ToolParameterSpec("frames", .boolean, default: .bool(false), description: "Include frames in observation output. Defaults to false.")
            ],
            cliUsage: "axon look [app | target-json] [--since snapshot-id] [--no-screenshot] [--screen-text] [--frames] [--json] [--details] [--debug] [--no-tree] [--offset n] [--limit n] [--depth n]"
        , availability: .all),
        ToolSpec(name: "navigate", description: "Navigate the active tab of a supported browser through its application scripting dictionary and verify the URL by read-back.", params: [
            ToolParameterSpec("app", .string, required: true, description: "Safari or Google Chrome, by name or exact bundle identifier."),
            ToolParameterSpec("url", .string, required: true, description: "Absolute http or https URL, limited to 8192 bytes.")
        ], availability: .swiftOnly),
        ToolSpec(name: "windows", description: "Enumerate browser windows authoritatively through the supported app's scripting dictionary and cross-check them against AX when available.", params: [
            ToolParameterSpec("app", .string, required: true, description: "Safari or Google Chrome, by name or exact bundle identifier.")
        ], availability: .swiftOnly),
        ToolSpec(name: "tabs", description: "Enumerate browser tabs authoritatively through the supported app's scripting dictionary.", params: [
            ToolParameterSpec("app", .string, required: true, description: "Safari or Google Chrome, by name or exact bundle identifier."),
            ToolParameterSpec("window", .integer, description: "Optional one-based window index from windows().")
        ], availability: .swiftOnly),
        ToolSpec(
            name: "find",
            description: "Resolve an AX locator against a fresh app snapshot.",
            params: [
                ToolParameterSpec("app", .string, required: true, description: "Bundle id, pid, exact app name, or partial app name."),
                ToolParameterSpec("locator", .locator, required: true, description: "AX locator with role, subrole, label, title, value, description, identifier, actions, and ancestors.")
            ],
            cliUsage: "axon find <app> '<locator-json>'"
        , availability: .all),
        ToolSpec(
            name: "wait_for_value",
            description: "Poll readable accessibility state from an app-scoped semantic name until a contains, equals, or regex predicate holds, or a bounded timeout reports the last observed state.",
            params: [
                ToolParameterSpec("target", .target(.element), required: true, description: "App-scoped semantic name target returned by look."),
                ToolParameterSpec("contains", .string, description: "Succeed when any readable field contains this text."),
                ToolParameterSpec("equals", .string, description: "Succeed when any readable field exactly equals this text."),
                ToolParameterSpec("matches", .string, description: "Succeed when any readable field matches this regular expression."),
                ToolParameterSpec("timeoutMs", .integer, default: .int(5_000), description: "Maximum time to poll before returning a failed timeout result. Defaults to 5000 ms and is capped at 60000 ms."),
                ToolParameterSpec("intervalMs", .integer, default: .int(100), description: "Delay between polls. Defaults to 100 ms and is capped by the remaining timeout.")
            ],
            cliUsage: "axon wait_for_value '<target-json>' (--contains text | --equals text | --matches regex) [--timeout-ms n] [--interval-ms n]"
        , availability: [.swift, .mac]),
        ToolSpec(
            name: "wait_for_stability",
            description: "Poll full app observations until the accessibility surface remains unchanged for a stability window or changes from its initial state; timeout returns the final observation.",
            params: [
                ToolParameterSpec("app", .string, required: true, description: "Bundle id, pid, exact app name, or partial app name."),
                ToolParameterSpec("condition", .string, default: .string("stable"), description: "stable waits for an unchanged stability window; changed waits for an observable app, tree, or focus change."),
                ToolParameterSpec("stableMs", .integer, default: .int(300), description: "Required unchanged duration for the stable condition. Defaults to 300 ms and is capped at 10000 ms."),
                ToolParameterSpec("timeoutMs", .integer, default: .int(5_000), description: "Maximum wait. Defaults to 5000 ms and is capped at 60000 ms."),
                ToolParameterSpec("intervalMs", .integer, default: .int(100), description: "Delay between observations. At least 10 ms and capped by the remaining timeout.")
            ],
            cliUsage: "axon wait_for_stability <app> [--condition stable|changed] [--stable-ms n] [--timeout-ms n] [--interval-ms n]"
        , availability: [.swift, .mac]),
        ToolSpec(
            name: "permit",
            description: "Ask macOS to show the Accessibility permission prompt for the running Axon daemon identity.",
            cliUsage: "axon permit"
        , availability: .swiftOnly),
        ToolSpec(
            name: "run",
            description: "Run a sequence of Axon actions from inline actions, a .axn path, or a path loaded first with inline actions appended.",
            params: [
                ToolParameterSpec("actions", .array, description: "Ordered action objects, each with a tool field and that tool's normal arguments."),
                ToolParameterSpec("path", .string, description: "Local .axn file path for the Axon daemon to read."),
                ToolParameterSpec("argValues", .freeformObject, description: "Caller-supplied .axn argument values keyed by declared arg name. Valid only for args without a declared source."),
                ToolParameterSpec("continueOnError", .boolean, default: .bool(false), description: "Continue after an action fails. Defaults to false."),
                ToolParameterSpec("dryRun", .boolean, description: "Trace the run without dispatching actions."),
                ToolParameterSpec("healedPath", .string, description: "Write a revised copy of the .axn to this path when replay resolves through drifted locator evidence. The source file is never modified.")
            ],
            cliUsage: "axon run <path.axn> [--arg name=value] [--dry-run] [--healed-path file] [--continue-on-error]"
        , availability: .all),
        ToolSpec(
            name: "save",
            description: "Save recent recorded Axon calls as an editable .axn action file. Read calls are omitted unless includeReads is true.",
            params: [
                ToolParameterSpec("sessionId", .string, default: .string("default"), description: "History session to export. Defaults to the daemon's default session."),
                ToolParameterSpec("from", .string, description: "Optional starting call id, inclusive."),
                ToolParameterSpec("to", .string, description: "Optional ending call id, inclusive."),
                ToolParameterSpec("path", .string, description: "Optional local path to write the .axn file."),
                ToolParameterSpec("includeReads", .boolean, default: .bool(false), description: "Include read/context tools such as look and find. Defaults to false.")
            ],
            cliUsage: "axon save [--session id] [--from call] [--to call] [--path file.axn] [--include-reads]"
        , availability: .swiftOnly),
        ToolSpec(
            name: "click",
            description: "Click an app-scoped semantic element name, explicit point, or text location.",
            params: [
                ToolParameterSpec("target", .target(.pointer), required: true, description: "Target to click."),
                deliveryPolicyParameter
            ],
            cliUsage: "axon click [--foreground] <target-json>"
        , availability: [.swift, .mac, .windows]),
        ToolSpec(
            name: "type",
            description: "Fill a writable field by setting AXValue directly on a target, avoiding focus and keystroke timing races.",
            params: [
                ToolParameterSpec("target", .target(.element), required: true, description: "App-scoped semantic name target for the writable field."),
                ToolParameterSpec("value", .string, required: true, description: "New string value."),
                deliveryPolicyParameter
            ],
            cliUsage: "axon type [--foreground] <target-json> <value>"
        , availability: .all),
        ToolSpec(
            name: "keyboard",
            description: "Post keyboard input for shortcuts, special keys, or raw text when field-level type is not the right intent.",
            params: [
                ToolParameterSpec("text", .string, description: "Arbitrary text to enter exactly as provided."),
                ToolParameterSpec("key", .string, description: "Recognized key or keystroke, for example End, Return, or cmd+shift+p. Unknown names are rejected."),
                ToolParameterSpec("app", .string, description: "Application that receives the input. Required for background delivery; without it only foregroundPermitted can reach the frontmost app."),
                deliveryPolicyParameter
            ],
            cliUsage: "axon keyboard [--app app] [--foreground] (--text text | --key keystroke)",
            exactlyOneOf: ["text", "key"]
        , availability: [.swift, .mac, .windows]),
        ToolSpec(
            name: "scroll",
            description: "Scroll an accessibility surface by resolving an offscreen descendant and requesting AXScrollToVisible.",
            params: [
                ToolParameterSpec("target", .target(.pointer), description: "Optional target to scroll or resolve into view."),
                ToolParameterSpec("app", .string, description: "Optional app used to resolve a scroll surface without activating it."),
                ToolParameterSpec("deltaX", .number, default: .int(0), description: "Horizontal scroll delta in pixels. Defaults to 0."),
                ToolParameterSpec("deltaY", .number, default: .int(-120), description: "Vertical scroll delta in pixels. Defaults to -120."),
                deliveryPolicyParameter
            ],
            cliUsage: "axon scroll [--app app] [--target target-json] [--dx n] [--dy n]"
        , availability: .all),
        ToolSpec(
            name: "drag",
            description: "Drag from one semantic name, explicit point, or text location to another. Pointer dispatch and verified semantic outcome are reported separately.",
            params: [
                ToolParameterSpec("from", .target(.pointer), required: true, description: "Starting semantic name, point, or text location."),
                ToolParameterSpec("to", .target(.pointer), required: true, description: "Ending semantic name, point, or text location."),
                ToolParameterSpec("app", .string, description: "Application that owns the drag. Required for background delivery; also the app foregroundPermitted activates and restores."),
                ToolParameterSpec("durationMs", .integer, description: "Optional drag duration in milliseconds. The pointer path still emits threshold and intermediate drag events."),
                ToolParameterSpec("expects", .array, description: "Optional post-action facts used by run to verify semantic success. Direct drag calls without a verified postcondition report an unverified semantic outcome."),
                deliveryPolicyParameter
            ],
            cliUsage: "axon drag [--app app] [--duration-ms n] [--foreground] <from-json> <to-json>"
        , availability: .swiftOnly),
        ToolSpec(
            name: "invoke",
            description: "Invoke a named accessibility action on an app-scoped semantic element name.",
            params: [
                ToolParameterSpec("target", .target(.element), required: true, description: "App-scoped semantic name target."),
                ToolParameterSpec("name", .string, required: true, description: "Accessibility action name, for example AXPress or AXShowMenu."),
                deliveryPolicyParameter
            ],
            cliUsage: "axon invoke [--foreground] <target-json> <action-name>"
        , availability: .all)
    ]

    /// The one public control over what an action may do to the session, shared verbatim by every
    /// mutating tool so MCP schemas, CLI signatures, and .axn steps cannot drift apart.
    public static let deliveryPolicyParameter = ToolParameterSpec(
        "deliveryPolicy",
        .string,
        default: .string(DeliveryPolicy.default.rawValue),
        description: "backgroundOnly (default) forbids activation, focus changes, real pointer movement, global keyboard input, and the clipboard, and returns a structured refusal instead. foregroundPermitted allows this one action to escalate; it is never inherited by later actions."
    )

    /// The tools that accept a delivery policy: every action that can mutate the session.
    public static var mutatingToolNames: [String] {
        tools.filter { tool in tool.params.contains { $0.name == "deliveryPolicy" } }.map(\.name)
    }

    public static var toolNames: [String] {
        tools.map(\.name)
    }

    public static func tool(named name: String) -> ToolSpec? {
        tools.first { $0.name == name }
    }

    public static func socketMethod(for toolName: String) -> String? {
        tool(named: toolName)?.socketMethod
    }

    public static var mcpSignatureBlock: String {
        tools.map { tool in
            let signature = tool.params.map { param in
                param.name + (param.required ? "" : "?")
            }.joined(separator: ", ")
            return "\(tool.name)(\(signature))"
        }.joined(separator: "\n")
    }

    public static var cliUsageBlock: String {
        tools.compactMap(\.cliUsage).joined(separator: "\n")
    }
}

public enum ToolSurfaceSchema {
    public static let artifactFormatVersion = 1

    public static func mcpToolJSONValues() -> [JSONValue] {
        ToolSurfaceSpec.tools.map(mcpToolJSONValue)
    }

    public static func normalizedArtifactJSONValue() -> JSONValue {
        .object([
            "formatVersion": .int(artifactFormatVersion),
            "productVersion": .string(AxonVersion.current),
            "tools": .array(ToolSurfaceSpec.tools.map { tool in
                guard case var .object(entry) = mcpToolJSONValue(tool) else {
                    preconditionFailure("MCP tool entries must be objects")
                }
                entry["socketMethod"] = .string(tool.socketMethod)
                entry["availability"] = .object(Dictionary(
                    uniqueKeysWithValues: ToolFacade.allCases.map {
                        ($0.rawValue, .bool(tool.availability.contains($0)))
                    }
                ))
                return .object(entry)
            })
        ])
    }

    public static func normalizedArtifactData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(normalizedArtifactJSONValue())
        data.append(0x0A)
        return data
    }

    public static func inputSchema(for tool: ToolSpec) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for param in tool.params { properties[param.name] = schema(for: param) }
        var object: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ]
        let required = tool.requiredParamNames
        if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
        if !tool.exactlyOneOf.isEmpty {
            object["oneOf"] = .array(tool.exactlyOneOf.map {
                .object(["required": .array([.string($0)])])
            })
        }
        return .object(object)
    }

    private static func mcpToolJSONValue(_ tool: ToolSpec) -> JSONValue {
        .object(["name": .string(tool.name), "title": .string(tool.name),
                 "description": .string(tool.description), "inputSchema": inputSchema(for: tool)])
    }

    private static func schema(for param: ToolParameterSpec) -> JSONValue {
        let base: JSONValue
        switch param.type {
        case .string: base = scalarSchema(type: "string", description: param.description)
        case .boolean: base = scalarSchema(type: "boolean", description: param.description)
        case .integer: base = scalarSchema(type: "integer", description: param.description)
        case .number: base = scalarSchema(type: "number", description: param.description)
        case .object: base = objectSchema(description: param.description)
        case .freeformObject:
            base = .object(["type": .string("object"), "description": .string(param.description),
                            "additionalProperties": .bool(true)])
        case .array:
            base = .object(["type": .string("array"), "description": .string(param.description),
                            "items": .object(["type": .string("object"), "additionalProperties": .bool(true)])])
        case .locator:
            base = .object(["type": .string("object"), "description": .string(param.description),
                            "additionalProperties": .bool(true)])
        case let .target(kinds): base = targetSchema(kinds: kinds, description: param.description)
        }
        guard let defaultValue = param.defaultValue, case var .object(object) = base else { return base }
        object["default"] = defaultValue
        return .object(object)
    }

    private static func targetSchema(kinds: ToolTargetKindSet, description: String) -> JSONValue {
        var branches: [JSONValue] = []
        for kind in kinds.orderedKinds {
            switch kind {
            case .semanticName: branches.append(semanticTargetSchema)
            case .point:
                branches.append(wrappedPointTargetSchema)
                branches.append(pointObjectSchema)
            case .textLocation: branches.append(textLocationTargetSchema)
            }
        }
        return .object(["description": .string(description), "anyOf": .array(branches)])
    }

    private static let semanticTargetSchema: JSONValue = .object([
        "type": .string("object"), "description": .string(ToolTargetKind.semanticName.schemaDescription),
        "properties": .object([
            "app": scalarSchema(type: "string", description: "Bundle id, pid, app name, or partial app name."),
            "name": scalarSchema(type: "string", description: "Semantic element name returned by look.")
        ]),
        "required": .array([.string("app"), .string("name")]), "additionalProperties": .bool(false)
    ])

    private static let pointObjectSchema: JSONValue = .object([
        "type": .string("object"), "description": .string(ToolTargetKind.point.schemaDescription),
        "properties": .object([
            "x": scalarSchema(type: "number", description: "Horizontal coordinate."),
            "y": scalarSchema(type: "number", description: "Vertical coordinate."),
            "coordinateSpace": enumStringSchema(values: ["screen", "window", "screenshot"], description: "Coordinate space. Defaults to screen."),
            "app": scalarSchema(type: "string", description: "App that owns a window or screenshot coordinate.")
        ]),
        "required": .array([.string("x"), .string("y")]), "additionalProperties": .bool(false)
    ])

    private static let wrappedPointTargetSchema: JSONValue = .object([
        "type": .string("object"), "description": .string(ToolTargetKind.point.schemaDescription),
        "properties": .object(["point": pointObjectSchema]), "required": .array([.string("point")]),
        "additionalProperties": .bool(false)
    ])

    private static let textLocationTargetSchema: JSONValue = .object([
        "type": .string("object"), "description": .string(ToolTargetKind.textLocation.schemaDescription),
        "properties": .object(["location": .object([
            "type": .string("object"),
            "properties": .object([
                "app": scalarSchema(type: "string", description: "App containing the visible text."),
                "text": .object([
                    "description": .string("Text to match exactly, or an exact/contains matcher object."),
                    "anyOf": .array([
                        .object(["type": .string("string")]),
                        .object([
                            "type": .string("object"),
                            "properties": .object([
                                "exact": scalarSchema(type: "string", description: "Text to match exactly."),
                                "contains": scalarSchema(type: "string", description: "Text fragment to match."),
                                "caseSensitive": .object(["type": .string("boolean"), "default": .bool(false),
                                                          "description": .string("Whether matching preserves case.")])
                            ]),
                            "oneOf": .array([
                                .object(["required": .array([.string("exact")])]),
                                .object(["required": .array([.string("contains")])])
                            ]),
                            "additionalProperties": .bool(false)
                        ])
                    ])
                ]),
                "source": enumStringSchema(values: ["auto", "ax", "screenshot"],
                                           description: "Text source. Defaults to auto.", defaultValue: "auto")
            ]),
            "required": .array([.string("app"), .string("text")]), "additionalProperties": .bool(false)
        ])]),
        "required": .array([.string("location")]), "additionalProperties": .bool(false)
    ])

    private static func scalarSchema(type: String, description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func enumStringSchema(values: [String], description: String, defaultValue: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("string"), "enum": .array(values.map(JSONValue.string)),
            "description": .string(description)
        ]
        if let defaultValue { object["default"] = .string(defaultValue) }
        return .object(object)
    }

    private static func objectSchema(description: String) -> JSONValue {
        .object(["type": .string("object"), "description": .string(description),
                 "additionalProperties": .bool(false)])
    }
}

public struct ToolParamDecoder {
    private let spec: ToolSpec?
    private let params: [String: JSONValue]

    public init(toolName: String, params: [String: JSONValue]) {
        self.spec = ToolSurfaceSpec.tool(named: toolName)
        self.params = params
    }

    public func string(_ name: String) throws -> String? {
        guard let value = value(name) else { return nil }
        guard case let .string(string) = value else {
            throw JSONRPCError.invalidParams("\(name) must be a string")
        }
        return string
    }

    public func requiredString(_ name: String) throws -> String {
        guard let string = try string(name) else {
            throw JSONRPCError.invalidParams("Missing string parameter: \(name)")
        }
        return string
    }

    public func bool(_ name: String) throws -> Bool? {
        guard let value = value(name) else { return nil }
        guard case let .bool(bool) = value else {
            throw JSONRPCError.invalidParams("\(name) must be a boolean")
        }
        return bool
    }

    public func int(_ name: String) throws -> Int? {
        guard let value = value(name) else { return nil }
        guard case let .int(int) = value else {
            throw JSONRPCError.invalidParams("\(name) must be an integer")
        }
        return int
    }

    public func number(_ name: String) throws -> Double? {
        guard let value = value(name) else { return nil }
        switch value {
        case let .double(double):
            return double
        case let .int(int):
            return Double(int)
        default:
            throw JSONRPCError.invalidParams("\(name) must be a number")
        }
    }

    /// Decodes the action's delivery policy, defaulting to backgroundOnly when the caller omits it.
    ///
    /// An unknown value fails here, before the target is resolved and before any native side
    /// effect, because a policy the daemon does not understand cannot be honoured safely.
    public func deliveryPolicy() throws -> DeliveryPolicy {
        guard let rawValue = try string("deliveryPolicy") else {
            return .default
        }
        return try DeliveryPolicy.validated(rawValue)
    }

    public func locator(_ name: String) throws -> AXLocator? {
        guard let value = value(name) else { return nil }
        return try AXLocator(jsonValue: value)
    }

    public func requiredLocator(_ name: String) throws -> AXLocator {
        guard let locator = try locator(name) else {
            throw JSONRPCError.invalidParams("Missing locator parameter")
        }
        return locator
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let value = value(name) else { return [] }
        guard case let .array(values) = value else {
            throw JSONRPCError.invalidParams("\(name) must be an array of strings")
        }
        return try values.map { value in
            guard case let .string(string) = value, !string.isEmpty else {
                throw JSONRPCError.invalidParams("\(name) must be an array of strings")
            }
            return string
        }
    }

    private func value(_ name: String) -> JSONValue? {
        guard let value = params[name], value != .null else {
            return nil
        }
        return value
    }
}
