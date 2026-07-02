import Foundation
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

@Test func locatorResolverUsesPrimaryWindowAsTieBreaker() {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Active", children: [
                AXNode(role: "AXComboBox", description: "Search with Google or enter address")
            ]),
            AXNode(role: "AXWindow", title: "Background", children: [
                AXNode(role: "AXComboBox", description: "Search with Google or enter address")
            ])
        ],
        screenshot: nil
    )
    let locator = AXLocator(
        role: "AXComboBox",
        description: .exact("Search with Google or enter address")
    )

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:1")
    #expect(resolution.best?.reasons.contains("primary window") == true)
}

@Test func locatorResolverPrefersValueMatchOverPrimaryWindowHint() {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Active", children: [
                AXNode(
                    role: "AXComboBox",
                    value: "wikipedia.org/",
                    description: "Search with Google or enter address"
                )
            ]),
            AXNode(role: "AXWindow", title: "Background", children: [
                AXNode(
                    role: "AXComboBox",
                    value: "wikipedia.org",
                    description: "Search with Google or enter address"
                )
            ])
        ],
        screenshot: nil
    )
    let locator = AXLocator(
        role: "AXComboBox",
        value: .exact("wikipedia.org"),
        description: .exact("Search with Google or enter address")
    )

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:3")
    #expect(resolution.best?.reasons.contains("value exact wikipedia.org") == true)
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

@Test func locatorResolverTreatsAppAncestorAndActionsAsReplayHints() throws {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", children: [
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXToolbar", children: [
                        AXNode(
                            role: "AXComboBox",
                            description: "Search with Google or enter address",
                            actions: []
                        )
                    ])
                ])
            ])
        ],
        screenshot: nil
    )
    let locator = AXLocator(
        role: "AXComboBox",
        description: .exact("Search with Google or enter address"),
        actions: ["AXShowMenu", "AXScrollToVisible", "AXPress"],
        ancestors: [
            AXAncestorLocator(role: "AXApplication", title: .exact("Firefox")),
            AXAncestorLocator(role: "AXWindow"),
            AXAncestorLocator(role: "AXToolbar")
        ]
    )

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:3")
    #expect(resolution.best?.reasons.contains("ancestor role AXApplication") == true)
    #expect(resolution.best?.reasons.contains { $0.hasPrefix("action ") } == false)
}

@Test func locatorResolverTreatsEditableValueAsReplayHint() throws {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", children: [
                AXNode(
                    role: "AXComboBox",
                    value: "",
                    description: "Search with Google or enter address"
                )
            ])
        ],
        screenshot: nil
    )
    let locator = AXLocator(
        role: "AXComboBox",
        value: .exact("w"),
        description: .exact("Search with Google or enter address")
    )

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:1")
    #expect(resolution.best?.reasons.contains { $0.hasPrefix("value ") } == false)
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

@Test func locatorResolverMatchesActionableLinkByDescendantTitle() {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Firefox", children: [
                AXNode(role: "AXWebArea", children: [
                    AXNode(role: "AXLink", actions: ["AXPress"], children: [
                        AXNode(role: "AXStaticText", title: "co-operation with Russia")
                    ])
                ])
            ])
        ],
        screenshot: nil
    )
    let locator = AXLocator(
        role: "AXLink",
        title: .exact("co-operation with Russia"),
        actions: ["AXPress"]
    )

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:2")
    #expect(resolution.best?.reasons.contains("descendant title exact co-operation with Russia") == true)
}

@Test func locatorResolverUsesNearbyTextAsPositiveContextOnly() {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXStaticText", title: "Billing"),
                    AXNode(role: "AXButton", title: "Edit", actions: ["AXPress"])
                ]),
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXStaticText", title: "Profile"),
                    AXNode(role: "AXButton", title: "Edit", actions: ["AXPress"])
                ])
            ])
        ],
        screenshot: nil
    )
    let locator = AXLocator(role: "AXButton", title: .exact("Edit"), nearbyText: [.exact("Billing")])

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:3")
    #expect(resolution.best?.reasons.contains("nearby text exact Billing") == true)
}

@Test func locatorResolverDoesNotPenalizeMissingNearbyTextContext() {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(role: "AXButton", title: "Edit", actions: ["AXPress"])
        ],
        screenshot: nil
    )
    let locator = AXLocator(role: "AXButton", title: .exact("Edit"), nearbyText: [.exact("Billing")])

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:0")
    #expect(resolution.best?.reasons.contains { $0.hasPrefix("nearby text ") } == false)
}

@Test func locatorResolverUsesGeometryOnlyAsWeakTieBreaker() {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXButton", title: "Edit", frame: AXFrame(x: 20, y: 20, width: 80, height: 30)),
                AXNode(role: "AXButton", title: "Edit", frame: AXFrame(x: 220, y: 20, width: 80, height: 30))
            ])
        ],
        screenshot: nil
    )
    let locator = AXLocator(
        role: "AXButton",
        title: .exact("Edit"),
        frame: AXFrame(x: 222, y: 18, width: 80, height: 30)
    )

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:2")
    #expect(resolution.best?.reasons.contains { $0.hasPrefix("frame distance ") } == true)
}

@Test func locatorResolverKeepsSemanticSignalsAheadOfGeometry() {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXStaticText", title: "Billing"),
                    AXNode(role: "AXButton", title: "Edit", frame: AXFrame(x: 20, y: 20, width: 80, height: 30))
                ]),
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXButton", title: "Edit", frame: AXFrame(x: 220, y: 20, width: 80, height: 30))
                ])
            ])
        ],
        screenshot: nil
    )
    let locator = AXLocator(
        role: "AXButton",
        title: .exact("Edit"),
        nearbyText: [.exact("Billing")],
        frame: AXFrame(x: 220, y: 20, width: 80, height: 30)
    )

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:3")
    #expect(resolution.best?.reasons.contains("nearby text exact Billing") == true)
}

@Test func locatorResolverMatchesFirstClassWindowScope() {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: [
                AXNode(role: "AXButton", title: "Deploy", actions: ["AXPress"])
            ]),
            AXNode(role: "AXWindow", title: "Build", children: [
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXButton", title: "Deploy", actions: ["AXPress"])
                ])
            ])
        ],
        screenshot: nil
    )
    let locator = AXLocator(
        role: "AXButton",
        title: .exact("Deploy"),
        window: AXAncestorLocator(title: .exact("Build"))
    )

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:4")
    #expect(resolution.best?.reasons.contains("window title exact Build") == true)
    #expect(resolution.confidence == .high)
}

@Test func locatorJSONParsesAdditiveScoringSignalsAndDefaultsOldPayloads() throws {
    let legacyLocator = try AXLocator(jsonValue: .object([
        "role": .string("AXButton"),
        "title": .string("Save")
    ]))
    #expect(legacyLocator.window == nil)
    #expect(legacyLocator.nearbyText.isEmpty)
    #expect(legacyLocator.frame == nil)

    let locator = try AXLocator(jsonValue: .object([
        "role": .string("AXComboBox"),
        "label": .object(["contains": .string("example.com")]),
        "window": .object(["title": .string("Build")]),
        "nearbyText": .array([.string("Billing"), .object(["contains": .string("Invoice")])]),
        "frame": .object([
            "x": .int(10),
            "y": .double(20.5),
            "width": .int(300),
            "height": .int(24)
        ]),
        "ancestors": .array([
            .object([
                "role": .string("AXToolbar"),
                "label": .string("Navigation")
            ])
        ])
    ]))

    #expect(locator.label?.matches("https://example.com") == true)
    #expect(locator.ancestors.first?.label?.matches("Navigation") == true)
    #expect(locator.window?.title?.matches("Build") == true)
    #expect(locator.nearbyText.count == 2)
    #expect(locator.nearbyText[0].matches("Billing") == true)
    #expect(locator.nearbyText[1].matches("Paid Invoice") == true)
    #expect(locator.frame == AXFrame(x: 10, y: 20.5, width: 300, height: 24))
}

@Test func locatorResolutionJSONIncludesNamedConfidence() throws {
    let snapshot = locatorFixtureSnapshot(buttons: ["NEW"])
    let locator = AXLocator(role: "AXButton", title: .exact("NEW"))

    let resolution = LocatorResolver().resolve(locator, in: snapshot)
    let json = resolution.jsonValue

    #expect(resolution.confidence == .medium)
    #expect(json["confidence"] == .string("medium"))
}

@Test func locatorResolverMatchesAncestorSubroleAndIdentifier() throws {
    let snapshot = AppSnapshot(
        id: SnapshotID("locator-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", children: [
                AXNode(role: "AXGroup", subrole: "AXContentGroup", identifier: "main-content", children: [
                    AXNode(role: "AXButton", title: "Deploy", actions: ["AXPress"])
                ]),
                AXNode(role: "AXGroup", subrole: "AXContentGroup", identifier: "secondary-content", children: [
                    AXNode(role: "AXButton", title: "Deploy", actions: ["AXPress"])
                ])
            ])
        ],
        screenshot: nil
    )
    let locator = try AXLocator(jsonValue: .object([
        "role": .string("AXButton"),
        "title": .string("Deploy"),
        "ancestors": .array([
            .object([
                "role": .string("AXGroup"),
                "subrole": .string("AXContentGroup"),
                "identifier": .string("main-content")
            ])
        ])
    ]))

    let resolution = LocatorResolver().resolve(locator, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.handle?.rawValue == "locator-fixture:2")
    #expect(resolution.best?.reasons.contains("ancestor subrole AXContentGroup") == true)
    #expect(resolution.best?.reasons.contains("ancestor identifier exact main-content") == true)
}

@Test func locatorResolutionJSONRedactsActiveCredentialCandidateTitles() throws {
    let rawSecret = "correct horse battery staple"
    let resolution = LocatorResolution(
        status: .unique,
        snapshotID: SnapshotID("locator-fixture"),
        best: LocatorCandidate(
            index: 2,
            handle: SnapshotHandle(snapshotID: SnapshotID("locator-fixture"), nodeIndex: 2),
            role: "AXButton",
            title: rawSecret,
            score: 1,
            reasons: ["title exact \(rawSecret)"]
        ),
        candidates: [
            LocatorCandidate(
                index: 2,
                handle: SnapshotHandle(snapshotID: SnapshotID("locator-fixture"), nodeIndex: 2),
                role: "AXButton",
                title: rawSecret,
                score: 1,
                reasons: ["title exact \(rawSecret)"]
            )
        ]
    )

    let json = resolution.jsonValue(activeSecretRedactor: try locatorActiveRedactor(values: [rawSecret]))
    let encoded = try JSONEncoder().encode(json)
    let encodedString = String(decoding: encoded, as: UTF8.self)

    #expect(json["best"]?["title"] == .string("<redacted: active-credential>"))
    #expect(json["best"]?["redaction"]?["reasons"]?["title"] == .string("active-credential"))
    #expect(json["candidates"]?[0]?["title"] == .string("<redacted: active-credential>"))
    #expect(encodedString.contains(rawSecret) == false)
}

@Test func locatorResolutionJSONRedactsDeterministicSubstringMatcherReasons() throws {
    let token = "sk-proj-abcdef1234567890SECRET"
    let title = "Generated token \(token)"
    let resolution = LocatorResolution(
        status: .unique,
        snapshotID: SnapshotID("locator-fixture"),
        best: LocatorCandidate(
            index: 2,
            handle: SnapshotHandle(snapshotID: SnapshotID("locator-fixture"), nodeIndex: 2),
            role: "AXButton",
            title: title,
            score: 1,
            reasons: ["title contains \(token)"]
        ),
        candidates: [
            LocatorCandidate(
                index: 2,
                handle: SnapshotHandle(snapshotID: SnapshotID("locator-fixture"), nodeIndex: 2),
                role: "AXButton",
                title: title,
                score: 1,
                reasons: ["title contains \(token)"]
            )
        ]
    )

    let json = resolution.jsonValue
    let encoded = try JSONEncoder().encode(json)
    let encodedString = String(decoding: encoded, as: UTF8.self)

    #expect(json["best"]?["title"] == .string("<redacted: auth-credential>"))
    #expect(json["best"]?["reasons"]?[0] == .string("<redacted: auth-credential>"))
    #expect(json["candidates"]?[0]?["reasons"]?[0] == .string("<redacted: auth-credential>"))
    #expect(encodedString.contains(token) == false)
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

private func locatorActiveRedactor(values: [String]) throws -> ActiveSecretRedactor {
    ActiveSecretRedactor(
        filter: try ActiveCredentialIndex(
            values: values,
            hmacKey: Data(repeating: 0x3C, count: 32),
            provider: "test",
            createdAt: Date(timeIntervalSince1970: 1_775_000_000)
        )
    )
}
