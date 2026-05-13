import Testing
@testable import AxonCore

@Test func locatorResolverReturnsUniqueMatchWithHandle() {
    let snapshot = locatorFixtureSnapshot(buttons: ["NEW"])
    let locator = AXLocator(
        role: "AXButton",
        title: .exact("NEW"),
        actions: ["AXPress"],
        ancestors: [
            AXAncestorLocator(role: "AXWindow", title: .exact("Main"))
        ]
    )

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.index == 2)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:2")
    #expect(resolution.best?.reasons.contains("title exact NEW") == true)
}

@Test func locatorResolverReportsAmbiguousMatches() {
    let snapshot = locatorFixtureSnapshot(buttons: ["NEW", "NEW"])
    let locator = AXLocator(role: "AXButton", title: .exact("NEW"))

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .ambiguous)
    #expect(resolution.best == nil)
    #expect(resolution.candidates.map(\.index) == [2, 3])
}

@Test func locatorResolverReportsMissingMatches() {
    let snapshot = locatorFixtureSnapshot(buttons: ["NEW"])
    let locator = AXLocator(role: "AXButton", title: .exact("DELETE"))

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .missing)
    #expect(resolution.best == nil)
    #expect(resolution.candidates.isEmpty)
}

@Test func locatorResolverMatchesTransitiveAncestorByDisplayLabel() {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Firefox", children: [
                AXNode(role: "AXToolbar", description: "Navigation", children: [
                    AXNode(role: "AXGroup", children: [
                        AXNode(role: "AXComboBox", value: "example.com", actions: ["AXSetValue"])
                    ])
                ])
            ])
        ],
        screenshot: nil
    )
    let locator = AXLocator(
        role: "AXComboBox",
        label: .contains("example.com"),
        ancestors: [
            AXAncestorLocator(role: "AXToolbar", label: .exact("Navigation"))
        ]
    )

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:3")
    #expect(resolution.best?.reasons.contains("label contains example.com") == true)
    #expect(resolution.best?.reasons.contains("ancestor label exact Navigation") == true)
}

@Test func locatorResolverKeepsTitleMatchingRawTitleOnly() {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Firefox", children: [
                AXNode(role: "AXToolbar", description: "Navigation", children: [
                    AXNode(role: "AXComboBox", value: "example.com", actions: ["AXSetValue"])
                ])
            ])
        ],
        screenshot: nil
    )
    let locator = AXLocator(
        role: "AXComboBox",
        value: .contains("example.com"),
        ancestors: [
            AXAncestorLocator(role: "AXToolbar", title: .exact("Navigation"))
        ]
    )

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .missing)
}

@Test func locatorJSONParsesLabelMatchersForTargetsAndAncestors() throws {
    let locator = try AXLocator(jsonValue: .object([
        "role": .string("AXComboBox"),
        "label": .object(["contains": .string("example.com")]),
        "ancestors": .array([
            .object([
                "role": .string("AXToolbar"),
                "label": .string("Navigation")
            ])
        ])
    ]))

    #expect(locator.label?.matches("https://example.com") == true)
    #expect(locator.ancestors.first?.label?.matches("Navigation") == true)
}

private func locatorFixtureSnapshot(buttons: [String]) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(
                role: "AXWindow",
                title: "Main",
                children: [
                    AXNode(
                        role: "AXGroup",
                        title: "Toolbar",
                        children: buttons.map { title in
                            AXNode(role: "AXButton", title: title, actions: ["AXPress"])
                        }
                    )
                ]
            )
        ],
        screenshot: nil
    )
}
