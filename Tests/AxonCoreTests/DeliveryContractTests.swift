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

@Test func aReportedRefusalCarriesEveryObstacleTheLadderWalkedPast() {
    // The pixel rung's obstacle is the only thing that answers "would the quiet rung ever work
    // against this target". Whichever reason wins the ranking, that sentence has to survive.
    let unbound = DeliveryCandidate(
        rung: .pixel,
        capability: .backgroundPixelInput,
        strategy: "CGEventToPid",
        unavailable: .backgroundPixelUnsupported,
        unavailableMessage: "the click names a bare screen point with no application behind it"
    )
    let obstacle = DeliveryObstacle(
        rung: .pixel,
        reason: .backgroundPixelUnsupported,
        message: "the click names a bare screen point with no application behind it"
    )

    // The policy boundary outranks the capability gap below it, and the gap still travels.
    guard case let .refusal(policyBound) = DeliveryPlanner.select(
        from: [unbound, foreground],
        policy: .backgroundOnly
    ) else {
        Issue.record("Expected a refusal when the pixel rung is out and the policy forbids foreground")
        return
    }
    #expect(policyBound.reason == .foregroundNotPermitted)
    #expect(policyBound.alsoRefused == [obstacle])
    #expect(policyBound.jsonValue["alsoRefused"] == .array([obstacle.jsonValue]))

    // Same ladder with no global input at all: a different winning reason, the same evidence
    // underneath it.
    let noGlobalInput = DeliveryCandidate(
        rung: .foreground,
        capability: .globalInput,
        strategy: "CGEvent",
        unavailable: .noDeliveryCandidate,
        unavailableMessage: "this session exposes no global input device"
    )
    guard case let .refusal(noMechanism) = DeliveryPlanner.select(
        from: [unbound, noGlobalInput],
        policy: .foregroundPermitted
    ) else {
        Issue.record("Expected a refusal when neither rung exists")
        return
    }
    #expect(noMechanism.reason == .noDeliveryCandidate)
    #expect(noMechanism.alsoRefused == [obstacle])

    // The reported refusal is never also listed as one of the ones walked past.
    for refusal in [policyBound, noMechanism] {
        #expect(refusal.alsoRefused.contains { $0.message == refusal.message } == false)
    }
}

@Test func aRefusalWithNothingBelowItReportsNoObstacles() {
    guard case let .refusal(emptyLadder) = DeliveryPlanner.select(from: [], policy: .foregroundPermitted),
          case let .refusal(onlyRung) = DeliveryPlanner.select(
              from: [foreground],
              policy: .backgroundOnly,
              after: .pixel
          )
    else {
        Issue.record("Both ladders end in a refusal")
        return
    }
    #expect(emptyLadder.alsoRefused.isEmpty)
    #expect(onlyRung.alsoRefused.isEmpty)
    #expect(emptyLadder.jsonValue["alsoRefused"] == .array([]))
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
