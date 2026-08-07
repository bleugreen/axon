import ApplicationServices

extension AXError {
    /// Names the error and keeps its code, so one message serves a reader and a matcher alike:
    /// `actionUnsupported (-25206)`.
    ///
    /// Accessibility errors otherwise reach callers as bare integers that have to be decoded by
    /// hand against the framework headers, which is how `-25205` came to be reported as an action
    /// error when it names an unsupported attribute.
    var axonDescription: String {
        "\(axonName) (\(rawValue))"
    }

    private var axonName: String {
        switch self {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown"
        }
    }
}
