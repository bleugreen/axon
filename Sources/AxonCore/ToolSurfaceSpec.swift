import Foundation

public enum ToolTargetKind: String, CaseIterable, Sendable {
    case handle
    case locator
    case point
    case textLocation

    public var schemaDescription: String {
        switch self {
        case .handle:
            return "Snapshot handle like s12:19."
        case .locator:
            return "Locator target object with app and locator fields. Locator may use label, title, value, description, identifier, actions, and ancestors."
        case .point:
            return "Point target object: { point: { x, y, coordinateSpace } } or { x, y, coordinateSpace }. coordinateSpace is screen, window, or screenshot; window and screenshot points require app when no top-level app is provided. Legacy { x, y } still resolves as screen coordinates for compatibility."
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

    public static let handle = ToolTargetKindSet(rawValue: 1 << 0)
    public static let locator = ToolTargetKindSet(rawValue: 1 << 1)
    public static let point = ToolTargetKindSet(rawValue: 1 << 2)
    public static let textLocation = ToolTargetKindSet(rawValue: 1 << 3)
    public static let element: ToolTargetKindSet = [.handle, .locator]
    public static let pointer: ToolTargetKindSet = [.handle, .locator, .point, .textLocation]

    public var orderedKinds: [ToolTargetKind] {
        ToolTargetKind.allCases.filter { contains($0) }
    }

    public func contains(_ kind: ToolTargetKind) -> Bool {
        switch kind {
        case .handle:
            return contains(ToolTargetKindSet.handle)
        case .locator:
            return contains(ToolTargetKindSet.locator)
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

    public init(
        name: String,
        socketMethod: String? = nil,
        description: String,
        params: [ToolParameterSpec] = [],
        cliUsage: String? = nil
    ) {
        self.name = name
        self.socketMethod = socketMethod ?? name
        self.description = description
        self.params = params
        self.cliUsage = cliUsage
    }

    public var requiredParamNames: [String] {
        params.filter(\.required).map(\.name)
    }
}

public enum ToolSurfaceSpec {
    public static let tools: [ToolSpec] = [
        ToolSpec(
            name: "look",
            description: "Observe Axon's current surface: no target lists apps, an app target captures state, a handle target pages children, and since returns a change check.",
            params: [
                ToolParameterSpec("target", .string, description: "Bundle id, pid, app name, partial app name, or retained snapshot handle such as s12:4. Omit to list apps."),
                ToolParameterSpec("since", .string, description: "Snapshot id from a prior look response. Returns a coarse change check instead of a tree."),
                ToolParameterSpec("screenshot", .boolean, default: .bool(false), description: "Include embedded ScreenCaptureKit screenshot data with an app observation. Defaults to false for MCP."),
                ToolParameterSpec("screenText", .boolean, default: .bool(false), description: "OCR visible text from the app window screenshot and include it as organized screenText. Defaults to false."),
                ToolParameterSpec("tree", .boolean, description: "Include the nested AX tree for app observations. Defaults to true for observation format and false for debug format."),
                ToolParameterSpec("offset", .integer, default: .int(0), description: "Zero-based child offset when target is a retained handle. Defaults to 0."),
                ToolParameterSpec("limit", .integer, description: "Maximum children when target is a retained handle. Defaults to Axon's sibling page size."),
                ToolParameterSpec("direct", .boolean, default: .bool(false), description: "For handle targets, return only direct children and retain their handles without recursively capturing descendants."),
                ToolParameterSpec("childDepth", .integer, description: "Initial child depth for app observations. Use 0 to retain top-level windows only and page children by handle."),
                ToolParameterSpec("depth", .integer, description: "Maximum tree depth to display for app observations, with windows at depth 0."),
                ToolParameterSpec("all", .boolean, description: "For no-target app lists, include all running processes. For direct handle child requests, include all direct children."),
                ToolParameterSpec("format", .string, description: "Defaults to observation. Use debug only when diagnosing Axon internals."),
                ToolParameterSpec("frames", .boolean, default: .bool(false), description: "Include frames in observation output. Defaults to false.")
            ],
            cliUsage: "axon look [target] [--since snapshot-id] [--screenshot] [--screen-text] [--frames] [--json] [--details] [--debug] [--no-tree] [--offset n] [--limit n] [--depth n]"
        ),
        ToolSpec(
            name: "find",
            description: "Resolve an AX locator against a fresh app snapshot.",
            params: [
                ToolParameterSpec("app", .string, required: true, description: "Bundle id, pid, exact app name, or partial app name."),
                ToolParameterSpec("locator", .locator, required: true, description: "AX locator with role, subrole, label, title, value, description, identifier, actions, and ancestors.")
            ],
            cliUsage: "axon find <app> '<locator-json>'"
        ),
        ToolSpec(
            name: "wait_for_value",
            description: "Poll readable AX state from a resolved locator until a contains, equals, or regex predicate holds, or a bounded timeout reports the last observed state.",
            params: [
                ToolParameterSpec("target", .target(.locator), required: true, description: "Locator target object with app and locator fields."),
                ToolParameterSpec("contains", .string, description: "Succeed when any readable field contains this text."),
                ToolParameterSpec("equals", .string, description: "Succeed when any readable field exactly equals this text."),
                ToolParameterSpec("matches", .string, description: "Succeed when any readable field matches this regular expression."),
                ToolParameterSpec("timeoutMs", .integer, default: .int(5_000), description: "Maximum time to poll before returning a failed timeout result. Defaults to 5000 ms and is capped at 60000 ms."),
                ToolParameterSpec("intervalMs", .integer, default: .int(100), description: "Delay between polls. Defaults to 100 ms and is capped by the remaining timeout.")
            ],
            cliUsage: "axon wait_for_value '<target-json>' (--contains text | --equals text | --matches regex) [--timeout-ms n] [--interval-ms n]"
        ),
        ToolSpec(
            name: "permit",
            description: "Ask macOS to show the Accessibility permission prompt for the running Axon daemon identity.",
            cliUsage: "axon permit"
        ),
        ToolSpec(
            name: "run",
            description: "Run a sequence of Axon actions from inline actions, a .axn path, or a path loaded first with inline actions appended.",
            params: [
                ToolParameterSpec("actions", .array, description: "Ordered action objects, each with a tool field and that tool's normal arguments."),
                ToolParameterSpec("path", .string, description: "Local .axn file path for the Axon daemon to read."),
                ToolParameterSpec("argValues", .freeformObject, description: "Caller-supplied .axn argument values keyed by declared arg name. Valid only for args without a declared source."),
                ToolParameterSpec("continueOnError", .boolean, default: .bool(false), description: "Continue after an action fails. Defaults to false."),
                ToolParameterSpec("dryRun", .boolean, description: "Trace the run without dispatching actions.")
            ],
            cliUsage: "axon run <path.axn> [--arg name=value] [--dry-run] [--continue-on-error]"
        ),
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
        ),
        ToolSpec(
            name: "click",
            description: "Click a target specified by snapshot handle, locator object, point, or text location.",
            params: [ToolParameterSpec("target", .target(.pointer), required: true, description: "Target to click.")],
            cliUsage: "axon click <handle|target-json>"
        ),
        ToolSpec(
            name: "type",
            description: "Fill a writable field by setting AXValue directly on a target, avoiding focus and keystroke timing races.",
            params: [
                ToolParameterSpec("target", .target(.element), required: true, description: "Handle or locator target for the writable field."),
                ToolParameterSpec("value", .string, required: true, description: "New string value.")
            ],
            cliUsage: "axon type <handle> <value>"
        ),
        ToolSpec(
            name: "keyboard",
            description: "Post keyboard input for shortcuts, special keys, or raw text when field-level type is not the right intent.",
            params: [
                ToolParameterSpec("keys", .string, required: true, description: "Text, special key, or combo, for example Return or cmd+shift+p."),
                ToolParameterSpec("app", .string, description: "Optional app to activate before posting keyboard input.")
            ],
            cliUsage: "axon keyboard [--app app] <keys-or-text>"
        ),
        ToolSpec(
            name: "scroll",
            description: "Scroll an accessibility surface by resolving an offscreen descendant and requesting AXScrollToVisible.",
            params: [
                ToolParameterSpec("target", .target(.pointer), description: "Optional target to scroll or resolve into view."),
                ToolParameterSpec("app", .string, description: "Optional app used to resolve a scroll surface without activating it."),
                ToolParameterSpec("deltaX", .number, default: .int(0), description: "Horizontal scroll delta in pixels. Defaults to 0."),
                ToolParameterSpec("deltaY", .number, default: .int(-120), description: "Vertical scroll delta in pixels. Defaults to -120.")
            ],
            cliUsage: "axon scroll [--app app] [--target target-json] [--dx n] [--dy n]"
        ),
        ToolSpec(
            name: "drag",
            description: "Drag from one point, snapshot handle, locator target, or text location to another. Pointer dispatch and verified semantic outcome are reported separately."
            params: [
                ToolParameterSpec("from", .target(.pointer), required: true, description: "Starting handle, locator, point, or text location."),
                ToolParameterSpec("to", .target(.pointer), required: true, description: "Ending handle, locator, point, or text location."),
                ToolParameterSpec("app", .string, description: "Optional app to activate before dragging."),
                ToolParameterSpec("durationMs", .integer, description: "Optional drag duration in milliseconds. The pointer path still emits threshold and intermediate drag events."),
                ToolParameterSpec("expects", .array, description: "Optional post-action facts used by run to verify semantic success. Direct drag calls without a verified postcondition report an unverified semantic outcome.")
            ],
            cliUsage: "axon drag [--app app] [--duration-ms n] <from-json> <to-json>"
        ),
        ToolSpec(
            name: "invoke",
            description: "Invoke a named AX action on a target specified by snapshot handle or locator object.",
            params: [
                ToolParameterSpec("target", .target(.element), required: true, description: "Handle or locator target."),
                ToolParameterSpec("name", .string, required: true, description: "Accessibility action name, for example AXPress or AXShowMenu.")
            ],
            cliUsage: "axon invoke <handle> <action-name>"
        )
    ]

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
    public static func mcpToolJSONValues() -> [JSONValue] {
        ToolSurfaceSpec.tools.map { tool in
            .object([
                "name": .string(tool.name),
                "title": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": inputSchema(for: tool)
            ])
        }
    }

    public static func inputSchema(for tool: ToolSpec) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for param in tool.params {
            properties[param.name] = schema(for: param)
        }
        var object: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ]
        let required = tool.requiredParamNames
        if !required.isEmpty {
            object["required"] = .array(required.map(JSONValue.string))
        }
        return .object(object)
    }

    private static func schema(for param: ToolParameterSpec) -> JSONValue {
        switch param.type {
        case .string:
            return scalarSchema(type: "string", description: param.description)
        case .boolean:
            return scalarSchema(type: "boolean", description: param.description)
        case .integer, .number:
            return scalarSchema(type: "number", description: param.description)
        case .object:
            return .object([
                "type": .string("object"),
                "description": .string(param.description),
                "additionalProperties": .bool(false)
            ])
        case .freeformObject:
            return .object([
                "type": .string("object"),
                "description": .string(param.description),
                "additionalProperties": .bool(true)
            ])
        case .array:
            return .object([
                "type": .string("array"),
                "description": .string(param.description),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(true)
                ])
            ])
        case .locator:
            return .object([
                "type": .string("object"),
                "description": .string(param.description),
                "additionalProperties": .bool(true)
            ])
        case let .target(kinds):
            return .object([
                "anyOf": .array(kinds.orderedKinds.map { kind in
                    switch kind {
                    case .handle:
                        return scalarSchema(type: "string", description: kind.schemaDescription)
                    case .locator, .point, .textLocation:
                        return .object([
                            "type": .string("object"),
                            "description": .string(kind.schemaDescription),
                            "additionalProperties": .bool(true)
                        ])
                    }
                })
            ])
        }
    }

    private static func scalarSchema(type: String, description: String) -> JSONValue {
        .object([
            "type": .string(type),
            "description": .string(description)
        ])
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
