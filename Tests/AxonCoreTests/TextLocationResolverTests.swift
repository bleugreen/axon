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

@Test func textLocationResolverReturnsCenterPointForScreenshotText() {
    let snapshot = textLocationFixtureSnapshot(
        [],
        screenshot: EncodedScreenshot(mediaType: "image/png", base64Data: "fake", width: 800, height: 600)
    )
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
    #expect(resolution.point == ActionPoint(x: 225, y: 200))
    #expect(resolution.best?.source == .screenshot)
    #expect(resolution.best?.matchedText == "Backlog")
    #expect(resolution.best?.frame == AXFrame(x: 175, y: 180, width: 100, height: 40))
}

@Test func textLocationResolverAutoFallsBackToScreenshotTextWhenAXTextIsMissing() {
    let snapshot = textLocationFixtureSnapshot(
        [AXNode(role: "AXStaticText", title: "Inbox", frame: AXFrame(x: 20, y: 20, width: 60, height: 20))],
        screenshot: EncodedScreenshot(mediaType: "image/png", base64Data: "fake", width: 800, height: 600)
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

private func textLocationFixtureSnapshot(
    _ children: [AXNode],
    screenshot: EncodedScreenshot? = nil
) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("text-location-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(
                role: "AXWindow",
                title: "Main",
                frame: AXFrame(x: 50, y: 60, width: 500, height: 400),
                children: children
            )
        ],
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
