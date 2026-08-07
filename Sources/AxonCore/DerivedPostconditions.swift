import Foundation

/// The shared rule set for turning observed state transitions into `expects` facts.
///
/// Both the derivation and the exclusions live here so there is one written-down answer to "may
/// this be asserted?", and so the answer can be tested without touching Accessibility.
public enum DerivedPostconditionRules {
    /// Roles whose `AXValue` reads as a chosen option rather than as free text. A change on one of
    /// these is a selection, and `RecordedFactEvaluator` checks a `selected` fact against the same
    /// `AXValue` a `value` fact would use.
    public static let selectionRoles: Set<String> = [
        "AXCheckBox",
        "AXComboBox",
        "AXMenuItem",
        "AXPopUpButton",
        "AXRadioButton"
    ]

    /// Locator keys that already prove themselves by resolving. An assertion repeating one of them
    /// verifies nothing.
    private static let identityLocatorKeys = ["title", "value", "description", "identifier"]

    /// Below this length a substring comparison stops meaning anything: a one-letter keystroke
    /// would exclude every assertion that happens to contain that letter.
    private static let minimumSubstringLength = 3

    /// Whether an assertion candidate carries the action's own input forward.
    ///
    /// Both directions matter. The direct case is a `type` whose field now reads back exactly what
    /// was typed; the downstream case is a preview label or window title that quotes it. Either
    /// way the user is expected to parameterize the input, and `expects` is not a substitutable
    /// field - AxnRunner rejects reference syntax anywhere inside it - so the assertion would
    /// either go stale or make the whole file unrunnable.
    public static func echoesInput(_ candidate: String, inputs: [String]) -> Bool {
        let needle = normalized(candidate)
        guard !needle.isEmpty else {
            return false
        }
        for input in inputs {
            let hay = normalized(input)
            guard !hay.isEmpty else {
                continue
            }
            if hay == needle {
                return true
            }
            if needle.count >= minimumSubstringLength, hay.contains(needle) {
                return true
            }
            if hay.count >= minimumSubstringLength, needle.contains(hay) {
                return true
            }
        }
        return false
    }

    /// Whether an assertion merely restates identity the fact's own locator already carries.
    ///
    /// Clicking a button labelled `Submit` and then asserting the button still reads `Submit`
    /// proves nothing: the locator resolving at all already proved it.
    public static func restatesLocator(_ candidate: String, locator: [String: JSONValue]) -> Bool {
        let needle = normalized(candidate)
        guard !needle.isEmpty else {
            return false
        }
        return identityLocatorKeys.contains { key in
            guard case let .string(value)? = locator[key] else {
                return false
            }
            return normalized(value) == needle
        }
    }

    /// Whether a string is secret-tainted and must never reach a saved file as an assertion.
    ///
    /// Observations are redacted before they are stored, so the marker check is the load-bearing
    /// one; running the deterministic rules again is defence in depth behind the input-echo rule.
    public static func isSecretTainted(
        _ candidate: String,
        deterministicRedactor: DeterministicRedactor = .standard
    ) -> Bool {
        if candidate.contains("<redacted:") {
            return true
        }
        return deterministicRedactor.redaction(
            for: "value",
            value: candidate,
            context: DeterministicRedactionContext(value: candidate)
        ) != nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Turns one action's observation into the postconditions that are safe to assert on replay.
///
/// Pure by construction: no Accessibility access, no I/O, no clock. Every rule that decides what a
/// saved workflow claims is reachable from a hand-built observation.
public struct DerivedPostconditionCompiler {
    public struct Input {
        public let actionID: String
        public let tool: String
        public let observation: ActionObservation
        /// Every input string the saved workflow carries, not only this action's own.
        ///
        /// Any of them may be parameterized later, and an echo often surfaces a step or two after
        /// the step that typed it - a click opens a window titled after text typed earlier. So no
        /// step may assert any input the workflow contains, whichever step supplied it.
        public let workflowInputs: [String]

        public init(
            actionID: String,
            tool: String,
            observation: ActionObservation,
            workflowInputs: [String] = []
        ) {
            self.actionID = actionID
            self.tool = tool
            self.observation = observation
            self.workflowInputs = workflowInputs
        }

        var excludedInputs: [String] {
            observation.inputs + workflowInputs
        }
    }

    /// One derived transition, before the exclusions have had their say.
    private struct Candidate {
        let kind: String
        let app: String
        let locator: [String: JSONValue]?
        let state: [String: JSONValue]
        /// The string this candidate asserts, when it asserts one. Existence-only facts have none.
        let assertion: String?
        /// Capture-time verdict: this string came out of the action's own input.
        let derivedFromInput: Bool
        /// Whether an unsettled read invalidates the candidate. Booleans and window-title sets are
        /// stable enough to keep; a string read mid-transition is not.
        let requiresSettled: Bool
        let settled: Bool
    }

    private let deterministicRedactor: DeterministicRedactor

    public init(deterministicRedactor: DeterministicRedactor = .standard) {
        self.deterministicRedactor = deterministicRedactor
    }

    public func facts(for input: Input) -> [JSONValue] {
        var counters: [String: Int] = [:]
        return candidates(for: input.observation)
            .filter { survives($0, inputs: input.excludedInputs) }
            .map { candidate in
                let index = counters[candidate.kind, default: 0]
                counters[candidate.kind] = index + 1
                return fact(candidate, id: "\(input.actionID).\(candidate.kind).\(index)")
            }
    }

    private func candidates(for observation: ActionObservation) -> [Candidate] {
        var candidates: [Candidate] = []
        let before = observation.targetBefore
        let after = observation.targetAfter

        if let after, before?.focused != true, after.focused == true {
            candidates.append(Candidate(
                kind: "focused",
                app: after.app,
                locator: after.locator,
                state: ["focused": .bool(true)],
                assertion: nil,
                derivedFromInput: false,
                requiresSettled: false,
                settled: after.settled
            ))
        }

        // Focus that landed somewhere other than the acted-on element is only visible in the
        // app-level read, which is why the observation carries one.
        if let focus = observation.focusAfter,
           focus.locator != nil,
           focus.locator != after?.locator {
            candidates.append(Candidate(
                kind: "focused",
                app: focus.app,
                locator: focus.locator,
                state: ["focused": .bool(true)],
                assertion: nil,
                derivedFromInput: false,
                requiresSettled: false,
                settled: focus.settled
            ))
        }

        if let after, let enabled = after.enabled, before?.enabled != enabled {
            candidates.append(Candidate(
                kind: "enabled",
                app: after.app,
                locator: after.locator,
                state: ["enabled": .bool(enabled)],
                assertion: nil,
                derivedFromInput: false,
                requiresSettled: false,
                settled: after.settled
            ))
        }

        if let after, let value = after.value, before?.value != value {
            let kind = DerivedPostconditionRules.selectionRoles.contains(after.role) ? "selected" : "value"
            candidates.append(Candidate(
                kind: kind,
                app: after.app,
                locator: after.locator,
                state: [kind: .object(["equals": .string(value)])],
                assertion: value,
                derivedFromInput: after.valueDerivedFromInput,
                requiresSettled: true,
                settled: after.settled
            ))
        }

        if let app = observation.app {
            let appeared = observation.windowTitlesAfter.filter {
                !observation.windowTitlesBefore.contains($0)
            }
            for title in appeared {
                candidates.append(Candidate(
                    kind: "window",
                    app: app,
                    locator: ["role": .string("AXWindow"), "title": .string(title)],
                    state: [:],
                    assertion: title,
                    derivedFromInput: false,
                    requiresSettled: false,
                    settled: true
                ))
            }
        }

        return candidates
    }

    /// The exclusions. A candidate that trips any of them is dropped silently: omission is the
    /// designed outcome, and an action with nothing safe to say stays a valid, unverified step.
    private func survives(_ candidate: Candidate, inputs: [String]) -> Bool {
        guard let locator = candidate.locator, !locator.isEmpty else {
            return false
        }
        if candidate.requiresSettled, !candidate.settled {
            return false
        }
        guard let assertion = candidate.assertion else {
            return true
        }
        guard !assertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if candidate.derivedFromInput || DerivedPostconditionRules.echoesInput(assertion, inputs: inputs) {
            return false
        }
        // A window fact asserts that a window resolves, not that it holds some string, so its own
        // title is not a restatement of anything.
        if !candidate.state.isEmpty,
           DerivedPostconditionRules.restatesLocator(assertion, locator: locator) {
            return false
        }
        if DerivedPostconditionRules.isSecretTainted(assertion, deterministicRedactor: deterministicRedactor) {
            return false
        }
        return true
    }

    private func fact(_ candidate: Candidate, id: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "kind": .string(candidate.kind),
            "target": .object([
                "app": .string(candidate.app),
                "locator": .object(candidate.locator ?? [:])
            ])
        ]
        if !candidate.state.isEmpty {
            object["state"] = .object(candidate.state)
        }
        return .object(object)
    }
}
