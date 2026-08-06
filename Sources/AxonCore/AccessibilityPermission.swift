import ApplicationServices
import CoreGraphics

public enum AccessibilityPermission {
    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public static func requestTrustPrompt() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

/// macOS Screen Recording approval, which gates window capture independently of Accessibility.
///
/// A daemon can hold Accessibility trust and still be unable to take a screenshot, so health
/// documents report the two grants separately rather than collapsing them into one "permitted".
public enum ScreenRecordingPermission {
    /// Reports the current grant without prompting. Preflight never shows UI, so it is safe to call
    /// from a status path that must not steal focus from the user.
    public static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}
