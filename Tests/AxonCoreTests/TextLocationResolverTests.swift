import Testing
@testable import AxonCore

@Test func textLocationResolverReturnsCenterPointForUniqueAXText() {
    let snapshot = textLocationFixtureSnapshot([
        AXNode(role: "AXStaticText", title: "Backlog", frame: AXFrame(x: 100, y: 50, width: 80, height: 20))
    ])
    let target = TextLocationTarget(app: "cairn", text: .exact("backlog"), source: .auto)

    let resolution = TextLocationResolver().resolve(target, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.point == ActionPoint(x: 140, y: 60))
    #expect(resolution.best?.matchedText == "Backlog")
    #expect(resolution.best?.source == .ax)
    #expect(resolution.best?.frame == AXFrame(x: 100, y: 50, width: 80, height: 20))
}

@Test func textLocationResolverReportsAmbiguousAXText() {
    let snapshot = textLocationFixtureSnapshot([
        AXNode(role: "AXStaticText", title: "Backlog", frame: AXFrame(x: 100, y: 50, width: 80, height: 20)),
        AXNode(role: "AXButton", title: "Backlog", frame: AXFrame(x: 300, y: 50, width: 80, height: 20))
    ])
    let target = TextLocationTarget(app: "cairn", text: .exact("Backlog"), source: .ax)

    let resolution = TextLocationResolver().resolve(target, in: snapshot)

    #expect(resolution.status == .ambiguous)
    #expect(resolution.point == nil)
    #expect(resolution.candidates.count == 2)
}

@Test func textLocationResolverIgnoresMatchingAXTextWithoutFrame() {
    let snapshot = textLocationFixtureSnapshot([
        AXNode(role: "AXStaticText", title: "Backlog"),
        AXNode(role: "AXStaticText", title: "Done", frame: AXFrame(x: 100, y: 50, width: 80, height: 20))
    ])
    let target = TextLocationTarget(app: "cairn", text: .exact("Backlog"), source: .auto)

    let resolution = TextLocationResolver().resolve(target, in: snapshot)

    #expect(resolution.status == .missing)
    #expect(resolution.candidates.isEmpty)
}

@Test func textLocationJSONParsesLocationTarget() throws {
    let target = try TextLocationTarget(jsonValue: .object([
        "app": .string("cairn"),
        "text": .string("Backlog"),
        "source": .string("auto")
    ]))

    #expect(target.app == "cairn")
    #expect(target.text.matches("backlog"))
    #expect(target.source == .auto)
}

private func textLocationFixtureSnapshot(_ children: [AXNode]) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("text-location-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(
                role: "AXWindow",
                title: "Main",
                frame: AXFrame(x: 0, y: 0, width: 500, height: 300),
                children: children
            )
        ],
        screenshot: nil
    )
}
