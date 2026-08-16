import Testing
@testable import AxonCore

private let photographedWindow = AXFrame(x: 1_400, y: 100, width: 1_200, height: 800)
private let otherWindow = AXFrame(x: 0, y: 0, width: 600, height: 400)

private func screenTextSnapshot(
    windows: [AXFrame],
    screenshot: EncodedScreenshot?
) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("screen-text"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: windows.map { AXNode(role: "AXWindow", title: "Window", frame: $0) },
        screenshot: screenshot
    )
}

private func recognizing(_ observations: [RecognizedTextObservation]) -> TextRecognitionHandler {
    { _ in observations }
}

/// Dyadic fractions, so the placement arithmetic is exact and the expectations can be too.
private let centeredBox = RecognizedTextObservation(
    text: "Backlog",
    boundingBox: NormalizedTextBoundingBox(x: 0.25, y: 0.5, width: 0.25, height: 0.25),
    confidence: 0.95
)

@Test func screenTextPlacesRecognizedBoxesAgainstThePhotographedWindow() {
    // The field defect: capture photographs one window while the accessibility tree lists another
    // first. Mapping through the wrong origin puts every point inside a window the image never
    // showed, which is how a click landed outside the window it was aimed at.
    let snapshot = screenTextSnapshot(
        windows: [otherWindow, photographedWindow],
        screenshot: EncodedScreenshot(
            mediaType: "image/png",
            base64Data: "fake",
            width: 1_200,
            height: 800,
            sourceWindowFrame: photographedWindow
        )
    )

    let items = ScreenTextExtractor(recognizeText: recognizing([centeredBox])).extract(in: snapshot)

    #expect(items.count == 1)
    #expect(items.first?.frame == AXFrame(x: 1_700, y: 300, width: 300, height: 200))
    // Specifically not the frame the first accessibility window would have produced.
    #expect(items.first?.frame != AXFrame(x: 150, y: 100, width: 150, height: 100))
}

@Test func screenTextYieldsNothingWhenTheImageCannotSayWhichWindowItShows() {
    // No safe guess exists here: every normalized box lands somewhere inside whatever frame it is
    // mapped through, so a wrong frame produces a plausible-looking point rather than an error.
    let snapshot = screenTextSnapshot(
        windows: [otherWindow],
        screenshot: EncodedScreenshot(mediaType: "image/png", base64Data: "fake", width: 1_200, height: 800)
    )

    let items = ScreenTextExtractor(recognizeText: recognizing([centeredBox])).extract(in: snapshot)

    #expect(items.isEmpty)
}

@Test func screenTextFlipsTheRecognizedOriginIntoScreenCoordinates() {
    // Vision reports a bottom-left origin; screen coordinates count down from the top.
    let snapshot = screenTextSnapshot(
        windows: [photographedWindow],
        screenshot: EncodedScreenshot(
            mediaType: "image/png",
            base64Data: "fake",
            width: 1_200,
            height: 800,
            sourceWindowFrame: photographedWindow
        )
    )
    let topOfImage = RecognizedTextObservation(
        text: "Title",
        boundingBox: NormalizedTextBoundingBox(x: 0, y: 0.75, width: 0.5, height: 0.25),
        confidence: nil
    )

    let items = ScreenTextExtractor(recognizeText: recognizing([topOfImage])).extract(in: snapshot)

    #expect(items.first?.frame == AXFrame(x: 1_400, y: 100, width: 600, height: 200))
}
