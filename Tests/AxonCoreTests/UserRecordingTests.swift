import Foundation
import Testing
@testable import AxonCore

final class RecorderSettleTestElement: @unchecked Sendable {}

@Test func recordingScopePickerListsAllAppsLast() {
    let editor = AppIdentity(bundleIdentifier: "com.example.Editor", name: "Editor", processIdentifier: 10)
    let browser = AppIdentity(bundleIdentifier: "com.example.Browser", name: "Browser", processIdentifier: 11)

    let scopes = UserRecordingScope.pickerOptions(for: [editor, browser])

    #expect(scopes == [.app(editor), .app(browser), .all])
}

@Test func recordingTranslatorEmitsMechanicalIdsAndValueExpectations() throws {
    let translator = UserRecordingTranslator()
    let target: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXTextField"),
            "identifier": .string("name-field")
        ])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(action: .setValue(target: target, value: "Mitch"))
    ])

    #expect(axnDocument["version"] == .int(1))
    #expect(axnDocument["actions"]?[0]?["id"] == .string("a001"))
    #expect(axnDocument["actions"]?[0]?["tool"] == .string("type"))
    #expect(axnDocument["actions"]?[0]?["expects"]?[0]?["id"] == .string("a001.value.0"))
    #expect(axnDocument["actions"]?[0]?["expects"]?[0]?["state"]?["value"]?["contains"] == .string("Mitch"))
}

@Test func recordingTranslatorUsesPostActionTargetForValueExpectation() throws {
    let translator = UserRecordingTranslator()
    let actionTarget: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXComboBox"),
            "description": .string("Search with Google or enter address")
        ])
    ])
    let factTarget: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXComboBox"),
            "value": .string("wikipedia.org")
        ])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(action: .setValue(target: actionTarget, value: "wikipedia.org", factTarget: factTarget))
    ])

    #expect(axnDocument["actions"]?[0]?["target"] == actionTarget)
    #expect(axnDocument["actions"]?[0]?["expects"]?[0]?["target"] == factTarget)
}

@Test func recorderSettleReturnsImmediatelyWhenTargetValueChangeWasAlreadyObserved() {
    let target = RecorderSettleTestElement()
    let buffer = AXNotificationEvidenceBuffer(
        elementMatches: { $0 === $1 },
        runUntil: { _ in Issue.record("settle should not wait when notification is already buffered") }
    )
    let evidence: JSONValue = .object(["notification": .string("AXValueChanged")])
    buffer.append(evidence, notification: "AXValueChanged", element: target)

    buffer.waitForValueChange(on: target, timeout: 1)

    #expect(buffer.drain() == [evidence])
}

@Test func recorderSettleWaitsUntilTargetValueChangeArrives() {
    let target = RecorderSettleTestElement()
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var waits = 0
    let buffer = AXNotificationEvidenceBuffer(
        elementMatches: { lhs, rhs in waits > 0 && lhs === rhs },
        now: { now },
        runUntil: { _ in
            waits += 1
            now = now.addingTimeInterval(0.01)
        }
    )
    buffer.append(.object(["notification": .string("AXValueChanged")]), notification: "AXValueChanged", element: target)

    buffer.waitForValueChange(on: target, timeout: 1)

    #expect(waits == 1)
}

@Test func recorderSettleFallsThroughAfterBoundedTimeout() {
    let target = RecorderSettleTestElement()
    let other = RecorderSettleTestElement()
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var waits = 0
    let buffer = AXNotificationEvidenceBuffer(
        elementMatches: { $0 === $1 },
        now: { now },
        runUntil: { deadline in
            waits += 1
            now = deadline
        }
    )
    buffer.append(.object(["notification": .string("AXValueChanged")]), notification: "AXValueChanged", element: other)

    buffer.waitForValueChange(on: target, timeout: 0.15)

    #expect(waits == 1)
    #expect(buffer.drain().count == 1)
}

@Test func recordingTranslatorAddsConservativeValueDependencyForSubmitKey() throws {
    let translator = UserRecordingTranslator()
    let target: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXTextField"),
            "identifier": .string("name-field")
        ])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(action: .setValue(target: target, value: "Mitch")),
        RecordedUserEventGroup(action: .pressKey(app: "Example", key: "Return"))
    ])

    #expect(axnDocument["actions"]?[1]?["id"] == .string("a002"))
    #expect(axnDocument["actions"]?[1]?["requires"]?[0] == .string("a001.value.0"))
}

@Test func recordingTranslatorConsumesValueDependencyAfterSubmitKey() throws {
    let translator = UserRecordingTranslator()
    let field: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXTextField"),
            "identifier": .string("name-field")
        ])
    ])
    let link: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXLink"),
            "title": .string("Article")
        ])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(action: .setValue(target: field, value: "wikipedia.com")),
        RecordedUserEventGroup(action: .pressKey(app: "Example", key: "Return")),
        RecordedUserEventGroup(action: .click(target: link))
    ])

    #expect(axnDocument["actions"]?[1]?["requires"]?[0] == .string("a001.value.0"))
    #expect(axnDocument["actions"]?[2]?["requires"] == nil)
}

@Test func recordingTranslatorConsumesValueDependencyAfterSubmitClick() throws {
    let translator = UserRecordingTranslator()
    let field: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXTextField"),
            "identifier": .string("name-field")
        ])
    ])
    let button: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXButton"),
            "title": .string("Search")
        ])
    ])
    let link: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXLink"),
            "title": .string("Result")
        ])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(action: .setValue(target: field, value: "wikipedia.com")),
        RecordedUserEventGroup(action: .click(target: button)),
        RecordedUserEventGroup(action: .click(target: link))
    ])

    #expect(axnDocument["actions"]?[1]?["requires"]?[0] == .string("a001.value.0"))
    #expect(axnDocument["actions"]?[2]?["requires"] == nil)
}

@Test func recordingTranslatorDoesNotSpendValueDependencyOnNonSubmitClick() throws {
    let translator = UserRecordingTranslator()
    let field: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXTextField"),
            "identifier": .string("name-field")
        ])
    ])
    let link: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXLink"),
            "title": .string("Help")
        ])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(action: .setValue(target: field, value: "wikipedia.com")),
        RecordedUserEventGroup(action: .click(target: link)),
        RecordedUserEventGroup(action: .pressKey(app: "Example", key: "Return"))
    ])

    #expect(axnDocument["actions"]?[1]?["requires"] == nil)
    #expect(axnDocument["actions"]?[2]?["requires"]?[0] == .string("a001.value.0"))
}

@Test func recordingTranslatorRecordsWarningsWithoutEnforcingObservedEvidence() throws {
    let translator = UserRecordingTranslator()

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(
            action: .click(target: .object(["point": .object(["x": .double(10), "y": .double(20)])])),
            observed: [.object(["kind": .string("raw-pointer")])],
            warnings: ["point fallback"]
        )
    ])

    #expect(axnDocument["actions"]?[0]?["tool"] == .string("click"))
    #expect(axnDocument["actions"]?[0]?["observed"]?[0]?["kind"] == .string("raw-pointer"))
    #expect(axnDocument["actions"]?[0]?["warnings"]?[0] == .string("point fallback"))
    #expect(axnDocument["actions"]?[0]?["expects"] == nil)
}

@Test func recordingTranslatorAddsChangedExpectationForSubmitKey() throws {
    let translator = UserRecordingTranslator()

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(action: .pressKey(app: "Example", key: "Return"))
    ])

    #expect(axnDocument["actions"]?[0]?["expects"]?[0]?["id"] == .string("a001.changed.0"))
    #expect(axnDocument["actions"]?[0]?["expects"]?[0]?["kind"] == .string("changed"))
    #expect(axnDocument["actions"]?[0]?["expects"]?[0]?["target"]?["app"] == .string("Example"))
}

@Test func recordingTranslatorAddsChangedExpectationForObservedNavigationClick() throws {
    let translator = UserRecordingTranslator()
    let target: JSONValue = .object([
        "app": .string("Example"),
        "point": .object(["x": .double(10), "y": .double(20)])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(
            action: .click(target: target),
            observed: [
                .object([
                    "kind": .string("ax-notification"),
                    "notification": .string("AXFocusedUIElementChanged"),
                    "role": .string("AXLink")
                ])
            ]
        )
    ])

    #expect(axnDocument["actions"]?[0]?["expects"]?[0]?["id"] == .string("a001.changed.0"))
    #expect(axnDocument["actions"]?[0]?["expects"]?[0]?["kind"] == .string("changed"))
}

@Test func recordingTranslatorDoesNotTreatFocusChurnAsNavigationChange() throws {
    let translator = UserRecordingTranslator()
    let target: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXTextField"),
            "identifier": .string("address")
        ])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(
            action: .setValue(target: target, value: "wikipedia.org"),
            observed: [
                .object([
                    "kind": .string("ax-notification"),
                    "notification": .string("AXValueChanged"),
                    "role": .string("AXComboBox")
                ]),
                .object([
                    "kind": .string("ax-notification"),
                    "notification": .string("AXFocusedUIElementChanged"),
                    "role": .string("AXWebArea")
                ])
            ]
        )
    ])

    let expects: [JSONValue]
    if case let .array(values)? = axnDocument["actions"]?[0]?["expects"] {
        expects = values
    } else {
        expects = []
    }
    #expect(expects.contains { $0["kind"] == .string("changed") } == false)
    #expect(expects.contains { $0["kind"] == .string("value") } == true)
}

@Test func recordingTranslatorDoesNotTreatTextInputPopupAsNavigationChange() throws {
    let translator = UserRecordingTranslator()
    let target: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXComboBox"),
            "description": .string("Search with Google or enter address")
        ])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(
            action: .setValue(target: target, value: "wikipedia.org"),
            observed: [
                .object([
                    "kind": .string("ax-notification"),
                    "notification": .string("AXWindowCreated"),
                    "role": .string("AXWindow")
                ]),
                .object([
                    "kind": .string("ax-notification"),
                    "notification": .string("AXFocusedUIElementChanged"),
                    "role": .string("AXWebArea")
                ])
            ]
        )
    ])

    let expects: [JSONValue]
    if case let .array(values)? = axnDocument["actions"]?[0]?["expects"] {
        expects = values
    } else {
        expects = []
    }
    #expect(expects.contains { $0["kind"] == .string("value") } == true)
    #expect(expects.contains { $0["kind"] == .string("changed") } == false)
}

@Test func recordingTranslatorCoalescesWheelBurstIntoSingleSemanticScroll() throws {
    let translator = UserRecordingTranslator()
    let target: JSONValue = .object([
        "app": .string("Example"),
        "point": .object([
            "x": .double(100),
            "y": .double(200)
        ])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(action: .scroll(target: target, app: "Example", deltaX: 0, deltaY: -1)),
        RecordedUserEventGroup(action: .scroll(target: target, app: "Example", deltaX: 0, deltaY: -4)),
        RecordedUserEventGroup(action: .scroll(target: target, app: "Example", deltaX: 0, deltaY: -120))
    ])

    let actions: [JSONValue]
    if case let .array(values)? = axnDocument["actions"] {
        actions = values
    } else {
        actions = []
    }

    #expect(actions.count == 1)
    #expect(axnDocument["actions"]?[0]?["id"] == .string("a001"))
    #expect(axnDocument["actions"]?[0]?["tool"] == .string("scroll"))
    #expect(axnDocument["actions"]?[0]?["deltaY"] == .double(-125))
}

@Test func recordingTranslatorCoalescesAlternatingWheelJitterIntoSingleRevealScroll() throws {
    let translator = UserRecordingTranslator()
    let scrollSurface: JSONValue = .object([
        "app": .string("Example"),
        "point": .object([
            "x": .double(100),
            "y": .double(200)
        ])
    ])
    let link: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXLink"),
            "title": .string("Article")
        ])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: -120)),
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: 120)),
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: -120)),
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: 120)),
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: -120)),
        RecordedUserEventGroup(action: .click(target: link))
    ])

    #expect(axnDocument["actions"]?[0]?["tool"] == .string("click"))
    #expect(axnDocument["actions"]?[0]?["target"] == link)
    #expect(axnDocument["actions"]?[0]?["resolve"]?["reveal"]?["app"] == .string("Example"))
    #expect(axnDocument["actions"]?[0]?["resolve"]?["reveal"]?["surface"] == nil)
    #expect(axnDocument["actions"]?[0]?["resolve"]?["reveal"]?["direction"] == .string("down"))
    #expect(axnDocument["actions"]?[0]?["resolve"]?["reveal"]?["deltaY"] == .double(-120))
    #expect(axnDocument["actions"]?[1] == nil)
}

@Test func recordingTranslatorMakesScrollBurstRevealNextActionTarget() throws {
    let translator = UserRecordingTranslator()
    let scrollSurface: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXScrollArea")
        ])
    ])
    let link: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXLink"),
            "title": .string("Article")
        ])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: -1)),
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: -4)),
        RecordedUserEventGroup(action: .click(target: link))
    ])

    #expect(axnDocument["actions"]?[0]?["id"] == .string("a001"))
    #expect(axnDocument["actions"]?[0]?["tool"] == .string("click"))
    #expect(axnDocument["actions"]?[0]?["target"] == link)
    #expect(axnDocument["actions"]?[0]?["resolve"]?["reveal"]?["surface"] == scrollSurface)
    #expect(axnDocument["actions"]?[0]?["resolve"]?["reveal"]?["direction"] == .string("down"))
    #expect(axnDocument["actions"]?[0]?["resolve"]?["reveal"]?["deltaY"] == .double(-120))
    #expect(axnDocument["actions"]?[0]?["expects"] == nil)
    #expect(axnDocument["actions"]?[1] == nil)
}

@Test func recordingTranslatorFoldsChangingScrollTargetsIntoNextActionReveal() throws {
    let translator = UserRecordingTranslator()
    let window: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXWindow"),
            "title": .string("Article - Browser")
        ])
    ])
    let incidentalLink: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXLink"),
            "title": .string("Incidental")
        ])
    ])
    let point: JSONValue = .object([
        "app": .string("Example"),
        "point": .object([
            "x": .double(200),
            "y": .double(300)
        ])
    ])
    let targetLink: JSONValue = .object([
        "app": .string("Example"),
        "locator": .object([
            "role": .string("AXLink"),
            "title": .string("Final")
        ])
    ])

    let axnDocument = try translator.axnDocument(from: [
        RecordedUserEventGroup(action: .scroll(target: window, app: "Example", deltaX: 0, deltaY: -120)),
        RecordedUserEventGroup(action: .scroll(target: incidentalLink, app: "Example", deltaX: 0, deltaY: -120)),
        RecordedUserEventGroup(action: .scroll(target: point, app: "Example", deltaX: 0, deltaY: -120)),
        RecordedUserEventGroup(action: .click(target: targetLink))
    ])

    #expect(axnDocument["actions"]?[0]?["tool"] == .string("click"))
    #expect(axnDocument["actions"]?[0]?["target"] == targetLink)
    #expect(axnDocument["actions"]?[0]?["resolve"]?["reveal"]?["app"] == .string("Example"))
    #expect(axnDocument["actions"]?[0]?["resolve"]?["reveal"]?["surface"] == nil)
    #expect(axnDocument["actions"]?[0]?["resolve"]?["reveal"]?["deltaY"] == .double(-360))
    #expect(axnDocument["actions"]?[1] == nil)
}

@Test func recordedLocatorDoesNotIncludeVolatileWindowTitle() {
    let locator = RecordedLocatorBuilder.locator(
        role: "AXButton",
        subrole: nil,
        identifier: nil,
        title: nil,
        description: "Open a new tab",
        actions: ["AXPress"],
        windowTitle: "Old Page Title"
    )

    #expect(locator["role"] == .string("AXButton"))
    #expect(locator["description"] == .string("Open a new tab"))
    #expect(locator["ancestors"]?[0]?["role"] == .string("AXWindow"))
    #expect(locator["ancestors"]?[0]?["title"] == nil)
}

@Test func recordedLocatorIncludesStableAncestorPath() throws {
    let locator = RecordedLocatorBuilder.locator(
        role: "AXButton",
        subrole: nil,
        identifier: nil,
        title: "Deploy",
        description: nil,
        actions: ["AXPress"],
        windowTitle: "Volatile Page Title",
        ancestors: [
            RecordedAncestorCandidate(
                role: "AXWindow",
                subrole: nil,
                identifier: nil,
                title: "Volatile Page Title"
            ),
            RecordedAncestorCandidate(
                role: "AXGroup",
                subrole: "AXContentGroup",
                identifier: "main-content",
                title: nil
            )
        ]
    )
    guard case let .array(ancestors)? = locator["ancestors"] else {
        Issue.record("expected ancestors array")
        return
    }

    #expect(ancestors.count == 2)
    #expect(ancestors[0]["role"] == .string("AXWindow"))
    #expect(ancestors[0]["title"] == nil)
    #expect(ancestors[1]["role"] == .string("AXGroup"))
    #expect(ancestors[1]["subrole"] == .string("AXContentGroup"))
    #expect(ancestors[1]["identifier"] == .string("main-content"))
}

@Test func recordedLocatorOmitsAppScopedAncestor() throws {
    let locator = RecordedLocatorBuilder.locator(
        role: "AXComboBox",
        subrole: nil,
        identifier: nil,
        title: nil,
        description: "Search with Google or enter address",
        actions: [],
        windowTitle: "Example",
        ancestors: [
            RecordedAncestorCandidate(role: "AXApplication", title: "Example"),
            RecordedAncestorCandidate(role: "AXWindow", title: "Example"),
            RecordedAncestorCandidate(role: "AXToolbar")
        ]
    )
    guard case let .array(ancestors)? = locator["ancestors"] else {
        Issue.record("expected ancestors array")
        return
    }

    #expect(ancestors.count == 2)
    #expect(ancestors[0]["role"] == .string("AXWindow"))
    #expect(ancestors[1]["role"] == .string("AXToolbar"))
}

@Test func recordedTargetSelectorOmitsEditableElementValueFromLocator() throws {
    let selection = try #require(RecordedTargetSelector.select(from: [
        RecordedElementCandidate(
            role: "AXComboBox",
            value: "wikipedia.org",
            windowTitle: "Example",
            hasWindowAncestor: true
        )
    ]))

    #expect(selection.locator["role"] == .string("AXComboBox"))
    #expect(selection.locator["value"] == nil)
}

@Test func recordedLocatorRejectsElementsOutsideWindowSnapshots() {
    let locator = RecordedLocatorBuilder.locator(
        role: "AXGroup",
        subrole: "AXApplicationGroup",
        identifier: nil,
        title: nil,
        description: nil,
        actions: ["AXPress"],
        windowTitle: nil
    )

    #expect(RecordedLocatorBuilder.strictReplayWarning(for: locator, role: "AXGroup", hasWindowAncestor: false) == "AX element is outside captured window tree; recorded point fallback")
}

@Test func recordedLocatorAcceptsStableLinksOutsideWindowSnapshots() {
    let locator = RecordedLocatorBuilder.locator(
        role: "AXLink",
        subrole: nil,
        identifier: nil,
        title: "Article",
        description: nil,
        actions: ["AXPress"],
        windowTitle: nil
    )

    #expect(RecordedLocatorBuilder.strictReplayWarning(for: locator, role: "AXLink", hasWindowAncestor: false) == nil)
}

@Test func recordedLocatorRejectsAnonymousStructuralClickTargets() {
    let locator = RecordedLocatorBuilder.locator(
        role: "AXGroup",
        subrole: nil,
        identifier: nil,
        title: nil,
        description: nil,
        actions: ["AXPress"],
        windowTitle: "Example"
    )

    #expect(RecordedLocatorBuilder.strictReplayWarning(for: locator, role: "AXGroup", hasWindowAncestor: true) == "structural AX element is not a stable replay target; recorded point fallback")
}

@Test func recordedLocatorAcceptsDescribedButtons() {
    let locator = RecordedLocatorBuilder.locator(
        role: "AXButton",
        subrole: nil,
        identifier: nil,
        title: nil,
        description: "New Tab",
        actions: ["AXPress"],
        windowTitle: "Example"
    )

    #expect(RecordedLocatorBuilder.strictReplayWarning(for: locator, role: "AXButton", hasWindowAncestor: true) == nil)
}

@Test func recordedTargetSelectorPromotesTextHitToActionableLinkAncestor() throws {
    let selection = try #require(RecordedTargetSelector.select(from: [
        RecordedElementCandidate(
            role: "AXStaticText",
            title: "Comet",
            actions: [],
            hasWindowAncestor: false
        ),
        RecordedElementCandidate(
            role: "AXLink",
            actions: ["AXPress"],
            hasWindowAncestor: false
        )
    ]))

    #expect(selection.candidate.role == "AXLink")
    #expect(selection.locator["role"] == .string("AXLink"))
    #expect(selection.locator["title"] == .string("Comet"))
    #expect(selection.locator["actions"] == .array([.string("AXPress")]))
    #expect(selection.warnings.isEmpty)
}

@Test func recordedTargetSelectorPrefersActionableAncestorOverReplayableTextChild() throws {
    let selection = try #require(RecordedTargetSelector.select(from: [
        RecordedElementCandidate(
            role: "AXStaticText",
            title: "Comet",
            actions: [],
            windowTitle: "Example",
            hasWindowAncestor: true
        ),
        RecordedElementCandidate(
            role: "AXLink",
            actions: ["AXPress"],
            windowTitle: "Example",
            hasWindowAncestor: true
        )
    ]))

    #expect(selection.candidate.role == "AXLink")
    #expect(selection.locator["role"] == .string("AXLink"))
    #expect(selection.locator["title"] == .string("Comet"))
}
