public struct Doctor {
    public static func run(permissionProvider: () -> Bool = AccessibilityPermission.isTrusted) -> DoctorReport {
        let accessibility = PermissionReport(
            name: "Accessibility",
            status: permissionProvider() ? .trusted : .denied
        )

        return DoctorReport(accessibility: accessibility)
    }
}

public struct DoctorReport: Equatable {
    public let accessibility: PermissionReport

    public var isReady: Bool {
        accessibility.status == .trusted
    }
}

public struct PermissionReport: Equatable {
    public let name: String
    public let status: PermissionStatus
}

public enum PermissionStatus: String, Equatable {
    case trusted
    case denied
}

