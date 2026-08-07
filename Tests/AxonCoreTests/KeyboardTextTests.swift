import AppKit
import CoreGraphics
import Foundation
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
        makeKeyboardLayout: { layout },
        frontmostApp: { ForegroundApp(processIdentifier: 7, name: "Prior", bundleIdentifier: "com.example.prior") },
        pointerLocation: { .zero }
    )

    // Keystroke synthesis is what these cases measure, and without a named app the only rung that
    // can carry keystrokes at all is the foreground one.
    _ = try executor.keyboard(app: nil, intent: .text(text), policy: .foregroundPermitted)
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
        policy: .foregroundPermitted,
        delivery: .foreground,
        dispatched: true,
        message: "unverified"
    )
    #expect(fallback.success == false)
    #expect(fallback.dispatchSuccess)
    #expect(fallback.delivery == .foreground)
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
        },
        frontmostApp: { ForegroundApp(processIdentifier: 7, name: "Prior", bundleIdentifier: "com.example.prior") },
        pointerLocation: { .zero }
    )

    let result = try executor.keyboard(app: nil, intent: .key("End"), policy: .foregroundPermitted)

    #expect(posted.map(\.keyCode) == [119, 119])
    #expect(posted.allSatisfy { $0.text.isEmpty })
    #expect(result.success == false)
    #expect(result.dispatchSuccess)
    #expect(result.delivery == .foreground)
    #expect(result.details["semanticSuccess"] == .null)
    #expect(result.details["semanticStatus"] == .string("unverified"))
}

@Test func keyboardWithoutAppRefusesUnderBackgroundOnlyWithoutPostingEvents() throws {
    var posted = 0
    let executor = AXPrimitiveActionExecutor(
        elementStore: AXElementStore(),
        overlay: nil,
        postEvent: { _ in posted += 1 },
        postEventToProcess: { _, _ in posted += 1 },
        frontmostApp: { ForegroundApp(processIdentifier: 7, name: "Prior", bundleIdentifier: "com.example.prior") },
        pointerLocation: { .zero }
    )

    let result = try executor.keyboard(app: nil, intent: .key("End"), policy: .backgroundOnly)

    #expect(posted == 0)
    #expect(result.success == false)
    #expect(result.dispatchSuccess == false)
    #expect(result.delivery == nil)
    #expect(result.strategy == "refused")
    #expect(result.refusal?.reason == .foregroundNotPermitted)
    #expect(result.refusal?.capability == .globalInput)
}

@Test func keyboardWithNamedAppDeliversToThatProcessWithoutGlobalEvents() throws {
    var global = 0
    var targeted: [pid_t] = []
    let executor = AXPrimitiveActionExecutor(
        elementStore: AXElementStore(),
        overlay: nil,
        postEvent: { _ in global += 1 },
        postEventToProcess: { _, pid in targeted.append(pid) },
        frontmostApp: { ForegroundApp(processIdentifier: 7, name: "Prior", bundleIdentifier: "com.example.prior") },
        activateProcess: { _ in Issue.record("background keyboard delivery must not activate"); return false },
        pointerLocation: { .zero }
    )

    // The frontmost application is always resolvable by pid, which gives the pixel rung a real
    // identity to bind to without depending on any particular app being installed.
    let target = try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier)
    let result = try executor.keyboard(
        app: String(target),
        intent: .key("End"),
        policy: .backgroundOnly
    )

    #expect(global == 0)
    #expect(targeted == [target, target])
    #expect(result.delivery == .pixel)
    #expect(result.dispatchSuccess)
    #expect(result.success == false)
    #expect(result.details["backgroundDelivery"]?["frontmostAppUnchanged"] == .bool(true))
    #expect(result.details["backgroundDelivery"]?["pointerUnchanged"] == .bool(true))
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
