import ApplicationServices

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
