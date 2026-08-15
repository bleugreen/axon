public struct PrimitiveActionResult: Codable, Equatable, Sendable {
    public let action: String
    public let target: String
    public let strategy: String
    public let success: Bool
    public let message: String?
    /// The policy the action ran under. Always present, always the caller's, never inherited.
    public let deliveryPolicy: DeliveryPolicy
    /// The rung that carried this action, or nil when no mechanism was ever reached — which is
    /// what a policy or capability refusal returns.
    public let delivery: DeliveryRung?
    /// Whether the mechanism accepted the action. Dispatch is evidence, not goal success: an
    /// accepted event still needs readback or a postcondition before `success` can be true.
    public let dispatchSuccess: Bool
    /// Set when Axon declined a rung. It is always decided before that mechanism produces any
    /// native side effect, so a result whose `delivery` is nil dispatched nothing at all; a result
    /// that names a rung tried that one and was only refused the escalation above it.
    public let refusal: DeliveryRefusal?
    public let details: [String: JSONValue]

    public init(
        action: String,
        target: String,
        strategy: String,
        success: Bool,
        message: String? = nil,
        deliveryPolicy: DeliveryPolicy = .default,
        delivery: DeliveryRung? = nil,
        dispatchSuccess: Bool? = nil,
        refusal: DeliveryRefusal? = nil,
        details: [String: JSONValue] = [:]
    ) {
        self.action = action
        self.target = target
        self.strategy = strategy
        self.success = success
        self.message = message
        self.deliveryPolicy = deliveryPolicy
        self.delivery = delivery
        self.dispatchSuccess = dispatchSuccess ?? success
        self.refusal = refusal
        self.details = details
    }

    /// A conclusive outcome: the rung dispatched and the result is already known to be right or
    /// wrong, with no postcondition required.
    public static func dispatched(
        action: String,
        target: String,
        strategy: String,
        policy: DeliveryPolicy,
        delivery: DeliveryRung,
        success: Bool,
        message: String? = nil,
        details: [String: JSONValue] = [:]
    ) -> PrimitiveActionResult {
        PrimitiveActionResult(
            action: action,
            target: target,
            strategy: strategy,
            success: success,
            message: message,
            deliveryPolicy: policy,
            delivery: delivery,
            dispatchSuccess: success,
            details: details
        )
    }

    /// Input reached the target but the goal cannot be proved from here. `run` may still upgrade
    /// this to a verified success through an `expects` postcondition.
    public static func unverifiedDispatch(
        action: String,
        target: String,
        strategy: String,
        policy: DeliveryPolicy = .default,
        delivery: DeliveryRung? = nil,
        dispatched: Bool,
        message: String,
        details: [String: JSONValue] = [:]
    ) -> PrimitiveActionResult {
        var resultDetails = details
        resultDetails["semanticSuccess"] = .null
        resultDetails["semanticStatus"] = .string("unverified")
        return PrimitiveActionResult(
            action: action,
            target: target,
            strategy: strategy,
            success: false,
            message: message,
            deliveryPolicy: policy,
            delivery: delivery,
            dispatchSuccess: dispatched,
            details: resultDetails
        )
    }

    /// Nothing was dispatched. Returned before any native side effect.
    public static func refused(
        action: String,
        target: String,
        policy: DeliveryPolicy,
        refusal: DeliveryRefusal,
        details: [String: JSONValue] = [:]
    ) -> PrimitiveActionResult {
        PrimitiveActionResult(
            action: action,
            target: target,
            strategy: "refused",
            success: false,
            message: refusal.message,
            deliveryPolicy: policy,
            delivery: nil,
            dispatchSuccess: false,
            refusal: refusal,
            details: details
        )
    }

    /// Records that escalation past the rung that was just attempted was declined.
    ///
    /// The attempted rung keeps whatever it earned: a mechanism that delivered events but could not
    /// prove the goal still reports `delivery` and `dispatchSuccess`, and the refusal explains only
    /// why nothing louder was tried.
    public func refusing(_ refusal: DeliveryRefusal) -> PrimitiveActionResult {
        PrimitiveActionResult(
            action: action,
            target: target,
            strategy: strategy,
            success: false,
            message: message.map { "\($0); \(refusal.message)" } ?? refusal.message,
            deliveryPolicy: deliveryPolicy,
            delivery: delivery,
            dispatchSuccess: dispatchSuccess,
            refusal: refusal,
            details: details
        )
    }

    public func withSuccess(_ success: Bool, message: String? = nil, details extraDetails: [String: JSONValue] = [:]) -> PrimitiveActionResult {
        var mergedDetails = details
        mergedDetails.merge(extraDetails) { _, detail in detail }
        return PrimitiveActionResult(
            action: action,
            target: target,
            strategy: strategy,
            success: success,
            message: message ?? self.message,
            deliveryPolicy: deliveryPolicy,
            delivery: delivery,
            dispatchSuccess: dispatchSuccess,
            refusal: refusal,
            details: mergedDetails
        )
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "action": .string(action),
            "target": .string(target),
            "strategy": .string(strategy),
            "success": .bool(success),
            "message": message.map(JSONValue.string) ?? .null,
            "deliveryPolicy": .string(deliveryPolicy.rawValue),
            "delivery": delivery.map { .string($0.rawValue) } ?? .null,
            "dispatchSuccess": .bool(dispatchSuccess),
            "refusal": refusal?.jsonValue ?? .null
        ]
        object.merge(details) { _, detail in detail }
        return .object(object)
    }
}

public enum KeyboardIntent: Equatable, Sendable {
    case text(String)
    case key(String)

    public static func validated(text: String?, key: String?) throws -> KeyboardIntent {
        switch (text, key) {
        case let (.some(text), .none):
            return .text(text)
        case let (.none, .some(key)):
            guard KeyStroke.isValid(key) else {
                throw JSONRPCError.invalidParams("Unknown keyboard key or keystroke: \(key)")
            }
            return .key(key)
        case (.some, .some):
            throw JSONRPCError.invalidParams("keyboard requires exactly one of text or key; both were provided")
        case (.none, .none):
            throw JSONRPCError.invalidParams("keyboard requires exactly one of text or key")
        }
    }
}

public enum ActionPointCoordinateSpace: String, Codable, Equatable, Sendable {
    case screen
    case window
    case screenshot
    case legacyScreen
}

public struct ActionPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let coordinateSpace: ActionPointCoordinateSpace
    public let app: String?
    /// The window frame these coordinates were computed against, when they were derived rather than
    /// given.
    ///
    /// A point resolved from a capture — recognized text, a screenshot-space coordinate — is only
    /// correct while that window is still where it was. Carrying the frame lets delivery measure
    /// the difference and refuse with it, instead of clicking a screen coordinate that has since
    /// come to mean somewhere else. Never accepted from a caller: a point a caller supplies has no
    /// provenance to record.
    public let sourceWindowFrame: AXFrame?

    public init(
        x: Double,
        y: Double,
        coordinateSpace: ActionPointCoordinateSpace = .legacyScreen,
        app: String? = nil,
        sourceWindowFrame: AXFrame? = nil
    ) {
        self.x = x
        self.y = y
        self.coordinateSpace = coordinateSpace
        self.app = app
        self.sourceWindowFrame = sourceWindowFrame
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "x": .double(x),
            "y": .double(y),
            "coordinateSpace": .string(coordinateSpace.rawValue)
        ]
        if let app {
            object["app"] = .string(app)
        }
        if let sourceWindowFrame {
            object["sourceWindowFrame"] = sourceWindowFrame.jsonValue
        }
        return .object(object)
    }

    public var targetDescription: String {
        let base = "point:\(format(x)),\(format(y))"
        return coordinateSpace == .legacyScreen ? base : "\(base)[\(coordinateSpace.rawValue)]"
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

public enum PointerTarget: Equatable, Sendable {
    case handle(String)
    case point(ActionPoint)

    /// The retained element this target names, or nil when it is a raw screen point.
    public var handle: String? {
        guard case let .handle(handle) = self else {
            return nil
        }
        return handle
    }

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

/// The backend boundary for the six mutating actions.
///
/// Every handler takes the caller's `DeliveryPolicy` explicitly: the policy gates delivery, and
/// delivery happens behind this boundary, so it has to travel the whole way rather than be
/// consulted once at the edge.
public struct PrimitiveActionHandlers {
    public var click: (String, DeliveryPolicy) throws -> PrimitiveActionResult
    public var clickPoint: (ActionPoint, DeliveryPolicy) throws -> PrimitiveActionResult
    public var invoke: (String, String, DeliveryPolicy) throws -> PrimitiveActionResult
    public var type: (String, String, DeliveryPolicy) throws -> PrimitiveActionResult
    public var keyboard: (String?, KeyboardIntent, DeliveryPolicy) throws -> PrimitiveActionResult
    public var scroll: (PointerTarget?, String?, Double, Double, DeliveryPolicy) throws -> PrimitiveActionResult
    public var drag: (PointerTarget, PointerTarget, String?, Int?, DeliveryPolicy) throws -> PrimitiveActionResult

    public init(
        click: @escaping (String, DeliveryPolicy) throws -> PrimitiveActionResult = { _, _ in throw JSONRPCError.methodNotFound("click") },
        clickPoint: @escaping (ActionPoint, DeliveryPolicy) throws -> PrimitiveActionResult = { _, _ in throw JSONRPCError.methodNotFound("click") },
        invoke: @escaping (String, String, DeliveryPolicy) throws -> PrimitiveActionResult = { _, _, _ in throw JSONRPCError.methodNotFound("invoke") },
        type: @escaping (String, String, DeliveryPolicy) throws -> PrimitiveActionResult = { _, _, _ in throw JSONRPCError.methodNotFound("type") },
        keyboard: @escaping (String?, KeyboardIntent, DeliveryPolicy) throws -> PrimitiveActionResult = { _, _, _ in throw JSONRPCError.methodNotFound("keyboard") },
        scroll: @escaping (PointerTarget?, String?, Double, Double, DeliveryPolicy) throws -> PrimitiveActionResult = { _, _, _, _, _ in throw JSONRPCError.methodNotFound("scroll") },
        drag: @escaping (PointerTarget, PointerTarget, String?, Int?, DeliveryPolicy) throws -> PrimitiveActionResult = { _, _, _, _, _ in throw JSONRPCError.methodNotFound("drag") }
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
