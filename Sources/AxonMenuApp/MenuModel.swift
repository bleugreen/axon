import AxonClient
import Foundation

/// What the shell last learned from polling the daemon's `health`.
enum DaemonState: Equatable {
    /// No poll has finished yet.
    case unknown
    /// Nothing is listening on the socket.
    case notRunning(socketPath: String)
    /// The daemon never answered within the poll bound, and the shell holds no earlier answer.
    case unreachable(String)
    /// Something answered with a `health` this shell cannot read.
    case unreadable(String)
    /// The daemon answered. `stale` when the latest poll timed out and this is the answer before it.
    case answered(DaemonReport, stale: Bool)
}

/// Where the in-app update stands.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(version: String)
    case available(ReleaseUpdate, brewManaged: Bool)
    case downloading(version: String, progress: Double)
    case installing(version: String)
    /// The new bundle is in place and launchd has been handed the re-registration.
    case restarting(version: String)
    case failed(reason: String, update: ReleaseUpdate?)
}

/// Everything the menu is built from. The shell gathers it; nothing here performs I/O.
struct MenuInputs: Equatable {
    var daemon: DaemonState = .unknown
    /// The daemon's executable: health provenance when it reports one, otherwise the kernel's
    /// answer for its pid.
    var daemonExecutablePath: String?
    var recording: RecordingStatus = .idle
    /// Resolved when the menu opens. Unknown counts as something to offer: an item with nothing
    /// left to do is a smaller failure than a grant with no way to mint it.
    var consentNeed: ConsentNeed?
    var update: UpdateState = .idle
    var registrationWarning: String?
    var strayEditorNotice: String?
    /// The `Axon.app` this shell is nested in, when it is nested in one.
    var enclosingBundlePath: String?
    var shellVersion: String
    var socketPath: String
}

enum MenuAction: Equatable {
    case useThisCopy
    case requestAccessibility
    case browserAutomation
    case openAxnFile
    case record
    case stopRecording
    case checkForUpdates
    case performUpdate
    case openReleasePage
    case quit
}

enum MenuEntry: Equatable {
    case label(String)
    case action(String, MenuAction, enabled: Bool = true, keyEquivalent: String = "")
    case separator
}

/// How the shell stands toward whatever is serving the socket.
enum DaemonStanding: Equatable {
    case unknown
    case notRunning(socketPath: String)
    case unreachable(String)
    /// A daemon from outside this shell's bundle owns the socket.
    case incumbent(summary: String)
    /// A daemon from this bundle, or of unknown origin, that does not speak this shell's contract.
    case incompatible(path: String, reason: String)
    /// A daemon this shell can drive.
    case compatible(DaemonReport, stale: Bool)
}

enum MenuModel {
    static let quitTitle = "Quit Axon Menu"

    static func standing(_ inputs: MenuInputs) -> DaemonStanding {
        switch inputs.daemon {
        case .unknown:
            return .unknown
        case let .notRunning(path):
            return .notRunning(socketPath: path)
        case let .unreachable(reason):
            return .unreachable(reason)
        case let .unreadable(reason):
            return .incompatible(path: inputs.socketPath, reason: reason)
        case let .answered(report, stale):
            let path = inputs.daemonExecutablePath
            if let path, let bundle = inputs.enclosingBundlePath, !isInside(path, bundle: bundle) {
                return .incumbent(summary: incumbentSummary(report: report, path: path))
            }
            guard report.shellContract == ShellContract.version else {
                let reason = report.shellContract.map {
                    "it speaks menu contract \($0) and this menu speaks \(ShellContract.version)"
                } ?? "it speaks no menu contract"
                return .incompatible(path: path ?? report.endpoint, reason: reason)
            }
            return .compatible(report, stale: stale)
        }
    }

    /// Whether the status icon shows the recording variant.
    static func isRecording(_ inputs: MenuInputs) -> Bool {
        guard case .compatible = standing(inputs) else { return false }
        return inputs.recording.recording
    }

    static func entries(_ inputs: MenuInputs) -> [MenuEntry] {
        var entries: [MenuEntry] = [.label("Axon")]
        let standing = standing(inputs)

        // A copy whose daemon lost to another one has nothing true to offer but who is in the way
        // and the two ways out.
        if case let .incumbent(summary) = standing {
            entries += [
                .label(summary),
                .separator,
                .action("Use This Copy", .useThisCopy),
                .action(quitTitle, .quit, keyEquivalent: "q")
            ]
            return entries
        }

        var report: DaemonReport?
        switch standing {
        case .unknown:
            entries.append(.label("Connecting to the Axon daemon..."))
        case let .notRunning(path):
            entries.append(.label("Axon daemon not running (\(path))"))
        case let .unreachable(reason):
            entries.append(.label("Axon daemon not answering: \(reason)"))
        case let .incompatible(path, reason):
            entries.append(.label("Incompatible daemon at \(path): \(reason)"))
        case let .compatible(answered, stale):
            report = answered
            let readiness = answered.ready ? "ready" : "not ready"
            let freshness = stale ? " (not answering; last known state)" : ""
            entries.append(.label("Daemon \(answered.version): \(readiness)\(freshness)"))
            if answered.version != inputs.shellVersion {
                entries.append(.label("Daemon \(answered.version) differs from this menu (\(inputs.shellVersion))"))
            }
            for permission in answered.permissions where !permission.granted {
                entries.append(.label("\(permissionName(permission.name)) not granted"))
            }
        case .incumbent:
            break
        }
        if let warning = inputs.registrationWarning {
            entries.append(.label(warning))
        }
        if let notice = inputs.strayEditorNotice {
            entries.append(.label(notice))
        }
        entries.append(.separator)

        let live = report != nil
        if let report, report.permissions.contains(where: { $0.name == HealthPermission.accessibility && !$0.granted }) {
            entries.append(.action("Request Accessibility", .requestAccessibility))
        }
        if live, inputs.consentNeed != ConsentNeed.none {
            entries.append(.action("Browser Automation...", .browserAutomation))
        }
        entries.append(.action("Open .axn File...", .openAxnFile))
        if live, inputs.recording.recording {
            let scope = inputs.recording.scope?.displayName ?? ""
            let target = inputs.recording.destination == nil ? "" : " for the editor"
            entries.append(.label("Recording \(scope)\(target)"))
            entries.append(.action("Stop Recording...", .stopRecording))
        } else {
            entries.append(.action("Record...", .record, enabled: live))
        }
        entries += updateEntries(inputs.update)
        entries += [.separator, .action(quitTitle, .quit, keyEquivalent: "q")]
        return entries
    }

    static func updateEntries(_ state: UpdateState) -> [MenuEntry] {
        switch state {
        case .idle:
            return [.action("Check for Updates...", .checkForUpdates)]
        case .checking:
            return [.label("Checking for Updates...")]
        case let .upToDate(version):
            // Never a dead end: a check that raced a release must be repeatable without relaunching.
            return [.label("Up to Date (\(version))"), .action("Check Again", .checkForUpdates)]
        case let .available(update, _):
            return [.action("Update to \(update.latestVersion)...", .performUpdate)]
        case let .downloading(version, progress):
            return [.label("Downloading \(version)... \(Int((progress * 100).rounded()))%")]
        case let .installing(version):
            return [.label("Installing \(version)...")]
        case let .restarting(version):
            return [.label("Restarting into \(version)...")]
        case let .failed(reason, update):
            var entries: [MenuEntry] = [
                .label("Update Failed"),
                .label(reason),
                .action("Check Again", .checkForUpdates)
            ]
            if update != nil {
                entries.append(.action("Open Release Page", .openReleasePage))
            }
            return entries
        }
    }

    /// The recording picker: each running application once, then every application.
    ///
    /// The daemon scopes a recording by name and bundle identifier and takes no pid, so two
    /// instances of one application are one choice.
    static func pickerScopes(for apps: [AppIdentity]) -> [RecordingScope] {
        var seen = Set<String>()
        var scopes: [RecordingScope] = []
        for app in apps {
            let key = app.bundleIdentifier ?? "name:\(app.name)"
            guard seen.insert(key).inserted else { continue }
            scopes.append(.application(RecordingApp(name: app.name, bundleIdentifier: app.bundleIdentifier)))
        }
        return scopes + [.allApplications]
    }

    private static func isInside(_ path: String, bundle: String) -> Bool {
        let bundle = URL(fileURLWithPath: bundle).standardizedFileURL.path
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(bundle + "/")
    }

    private static func incumbentSummary(report: DaemonReport, path: String) -> String {
        "Axon \(report.version) at \(path) (pid \(report.processId)) is already serving"
    }

    private static func permissionName(_ name: String) -> String {
        switch name {
        case HealthPermission.accessibility: return "Accessibility"
        case HealthPermission.screenRecording: return "Screen Recording"
        default: return name
        }
    }
}
