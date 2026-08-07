import Foundation
import Testing
@testable import AxonCore

/// Conformance between the Swift delivery contract and the shared fixtures.
///
/// `rust/axon-core/tests/delivery.rs` runs the equivalent checks against the same files. Both
/// languages parsing the same bytes is what keeps a macOS refusal and a Windows refusal one
/// contract rather than two dialects.
private func deliveryFixture(_ name: String) throws -> JSONValue {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("schema/fixtures/delivery")
        .appendingPathComponent(name)
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

private func strings(_ value: JSONValue?) -> [String] {
    guard case let .array(entries)? = value else { return [] }
    return entries.compactMap { entry in
        guard case let .string(text) = entry else { return nil }
        return text
    }
}

@Test func wireVocabularyMatchesTheSharedFixtureInCanonicalOrder() throws {
    let vocabulary = try deliveryFixture("vocabulary.json")

    #expect(DeliveryPolicy.allCases.map(\.rawValue) == strings(vocabulary["policies"]))
    #expect(vocabulary["defaultPolicy"] == .string(DeliveryPolicy.default.rawValue))
    #expect(DeliveryRung.allCases.map(\.rawValue) == strings(vocabulary["rungs"]))
    #expect(DeliveryCapability.allCases.map(\.rawValue) == strings(vocabulary["capabilities"]))
    #expect(
        DeliveryCapability.allCases.filter(\.isForbidden).map(\.rawValue)
            == strings(vocabulary["forbiddenCapabilities"])
    )
    #expect(DeliveryRefusalReason.allCases.map(\.rawValue) == strings(vocabulary["refusalReasons"]))
    #expect(ToolSurfaceSpec.mutatingToolNames == strings(vocabulary["mutatingTools"]))
}

@Test func everyFixtureResultCaseRoundTripsThroughTheActionResult() throws {
    guard case let .array(cases)? = try deliveryFixture("results.json")["cases"] else {
        Issue.record("delivery result fixture must carry cases")
        return
    }

    for fixtureCase in cases {
        guard case let .string(name)? = fixtureCase["name"],
              case let .string(rawPolicy)? = fixtureCase["deliveryPolicy"]
        else {
            Issue.record("every delivery result case names itself and its policy")
            continue
        }
        let policy = try DeliveryPolicy.validated(rawPolicy)
        let delivery: DeliveryRung? = {
            guard case let .string(rawRung)? = fixtureCase["delivery"] else { return nil }
            return DeliveryRung(rawValue: rawRung)
        }()
        let refusal: DeliveryRefusal? = try {
            guard let value = fixtureCase["refusal"], value != .null else { return nil }
            return try JSONDecoder().decode(
                DeliveryRefusal.self,
                from: JSONEncoder().encode(value)
            )
        }()

        let result = PrimitiveActionResult(
            action: "fixture",
            target: "fixture",
            strategy: refusal == nil ? "fixture" : "refused",
            success: false,
            deliveryPolicy: policy,
            delivery: delivery,
            dispatchSuccess: fixtureCase["dispatchSuccess"] == .bool(true),
            refusal: refusal
        )
        let json = result.jsonValue

        #expect(json["deliveryPolicy"] == fixtureCase["deliveryPolicy"], "\(name) policy")
        #expect(json["delivery"] == fixtureCase["delivery"], "\(name) rung")
        #expect(json["dispatchSuccess"] == fixtureCase["dispatchSuccess"], "\(name) dispatch")
        #expect(json["refusal"] == fixtureCase["refusal"], "\(name) refusal")

        // A refusal is decided before the mechanism it names acts, so it can never claim a rung.
        if refusal != nil, fixtureCase["delivery"] == .null {
            #expect(result.dispatchSuccess == false, "\(name) dispatch")
        }

        if let foreground = fixtureCase["foreground"], foreground != .null {
            let cleanup = try JSONDecoder().decode(
                ForegroundCleanup.self,
                from: JSONEncoder().encode(foreground)
            )
            #expect(cleanup.jsonValue == foreground, "\(name) foreground cleanup")
        }
    }
}
