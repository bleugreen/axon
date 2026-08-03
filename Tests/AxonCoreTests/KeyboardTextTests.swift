import CoreGraphics
import Testing
@testable import AxonCore

private let asciiLayout = KeyboardLayoutMap(strokes: [
    "h": KeyboardLayoutMap.Stroke(keyCode: 4, flags: []),
    "i": KeyboardLayoutMap.Stroke(keyCode: 34, flags: []),
    "H": KeyboardLayoutMap.Stroke(keyCode: 4, flags: .maskShift)
])

private func postedKeyboardEvents(
    text: String,
    layout: KeyboardLayoutMap
) throws -> [(keyCode: Int64, flags: CGEventFlags, text: String)] {
    var posted: [(keyCode: Int64, flags: CGEventFlags, text: String)] = []
    let executor = AXPrimitiveActionExecutor(
        elementStore: AXElementStore(),
        overlay: nil,
        postEvent: { event in
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
            posted.append((
                event.getIntegerValueField(.keyboardEventKeycode),
                event.flags,
                String(utf16CodeUnits: buffer, count: length)
            ))
        },
        makeKeyboardLayout: { layout }
    )

    _ = try executor.keyboard(app: nil, intent: .text(text))
    // Every character posts a key-down and a key-up carrying the same payload.
    return stride(from: 0, to: posted.count, by: 2).map { posted[$0] }
}

@Test func typeSuccessRequiresExactAXValueReadbackAndFallbackStaysUnverified() {
    #expect(AXPrimitiveActionExecutor.axValueWasVerified(setResult: .success, readValue: "hello", expected: "hello"))
    #expect(!AXPrimitiveActionExecutor.axValueWasVerified(setResult: .success, readValue: "old", expected: "hello"))
    #expect(!AXPrimitiveActionExecutor.axValueWasVerified(setResult: .cannotComplete, readValue: "hello", expected: "hello"))

    let fallback = PrimitiveActionResult.unverifiedDispatch(
        action: "type",
        target: "s1:2",
        strategy: "CGEventKeyboard",
        dispatched: true,
        message: "unverified"
    )
    #expect(fallback.success == false)
    #expect(fallback.details["dispatchSuccess"] == .bool(true))
    #expect(fallback.details["semanticSuccess"] == .null)
}

@Test func keyboardEndDispatchesNavigationKeyAndReportsUnverifiedOutcome() throws {
    var posted: [(keyCode: Int64, text: String)] = []
    let executor = AXPrimitiveActionExecutor(
        elementStore: AXElementStore(),
        overlay: nil,
        postEvent: { event in
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
            posted.append((event.getIntegerValueField(.keyboardEventKeycode), String(utf16CodeUnits: buffer, count: length)))
        }
    )

    let result = try executor.keyboard(app: nil, intent: .key("End"))

    #expect(posted.map(\.keyCode) == [119, 119])
    #expect(posted.allSatisfy { $0.text.isEmpty })
    #expect(result.success == false)
    #expect(result.details["dispatchSuccess"] == .bool(true))
    #expect(result.details["semanticSuccess"] == .null)
    #expect(result.details["semanticStatus"] == .string("unverified"))
}

@Test func keyboardIntentValidationKeepsTextArbitraryAndRejectsUnknownKeys() throws {
    #expect(try KeyboardIntent.validated(text: "End and anything 😀", key: nil) == .text("End and anything 😀"))
    #expect(throws: JSONRPCError.self) {
        try KeyboardIntent.validated(text: nil, key: "DefinitelyNotAKey")
    }
}

@Test func keyboardTextPostsPerCharacterKeycodesNotAConstant() throws {
    let events = try postedKeyboardEvents(text: "hi", layout: asciiLayout)

    #expect(events.map(\.keyCode) == [4, 34])
    #expect(events.map(\.text) == ["h", "i"])
}

@Test func keyboardTextCarriesLayoutModifiersForShiftedCharacters() throws {
    let events = try postedKeyboardEvents(text: "Hi", layout: asciiLayout)

    #expect(events.map(\.keyCode) == [4, 34])
    #expect(events[0].flags.contains(.maskShift))
    #expect(events[1].flags.contains(.maskShift) == false)
    #expect(events.map(\.text) == ["H", "i"])
}

@Test func keyboardTextFallsBackToPayloadForCharactersTheLayoutCannotProduce() throws {
    // Emoji are outside every layout, and their scalars exceed a single UTF-16 unit — the case
    // that previously trapped on conversion.
    let events = try postedKeyboardEvents(text: "a😀", layout: asciiLayout)

    #expect(events.count == 2)
    #expect(events[0].keyCode == 0)
    #expect(events[0].text == "a")
    #expect(events[1].keyCode == 0)
    #expect(events[1].text == "😀")
}

@Test func currentKeyboardLayoutResolvesCommonCharactersToDistinctKeycodes() throws {
    let layout = KeyboardLayoutMap.current()

    // Guards the real Carbon lookup: an empty or constant map is the bug this fixes.
    try #require(layout.isEmpty == false)
    let lowercase = "abcdefghijklmnopqrstuvwxyz".unicodeScalars.compactMap { layout.stroke(for: $0)?.keyCode }
    #expect(lowercase.count == 26)
    #expect(Set(lowercase).count == 26)
    #expect(layout.stroke(for: " ")?.keyCode == 49)
}
