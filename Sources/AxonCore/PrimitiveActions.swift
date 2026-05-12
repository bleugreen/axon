public struct PrimitiveActionResult: Codable, Equatable, Sendable {
    public let action: String
    public let target: String
    public let strategy: String
    public let success: Bool
    public let message: String?

    public init(action: String, target: String, strategy: String, success: Bool, message: String? = nil) {
        self.action = action
        self.target = target
        self.strategy = strategy
        self.success = success
        self.message = message
    }

    public var jsonValue: JSONValue {
        .object([
            "action": .string(action),
            "target": .string(target),
            "strategy": .string(strategy),
            "success": .bool(success),
            "message": message.map(JSONValue.string) ?? .null
        ])
    }
}

public struct PrimitiveActionHandlers {
    public var click: (String) throws -> PrimitiveActionResult
    public var performAction: (String, String) throws -> PrimitiveActionResult
    public var setValue: (String, String) throws -> PrimitiveActionResult
    public var typeText: (String, String) throws -> PrimitiveActionResult
    public var pressKey: (String, String) throws -> PrimitiveActionResult

    public init(
        click: @escaping (String) throws -> PrimitiveActionResult = { _ in throw JSONRPCError.methodNotFound("click") },
        performAction: @escaping (String, String) throws -> PrimitiveActionResult = { _, _ in throw JSONRPCError.methodNotFound("perform_action") },
        setValue: @escaping (String, String) throws -> PrimitiveActionResult = { _, _ in throw JSONRPCError.methodNotFound("set_value") },
        typeText: @escaping (String, String) throws -> PrimitiveActionResult = { _, _ in throw JSONRPCError.methodNotFound("type_text") },
        pressKey: @escaping (String, String) throws -> PrimitiveActionResult = { _, _ in throw JSONRPCError.methodNotFound("press_key") }
    ) {
        self.click = click
        self.performAction = performAction
        self.setValue = setValue
        self.typeText = typeText
        self.pressKey = pressKey
    }
}

