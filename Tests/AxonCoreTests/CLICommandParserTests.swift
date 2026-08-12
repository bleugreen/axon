import Foundation
import Testing
@testable import AxonCore

// These pin what the command line packs onto the wire against what the router accepts.
//
// The semantic-names cutover changed the shape of a `look` positional and of every element target,
// and the CLI kept sending the pre-cutover shape while every MCP-side and router-side test stayed
// green, because none of them go through argument parsing. Asserting the exact params object each
// command line builds — and handing the packed target back to `ToolTarget`, the same type the
// router validates with — is the only place that divergence is visible.

private let semanticTargetJSON = #"{"app":"Notes","name":"main/submit"}"#

@Test func lookWithoutAPositionalAsksForTheAppList() throws {
    #expect(try CLICommandParser.look(arguments: ["look"]).params == [:])
}

@Test func lookWithAPlainPositionalObservesThatApp() throws {
    #expect(try CLICommandParser.look(arguments: ["look", "Notes"]).params == ["app": .string("Notes")])
    #expect(try CLICommandParser.look(arguments: ["look", "com.apple.Notes"]).params == ["app": .string("com.apple.Notes")])
    // A pid parses as JSON but is still an app selector, so only an object may become a target.
    #expect(try CLICommandParser.look(arguments: ["look", "4213"]).params == ["app": .string("4213")])
}

@Test func lookWithASemanticObjectPagesThatElement() throws {
    let params = try CLICommandParser.look(arguments: ["look", semanticTargetJSON]).params
    #expect(params == ["target": .object(["app": .string("Notes"), "name": .string("main/submit")])])
    #expect(try ToolTarget(jsonValue: try #require(params["target"]), acceptedKinds: .element)
        == .semanticName(app: "Notes", name: "main/submit"))
    #expect(params["app"] == nil)
}

@Test func lookSinceIsUntouchedByThePositionalSplit() throws {
    #expect(try CLICommandParser.look(arguments: ["look", "--since", "s12"]).params == ["since": .string("s12")])
}

@Test func lookFlagsSplitBetweenWireParamsAndRendering() throws {
    let command = try CLICommandParser.look(arguments: [
        "look", "Notes", "--screenshot", "--screen-text", "--no-tree",
        "--offset", "5", "--limit", "20", "--depth", "3", "--frames", "--json"
    ])
    #expect(command.params == [
        "app": .string("Notes"),
        "screenshot": .bool(true),
        "screenText": .bool(true),
        "tree": .bool(false),
        "offset": .int(5),
        "limit": .int(20),
        "depth": .int(3)
    ])
    #expect(command.frames)
    #expect(command.json)
    #expect(!command.details)
}

@Test func lookDetailsAndDebugDifferOnlyInFormat() throws {
    let details = try CLICommandParser.look(arguments: ["look", "--details"])
    #expect(details.params == ["all": .bool(true)])
    #expect(details.details)
    #expect(!details.json)

    let debug = try CLICommandParser.look(arguments: ["look", "--debug"])
    #expect(debug.params == ["all": .bool(true), "format": .string("debug")])
    #expect(debug.details)
    #expect(debug.json)
}

// Screenshots are on by default post-#101, so the flag that carries information is the negative
// one. Omitting both must send neither key, leaving the default where the spec states it rather
// than restating it at the command line.
@Test func lookScreenshotFlagsAreExplicitInBothDirections() throws {
    #expect(try CLICommandParser.look(arguments: ["look", "Notes", "--no-screenshot"]).params == [
        "app": .string("Notes"),
        "screenshot": .bool(false)
    ])
    #expect(try CLICommandParser.look(arguments: ["look", "Notes", "--screenshot"]).params == [
        "app": .string("Notes"),
        "screenshot": .bool(true)
    ])
    #expect(try CLICommandParser.look(arguments: ["look", "Notes"]).params["screenshot"] == nil)
}

@Test func lookRejectsASecondPositional() throws {
    #expect(throws: CLIError.self) {
        try CLICommandParser.look(arguments: ["look", "Notes", "Mail"])
    }
}

@Test func clickPacksItsTargetAsJSON() throws {
    #expect(try CLICommandParser.click(arguments: ["click", semanticTargetJSON]) == [
        "target": .object(["app": .string("Notes"), "name": .string("main/submit")])
    ])
    // Click takes a target, not an app, and the refusal used to say otherwise. Exit code 2 is the
    // documented "used wrongly" signal that consumers script against.
    do {
        _ = try CLICommandParser.click(arguments: ["click"])
        Issue.record("click without a target should be refused")
    } catch let error as CLIError {
        #expect(String(describing: error) == "click requires a target")
        #expect(error.exitCode == 2)
    }
}

@Test func invokePacksItsTargetAsJSONAlongsideTheActionName() throws {
    #expect(try CLICommandParser.invoke(arguments: ["invoke", semanticTargetJSON, "AXPress"]) == [
        "target": .object(["app": .string("Notes"), "name": .string("main/submit")]),
        "name": .string("AXPress")
    ])
    #expect(throws: CLIError.self) {
        try CLICommandParser.invoke(arguments: ["invoke", semanticTargetJSON])
    }
}

@Test func typePacksItsTargetAsJSONAndJoinsTheRemainingValue() throws {
    #expect(try CLICommandParser.type(arguments: ["type", semanticTargetJSON, "hello", "there"]) == [
        "target": .object(["app": .string("Notes"), "name": .string("main/submit")]),
        "value": .string("hello there")
    ])
    #expect(throws: CLIError.self) {
        try CLICommandParser.type(arguments: ["type", semanticTargetJSON])
    }
}

@Test func everyPackedElementTargetSatisfiesTheRouterContract() throws {
    let packed = [
        try CLICommandParser.click(arguments: ["click", semanticTargetJSON]),
        try CLICommandParser.invoke(arguments: ["invoke", semanticTargetJSON, "AXPress"]),
        try CLICommandParser.type(arguments: ["type", semanticTargetJSON, "hello"]),
        try CLICommandParser.waitForValue(arguments: ["wait_for_value", semanticTargetJSON, "--contains", "done"]),
        try CLICommandParser.look(arguments: ["look", semanticTargetJSON]).params
    ]
    for params in packed {
        #expect(try ToolTarget(jsonValue: try #require(params["target"]), acceptedKinds: .element)
            == .semanticName(app: "Notes", name: "main/submit"))
    }
}

@Test func foregroundMayAppearAnywhereAndBecomesTheDeliveryPolicy() throws {
    let escalated = JSONValue.string(DeliveryPolicy.foregroundPermitted.rawValue)
    #expect(try CLICommandParser.click(arguments: ["click", "--foreground", semanticTargetJSON])["deliveryPolicy"] == escalated)
    #expect(try CLICommandParser.invoke(arguments: ["invoke", semanticTargetJSON, "AXPress", "--foreground"])["deliveryPolicy"] == escalated)
    #expect(try CLICommandParser.type(arguments: ["type", "--foreground", semanticTargetJSON, "hello"])["deliveryPolicy"] == escalated)
    #expect(try CLICommandParser.click(arguments: ["click", semanticTargetJSON])["deliveryPolicy"] == nil)
}

@Test func scrollPacksItsAppTargetAndDeltas() throws {
    #expect(try CLICommandParser.scroll(arguments: [
        "scroll", "--app", "Notes", "--target", semanticTargetJSON, "--dx", "10", "--dy", "-40"
    ]) == [
        "app": .string("Notes"),
        "target": .object(["app": .string("Notes"), "name": .string("main/submit")]),
        "deltaX": .double(10),
        "deltaY": .double(-40)
    ])
}

@Test func dragPacksBothEndpointsAsJSON() throws {
    #expect(try CLICommandParser.drag(arguments: [
        "drag", "--duration-ms", "250", semanticTargetJSON, #"{"app":"Notes","name":"main/well"}"#
    ]) == [
        "durationMs": .int(250),
        "from": .object(["app": .string("Notes"), "name": .string("main/submit")]),
        "to": .object(["app": .string("Notes"), "name": .string("main/well")])
    ])
    #expect(throws: CLIError.self) {
        try CLICommandParser.drag(arguments: ["drag", semanticTargetJSON])
    }
}

@Test func keyboardRequiresExactlyOneInputKind() throws {
    #expect(try CLICommandParser.keyboard(arguments: ["keyboard", "--app", "Notes", "--key", "cmd+s"]) == [
        "app": .string("Notes"),
        "key": .string("cmd+s")
    ])
    #expect(throws: CLIError.self) {
        try CLICommandParser.keyboard(arguments: ["keyboard", "--text", "a", "--key", "Return"])
    }
    #expect(throws: CLIError.self) {
        try CLICommandParser.keyboard(arguments: ["keyboard", "--app", "Notes"])
    }
}

@Test func findSendsTheAppBesideTheLocator() throws {
    #expect(try CLICommandParser.find(arguments: ["find", "Notes", #"{"role":"AXButton"}"#]) == [
        "app": .string("Notes"),
        "locator": .object(["role": .string("AXButton")])
    ])
    #expect(throws: CLIError.self) {
        try CLICommandParser.find(arguments: ["find", "Notes"])
    }
}

@Test func waitForValuePacksItsPredicate() throws {
    #expect(try CLICommandParser.waitForValue(arguments: [
        "wait_for_value", semanticTargetJSON, "--contains", "done", "--timeout-ms", "1500"
    ]) == [
        "target": .object(["app": .string("Notes"), "name": .string("main/submit")]),
        "contains": .string("done"),
        "timeoutMs": .int(1_500)
    ])
    // Unlike look, this positional has only one meaning, so a bare word is a usage error.
    #expect(throws: (any Error).self) {
        try CLICommandParser.waitForValue(arguments: ["wait_for_value", "Notes", "--contains", "done"])
    }
}

@Test func waitForStabilityPacksItsAppAndBounds() throws {
    #expect(try CLICommandParser.waitForStability(arguments: [
        "wait_for_stability", "Notes", "--condition", "changed", "--stable-ms", "500"
    ]) == [
        "app": .string("Notes"),
        "condition": .string("changed"),
        "stableMs": .int(500)
    ])
}

@Test func runAndSavePackTheirOptions() throws {
    #expect(try CLICommandParser.run(arguments: [
        "run", "flow.axn", "--arg", "name=value", "--dry-run"
    ]) == [
        "path": .string("flow.axn"),
        "argValues": .object(["name": .string("value")]),
        "dryRun": .bool(true)
    ])
    #expect(throws: CLIError.self) {
        try CLICommandParser.run(arguments: ["run", "--dry-run"])
    }
    #expect(try CLICommandParser.save(arguments: [
        "save", "--session", "s1", "--from", "c1", "--to", "c2", "--path", "out.axn", "--include-reads"
    ]) == [
        "sessionId": .string("s1"),
        "from": .string("c1"),
        "to": .string("c2"),
        "path": .string("out.axn"),
        "includeReads": .bool(true)
    ])
}
