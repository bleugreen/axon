import Foundation
import Testing
@testable import AxonCore

@Test func textLocationResolverReturnsCenterPointForUniqueAXText() {
    let snapshot = textLocationFixtureSnapshot([
        AXNode(role: "AXStaticText", title: "Backlog", frame: AXFrame(x: 100, y: 50, width: 80, height: 20))
    ])
    let target = TextLocationTarget(app: "cairn", text: .exact("backlog"), source: .auto)

    let resolution = TextLocationResolver().resolve(target, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.point == ActionPoint(
        x: 140,
        y: 60,
        app: "com.example.App",
        sourceWindowFrame: textLocationFixtureWindowFrame
    ))
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

@Test func textLocationResolverReturnsCenterPointForScreenshotText() {
    let snapshot = textLocationFixtureSnapshot([], screenshot: textLocationFixtureScreenshot())
    let target = TextLocationTarget(app: "cairn", text: .exact("Backlog"), source: .screenshot)
    let resolver = TextLocationResolver(recognizeText: { _ in
        [
            RecognizedTextObservation(
                text: "Backlog",
                boundingBox: NormalizedTextBoundingBox(x: 0.25, y: 0.60, width: 0.20, height: 0.10),
                confidence: 0.95
            )
        ]
    })

    let resolution = resolver.resolve(target, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.point == ActionPoint(
        x: 225,
        y: 200,
        app: "com.example.App",
        sourceWindowFrame: textLocationFixtureWindowFrame
    ))
    #expect(resolution.best?.source == .screenshot)
    #expect(resolution.best?.matchedText == "Backlog")
    #expect(resolution.best?.frame == AXFrame(x: 175, y: 180, width: 100, height: 40))
}

@Test func textLocationResolverAutoFallsBackToScreenshotTextWhenAXTextIsMissing() {
    let snapshot = textLocationFixtureSnapshot(
        [AXNode(role: "AXStaticText", title: "Inbox", frame: AXFrame(x: 20, y: 20, width: 60, height: 20))],
        screenshot: textLocationFixtureScreenshot()
    )
    let target = TextLocationTarget(app: "cairn", text: .exact("Backlog"), source: .auto)
    let resolver = TextLocationResolver(recognizeText: { _ in
        [
            RecognizedTextObservation(
                text: "Backlog",
                boundingBox: NormalizedTextBoundingBox(x: 0.25, y: 0.60, width: 0.20, height: 0.10),
                confidence: 0.95
            )
        ]
    })

    let resolution = resolver.resolve(target, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.source == .screenshot)
}

@Test func textLocationResolverCountsFramedNodesWithNoReadableText() {
    // The Safari shape from the field report: a link with a correct role and frame whose
    // every matched attribute is empty. No text in the captured node means nothing for
    // source:'ax' to match, whatever a human sees rendered in its place.
    let snapshot = textLocationFixtureSnapshot([
        AXNode(role: "AXLink", frame: AXFrame(x: 100, y: 50, width: 80, height: 20))
    ])
    let target = TextLocationTarget(app: "cairn", text: .exact("719 comments"), source: .ax)

    let resolution = TextLocationResolver().resolve(target, in: snapshot)

    #expect(resolution.status == .missing)
    #expect(resolution.opaqueNodeCount == 1)
    #expect(resolution.jsonValue["opaqueNodeCount"] == .int(1))
}

@Test func textLocationResolverMatchesTextCarriedInValue() {
    let snapshot = textLocationFixtureSnapshot([
        AXNode(role: "AXStaticText", value: "Backlog", frame: AXFrame(x: 100, y: 50, width: 80, height: 20))
    ])
    let target = TextLocationTarget(app: "cairn", text: .exact("Backlog"), source: .ax)

    let resolution = TextLocationResolver().resolve(target, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.best?.reasons.first?.hasPrefix("value ") == true)
}

@Test func textLocationResolverReportsNoOpaqueNodesWhenAXMatchingSucceeds() {
    let snapshot = textLocationFixtureSnapshot([
        AXNode(role: "AXStaticText", title: "Backlog", frame: AXFrame(x: 100, y: 50, width: 80, height: 20)),
        AXNode(role: "AXLink", frame: AXFrame(x: 300, y: 50, width: 80, height: 20))
    ])
    let target = TextLocationTarget(app: "cairn", text: .exact("Backlog"), source: .ax)

    let resolution = TextLocationResolver().resolve(target, in: snapshot)

    #expect(resolution.status == .unique)
    #expect(resolution.opaqueNodeCount == 0)
}

@Test func textLocationResolverSkipsOpaqueCountForScreenshotSource() {
    let snapshot = textLocationFixtureSnapshot([
        AXNode(role: "AXLink", frame: AXFrame(x: 100, y: 50, width: 80, height: 20))
    ])
    let target = TextLocationTarget(app: "cairn", text: .exact("719 comments"), source: .screenshot)

    let resolution = TextLocationResolver(recognizeText: { _ in [] }).resolve(target, in: snapshot)

    #expect(resolution.status == .missing)
    #expect(resolution.opaqueNodeCount == 0)
}

// The two surfaces share the ordered attribute list, not the whole predicate, and these
// two tests exist to stop a reader from re-deriving the tempting-but-false claim that an
// observation's ⟨N unreadable nodes⟩ marker and an unmatchable AX node are the same fact.
// They are not: the marker reports children that vanished from the observation for any
// reason, and thinning drops readable children too.

@Test func observationMarksCoalescedChildrenUnreadableEvenThoughAXCanMatchThem() {
    // A link with no text of its own and two labeled text children. The formatter folds the
    // children's labels into the parent and empties the child list, which trips the opacity
    // marker — while the children remain in the captured tree and remain matchable.
    let snapshot = textLocationFixtureSnapshot([
        AXNode(
            role: "AXLink",
            frame: AXFrame(x: 100, y: 50, width: 160, height: 20),
            children: [
                AXNode(role: "AXStaticText", title: "719 comments", frame: AXFrame(x: 100, y: 50, width: 80, height: 20)),
                AXNode(role: "AXStaticText", title: "Reply", frame: AXFrame(x: 180, y: 50, width: 80, height: 20))
            ]
        )
    ])
    let formatter = SnapshotObservationFormatter()
    let observationText = formatter.text(from: formatter.observation(from: snapshot.jsonValue, frames: false))

    let resolution = TextLocationResolver().resolve(
        TextLocationTarget(app: "cairn", text: .exact("719 comments"), source: .ax),
        in: snapshot
    )

    #expect(observationText.contains("unreadable"))
    #expect(resolution.status == .unique)
    #expect(resolution.opaqueNodeCount == 0)
}

@Test func aPointerDescriptionIsReadableToTheMatcherAndUnreadableToTheObservation() {
    // The observation rejects AX pointer descriptions as labels; the matcher does not filter
    // them, so such a node is not opaque by the resolver's measure even when the observation
    // has nothing to render for it.
    let snapshot = textLocationFixtureSnapshot([
        AXNode(
            role: "AXGroup",
            title: "<AXUIElement 0x600000123456> {pid=42}",
            frame: AXFrame(x: 100, y: 50, width: 80, height: 20)
        )
    ])

    let resolution = TextLocationResolver().resolve(
        TextLocationTarget(app: "cairn", text: .exact("719 comments"), source: .ax),
        in: snapshot
    )

    #expect(resolution.status == .missing)
    #expect(resolution.opaqueNodeCount == 0)
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

@Test func textLocationResolutionJSONRedactsActiveCredentialMatchedText() throws {
    let secret = "correct horse battery staple"
    let resolution = TextLocationResolution(
        status: .unique,
        snapshotID: SnapshotID("text-location-fixture"),
        best: TextLocationCandidate(
            index: 1,
            handle: SnapshotHandle(snapshotID: SnapshotID("text-location-fixture"), nodeIndex: 1),
            role: "AXStaticText",
            matchedText: secret,
            source: .ax,
            frame: AXFrame(x: 100, y: 100, width: 100, height: 20),
            point: ActionPoint(x: 150, y: 110),
            reasons: ["title exact \(secret)"]
        ),
        candidates: [
            TextLocationCandidate(
                index: 1,
                handle: SnapshotHandle(snapshotID: SnapshotID("text-location-fixture"), nodeIndex: 1),
                role: "AXStaticText",
                matchedText: secret,
                source: .ax,
                frame: AXFrame(x: 100, y: 100, width: 100, height: 20),
                point: ActionPoint(x: 150, y: 110),
                reasons: ["title exact \(secret)"]
            )
        ]
    )

    let json = resolution.jsonValue(activeSecretRedactor: try textLocationActiveRedactor(values: [secret]))
    let encoded = try JSONEncoder().encode(json)
    let encodedString = String(decoding: encoded, as: UTF8.self)

    #expect(json["best"]?["matchedText"] == .string("<redacted: active-credential>"))
    #expect(json["best"]?["redaction"]?["reasons"]?["matchedText"] == .string("active-credential"))
    #expect(json["candidates"]?[0]?["matchedText"] == .string("<redacted: active-credential>"))
    #expect(encodedString.contains(secret) == false)
}

@Test func textLocationResolutionJSONRedactsDeterministicSubstringMatcherReasons() throws {
    let token = "sk-proj-abcdef1234567890SECRET"
    let matchedText = "Generated token \(token)"
    let resolution = TextLocationResolution(
        status: .unique,
        snapshotID: SnapshotID("text-location-fixture"),
        best: TextLocationCandidate(
            index: 1,
            handle: SnapshotHandle(snapshotID: SnapshotID("text-location-fixture"), nodeIndex: 1),
            role: "AXStaticText",
            matchedText: matchedText,
            source: .ax,
            frame: AXFrame(x: 100, y: 100, width: 100, height: 20),
            point: ActionPoint(x: 150, y: 110),
            reasons: ["title contains \(token)"]
        ),
        candidates: [
            TextLocationCandidate(
                index: 1,
                handle: SnapshotHandle(snapshotID: SnapshotID("text-location-fixture"), nodeIndex: 1),
                role: "AXStaticText",
                matchedText: matchedText,
                source: .ax,
                frame: AXFrame(x: 100, y: 100, width: 100, height: 20),
                point: ActionPoint(x: 150, y: 110),
                reasons: ["title contains \(token)"]
            )
        ]
    )

    let json = resolution.jsonValue
    let encoded = try JSONEncoder().encode(json)
    let encodedString = String(decoding: encoded, as: UTF8.self)

    #expect(json["best"]?["matchedText"] == .string("<redacted: auth-credential>"))
    #expect(json["best"]?["reasons"]?[0] == .string("<redacted: auth-credential>"))
    #expect(json["candidates"]?[0]?["reasons"]?[0] == .string("<redacted: auth-credential>"))
    #expect(encodedString.contains(token) == false)
}

/// The frame of the fixture's only window, and therefore of whatever a capture photographed.
private let textLocationFixtureWindowFrame = AXFrame(x: 50, y: 60, width: 500, height: 400)

private func textLocationFixtureScreenshot(
    width: Int = 800,
    height: Int = 600,
    sourceWindowFrame: AXFrame? = textLocationFixtureWindowFrame
) -> EncodedScreenshot {
    EncodedScreenshot(
        mediaType: "image/png",
        base64Data: "fake",
        width: width,
        height: height,
        sourceWindowFrame: sourceWindowFrame
    )
}

private func textLocationFixtureSnapshot(
    _ children: [AXNode],
    screenshot: EncodedScreenshot? = nil,
    windowFrames: [AXFrame] = [textLocationFixtureWindowFrame]
) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("text-location-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: windowFrames.enumerated().map { index, frame in
            AXNode(
                role: "AXWindow",
                title: "Main",
                frame: frame,
                children: index == 0 ? children : []
            )
        },
        screenshot: screenshot
    )
}

private func textLocationActiveRedactor(values: [String]) throws -> ActiveSecretRedactor {
    ActiveSecretRedactor(
        filter: try ActiveCredentialIndex(
            values: values,
            hmacKey: Data(repeating: 0xD4, count: 32),
            provider: "test",
            createdAt: Date(timeIntervalSince1970: 1_775_000_000)
        )
    )
}
