import Testing
@testable import AxonCore

@Test func recordedKeyClassifierTreatsReturnKeyCodesAsPressKey() {
    #expect(RecordedKeyClassifier.specialKeyName(keyCode: 36, text: nil) == "Return")
    #expect(RecordedKeyClassifier.specialKeyName(keyCode: 76, text: nil) == "Return")
}

@Test func recordedKeyClassifierTreatsNewlineTextAsReturn() {
    #expect(RecordedKeyClassifier.specialKeyName(keyCode: 0, text: "\r") == "Return")
    #expect(RecordedKeyClassifier.specialKeyName(keyCode: 0, text: "\n") == "Return")
}
