import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Maps characters to the keystroke that produces them on a keyboard layout.
///
/// Synthesized text events can carry a character two ways: as a Unicode payload attached to the
/// event, or as a virtual keycode the receiver translates itself. Native macOS controls read the
/// payload, so a payload alone looks correct in most testing. Consumers that read the raw keycode
/// — browser-hosted remote consoles forwarding scancodes, games, remote-desktop clients — see only
/// the keycode, and a constant keycode makes every character arrive as the same letter.
///
/// Posting the real keycode alongside the payload satisfies both readers.
public struct KeyboardLayoutMap: Sendable {
    public struct Stroke: Equatable, Sendable {
        public let keyCode: CGKeyCode
        public let flags: CGEventFlags

        public init(keyCode: CGKeyCode, flags: CGEventFlags) {
            self.keyCode = keyCode
            self.flags = flags
        }
    }

    private let strokes: [UnicodeScalar: Stroke]

    public init(strokes: [UnicodeScalar: Stroke]) {
        self.strokes = strokes
    }

    /// The keystroke that types `scalar`, or nil when the layout cannot produce it.
    public func stroke(for scalar: UnicodeScalar) -> Stroke? {
        strokes[scalar]
    }

    public var isEmpty: Bool {
        strokes.isEmpty
    }

    /// Derives the map from the active input source.
    ///
    /// Returns an empty map when the input source exposes no Unicode layout data, which is the
    /// case for some input methods. Callers fall back to a payload-only event.
    public static func current() -> KeyboardLayoutMap {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return KeyboardLayoutMap(strokes: [:])
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return KeyboardLayoutMap(layoutData: layoutData, keyboardType: UInt32(LMGetKbdType()))
    }

    /// Ordered by preference: a character reachable unmodified beats the same character behind a
    /// modifier, so `a` maps to a bare keypress rather than some shifted equivalent.
    private static let modifierCombinations: [(carbonModifiers: UInt32, flags: CGEventFlags)] = [
        (0, []),
        (UInt32(shiftKey) >> 8, .maskShift),
        (UInt32(optionKey) >> 8, .maskAlternate),
        ((UInt32(shiftKey) | UInt32(optionKey)) >> 8, [.maskShift, .maskAlternate])
    ]

    /// Virtual keycodes above this are function and navigation keys, which produce no text.
    private static let keyCodeCount: CGKeyCode = 128

    init(layoutData: Data, keyboardType: UInt32) {
        var strokes: [UnicodeScalar: Stroke] = [:]
        layoutData.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return
            }
            for combination in Self.modifierCombinations {
                for keyCode in 0..<Self.keyCodeCount {
                    guard let scalar = Self.character(
                        layout: layout,
                        keyCode: keyCode,
                        carbonModifiers: combination.carbonModifiers,
                        keyboardType: keyboardType
                    ) else {
                        continue
                    }
                    if strokes[scalar] == nil {
                        strokes[scalar] = Stroke(keyCode: keyCode, flags: combination.flags)
                    }
                }
            }
        }
        self.strokes = strokes
    }

    private static func character(
        layout: UnsafePointer<UCKeyboardLayout>,
        keyCode: CGKeyCode,
        carbonModifiers: UInt32,
        keyboardType: UInt32
    ) -> UnicodeScalar? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDown),
            carbonModifiers,
            keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length == 1, let scalar = UnicodeScalar(characters[0]) else {
            return nil
        }
        // Control characters (return, tab, escape) share keycodes with keys callers drive by name
        // through `keyboard`'s keystroke mode. Leaving them out keeps text mode to printable text.
        guard scalar.value >= 0x20, scalar.value != 0x7F else {
            return nil
        }
        return scalar
    }
}
