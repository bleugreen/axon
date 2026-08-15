import Foundation
import Testing
@testable import AxonCore

/// Conformance between the Swift runner and the shared dispatch-verification contract.
///
/// `rust/axon-core/tests/conformance.rs` runs the equivalent checks against the same file. Both
/// languages reading the same bytes is what keeps a dispatched click meaning one thing on macOS and
/// one thing on Windows, rather than `success` carrying a different promise per platform.
private struct DispatchVerificationCase {
    let name: String
    let tool: String
    let factKinds: [String]
    let dispatchSucceeded: Bool
    let expectationHeldBeforeDispatch: Bool
    let expectationHoldsAfterDispatch: Bool
    let dispatched: Bool
    let postconditionDecides: Bool
    let actionSuccess: Bool

    init?(_ value: JSONValue) {
        guard case let .string(name)? = value["name"],
              case let .string(tool)? = value["tool"],
              case let .array(kinds)? = value["factKinds"],
              case let .bool(dispatchSucceeded)? = value["dispatchSucceeded"],
              case let .bool(heldBefore)? = value["expectationHeldBeforeDispatch"],
              case let .bool(holdsAfter)? = value["expectationHoldsAfterDispatch"],
              case let .bool(dispatched)? = value["dispatched"],
              case let .bool(decides)? = value["postconditionDecides"],
              case let .bool(success)? = value["actionSuccess"]
        else { return nil }
        self.name = name
        self.tool = tool
        self.factKinds = kinds.compactMap { kind in
            guard case let .string(text) = kind else { return nil }
            return text
        }
        self.dispatchSucceeded = dispatchSucceeded
        self.expectationHeldBeforeDispatch = heldBefore
        self.expectationHoldsAfterDispatch = holdsAfter
        self.dispatched = dispatched
        self.postconditionDecides = decides
        self.actionSuccess = success
    }
}

/// The world each case describes, observed through the one list whose value the facts assert.
private func dispatchVerificationSnapshot(holds: Bool) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("dispatch-verification-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: holds ? "After" : "Before", children: [
                AXNode(role: "AXList", value: holds ? "After" : "Before", identifier: "subject-list")
            ])
        ],
        screenshot: nil
    )
}

private func dispatchVerificationFact(kind: String, index: Int) -> JSONValue {
    if kind == "changed" {
        return .object([
            "id": .string("fact-\(index)"),
            "kind": .string("changed"),
            "target": .object(["app": .string("Example")])
        ])
    }
    return .object([
        "id": .string("fact-\(index)"),
        "kind": .string(kind),
        "target": .object([
            "app": .string("Example"),
            "locator": .object(["role": .string("AXList"), "identifier": .string("subject-list")])
        ]),
        "state": .object(["value": .object(["equals": .string("After")])])
    ])
}

/// Parameters each tool needs to reach dispatch, beyond the target every one of them carries.
private func dispatchVerificationParams(tool: String) -> [String: JSONValue] {
    switch tool {
    case "keyboard": return ["key": .string("End")]
    case "type": return ["value": .string("After")]
    case "invoke": return ["name": .string("AXPress")]
    case "scroll": return ["direction": .string("down"), "amount": .int(1)]
    default: return [:]
    }
}

@Test func everySharedCaseAgreesOnWhenAPostconditionDecidesADispatchedAction() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("schema/fixtures/axn/dispatch-verification.json")
    let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    guard case let .array(rawCases)? = fixture["cases"] else {
        Issue.record("the shared dispatch fixture must carry cases")
        return
    }
    let cases = rawCases.compactMap(DispatchVerificationCase.init)
    #expect(cases.count == rawCases.count, "every case names its decision")

    for fixtureCase in cases {
        var dispatched = false
        var postDispatchObservations = 0
        let runner = AxnRunner(
            commandHandler: { request in
                dispatched = true
                return JSONRPCResponse(id: request.id, result: ["action": .object([
                    "success": .bool(false),
                    "dispatchSuccess": .bool(fixtureCase.dispatchSucceeded),
                    "semanticSuccess": .null,
                    "semanticStatus": .string("unverified")
                ])])
            },
            snapshotProvider: { _ in
                if dispatched { postDispatchObservations += 1 }
                let holds = dispatched
                    ? fixtureCase.expectationHoldsAfterDispatch
                    : fixtureCase.expectationHeldBeforeDispatch
                return dispatchVerificationSnapshot(holds: holds)
            },
            changePollIntervalMs: 1,
            changeTimeoutMs: 20
        )

        var action: [String: JSONValue] = [
            "tool": .string(fixtureCase.tool),
            "target": .object([
                "app": .string("Example"),
                "name": .string("main/subject"),
                "locator": .object([
                    "role": .string("AXList"),
                    "identifier": .string("subject-list")
                ])
            ])
        ]
        action.merge(dispatchVerificationParams(tool: fixtureCase.tool)) { current, _ in current }
        if !fixtureCase.factKinds.isEmpty {
            action["expects"] = .array(fixtureCase.factKinds.enumerated().map { index, kind in
                dispatchVerificationFact(kind: kind, index: index)
            })
        }

        let batch = try runner.run(params: ["actions": .array([.object(action)])])

        // A probe that cannot be evaluated establishes no before-state, so there is nothing a
        // later read could be evidence about. The action must fail without acting at all.
        #expect(dispatched == fixtureCase.dispatched, "\(fixtureCase.name): dispatched")

        // The runner consults a postcondition after dispatch exactly when it handed that action's
        // verdict to it, so consultation is the observable signature of that decision.
        #expect(
            (postDispatchObservations > 0) == fixtureCase.postconditionDecides,
            "\(fixtureCase.name): postcondition consulted after dispatch"
        )
        #expect(
            batch["trace"]?[0]?["success"] == .bool(fixtureCase.actionSuccess),
            "\(fixtureCase.name): trace"
        )
        #expect(batch["success"] == .bool(fixtureCase.actionSuccess), "\(fixtureCase.name): run")

        // A postcondition that decided in the action's favour rewrites the unverified result it
        // judged, so a caller reading the result agrees with the trace.
        if fixtureCase.actionSuccess {
            #expect(
                batch["trace"]?[0]?["result"]?["semanticSuccess"] == .bool(true),
                "\(fixtureCase.name): result"
            )
            #expect(
                batch["trace"]?[0]?["result"]?["semanticStatus"] == .string("verified"),
                "\(fixtureCase.name): verification"
            )
        }
    }
}
