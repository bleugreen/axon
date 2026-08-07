import Foundation
import Testing
@testable import AxonCore

private let semantic = DeliveryCandidate(rung: .semantic, capability: .semanticAction, strategy: "AXPress")
private let pixel = DeliveryCandidate(rung: .pixel, capability: .backgroundPixelInput, strategy: "CGEventToPid")
private let foreground = DeliveryCandidate(rung: .foreground, capability: .globalInput, strategy: "CGEvent")

@Test func deliveryPolicyDefaultsToBackgroundOnlyAndRejectsUnknownValues() throws {
    #expect(DeliveryPolicy.default == .backgroundOnly)
    #expect(try DeliveryPolicy.validated("backgroundOnly") == .backgroundOnly)
    #expect(try DeliveryPolicy.validated("foregroundPermitted") == .foregroundPermitted)
    #expect(throws: JSONRPCError.self) {
        try DeliveryPolicy.validated("whateverItTakes")
    }

    let decoder = ToolParamDecoder(toolName: "click", params: ["target": .string("s1:2")])
    #expect(try decoder.deliveryPolicy() == .backgroundOnly)
}

@Test func deliveryPolicyIsAcceptedByEveryMutatingToolAndNoOthers() {
    #expect(ToolSurfaceSpec.mutatingToolNames == ["click", "type", "keyboard", "scroll", "drag", "invoke"])
    for name in ToolSurfaceSpec.mutatingToolNames {
        let parameter = ToolSurfaceSpec.tool(named: name)?.params.first { $0.name == "deliveryPolicy" }
        #expect(parameter?.required == false)
        #expect(parameter?.defaultValue == .string("backgroundOnly"))
    }
    #expect(ToolSurfaceSpec.tool(named: "look")?.params.contains { $0.name == "deliveryPolicy" } == false)
}

@Test func plannerTakesTheLowestRungThePolicyAndRuntimeAllow() {
    #expect(
        DeliveryPlanner.select(from: [semantic, pixel, foreground], policy: .backgroundOnly)
            == .candidate(semantic)
    )
    #expect(
        DeliveryPlanner.select(from: [semantic, pixel, foreground], policy: .backgroundOnly, after: .semantic)
            == .candidate(pixel)
    )
    // foregroundPermitted still prefers the quietest rung that works; it only widens the ceiling.
    #expect(
        DeliveryPlanner.select(from: [pixel, foreground], policy: .foregroundPermitted)
            == .candidate(pixel)
    )
    #expect(
        DeliveryPlanner.select(from: [semantic, pixel, foreground], policy: .foregroundPermitted, after: .pixel)
            == .candidate(foreground)
    )
}

@Test func plannerRefusesForegroundUnderBackgroundOnlyEvenAfterALowerRungFails() {
    guard case let .refusal(refusal) = DeliveryPlanner.select(
        from: [semantic, pixel, foreground],
        policy: .backgroundOnly,
        after: .pixel
    ) else {
        Issue.record("Expected a refusal once only the foreground rung remained")
        return
    }
    #expect(refusal.reason == .foregroundNotPermitted)
    #expect(refusal.requiredRung == .foreground)
    #expect(refusal.capability == .globalInput)
}

@Test func plannerReportsThePolicyBoundaryAheadOfALowerCapabilityGap() {
    let unbound = DeliveryCandidate(
        rung: .pixel,
        capability: .backgroundPixelInput,
        strategy: "CGEventToPid",
        unavailable: .backgroundPixelUnsupported,
        unavailableMessage: "no process to bind to"
    )

    guard case let .refusal(refusal) = DeliveryPlanner.select(
        from: [unbound, foreground],
        policy: .backgroundOnly
    ) else {
        Issue.record("Expected a refusal when neither rung is usable")
        return
    }
    // Opting in is the actionable answer, so it outranks the capability gap below it.
    #expect(refusal.reason == .foregroundNotPermitted)

    guard case let .refusal(permitted) = DeliveryPlanner.select(
        from: [unbound],
        policy: .foregroundPermitted
    ) else {
        Issue.record("Expected a refusal when the only rung is unavailable")
        return
    }
    #expect(permitted.reason == .backgroundPixelUnsupported)
    #expect(permitted.message == "no process to bind to")
}

@Test func plannerNeverOffersAnOptInToAMechanismTheRuntimeDoesNotHave() {
    // Reporting foregroundNotPermitted here would tell the caller to opt in to global input this
    // backend cannot produce, sending them after a permission that changes nothing.
    let missing = DeliveryCandidate(
        rung: .foreground,
        capability: .globalInput,
        strategy: "XTest",
        unavailable: .noDeliveryCandidate,
        unavailableMessage: "this session exposes no global input device"
    )

    for policy in DeliveryPolicy.allCases {
        guard case let .refusal(refusal) = DeliveryPlanner.select(from: [missing], policy: policy) else {
            Issue.record("A missing mechanism cannot be selected under \(policy)")
            return
        }
        #expect(refusal.reason == .noDeliveryCandidate)
        #expect(refusal.requiredRung == .foreground)
        #expect(refusal.message == "this session exposes no global input device")
    }
}

@Test func plannerNeverSelectsAClipboardCandidateAtAnyPolicy() {
    let clipboard = DeliveryCandidate(rung: .pixel, capability: .clipboard, strategy: "NSPasteboard")

    for policy in DeliveryPolicy.allCases {
        guard case let .refusal(refusal) = DeliveryPlanner.select(from: [clipboard], policy: policy) else {
            Issue.record("Clipboard delivery must never be selected, including under \(policy)")
            return
        }
        #expect(refusal.reason == .clipboardForbidden)
        #expect(refusal.capability == .clipboard)
    }
    #expect(DeliveryCapability.clipboard.isForbidden)
    #expect(DeliveryCapability.allCases.filter(\.isForbidden) == [.clipboard])
}

@Test func plannerRefusesAnEmptyLadderWithoutInventingAReason() {
    guard case let .refusal(refusal) = DeliveryPlanner.select(from: [], policy: .foregroundPermitted) else {
        Issue.record("An action with no mechanism cannot be delivered")
        return
    }
    #expect(refusal.reason == .noDeliveryCandidate)
    #expect(refusal.capability == nil)
}

@Test func refusalResultsCarryNoDispatchAndSerializeAtTheTopLevel() {
    let result = PrimitiveActionResult.refused(
        action: "keyboard",
        target: "frontmost",
        policy: .backgroundOnly,
        refusal: DeliveryRefusal(
            reason: .foregroundNotPermitted,
            requiredRung: .foreground,
            capability: .globalInput,
            message: "needs foreground"
        )
    )

    #expect(result.success == false)
    #expect(result.dispatchSuccess == false)
    #expect(result.delivery == nil)

    let json = result.jsonValue
    #expect(json["deliveryPolicy"] == .string("backgroundOnly"))
    #expect(json["delivery"] == .null)
    #expect(json["dispatchSuccess"] == .bool(false))
    #expect(json["refusal"]?["reason"] == .string("foregroundNotPermitted"))
    #expect(json["refusal"]?["requiredRung"] == .string("foreground"))
    #expect(json["refusal"]?["capability"] == .string("globalInput"))
    #expect(json["refusal"]?["message"] == .string("needs foreground"))
    // A refusal never claims a semantic outcome it did not attempt.
    #expect(json["semanticStatus"] == nil)
}

@Test func dispatchedAndUnverifiedResultsKeepTheirRungOnTheWire() {
    let verified = PrimitiveActionResult.dispatched(
        action: "AXPress", target: "s1:2", strategy: "AXAction",
        policy: .backgroundOnly, delivery: .semantic, success: true
    )
    #expect(verified.jsonValue["delivery"] == .string("semantic"))
    #expect(verified.jsonValue["dispatchSuccess"] == .bool(true))
    #expect(verified.jsonValue["refusal"] == .null)

    let unverified = PrimitiveActionResult.unverifiedDispatch(
        action: "click", target: "s1:2", strategy: "CGEventToPid",
        policy: .backgroundOnly, delivery: .pixel, dispatched: true, message: "dispatched"
    )
    #expect(unverified.jsonValue["delivery"] == .string("pixel"))
    #expect(unverified.jsonValue["success"] == .bool(false))
    #expect(unverified.jsonValue["dispatchSuccess"] == .bool(true))
    #expect(unverified.jsonValue["semanticStatus"] == .string("unverified"))
}

@Test func allVocabularyValuesRoundTripThroughTheirWireNames() throws {
    #expect(DeliveryPolicy.allCases.map(\.rawValue) == ["backgroundOnly", "foregroundPermitted"])
    #expect(DeliveryRung.allCases.map(\.rawValue) == ["semantic", "pixel", "foreground"])
    #expect(DeliveryRung.allCases.map(\.order) == [0, 1, 2])
    #expect(DeliveryCapability.allCases.map(\.rawValue) == [
        "semanticAction", "semanticValue", "backgroundPixelInput", "globalInput", "clipboard"
    ])
    #expect(DeliveryRefusalReason.allCases.map(\.rawValue) == [
        "foregroundNotPermitted",
        "backgroundPixelUnsupported",
        "targetIdentityUnavailable",
        "clipboardForbidden",
        "activationNotProved",
        "noDeliveryCandidate"
    ])

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let cleanup = ForegroundCleanup(
        priorApp: "com.example.prior",
        priorAppProcessIdentifier: 7,
        alreadyFrontmost: false,
        activationProved: true,
        restored: true,
        pointerRestored: true,
        message: nil
    )
    #expect(try decoder.decode(ForegroundCleanup.self, from: encoder.encode(cleanup)) == cleanup)
    #expect(cleanup.jsonValue["priorApp"] == .string("com.example.prior"))
    #expect(cleanup.jsonValue["pointerRestored"] == .bool(true))
}
