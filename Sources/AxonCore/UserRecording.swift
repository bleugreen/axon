import Foundation

public enum RecordedUserAction: Equatable, Sendable {
    case click(target: JSONValue)
    case setValue(target: JSONValue, value: String, factTarget: JSONValue? = nil)
    case typeText(app: String, text: String)
    case pressKey(app: String, key: String)
    case scroll(target: JSONValue?, app: String?, deltaX: Double, deltaY: Double)
    case drag(from: JSONValue, to: JSONValue, app: String?, durationMs: Int?)
    case performAction(target: JSONValue, action: String)
}

public struct RecordedUserEventGroup: Equatable, Sendable {
    public let action: RecordedUserAction
    public let observed: [JSONValue]
    public let warnings: [String]
    /// The before/after read taken around the recorded event, when the event had an observable
    /// target. This is what lets the translator run the same derived-postcondition compiler the
    /// agent path's `save` runs; notification evidence alone cannot feed it.
    public let observation: ActionObservation?

    public init(
        action: RecordedUserAction,
        observed: [JSONValue] = [],
        warnings: [String] = [],
        observation: ActionObservation? = nil
    ) {
        self.action = action
        self.observed = observed
        self.warnings = warnings
        self.observation = observation
    }
}

public struct UserRecordingTranslator {
    public init() {}

    public func axnDocument(from groups: [RecordedUserEventGroup]) throws -> JSONValue {
        var actions: [JSONValue] = []
        var lastValueFactID: String?
        var guardFactIDs = Set<String>()
        // Gathered across the whole recording before any step is compiled, mirroring `save`: an
        // echo of typed text can surface a step or two later, and every one of these strings is a
        // parameterization candidate no step may assert.
        let workflowInputs = groups.flatMap { inputStrings(for: $0.action) }
        let semanticGroups = coalescedScrollBursts(from: groups)
        var index = 0
        var actionNumber = 1

        while index < semanticGroups.count {
            let group = semanticGroups[index]
            var resolve: JSONValue?
            var observed = group.observed
            var warnings = group.warnings
            var emittedGroup = group

            if let scroll = scrollComponents(group.action),
               index + 1 < semanticGroups.count,
               let revealTarget = targetBearingActionTarget(semanticGroups[index + 1].action),
               revealTarget["locator"] != nil {
                emittedGroup = semanticGroups[index + 1]
                observed = uniqued(group.observed + emittedGroup.observed)
                warnings = uniqued(group.warnings + emittedGroup.warnings)
                resolve = revealResolution(for: scroll)
                index += 1
            }

            let actionID = String(format: "a%03d", actionNumber)
            var object = actionObject(for: group.action)
            if emittedGroup != group {
                object = actionObject(for: emittedGroup.action)
            }
            object["id"] = .string(actionID)

            if let resolve {
                object["resolve"] = resolve
            }

            if let requiredValueFactID = lastValueFactID, requiresRecordedValue(emittedGroup.action) {
                object["requires"] = .array([.string(requiredValueFactID)])
                lastValueFactID = nil
            }

            var expectedFacts: [JSONValue] = []
            if let observation = emittedGroup.observation {
                expectedFacts.append(contentsOf: DerivedPostconditionCompiler().facts(
                    for: DerivedPostconditionCompiler.Input(
                        actionID: actionID,
                        tool: toolName(for: emittedGroup.action),
                        observation: observation,
                        workflowInputs: workflowInputs
                    )
                ))
            }
            switch emittedGroup.action {
            case let .setValue(target, value, factTarget):
                // The guard is indexed after any value facts the compiler derived for this step,
                // so a formatted field value (a derived `equals` fact) and the typed input (the
                // guard's `contains`) can coexist without colliding ids.
                let derivedValueFacts = expectedFacts.filter { $0["kind"] == .string("value") }.count
                let factID = "\(actionID).value.\(derivedValueFacts)"
                expectedFacts.append(valueFact(id: factID, target: factTarget ?? target, value: value))
                guardFactIDs.insert(factID)
                lastValueFactID = factID
            default:
                break
            }
            if expectsAppChange(emittedGroup) {
                if let app = appName(for: emittedGroup.action) {
                    expectedFacts.append(changedFact(id: "\(actionID).changed.0", app: app))
                }
            }
            if !expectedFacts.isEmpty {
                object["expects"] = .array(expectedFacts)
            }
            if !observed.isEmpty {
                object["observed"] = .array(observed)
            }
            if !warnings.isEmpty {
                object["warnings"] = .array(warnings.map(JSONValue.string))
            }
            actions.append(.object(object))
            index += 1
            actionNumber += 1
        }

        return .object([
            "version": .int(1),
            "actions": .array(prunedUnrequiredGuardFacts(in: actions, guardFactIDs: guardFactIDs))
        ])
    }

    private func inputStrings(for action: RecordedUserAction) -> [String] {
        switch action {
        case let .setValue(_, value, _):
            return [value]
        case let .typeText(_, text):
            return [text]
        case let .pressKey(_, key):
            return [key]
        case .click, .scroll, .drag, .performAction:
            return []
        }
    }

    private func toolName(for action: RecordedUserAction) -> String {
        switch action {
        case .click:
            return "click"
        case .setValue:
            return "type"
        case .typeText, .pressKey:
            return "keyboard"
        case .scroll:
            return "scroll"
        case .drag:
            return "drag"
        case .performAction:
            return "invoke"
        }
    }

    /// Drops typed-value facts that nothing depends on.
    ///
    /// This fact is not a derived postcondition; it is a dependency guard, which is why the
    /// following submit-like step points a `requires` at it: do not press Return unless the field
    /// still holds what was typed. Emitted on every text burst it would instead assert the input
    /// back at itself on most steps, which is the input echo derived postconditions must never be.
    /// Keeping only the consumed ones preserves the single real guarantee and drops the rest.
    private func prunedUnrequiredGuardFacts(in actions: [JSONValue], guardFactIDs: Set<String>) -> [JSONValue] {
        var requiredFactIDs = Set<String>()
        for action in actions {
            guard case let .array(requires)? = action["requires"] else {
                continue
            }
            for case let .string(id) in requires {
                requiredFactIDs.insert(id)
            }
        }

        return actions.map { action in
            guard case var .object(object) = action,
                  case let .array(facts)? = object["expects"]
            else {
                return action
            }
            // Only facts this translator emitted as dependency guards are prunable. A `value`
            // fact the compiler derived is a postcondition like any other and stays.
            let kept = facts.filter { fact in
                guard case let .string(id)? = fact["id"], guardFactIDs.contains(id) else {
                    return true
                }
                return requiredFactIDs.contains(id)
            }
            if kept.isEmpty {
                object.removeValue(forKey: "expects")
            } else {
                object["expects"] = .array(kept)
            }
            return .object(object)
        }
    }

    public func yaml(from groups: [RecordedUserEventGroup]) throws -> String {
        let axnDocument = try axnDocument(from: groups)
        return try AxnDocumentCodec.yamlString(from: axnDocument)
    }

    private func coalescedScrollBursts(from groups: [RecordedUserEventGroup]) -> [RecordedUserEventGroup] {
        var result: [RecordedUserEventGroup] = []
        var index = 0

        while index < groups.count {
            let group = groups[index]
            guard let scroll = scrollComponents(group.action),
                  let signature = scrollSignature(deltaX: scroll.deltaX, deltaY: scroll.deltaY)
            else {
                result.append(group)
                index += 1
                continue
            }

            var scrollGroups = [group]
            var observed = group.observed
            var warnings = group.warnings
            var totalDeltaX = scroll.deltaX
            var totalDeltaY = scroll.deltaY
            var lastSignature = signature
            var nextIndex = index + 1
            while nextIndex < groups.count,
                  let nextScroll = scrollComponents(groups[nextIndex].action),
                  scroll.app == nextScroll.app,
                  let nextSignature = scrollSignature(deltaX: nextScroll.deltaX, deltaY: nextScroll.deltaY)
            {
                scrollGroups.append(groups[nextIndex])
                totalDeltaX += nextScroll.deltaX
                totalDeltaY += nextScroll.deltaY
                lastSignature = nextSignature
                observed.append(contentsOf: groups[nextIndex].observed)
                warnings.append(contentsOf: groups[nextIndex].warnings)
                nextIndex += 1
            }

            let normalized = aggregateScrollDelta(
                totalDeltaX: totalDeltaX,
                totalDeltaY: totalDeltaY,
                fallbackSignature: lastSignature
            )
            result.append(RecordedUserEventGroup(
                action: .scroll(
                    target: scrollSurfaceTarget(in: scrollGroups),
                    app: scroll.app,
                    deltaX: normalized.deltaX,
                    deltaY: normalized.deltaY
                ),
                observed: uniqued(observed),
                warnings: uniqued(warnings)
            ))
            index = nextIndex
        }

        return result
    }

    private func scrollComponents(_ action: RecordedUserAction) -> (
        target: JSONValue?,
        app: String?,
        deltaX: Double,
        deltaY: Double
    )? {
        guard case let .scroll(target, app, deltaX, deltaY) = action else {
            return nil
        }
        return (target, app, deltaX, deltaY)
    }

    private enum ScrollAxis: Equatable {
        case horizontal
        case vertical
    }

    private func scrollSignature(deltaX: Double, deltaY: Double) -> (axis: ScrollAxis, sign: Int)? {
        if abs(deltaX) > abs(deltaY), deltaX != 0 {
            return (.horizontal, deltaX < 0 ? -1 : 1)
        }
        guard deltaY != 0 else {
            return nil
        }
        return (.vertical, deltaY < 0 ? -1 : 1)
    }

    private func aggregateScrollDelta(
        totalDeltaX: Double,
        totalDeltaY: Double,
        fallbackSignature: (axis: ScrollAxis, sign: Int)
    ) -> (deltaX: Double, deltaY: Double) {
        let signature = scrollSignature(deltaX: totalDeltaX, deltaY: totalDeltaY) ?? fallbackSignature
        switch signature.axis {
        case .horizontal:
            return (signedMagnitude(totalDeltaX, sign: signature.sign), 0)
        case .vertical:
            return (0, signedMagnitude(totalDeltaY, sign: signature.sign))
        }
    }

    private func signedMagnitude(_ value: Double, sign: Int) -> Double {
        Double(sign) * max(abs(value), 120)
    }

    private func scrollSurfaceTarget(in groups: [RecordedUserEventGroup]) -> JSONValue? {
        for group in groups {
            guard let scroll = scrollComponents(group.action),
                  let target = scroll.target,
                  isScrollSurface(target)
            else {
                continue
            }
            return target
        }
        return nil
    }

    private func isScrollSurface(_ target: JSONValue) -> Bool {
        guard case let .object(object) = target,
              case let .object(locator)? = object["locator"],
              case let .string(role)? = locator["role"]
        else {
            return false
        }
        return role == "AXScrollArea" || role == "AXWebArea"
    }

    private func revealResolution(for scroll: (target: JSONValue?, app: String?, deltaX: Double, deltaY: Double)) -> JSONValue? {
        guard let signature = scrollSignature(deltaX: scroll.deltaX, deltaY: scroll.deltaY) else {
            return nil
        }
        var reveal: [String: JSONValue] = [
            "direction": .string(direction(for: signature))
        ]
        if scroll.deltaX != 0 {
            reveal["deltaX"] = .double(scroll.deltaX)
        }
        if scroll.deltaY != 0 {
            reveal["deltaY"] = .double(scroll.deltaY)
        }
        if let target = scroll.target {
            reveal["surface"] = target
        } else if let app = scroll.app {
            reveal["app"] = .string(app)
        }
        return .object(["reveal": .object(reveal)])
    }

    private func direction(for signature: (axis: ScrollAxis, sign: Int)) -> String {
        switch signature.axis {
        case .horizontal:
            return signature.sign < 0 ? "right" : "left"
        case .vertical:
            return signature.sign < 0 ? "down" : "up"
        }
    }

    private func uniqued(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }

    private func uniqued(_ values: [JSONValue]) -> [JSONValue] {
        var result: [JSONValue] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }

    private func targetBearingActionTarget(_ action: RecordedUserAction) -> JSONValue? {
        switch action {
        case let .click(target), let .setValue(target, _, _), let .performAction(target, _):
            return target
        case let .drag(_, to, _, _):
            return to
        case .typeText, .pressKey, .scroll:
            return nil
        }
    }

    private func actionObject(for action: RecordedUserAction) -> [String: JSONValue] {
        switch action {
        case let .click(target):
            return ["tool": .string("click"), "target": target]
        case let .setValue(target, value, _):
            return ["tool": .string("type"), "target": target, "value": .string(value)]
        case let .typeText(app, text):
            return ["tool": .string("keyboard"), "app": .string(app), "text": .string(text)]
        case let .pressKey(app, key):
            return ["tool": .string("keyboard"), "app": .string(app), "key": .string(key)]
        case let .scroll(target, app, deltaX, deltaY):
            var object: [String: JSONValue] = [
                "tool": .string("scroll"),
                "deltaX": .double(deltaX),
                "deltaY": .double(deltaY)
            ]
            if let target {
                object["target"] = target
            }
            if let app {
                object["app"] = .string(app)
            }
            return object
        case let .drag(from, to, app, durationMs):
            var object: [String: JSONValue] = ["tool": .string("drag"), "from": from, "to": to]
            if let app {
                object["app"] = .string(app)
            }
            if let durationMs {
                object["durationMs"] = .int(durationMs)
            }
            return object
        case let .performAction(target, action):
            return ["tool": .string("invoke"), "target": target, "name": .string(action)]
        }
    }

    private func requiresRecordedValue(_ action: RecordedUserAction) -> Bool {
        switch action {
        case let .pressKey(_, key):
            return ["Return", "Enter", "Tab"].contains(key)
        case let .click(target), let .performAction(target, _):
            return isSubmitTarget(target)
        case .setValue, .typeText, .scroll, .drag:
            return false
        }
    }

    private func expectsAppChange(_ group: RecordedUserEventGroup) -> Bool {
        if isSubmitAction(group.action) {
            return true
        }
        switch group.action {
        case .click, .performAction:
            return group.observed.contains(where: observedNavigationEvidence(_:))
        case .setValue, .typeText, .pressKey, .scroll, .drag:
            return false
        }
    }

    private func isSubmitAction(_ action: RecordedUserAction) -> Bool {
        switch action {
        case let .pressKey(_, key):
            return ["Return", "Enter"].contains(key)
        case let .click(target), let .performAction(target, _):
            return isSubmitTarget(target)
        case .setValue, .typeText, .scroll, .drag:
            return false
        }
    }

    private func observedNavigationEvidence(_ value: JSONValue) -> Bool {
        guard case let .object(object) = value else {
            return false
        }
        let notification: String?
        if case let .string(value)? = object["notification"] {
            notification = value
        } else {
            notification = nil
        }
        let role: String?
        if case let .string(value)? = object["role"] {
            role = value
        } else {
            role = nil
        }
        if notification == "AXWindowCreated" {
            return true
        }
        if notification == "AXFocusedUIElementChanged", role == "AXLink" {
            return true
        }
        return false
    }

    private func appName(for action: RecordedUserAction) -> String? {
        switch action {
        case let .click(target), let .setValue(target, _, _), let .performAction(target, _):
            return appName(in: target)
        case let .typeText(app, _), let .pressKey(app, _):
            return app
        case let .scroll(_, app, _, _), let .drag(_, _, app, _):
            return app
        }
    }

    private func appName(in target: JSONValue) -> String? {
        guard case let .object(object) = target,
              case let .string(app)? = object["app"],
              !app.isEmpty
        else {
            return nil
        }
        return app
    }

    private func isSubmitTarget(_ target: JSONValue) -> Bool {
        let haystack = targetTextFragments(target)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !haystack.isEmpty else {
            return false
        }
        let submitTerms = [
            "search",
            "submit",
            "go",
            "continue",
            "confirm",
            "ok",
            "done",
            "save",
            "sign in",
            "log in",
            "login"
        ]
        return submitTerms.contains { haystack.contains($0) }
    }

    private func targetTextFragments(_ value: JSONValue) -> [String] {
        guard case let .object(object) = value,
              case let .object(locator)? = object["locator"]
        else {
            return []
        }
        var fragments: [String] = []
        for key in ["role", "title", "label", "value", "description", "identifier"] {
            appendText(from: locator[key], to: &fragments)
        }
        return fragments
    }

    private func appendText(from value: JSONValue?, to fragments: inout [String]) {
        switch value {
        case let .string(text):
            fragments.append(text)
        case let .object(object):
            for key in ["equals", "exact", "contains"] {
                if case let .string(text)? = object[key] {
                    fragments.append(text)
                }
            }
        default:
            break
        }
    }

    private func valueFact(id: String, target: JSONValue, value: String) -> JSONValue {
        .object([
            "id": .string(id),
            "kind": .string("value"),
            "target": target,
            "state": .object([
                "value": .object(["contains": .string(value)])
            ])
        ])
    }

    private func changedFact(id: String, app: String) -> JSONValue {
        .object([
            "id": .string(id),
            "kind": .string("changed"),
            "target": .object(["app": .string(app)])
        ])
    }

}
