import Foundation
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
    let tree = treeString(in: observation)

    #expect(tree.contains("obs:1: tabgroup \"Browser tabs\""))
    #expect((1...24).allSatisfy { tree.contains("radiobutton \"Tab \($0)\" [click]") })
    #expect(!tree.contains("Tab 25"))
    #expect(tree.contains("obs:1: tabgroup \"Browser tabs\" <truncated: children display limited to 24 of 30>"))
    #expect(tree.contains("heading \"Front page story\""))
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
    let tree = treeString(in: observation)

    #expect(tree == "obs:0: window \"Main\"\n  obs:5: button \"Run\" [click]")
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
    let tree = treeString(in: observation)

    #expect(tree == """
    obs:0: window "Main"
      obs:1: group "42 points by alice 13 comments"
        obs:2: link "Story title" [click]
    """)
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
    let tree = treeString(in: observation)

    #expect(tree.contains("obs:1: tabgroup <truncated: children limited to 24 of 92>"))
    #expect(!tree.contains("<AXUIElement"))
}

@Test func observationPaginatesBroadChildrenAfterDslFiltering() {
    let buttons = (1...26).map { index in
        AXNode(role: "AXButton", title: "Action \(index)", actions: ["AXPress"])
    }
    let snapshot = AppSnapshot(
        id: SnapshotID("obs-filtered-page"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Example", children: [
                AXNode(role: "AXGroup", truncationReason: "children limited to 28 of 143", children: [
                    AXNode(role: "AXGroup"),
                    AXNode(role: "AXStaticText", title: "|")
                ] + buttons)
            ])
        ],
        screenshot: nil
    )

    let observation = SnapshotObservationFormatter().observation(from: snapshot.jsonValue, frames: false)
    let tree = treeString(in: observation)
    let text = SnapshotObservationFormatter().text(from: observation)

    #expect((1...24).allSatisfy { tree.contains("button \"Action \($0)\" [click]") })
    #expect(!tree.contains("Action 25"))
    #expect(tree.contains("obs-filtered-page:1: group <truncated: children limited to 24 of 143>"))
    #expect(text.contains("more: look target=obs-filtered-page:1 offset=26 limit=24 total=143"))
}

@Test func observationKeepsSemanticSubroleItemsThatReportOffscreenFrames() {
    let tabs = (1...26).map { index in
        AXNode(
            role: "AXRadioButton",
            subrole: "AXTabButton",
            title: "Tab \(index)",
            frame: AXFrame(x: -9_000 + Double(index * 76), y: 33, width: 76, height: 44),
            actions: ["AXPress"]
        )
    }
    let snapshot = AppSnapshot(
        id: SnapshotID("obs-tabs"),
        app: AppIdentity(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Firefox", children: [
                AXNode(role: "AXTabGroup", truncationReason: "children limited to 28 of 143", children: [
                    AXNode(role: "AXGroup", frame: AXFrame(x: 190, y: 33, width: 0, height: 44)),
                    AXNode(role: "AXButton", title: "Scroll backwards", frame: AXFrame(x: 190, y: 33, width: 28, height: 44), actions: ["AXPress"])
                ] + tabs)
            ])
        ],
        screenshot: nil
    )

    let observation = SnapshotObservationFormatter().observation(from: snapshot.jsonValue, frames: false)
    let tree = treeString(in: observation)
    let text = SnapshotObservationFormatter().text(from: observation)

    #expect((1...24).allSatisfy { tree.contains("radiobutton \"Tab \($0)\" [click]") })
    #expect(!tree.contains("Tab 25"))
    #expect(!tree.contains("Scroll backwards"))
    #expect(tree.contains("obs-tabs:1: tabgroup <truncated: children limited to 24 of 143>"))
    #expect(text.contains("more: look target=obs-tabs:1 offset=26 limit=24 total=143"))
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
    let tree = treeString(in: observation)
    let text = SnapshotObservationFormatter().text(from: observation)

    #expect(tree.contains("obs:1: group \"Comment thread\" <truncated: children limited to 24 of 154>"))
    #expect(tree.contains("more: look target=obs:1 offset=24 limit=24 total=154"))
    #expect(text.contains("more: look target=obs:1 offset=24 limit=24 total=154"))
    #expect(text.contains("children limited to 24 of 154"))
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
    let tree = treeString(in: observation)

    #expect(tree.contains("obs:1: heading \"Overview\""))
    #expect(!tree.contains("heading \"Overview\" [click]"))
}

@Test func observationPromotesAllNodeRedactionReferencesToEnvelope() throws {
    let firstSecret = "first active credential"
    let secondSecret = "second active credential"
    let snapshot = AppSnapshot(
        id: SnapshotID("obs-redaction"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXTextField", value: firstSecret),
                AXNode(role: "AXTextField", value: secondSecret)
            ])
        ],
        screenshot: nil
    )
    let redactor = ActiveSecretRedactor(
        filter: try ActiveCredentialIndex(
            secrets: [
                ActiveCredentialSecret(value: firstSecret, provider: "test", reference: "op://Test/First/secret"),
                ActiveCredentialSecret(value: secondSecret, provider: "test", reference: "op://Test/Second/secret")
            ],
            hmacKey: Data(repeating: 0xA5, count: 32),
            provider: "test",
            createdAt: Date(timeIntervalSince1970: 1_775_000_000)
        )
    )

    let observation = SnapshotObservationFormatter().observation(
        from: snapshot.jsonValue(includeTree: true, activeSecretRedactor: redactor),
        frames: false
    )
    let references = observation["redaction"]?["references"]?["value"]?.arrayValue ?? []

    #expect(references.contains(.string("op://Test/First/secret")))
    #expect(references.contains(.string("op://Test/Second/secret")))
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
    #expect(observation["tree"] == .string("s12:42: button \"Tab 25\" [click]\ns12:43: button \"Tab 26\" [click]"))
    #expect(text.contains("children:"))
    #expect(text.contains("range: 24..<26 of 30"))
    #expect(text.contains("nextOffset: 26"))
    #expect(text.contains("s12:42: button \"Tab 25\" [click]"))
}

private func treeString(in observation: JSONValue) -> String {
    guard case let .string(tree)? = observation["tree"] else {
        return ""
    }
    return tree
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else {
            return nil
        }
        return values
    }
}
