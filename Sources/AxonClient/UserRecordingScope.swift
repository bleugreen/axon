import Foundation

public enum UserRecordingScope: Equatable, Sendable {
    case app(AppIdentity)
    case all

    public static func pickerOptions(for apps: [AppIdentity]) -> [UserRecordingScope] {
        apps.map(UserRecordingScope.app) + [.all]
    }

    public var displayName: String {
        switch self {
        case let .app(app):
            return app.name
        case .all:
            return "All Running Apps"
        }
    }
}
