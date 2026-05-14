import Carbon
import Foundation

public enum RecordedKeyClassifier {
    public static func specialKeyName(keyCode: Int, text: String?) -> String? {
        if text == "\r" || text == "\n" {
            return "Return"
        }

        switch keyCode {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return "Return"
        case kVK_Tab:
            return "Tab"
        case kVK_Escape:
            return "Escape"
        case kVK_Delete:
            return "Delete"
        default:
            return nil
        }
    }
}
