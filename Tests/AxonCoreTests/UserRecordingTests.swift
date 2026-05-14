import Testing
@testable import AxonCore

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

    let batch = try translator.batch(from: [
        RecordedUserEventGroup(action: .setValue(target: target, value: "Mitch"))
    ])

    #expect(batch["version"] == .int(1))
    #expect(batch["actions"]?[0]?["id"] == .string("a001"))
    #expect(batch["actions"]?[0]?["tool"] == .string("type"))
    #expect(batch["actions"]?[0]?["expects"]?[0]?["id"] == .string("a001.value.0"))
    #expect(batch["actions"]?[0]?["expects"]?[0]?["state"]?["value"]?["contains"] == .string("Mitch"))
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

    let batch = try translator.batch(from: [
        RecordedUserEventGroup(action: .setValue(target: target, value: "Mitch")),
        RecordedUserEventGroup(action: .pressKey(app: "Example", key: "Return"))
    ])

    #expect(batch["actions"]?[1]?["id"] == .string("a002"))
    #expect(batch["actions"]?[1]?["requires"]?[0] == .string("a001.value.0"))
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

    let batch = try translator.batch(from: [
        RecordedUserEventGroup(action: .setValue(target: field, value: "wikipedia.com")),
        RecordedUserEventGroup(action: .pressKey(app: "Example", key: "Return")),
        RecordedUserEventGroup(action: .click(target: link))
    ])

    #expect(batch["actions"]?[1]?["requires"]?[0] == .string("a001.value.0"))
    #expect(batch["actions"]?[2]?["requires"] == nil)
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

    let batch = try translator.batch(from: [
        RecordedUserEventGroup(action: .setValue(target: field, value: "wikipedia.com")),
        RecordedUserEventGroup(action: .click(target: button)),
        RecordedUserEventGroup(action: .click(target: link))
    ])

    #expect(batch["actions"]?[1]?["requires"]?[0] == .string("a001.value.0"))
    #expect(batch["actions"]?[2]?["requires"] == nil)
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

    let batch = try translator.batch(from: [
        RecordedUserEventGroup(action: .setValue(target: field, value: "wikipedia.com")),
        RecordedUserEventGroup(action: .click(target: link)),
        RecordedUserEventGroup(action: .pressKey(app: "Example", key: "Return"))
    ])

    #expect(batch["actions"]?[1]?["requires"] == nil)
    #expect(batch["actions"]?[2]?["requires"]?[0] == .string("a001.value.0"))
}

@Test func recordingTranslatorRecordsWarningsWithoutEnforcingObservedEvidence() throws {
    let translator = UserRecordingTranslator()

    let batch = try translator.batch(from: [
        RecordedUserEventGroup(
            action: .click(target: .object(["point": .object(["x": .double(10), "y": .double(20)])])),
            observed: [.object(["kind": .string("raw-pointer")])],
            warnings: ["point fallback"]
        )
    ])

    #expect(batch["actions"]?[0]?["tool"] == .string("click"))
    #expect(batch["actions"]?[0]?["observed"]?[0]?["kind"] == .string("raw-pointer"))
    #expect(batch["actions"]?[0]?["warnings"]?[0] == .string("point fallback"))
    #expect(batch["actions"]?[0]?["expects"] == nil)
}

@Test func recordingTranslatorAddsChangedExpectationForSubmitKey() throws {
    let translator = UserRecordingTranslator()

    let batch = try translator.batch(from: [
        RecordedUserEventGroup(action: .pressKey(app: "Example", key: "Return"))
    ])

    #expect(batch["actions"]?[0]?["expects"]?[0]?["id"] == .string("a001.changed.0"))
    #expect(batch["actions"]?[0]?["expects"]?[0]?["kind"] == .string("changed"))
    #expect(batch["actions"]?[0]?["expects"]?[0]?["target"]?["app"] == .string("Example"))
}

@Test func recordingTranslatorAddsChangedExpectationForObservedNavigationClick() throws {
    let translator = UserRecordingTranslator()
    let target: JSONValue = .object([
        "app": .string("Example"),
        "point": .object(["x": .double(10), "y": .double(20)])
    ])

    let batch = try translator.batch(from: [
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

    #expect(batch["actions"]?[0]?["expects"]?[0]?["id"] == .string("a001.changed.0"))
    #expect(batch["actions"]?[0]?["expects"]?[0]?["kind"] == .string("changed"))
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

    let batch = try translator.batch(from: [
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
    if case let .array(values)? = batch["actions"]?[0]?["expects"] {
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

    let batch = try translator.batch(from: [
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
    if case let .array(values)? = batch["actions"]?[0]?["expects"] {
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

    let batch = try translator.batch(from: [
        RecordedUserEventGroup(action: .scroll(target: target, app: "Example", deltaX: 0, deltaY: -1)),
        RecordedUserEventGroup(action: .scroll(target: target, app: "Example", deltaX: 0, deltaY: -4)),
        RecordedUserEventGroup(action: .scroll(target: target, app: "Example", deltaX: 0, deltaY: -120))
    ])

    let actions: [JSONValue]
    if case let .array(values)? = batch["actions"] {
        actions = values
    } else {
        actions = []
    }

    #expect(actions.count == 1)
    #expect(batch["actions"]?[0]?["id"] == .string("a001"))
    #expect(batch["actions"]?[0]?["tool"] == .string("scroll"))
    #expect(batch["actions"]?[0]?["deltaY"] == .double(-125))
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

    let batch = try translator.batch(from: [
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: -120)),
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: 120)),
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: -120)),
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: 120)),
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: -120)),
        RecordedUserEventGroup(action: .click(target: link))
    ])

    #expect(batch["actions"]?[0]?["tool"] == .string("click"))
    #expect(batch["actions"]?[0]?["target"] == link)
    #expect(batch["actions"]?[0]?["resolve"]?["reveal"]?["app"] == .string("Example"))
    #expect(batch["actions"]?[0]?["resolve"]?["reveal"]?["surface"] == nil)
    #expect(batch["actions"]?[0]?["resolve"]?["reveal"]?["direction"] == .string("down"))
    #expect(batch["actions"]?[0]?["resolve"]?["reveal"]?["deltaY"] == .double(-120))
    #expect(batch["actions"]?[1] == nil)
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

    let batch = try translator.batch(from: [
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: -1)),
        RecordedUserEventGroup(action: .scroll(target: scrollSurface, app: "Example", deltaX: 0, deltaY: -4)),
        RecordedUserEventGroup(action: .click(target: link))
    ])

    #expect(batch["actions"]?[0]?["id"] == .string("a001"))
    #expect(batch["actions"]?[0]?["tool"] == .string("click"))
    #expect(batch["actions"]?[0]?["target"] == link)
    #expect(batch["actions"]?[0]?["resolve"]?["reveal"]?["surface"] == scrollSurface)
    #expect(batch["actions"]?[0]?["resolve"]?["reveal"]?["direction"] == .string("down"))
    #expect(batch["actions"]?[0]?["resolve"]?["reveal"]?["deltaY"] == .double(-120))
    #expect(batch["actions"]?[0]?["expects"] == nil)
    #expect(batch["actions"]?[1] == nil)
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

    let batch = try translator.batch(from: [
        RecordedUserEventGroup(action: .scroll(target: window, app: "Example", deltaX: 0, deltaY: -120)),
        RecordedUserEventGroup(action: .scroll(target: incidentalLink, app: "Example", deltaX: 0, deltaY: -120)),
        RecordedUserEventGroup(action: .scroll(target: point, app: "Example", deltaX: 0, deltaY: -120)),
        RecordedUserEventGroup(action: .click(target: targetLink))
    ])

    #expect(batch["actions"]?[0]?["tool"] == .string("click"))
    #expect(batch["actions"]?[0]?["target"] == targetLink)
    #expect(batch["actions"]?[0]?["resolve"]?["reveal"]?["app"] == .string("Example"))
    #expect(batch["actions"]?[0]?["resolve"]?["reveal"]?["surface"] == nil)
    #expect(batch["actions"]?[0]?["resolve"]?["reveal"]?["deltaY"] == .double(-360))
    #expect(batch["actions"]?[1] == nil)
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
