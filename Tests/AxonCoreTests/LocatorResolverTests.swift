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
    #expect(resolution.best?.handle?.rawValue == "snapshot:locator-fixture:2")
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
