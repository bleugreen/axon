public struct PrimitiveActionResult: Codable, Equatable, Sendable {
    public let action: String
    public let target: String
    public let strategy: String
    public let success: Bool
    public let message: String?
    public let details: [String: JSONValue]

    public init(
        action: String,
        target: String,
        strategy: String,
        success: Bool,
        message: String? = nil,
        details: [String: JSONValue] = [:]
    ) {
        self.action = action
        self.target = target
        self.strategy = strategy
        self.success = success
        self.message = message
        self.details = details
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "action": .string(action),
            "target": .string(target),
            "strategy": .string(strategy),
            "success": .bool(success),
            "message": message.map(JSONValue.string) ?? .null
        ]
        object.merge(details) { _, detail in detail }
        return .object(object)
    }
}

public struct ActionPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var jsonValue: JSONValue {
        .object([
            "x": .double(x),
            "y": .double(y)
        ])
    }

    public var targetDescription: String {
        "point:\(format(x)),\(format(y))"
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

public enum PointerTarget: Equatable, Sendable {
    case handle(String)
    case point(ActionPoint)

    public var targetDescription: String {
        switch self {
        case let .handle(handle):
            return handle
        case let .point(point):
            return point.targetDescription
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case let .handle(handle):
            return .object(["handle": .string(handle)])
        case let .point(point):
            return .object(["point": point.jsonValue])
        }
    }
}

public struct PrimitiveActionHandlers {
    public var click: (String) throws -> PrimitiveActionResult
    public var clickPoint: (ActionPoint) throws -> PrimitiveActionResult
    public var invoke: (String, String) throws -> PrimitiveActionResult
    public var type: (String, String) throws -> PrimitiveActionResult
    public var keyboard: (String?, String) throws -> PrimitiveActionResult
    public var scroll: (PointerTarget?, String?, Double, Double) throws -> PrimitiveActionResult
    public var drag: (PointerTarget, PointerTarget, String?, Int?) throws -> PrimitiveActionResult

    public init(
        click: @escaping (String) throws -> PrimitiveActionResult = { _ in throw JSONRPCError.methodNotFound("click") },
        clickPoint: @escaping (ActionPoint) throws -> PrimitiveActionResult = { _ in throw JSONRPCError.methodNotFound("click") },
        invoke: @escaping (String, String) throws -> PrimitiveActionResult = { _, _ in throw JSONRPCError.methodNotFound("invoke") },
        type: @escaping (String, String) throws -> PrimitiveActionResult = { _, _ in throw JSONRPCError.methodNotFound("type") },
        keyboard: @escaping (String?, String) throws -> PrimitiveActionResult = { _, _ in throw JSONRPCError.methodNotFound("keyboard") },
        scroll: @escaping (PointerTarget?, String?, Double, Double) throws -> PrimitiveActionResult = { _, _, _, _ in throw JSONRPCError.methodNotFound("scroll") },
        drag: @escaping (PointerTarget, PointerTarget, String?, Int?) throws -> PrimitiveActionResult = { _, _, _, _ in throw JSONRPCError.methodNotFound("drag") }
    ) {
        self.click = click
        self.clickPoint = clickPoint
        self.invoke = invoke
        self.type = type
        self.keyboard = keyboard
        self.scroll = scroll
        self.drag = drag
    }
}
