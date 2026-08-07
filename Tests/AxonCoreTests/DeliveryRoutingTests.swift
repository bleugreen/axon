import Foundation
import Testing
@testable import AxonCore

/// Records the policy every handler was called with, so a test can prove the caller's policy
/// reached the backend rather than being consulted and dropped at the edge.
private final class PolicySpy: @unchecked Sendable {
    private(set) var seen: [DeliveryPolicy] = []

    func record(_ policy: DeliveryPolicy) -> PrimitiveActionResult {
        seen.append(policy)
        return PrimitiveActionResult.dispatched(
            action: "spy", target: "spy", strategy: "spy",
            policy: policy, delivery: .semantic, success: true
        )
    }

    var handlers: PrimitiveActionHandlers {
        PrimitiveActionHandlers(
            click: { _, policy in self.record(policy) },
            clickPoint: { _, policy in self.record(policy) },
            invoke: { _, _, policy in self.record(policy) },
            type: { _, _, policy in self.record(policy) },
            keyboard: { _, _, policy in self.record(policy) },
            scroll: { _, _, _, _, policy in self.record(policy) },
            drag: { _, _, _, _, policy in self.record(policy) }
        )
    }
}

private let mutatingRequests: [(method: String, params: [String: JSONValue])] = [
    ("click", ["target": .string("s1:2")]),
    ("type", ["target": .string("s1:2"), "value": .string("hello")]),
    ("keyboard", ["key": .string("Return")]),
    ("scroll", ["target": .string("s1:2")]),
    ("drag", ["from": .string("s1:2"), "to": .string("s1:3")]),
    ("invoke", ["target": .string("s1:2"), "name": .string("AXPress")])
]

@Test func omittedPolicyReachesEveryHandlerAsBackgroundOnly() {
    let spy = PolicySpy()
    let router = CommandRouter(actions: spy.handlers)

    for request in mutatingRequests {
        let response = router.handle(JSONRPCRequest(
            id: .string(request.method),
            method: request.method,
            params: .object(request.params)
        ))
        #expect(response.error == nil)
    }

    #expect(spy.seen == Array(repeating: .backgroundOnly, count: mutatingRequests.count))
}

@Test func explicitForegroundPolicyReachesEveryHandler() {
    let spy = PolicySpy()
    let router = CommandRouter(actions: spy.handlers)

    for request in mutatingRequests {
        var params = request.params
        params["deliveryPolicy"] = .string("foregroundPermitted")
        let response = router.handle(JSONRPCRequest(
            id: .string(request.method),
            method: request.method,
            params: .object(params)
        ))
        #expect(response.error == nil)
    }

    #expect(spy.seen == Array(repeating: .foregroundPermitted, count: mutatingRequests.count))
}

@Test func invalidPolicyFailsBeforeAnyTargetResolutionOrDispatch() {
    let spy = PolicySpy()
    var resolutions = 0
    let router = CommandRouter(
        resolveLocator: { _, _, _ in
            resolutions += 1
            throw JSONRPCError.internalError("locator resolution must not run")
        },
        actions: spy.handlers
    )

    for request in mutatingRequests {
        var params = request.params
        params["deliveryPolicy"] = .string("whateverItTakes")
        let response = router.handle(JSONRPCRequest(
            id: .string(request.method),
            method: request.method,
            params: .object(params)
        ))
        #expect(response.error?.code == JSONRPCError.invalidParams("").code)
        #expect(response.error?.message.contains("deliveryPolicy") == true)
    }

    #expect(spy.seen.isEmpty)
    #expect(resolutions == 0)
}

@Test func refusalsTravelTheSocketResultEnvelopeIntact() {
    let refusal = DeliveryRefusal(
        reason: .backgroundPixelUnsupported,
        requiredRung: .pixel,
        capability: .backgroundPixelInput,
        message: "no target-bound mechanism for this window"
    )
    let router = CommandRouter(actions: PrimitiveActionHandlers(
        click: { target, policy in
            .refused(action: "click", target: target, policy: policy, refusal: refusal)
        }
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("click-refused"),
        method: "click",
        params: .object(["target": .string("s1:2")])
    ))

    // A refusal is an action result, not a transport error: the request was well formed.
    #expect(response.error == nil)
    let action = response.result?["action"]
    #expect(action?["success"] == .bool(false))
    #expect(action?["dispatchSuccess"] == .bool(false))
    #expect(action?["delivery"] == .null)
    #expect(action?["deliveryPolicy"] == .string("backgroundOnly"))
    #expect(action?["refusal"]?["reason"] == .string("backgroundPixelUnsupported"))
    #expect(action?["refusal"]?["requiredRung"] == .string("pixel"))
    #expect(action?["refusal"]?["capability"] == .string("backgroundPixelInput"))
}

@Test func refusalsSurviveAnAxnRunTraceAsFailuresWithoutChangingTheBatchWrapper() throws {
    let router = CommandRouter(actions: PrimitiveActionHandlers(
        keyboard: { _, _, policy in
            .refused(
                action: "keyboard",
                target: "frontmost",
                policy: policy,
                refusal: DeliveryRefusal(
                    reason: .foregroundNotPermitted,
                    requiredRung: .foreground,
                    capability: .globalInput,
                    message: "CGEvent requires foreground delivery"
                )
            )
        }
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("run-refused"),
        method: "run",
        params: .object(["actions": .array([.object([
            "tool": .string("keyboard"),
            "key": .string("Return")
        ])])])
    ))

    let batch = response.result?["batch"]
    #expect(batch?["success"] == .bool(false))
    let step = batch?["trace"]?[0]
    #expect(step?["success"] == .bool(false))
    // Nothing was dispatched, and the refusal reaches the trace intact.
    #expect(step?["result"]?["dispatchSuccess"] == .bool(false))
    #expect(step?["result"]?["delivery"] == .null)
    #expect(step?["result"]?["refusal"]?["reason"] == .string("foregroundNotPermitted"))
}

@Test func anUnresolvableTargetIsATransportErrorNotADeliveryRefusal() throws {
    // A refusal means the request was well formed and the target resolved, and the daemon
    // declined. A target that is absent, malformed, or stale never gets that far, so it stays a
    // JSON-RPC error even under the default policy where the rung would have been refused anyway.
    let spy = PolicySpy()
    let router = CommandRouter(
        resolveLocator: { _, _, _ in throw JSONRPCError.invalidParams("no such element") },
        actions: spy.handlers
    )

    let unresolvable: [(method: String, params: [String: JSONValue])] = [
        ("click", [:]),
        ("click", ["target": .object(["app": .string("Example"), "locator": .object(["role": .string("AXButton")])])]),
        ("type", ["target": .string("s1:2")]),
        ("invoke", ["target": .string("s1:2")]),
        ("drag", ["from": .string("s1:2")])
    ]

    for request in unresolvable {
        let response = router.handle(JSONRPCRequest(
            id: .string(request.method),
            method: request.method,
            params: .object(request.params)
        ))
        #expect(response.error != nil, "\(request.method) must fail as a transport error")
        #expect(response.result?["action"]?["refusal"] == nil, "\(request.method)")
    }

    #expect(spy.seen.isEmpty)
}

@Test func mcpToolSchemasOfferTheDeliveryPolicyOnEveryMutatingTool() {
    let tools = ToolSurfaceSchema.mcpToolJSONValues()

    for name in ToolSurfaceSpec.mutatingToolNames {
        let tool = tools.first { $0["name"] == .string(name) }
        let property = tool?["inputSchema"]?["properties"]?["deliveryPolicy"]
        #expect(property?["type"] == .string("string"))
        #expect(property?["description"]?.stringValue?.contains("backgroundOnly") == true)
        // The policy is never required: omitting it is how a caller gets the safe default.
        #expect(tool?["inputSchema"]?["required"]?.arrayValue?.contains(.string("deliveryPolicy")) != true)
    }
}

private extension JSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else { return nil }
        return values
    }
}
