import Testing
@testable import AxonCore

@Test func observationPagesBroadSiblingSetsWithoutDroppingFollowingContent() {
    let tabs = (1...30).map { index in
        AXNode(role: "AXRadioButton", title: "Tab \(index)", actions: ["AXPress"], children: [
            AXNode(role: "AXStaticText", title: "Tab \(index)")
        ])
    }
    let snapshot = AppSnapshot(
        id: SnapshotID("obs"),
        app: AppIdentity(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Firefox", children: [
                AXNode(role: "AXTabGroup", title: "Browser tabs", children: tabs),
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXGroup", children: [
                        AXNode(role: "AXHeading", title: "Front page story")
                    ])
                ])
            ])
        ],
        screenshot: nil
    )

    let observation = SnapshotObservationFormatter().observation(from: snapshot.jsonValue, frames: false)
    let window = observation["tree"]?[0]
    let tabGroup = window?["children"]?[0]

    #expect(tabGroup?["role"] == .string("tabgroup"))
    #expect(tabGroup?["children"]?.arrayValue?.count == 24)
    #expect(tabGroup?["truncated"] == .string("showing 24 of 30 children"))
    #expect(window?["children"]?[1]?["role"] == .string("heading"))
    #expect(window?["children"]?[1]?["label"] == .string("Front page story"))
}

@Test func observationCollapsesAnonymousWrapperChainsBeforeUsefulLeaves() {
    let snapshot = AppSnapshot(
        id: SnapshotID("obs"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXGroup", actions: ["AXPress", "AXShowMenu", "AXScrollToVisible"], children: [
                    AXNode(role: "AXScrollArea", actions: ["AXPress", "AXShowMenu", "AXScrollToVisible"], children: [
                        AXNode(role: "AXWebArea", actions: ["AXPress", "AXShowMenu", "AXScrollToVisible"], children: [
                            AXNode(role: "AXGroup", actions: ["AXPress", "AXShowMenu", "AXScrollToVisible"], children: [
                                AXNode(role: "AXButton", title: "Run", actions: ["AXPress"])
                            ])
                        ])
                    ])
                ])
            ])
        ],
        screenshot: nil
    )

    let observation = SnapshotObservationFormatter().observation(from: snapshot.jsonValue, frames: false)
    let child = observation["tree"]?[0]?["children"]?[0]

    #expect(child?["role"] == .string("button"))
    #expect(child?["label"] == .string("Run"))
}

@Test func observationCoalescesAdjacentStaticTextUnderParent() {
    let snapshot = AppSnapshot(
        id: SnapshotID("obs"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXLink", title: "Story title", actions: ["AXPress"]),
                    AXNode(role: "AXStaticText", title: "42 points"),
                    AXNode(role: "AXStaticText", title: "by alice"),
                    AXNode(role: "AXStaticText", title: "13 comments")
                ])
            ])
        ],
        screenshot: nil
    )

    let observation = SnapshotObservationFormatter().observation(from: snapshot.jsonValue, frames: false)
    let row = observation["tree"]?[0]?["children"]?[0]

    #expect(row?["role"] == .string("group"))
    #expect(row?["label"] == .string("42 points by alice 13 comments"))
    #expect(row?["children"]?.arrayValue?.count == 1)
    #expect(row?["children"]?[0]?["role"] == .string("link"))
    #expect(row?["children"]?[0]?["label"] == .string("Story title"))
}

@Test func observationIgnoresAXUIElementPointerLabels() {
    let snapshot = AppSnapshot(
        id: SnapshotID("obs"),
        app: AppIdentity(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Firefox", children: [
                AXNode(
                    role: "AXTabGroup",
                    title: "<AXUIElement 0x123> {pid=7}",
                    truncationReason: "children limited to 24 of 92"
                )
            ])
        ],
        screenshot: nil
    )

    let observation = SnapshotObservationFormatter().observation(from: snapshot.jsonValue, frames: false)
    let tabGroup = observation["tree"]?[0]?["children"]?[0]

    #expect(tabGroup?["role"] == .string("tabgroup"))
    #expect(tabGroup?["label"] == nil)
    #expect(tabGroup?["truncated"] == .string("children limited to 24 of 92"))
}

@Test func observationDoesNotExposeClickOnHeadings() {
    let snapshot = AppSnapshot(
        id: SnapshotID("obs"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXHeading", title: "Overview", actions: ["AXPress"])
            ])
        ],
        screenshot: nil
    )

    let observation = SnapshotObservationFormatter().observation(from: snapshot.jsonValue, frames: false)
    let heading = observation["tree"]?[0]?["children"]?[0]

    #expect(heading?["role"] == .string("heading"))
    #expect(heading?["label"] == .string("Overview"))
    #expect(heading?["actions"] == nil)
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else {
            return nil
        }
        return values
    }
}
