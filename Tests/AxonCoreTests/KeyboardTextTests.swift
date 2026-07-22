import CoreGraphics
import Testing
@testable import AxonCore

private let asciiLayout = KeyboardLayoutMap(strokes: [
    "h": KeyboardLayoutMap.Stroke(keyCode: 4, flags: []),
    "i": KeyboardLayoutMap.Stroke(keyCode: 34, flags: []),
    "H": KeyboardLayoutMap.Stroke(keyCode: 4, flags: .maskShift)
])

private func postedKeyboardEvents(
    keys: String,
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

    _ = try executor.keyboard(app: nil, keys: keys)
    // Every character posts a key-down and a key-up carrying the same payload.
    return stride(from: 0, to: posted.count, by: 2).map { posted[$0] }
}

@Test func keyboardTextPostsPerCharacterKeycodesNotAConstant() throws {
    let events = try postedKeyboardEvents(keys: "hi", layout: asciiLayout)

    #expect(events.map(\.keyCode) == [4, 34])
    #expect(events.map(\.text) == ["h", "i"])
}

@Test func keyboardTextCarriesLayoutModifiersForShiftedCharacters() throws {
    let events = try postedKeyboardEvents(keys: "Hi", layout: asciiLayout)

    #expect(events.map(\.keyCode) == [4, 34])
    #expect(events[0].flags.contains(.maskShift))
    #expect(events[1].flags.contains(.maskShift) == false)
    #expect(events.map(\.text) == ["H", "i"])
}

@Test func keyboardTextFallsBackToPayloadForCharactersTheLayoutCannotProduce() throws {
    // Emoji are outside every layout, and their scalars exceed a single UTF-16 unit — the case
    // that previously trapped on conversion.
    let events = try postedKeyboardEvents(keys: "a😀", layout: asciiLayout)

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
