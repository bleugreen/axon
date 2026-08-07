import Foundation
import Testing
@testable import AxonCore

// MARK: - Derivations

@Test func derivesFocusGainedOnTheActionsOwnTarget() {
    let facts = compile(observation(
        tool: "click",
        targetBefore: observedState(focused: false),
        targetAfter: observedState(focused: true)
    ))

    #expect(facts.count == 1)
    #expect(facts[0]["id"] == .string("a001.focused.0"))
    #expect(facts[0]["kind"] == .string("focused"))
    #expect(facts[0]["state"]?["focused"] == .bool(true))
    #expect(facts[0]["target"]?["app"] == .string("Example"))
}

@Test func derivesFocusThatMovedToADifferentElement() {
    let elsewhere = observedState(
        role: "AXTextArea",
        locator: ["role": .string("AXTextArea"), "identifier": .string("body")],
        focused: true
    )
    let facts = compile(observation(
        tool: "keyboard",
        targetBefore: observedState(focused: true),
        targetAfter: observedState(focused: true),
        focusAfter: elsewhere
    ))

    #expect(facts.count == 1)
    #expect(facts[0]["kind"] == .string("focused"))
    #expect(facts[0]["target"]?["locator"]?["identifier"] == .string("body"))
}

@Test func derivesEnabledTransitionsInBothDirections() {
    let disabled = compile(observation(
        tool: "click",
        targetBefore: observedState(enabled: true),
        targetAfter: observedState(enabled: false)
    ))
    let enabled = compile(observation(
        tool: "click",
        targetBefore: observedState(enabled: false),
        targetAfter: observedState(enabled: true)
    ))

    #expect(disabled.count == 1)
    #expect(disabled[0]["kind"] == .string("enabled"))
    #expect(disabled[0]["state"]?["enabled"] == .bool(false))
    #expect(enabled.count == 1)
    #expect(enabled[0]["state"]?["enabled"] == .bool(true))
}

@Test func derivesValueChangeOnATextField() {
    let facts = compile(observation(
        tool: "click",
        targetBefore: observedState(value: ""),
        targetAfter: observedState(value: "Ada Lovelace")
    ))

    #expect(facts.count == 1)
    #expect(facts[0]["kind"] == .string("value"))
    #expect(facts[0]["state"]?["value"]?["equals"] == .string("Ada Lovelace"))
}

@Test func derivesSelectionChangeOnAPopUpButtonAsSelectedRatherThanValue() {
    let popUp: [String: JSONValue] = ["role": .string("AXPopUpButton"), "identifier": .string("units")]
    let facts = compile(observation(
        tool: "click",
        targetBefore: observedState(role: "AXPopUpButton", locator: popUp, value: "Metric"),
        targetAfter: observedState(role: "AXPopUpButton", locator: popUp, value: "Imperial")
    ))

    #expect(facts.count == 1)
    #expect(facts[0]["kind"] == .string("selected"))
    #expect(facts[0]["state"]?["selected"]?["equals"] == .string("Imperial"))
}

@Test func derivesAWindowThatAppeared() {
    let facts = compile(observation(
        tool: "click",
        windowTitlesBefore: ["Main"],
        windowTitlesAfter: ["Main", "Preferences"]
    ))

    #expect(facts.count == 1)
    #expect(facts[0]["kind"] == .string("window"))
    #expect(facts[0]["target"]?["locator"]?["role"] == .string("AXWindow"))
    #expect(facts[0]["target"]?["locator"]?["title"] == .string("Preferences"))
    // Existence-only: the window fact makes no claim beyond the locator resolving.
    #expect(facts[0]["state"] == nil)
}

// MARK: - Exclusions

@Test func dropsValueAssertionThatEchoesTheActionsOwnInput() {
    let facts = compile(observation(
        tool: "type",
        inputs: ["Ada Lovelace"],
        targetBefore: observedState(value: ""),
        targetAfter: observedState(value: "Ada Lovelace", valueDerivedFromInput: true)
    ))

    #expect(facts.isEmpty)
}

@Test func dropsDownstreamEchoOfTypedTextOnADifferentElement() {
    // The typed title turned up in a new window's title. Nothing flagged it at capture, because
    // it is not the target's own value, but the user will parameterize the input all the same.
    let facts = compile(observation(
        tool: "type",
        inputs: ["Draft issue title"],
        windowTitlesBefore: ["Issues"],
        windowTitlesAfter: ["Issues", "Draft issue title - Editor"]
    ))

    #expect(facts.isEmpty)
}

@Test func dropsAnEchoOfTextTypedByAnEarlierStep() {
    // The click carries no input of its own; the window it opened is titled after text a previous
    // step typed, and that step's value is exactly what the user will parameterize.
    let facts = DerivedPostconditionCompiler().facts(for: DerivedPostconditionCompiler.Input(
        actionID: "a002",
        tool: "click",
        observation: observation(
            tool: "click",
            windowTitlesBefore: ["Issues"],
            windowTitlesAfter: ["Issues", "Result: Draft issue title"]
        ),
        workflowInputs: ["Draft issue title"]
    ))

    #expect(facts.isEmpty)
}

@Test func dropsAssertionThatOnlyRestatesTheTargetsOwnLocator() {
    let button: [String: JSONValue] = ["role": .string("AXButton"), "title": .string("Submit")]
    let facts = compile(observation(
        tool: "click",
        targetBefore: observedState(role: "AXButton", locator: button, value: nil),
        targetAfter: observedState(role: "AXButton", locator: button, value: "Submit")
    ))

    #expect(facts.isEmpty)
}

@Test func dropsSecretTaintedAssertions() {
    let facts = compile(observation(
        tool: "click",
        targetBefore: observedState(value: ""),
        targetAfter: observedState(value: "<redacted: active-credential>")
    ))

    #expect(facts.isEmpty)
}

@Test func derivesNothingFromAnElementWithoutADurableLocator() {
    let facts = compile(observation(
        tool: "click",
        targetBefore: observedState(locator: nil, value: "", focused: false, enabled: false),
        targetAfter: observedState(locator: nil, value: "Ada", focused: true, enabled: true)
    ))

    #expect(facts.isEmpty)
}

@Test func anUnsettledReadDropsStringAssertionsButKeepsBooleanOnes() {
    let facts = compile(observation(
        tool: "click",
        targetBefore: observedState(value: "", focused: false, enabled: false),
        targetAfter: observedState(value: "mid-transition", focused: true, enabled: true, settled: false)
    ))

    #expect(facts.map { $0["kind"] } == [.string("focused"), .string("enabled")])
}

@Test func derivesNothingWhenNoObservedStateChanged() {
    let unchanged = observedState(value: "steady", focused: true, enabled: true)
    let facts = compile(observation(
        tool: "click",
        targetBefore: unchanged,
        targetAfter: unchanged,
        windowTitlesBefore: ["Main"],
        windowTitlesAfter: ["Main"]
    ))

    #expect(facts.isEmpty)
}

@Test func numbersMultipleFactsOfTheSameKindFromTheActionID() {
    let facts = compile(observation(
        tool: "click",
        windowTitlesBefore: [],
        windowTitlesAfter: ["Preferences", "Inspector"]
    ))

    #expect(facts.count == 2)
    #expect(facts[0]["id"] == .string("a001.window.0"))
    #expect(facts[1]["id"] == .string("a001.window.1"))
}

// MARK: - Fixtures

private func compile(_ observation: ActionObservation, actionID: String = "a001") -> [JSONValue] {
    DerivedPostconditionCompiler().facts(for: DerivedPostconditionCompiler.Input(
        actionID: actionID,
        tool: observation.tool,
        observation: observation
    ))
}

private func observedState(
    app: String = "Example",
    role: String = "AXTextField",
    locator: [String: JSONValue]? = ["role": .string("AXTextField"), "identifier": .string("name-field")],
    value: String? = nil,
    focused: Bool? = nil,
    enabled: Bool? = nil,
    valueDerivedFromInput: Bool = false,
    settled: Bool = true
) -> ObservedElementState {
    ObservedElementState(
        app: app,
        role: role,
        locator: locator,
        value: value,
        focused: focused,
        enabled: enabled,
        valueDerivedFromInput: valueDerivedFromInput,
        settled: settled
    )
}

private func observation(
    tool: String,
    app: String? = "Example",
    inputs: [String] = [],
    targetBefore: ObservedElementState? = nil,
    targetAfter: ObservedElementState? = nil,
    focusAfter: ObservedElementState? = nil,
    windowTitlesBefore: [String] = [],
    windowTitlesAfter: [String] = []
) -> ActionObservation {
    ActionObservation(
        tool: tool,
        app: app,
        inputs: inputs,
        targetBefore: targetBefore,
        targetAfter: targetAfter,
        focusAfter: focusAfter,
        windowTitlesBefore: windowTitlesBefore,
        windowTitlesAfter: windowTitlesAfter
    )
}
