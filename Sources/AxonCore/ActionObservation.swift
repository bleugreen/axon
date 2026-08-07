import Foundation

/// One element's state as read at a single moment, carrying the durable identity a later session
/// would need to find it again.
///
/// `locator` is nil when the element has no identity that survives the snapshot it was captured
/// in. Such an element can still be observed — its before/after values are real — but nothing may
/// be asserted about it, because a postcondition needs a target a replay can resolve.
public struct ObservedElementState: Equatable, Sendable {
    public let app: String
    public let role: String
    public let locator: [String: JSONValue]?
    public let value: String?
    public let focused: Bool?
    public let enabled: Bool?
    /// True when `value` was produced by this action's own input parameters.
    ///
    /// Computed at capture time against the live, unredacted request. History params and
    /// observations are redacted afterwards, so a comparison made later could not tell a typed
    /// secret from an unrelated string and would let it through as an assertion.
    public let valueDerivedFromInput: Bool
    /// False when the settle loop never saw two agreeing reads inside its budget.
    public let settled: Bool

    public init(
        app: String,
        role: String,
        locator: [String: JSONValue]?,
        value: String? = nil,
        focused: Bool? = nil,
        enabled: Bool? = nil,
        valueDerivedFromInput: Bool = false,
        settled: Bool = true
    ) {
        self.app = app
        self.role = role
        self.locator = locator
        self.value = value
        self.focused = focused
        self.enabled = enabled
        self.valueDerivedFromInput = valueDerivedFromInput
        self.settled = settled
    }

    /// Stamps the capture-time verdicts an observer cannot reach on its own: whether this value
    /// merely echoes the action's input, and whether the read it came from had settled.
    func resolving(inputs: [String], settled: Bool) -> ObservedElementState {
        ObservedElementState(
            app: app,
            role: role,
            locator: locator,
            value: value,
            focused: focused,
            enabled: enabled,
            valueDerivedFromInput: value.map { DerivedPostconditionRules.echoesInput($0, inputs: inputs) } ?? false,
            settled: settled
        )
    }

    func redacted(
        activeSecretRedactor: ActiveSecretRedactor,
        deterministicRedactor: DeterministicRedactor
    ) -> ObservedElementState {
        ObservedElementState(
            app: app,
            role: role,
            locator: locator.map {
                JSONValue.object($0).redactingSensitiveHistoryValues(
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor
                ).objectValue ?? $0
            },
            value: value.map {
                ObservationRedaction.string(
                    $0,
                    field: "value",
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor
                )
            },
            focused: focused,
            enabled: enabled,
            valueDerivedFromInput: valueDerivedFromInput,
            settled: settled
        )
    }
}

/// App-scoped state read alongside an action: which windows exist and what holds focus.
public struct ObservedAppState: Equatable, Sendable {
    public let app: String
    public let windowTitles: [String]
    public let focused: ObservedElementState?

    public init(app: String, windowTitles: [String], focused: ObservedElementState?) {
        self.app = app
        self.windowTitles = windowTitles
        self.focused = focused
    }
}

/// What one dispatched action changed, as a bounded before/after read of its target element and
/// the app around it.
///
/// This is the only evidence `save` has that a step did anything, and the sole input to the
/// postcondition compiler.
public struct ActionObservation: Equatable, Sendable {
    public let tool: String
    public let app: String?
    /// The action's own input strings (`value`, `text`, `key`), redacted with everything else.
    /// A derived fact may never assert one of these back, because the user is expected to
    /// parameterize them and `expects` is not a substitutable field.
    public let inputs: [String]
    public let targetBefore: ObservedElementState?
    public let targetAfter: ObservedElementState?
    public let fromBefore: ObservedElementState?
    public let toBefore: ObservedElementState?
    /// The app's focused element before and after the action. The pair is how a focus move to some
    /// element other than the action's own target becomes visible - and, just as importantly, how
    /// focus that never moved is recognised as no transition at all.
    public let focusBefore: ObservedElementState?
    public let focusAfter: ObservedElementState?
    public let windowTitlesBefore: [String]
    public let windowTitlesAfter: [String]
    public let warnings: [String]

    public init(
        tool: String,
        app: String?,
        inputs: [String] = [],
        targetBefore: ObservedElementState? = nil,
        targetAfter: ObservedElementState? = nil,
        fromBefore: ObservedElementState? = nil,
        toBefore: ObservedElementState? = nil,
        focusBefore: ObservedElementState? = nil,
        focusAfter: ObservedElementState? = nil,
        windowTitlesBefore: [String] = [],
        windowTitlesAfter: [String] = [],
        warnings: [String] = []
    ) {
        self.tool = tool
        self.app = app
        self.inputs = inputs
        self.targetBefore = targetBefore
        self.targetAfter = targetAfter
        self.fromBefore = fromBefore
        self.toBefore = toBefore
        self.focusBefore = focusBefore
        self.focusAfter = focusAfter
        self.windowTitlesBefore = windowTitlesBefore
        self.windowTitlesAfter = windowTitlesAfter
        self.warnings = warnings
    }

    func redacted(
        activeSecretRedactor: ActiveSecretRedactor,
        deterministicRedactor: DeterministicRedactor
    ) -> ActionObservation {
        func redact(_ state: ObservedElementState?) -> ObservedElementState? {
            state?.redacted(
                activeSecretRedactor: activeSecretRedactor,
                deterministicRedactor: deterministicRedactor
            )
        }
        func redactTitles(_ titles: [String]) -> [String] {
            titles.map {
                ObservationRedaction.string(
                    $0,
                    field: "title",
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor
                )
            }
        }
        return ActionObservation(
            tool: tool,
            app: app,
            inputs: inputs.map {
                ObservationRedaction.string(
                    $0,
                    field: "value",
                    activeSecretRedactor: activeSecretRedactor,
                    deterministicRedactor: deterministicRedactor
                )
            },
            targetBefore: redact(targetBefore),
            targetAfter: redact(targetAfter),
            fromBefore: redact(fromBefore),
            toBefore: redact(toBefore),
            focusBefore: redact(focusBefore),
            focusAfter: redact(focusAfter),
            windowTitlesBefore: redactTitles(windowTitlesBefore),
            windowTitlesAfter: redactTitles(windowTitlesAfter),
            warnings: warnings
        )
    }
}

enum ObservationRedaction {
    static func string(
        _ value: String,
        field: String,
        activeSecretRedactor: ActiveSecretRedactor,
        deterministicRedactor: DeterministicRedactor
    ) -> String {
        JSONValue.string(value).redactingSensitiveHistoryValues(
            activeSecretRedactor: activeSecretRedactor,
            deterministicRedactor: deterministicRedactor,
            field: field
        ).stringValue ?? value
    }
}

/// Which surface an action's observation is scoped to.
public enum ActionObservationScope: Equatable, Sendable {
    /// An action with an element target; the app is reached through the retained element.
    case element(handle: String)
    /// An action addressed to an app rather than an element, such as `keyboard`.
    case app(name: String)
}

/// Reads live element and app state for the observation collector.
///
/// Deliberately narrow: targeted attribute reads, never a tree capture. A full snapshot per action
/// would multiply the cost of every agent action, and nothing derived here needs more than a
/// handful of attributes.
public protocol ActionStateObserving: Sendable {
    /// State of a retained element, or nil when the handle no longer resolves.
    func elementState(handle: String) -> ObservedElementState?
    /// Window titles and focused element for the app the scope names or belongs to.
    func appState(_ scope: ActionObservationScope) -> ObservedAppState?
}

/// Collects one action's before/after reads at the dispatch seam.
///
/// A collector belongs to a single dispatched action. `begin` records the pre-action state next to
/// the resolved target, `finish` waits for the effect to settle and records the post-action state,
/// and only a successful dispatch produces an observation — a refused or failed action has no
/// transition to describe.
public final class ActionObservationCollector {
    /// Actions whose whole point is to cause a transition, and so are worth waiting on. `type`
    /// already reads its own AXValue back, and `scroll` moves geometry rather than any state this
    /// compiler derives, so neither pays for a settle wait.
    private static let transitionLikelyTools: Set<String> = ["click", "invoke", "keyboard", "drag"]
    static let settleIntervalMs = 25
    static let settleBudgetMs = 150

    private struct Pending {
        let tool: String
        let inputs: [String]
        let scope: ActionObservationScope?
        let targetHandle: String?
        let targetBefore: ObservedElementState?
        let fromBefore: ObservedElementState?
        let toBefore: ObservedElementState?
        let appBefore: ObservedAppState?
    }

    private struct Reading: Equatable {
        let element: ObservedElementState?
        let app: ObservedAppState?
    }

    private let observer: (any ActionStateObserving)?
    private let sleepMilliseconds: (Int) -> Void
    private let now: () -> Date

    private var pending: Pending?
    public private(set) var observation: ActionObservation?

    public init(
        observer: (any ActionStateObserving)?,
        sleepMilliseconds: @escaping (Int) -> Void,
        now: @escaping () -> Date
    ) {
        self.observer = observer
        self.sleepMilliseconds = sleepMilliseconds
        self.now = now
    }

    public func reset() {
        pending = nil
        observation = nil
    }

    /// Starts observing an action that acts on one resolved element.
    func begin(tool: String, handle: String, inputs: [String] = []) {
        guard let observer else { return }
        let scope = ActionObservationScope.element(handle: handle)
        pending = Pending(
            tool: tool,
            inputs: inputs,
            scope: scope,
            targetHandle: handle,
            targetBefore: observer.elementState(handle: handle),
            fromBefore: nil,
            toBefore: nil,
            appBefore: observer.appState(scope)
        )
    }

    /// Starts observing a drag. The `to` element is the action's target for postcondition
    /// purposes; `from` is recorded so the saved step can carry a durable origin.
    func beginDrag(fromHandle: String?, toHandle: String?, inputs: [String] = []) {
        guard let observer else { return }
        let scope = toHandle.map(ActionObservationScope.element(handle:))
            ?? fromHandle.map(ActionObservationScope.element(handle:))
        pending = Pending(
            tool: "drag",
            inputs: inputs,
            scope: scope,
            targetHandle: toHandle,
            targetBefore: toHandle.flatMap(observer.elementState(handle:)),
            fromBefore: fromHandle.flatMap(observer.elementState(handle:)),
            toBefore: toHandle.flatMap(observer.elementState(handle:)),
            appBefore: scope.flatMap(observer.appState)
        )
    }

    /// Starts observing an action addressed to an app rather than an element.
    func begin(tool: String, app: String?, inputs: [String] = []) {
        guard let observer, let app, !app.isEmpty else { return }
        let scope = ActionObservationScope.app(name: app)
        pending = Pending(
            tool: tool,
            inputs: inputs,
            scope: scope,
            targetHandle: nil,
            targetBefore: nil,
            fromBefore: nil,
            toBefore: nil,
            appBefore: observer.appState(scope)
        )
    }

    /// Records the post-action state. A failed or refused dispatch clears the pending read instead.
    func finish(success: Bool) {
        guard let pending else { return }
        self.pending = nil
        guard success, observer != nil else { return }

        let settled = settledReading(for: pending)
        let inputs = pending.inputs
        let targetAfter = settled.reading.element?.resolving(inputs: inputs, settled: settled.settled)
        let focusAfter = settled.reading.app?.focused?.resolving(inputs: inputs, settled: settled.settled)

        observation = ActionObservation(
            tool: pending.tool,
            app: pending.appBefore?.app ?? settled.reading.app?.app ?? pending.targetBefore?.app,
            inputs: inputs,
            targetBefore: pending.targetBefore,
            targetAfter: targetAfter,
            fromBefore: pending.fromBefore,
            toBefore: pending.toBefore,
            focusBefore: pending.appBefore?.focused,
            focusAfter: focusAfter,
            windowTitlesBefore: pending.appBefore?.windowTitles ?? [],
            windowTitlesAfter: settled.reading.app?.windowTitles ?? []
        )
    }

    private func settledReading(for pending: Pending) -> (reading: Reading, settled: Bool) {
        guard Self.transitionLikelyTools.contains(pending.tool) else {
            return (read(pending), true)
        }

        let deadline = now().addingTimeInterval(Double(Self.settleBudgetMs) / 1_000)
        // Bounded on both ends: the clock stops a slow app, the read count stops a surface that
        // keeps changing faster than the clock an injected time source advances.
        let maxReads = max(2, Self.settleBudgetMs / Self.settleIntervalMs + 1)
        var previous: Reading?
        for index in 0..<maxReads {
            let current = read(pending)
            if let previous, previous == current {
                return (current, true)
            }
            previous = current
            if index == maxReads - 1 || now() >= deadline {
                break
            }
            sleepMilliseconds(Self.settleIntervalMs)
        }
        return (previous ?? Reading(element: nil, app: nil), false)
    }

    private func read(_ pending: Pending) -> Reading {
        guard let observer else {
            return Reading(element: nil, app: nil)
        }
        return Reading(
            element: pending.targetHandle.flatMap(observer.elementState(handle:)),
            app: pending.scope.flatMap(observer.appState)
        )
    }
}
