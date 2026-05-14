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
    #expect(tabGroup?["children"]?.arrayValue?.count == 30)
    #expect(tabGroup?["truncated"] == nil)
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

@Test func observationDropsEmptyRowsCellsAndDecorativeLabels() {
    let snapshot = AppSnapshot(
        id: SnapshotID("obs"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXList", children: [
                    AXNode(role: "AXRow"),
                    AXNode(role: "AXRow", children: [
                        AXNode(role: "AXCell"),
                        AXNode(role: "AXCell", title: "( )"),
                        AXNode(role: "AXCell", children: [
                            AXNode(role: "AXLink", title: "Story title", actions: ["AXPress"])
                        ]),
                        AXNode(role: "AXCell", children: [
                            AXNode(role: "AXStaticText", title: "|"),
                            AXNode(role: "AXLink", title: "[–]", actions: ["AXPress"])
                        ]),
                        AXNode(role: "AXCell", children: [
                            AXNode(role: "AXStaticText", title: "42 points"),
                            AXNode(role: "AXStaticText", title: "by alice"),
                            AXNode(role: "AXLink", title: "13 comments", actions: ["AXPress"])
                        ])
                    ])
                ])
            ])
        ],
        screenshot: nil
    )

    let observation = SnapshotObservationFormatter().observation(from: snapshot.jsonValue, frames: false)
    let text = SnapshotObservationFormatter().text(from: observation)

    #expect(text.contains("link \"Story title\" [click]"))
    #expect(text.contains("item"))
    #expect(text.contains("group \"42 points by alice\""))
    #expect(text.contains("link \"13 comments\" [click]"))
    #expect(!text.contains("row"))
    #expect(!text.contains("cell"))
    #expect(!text.contains("\"( )\""))
    #expect(!text.contains("text"))
    #expect(!text.contains("\"[–]\""))
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

@Test func observationShowsContinuationDoorForCaptureTruncation() {
    let snapshot = AppSnapshot(
        id: SnapshotID("obs"),
        app: AppIdentity(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Firefox", children: [
                AXNode(
                    role: "AXGroup",
                    title: "Comment thread",
                    truncationReason: "children limited to 24 of 154",
                    children: [
                        AXNode(role: "AXLink", title: "reply", actions: ["AXPress"])
                    ]
                )
            ])
        ],
        screenshot: nil
    )

    let observation = SnapshotObservationFormatter().observation(from: snapshot.jsonValue, frames: false)
    let thread = observation["tree"]?[0]?["children"]?[0]
    let text = SnapshotObservationFormatter().text(from: observation)

    #expect(thread?["more"]?["tool"] == .string("look"))
    #expect(thread?["more"]?["target"] == .string("obs:1"))
    #expect(thread?["more"]?["offset"] == .int(24))
    #expect(thread?["more"]?["total"] == .int(154))
    #expect(text.contains("more: look target=obs:1 offset=24 limit=24 total=154"))
    #expect(!text.contains("children limited to 24 of 154"))
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

@Test func childListObservationContainsOnlyRequestedChildrenAndPagingCursor() {
    let children = AXChildrenPage(
        snapshotID: SnapshotID("s12"),
        parentHandle: "s12:4",
        offset: 24,
        limit: 2,
        total: 30,
        baseIndex: 42,
        children: [
            AXNode(role: "AXButton", title: "Tab 25", actions: ["AXPress"]),
            AXNode(role: "AXButton", title: "Tab 26", actions: ["AXPress"])
        ]
    )

    let observation = SnapshotObservationFormatter().children(from: children.jsonValue, frames: false)
    let text = SnapshotObservationFormatter().text(from: observation)

    #expect(observation["format"] == .string("children"))
    #expect(observation["parent"] == .string("s12:4"))
    #expect(observation["offset"] == .int(24))
    #expect(observation["nextOffset"] == .int(26))
    #expect(observation["items"]?[0]?["handle"] == .string("s12:42"))
    #expect(observation["items"]?[1]?["handle"] == .string("s12:43"))
    #expect(observation["tree"] == nil)
    #expect(text.contains("children:"))
    #expect(text.contains("range: 24..<26 of 30"))
    #expect(text.contains("nextOffset: 26"))
    #expect(text.contains("s12:42 button \"Tab 25\""))
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else {
            return nil
        }
        return values
    }
}
