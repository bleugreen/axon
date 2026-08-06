import Darwin
import Foundation
import Security

/// Local macOS state: which permissions are granted, what session this process occupies, and what
/// the daemon can therefore actually do.
///
/// Everything here is a pure function of injected observations, so the derivations that matter —
/// which capabilities a denied grant takes away, which session counts as usable — are testable
/// without a logged-in Mac.
public struct Doctor {
    public static func run(
        permissionProvider: () -> Bool = AccessibilityPermission.isTrusted,
        screenRecordingProvider: () -> Bool = ScreenRecordingPermission.isGranted
    ) -> DoctorReport {
        DoctorReport(
            accessibility: PermissionReport(
                name: "Accessibility",
                status: permissionProvider() ? .trusted : .denied
            ),
            screenRecording: PermissionReport(
                name: "Screen Recording",
                status: screenRecordingProvider() ? .trusted : .denied
            )
        )
    }

    /// Resolves the permission lookups once, before the daemon starts serving.
    ///
    /// The first permission query against a newly installed executable makes macOS resolve it
    /// against TCC, which has been measured at several seconds; once resolved every later query is
    /// instant. That cost lands precisely when `daemon install` is waiting for readiness, so
    /// startup pays it before serving instead of inside the first health request. Grants can change
    /// while the daemon runs, so this warms the lookup rather than caching an answer.
    public static func warmUp() {
        _ = run()
    }

    /// The daemon's answer to a `health` request: what this process, in this session, with these
    /// grants, can serve right now.
    public static func daemonReport(
        endpoint: String,
        ready: Bool,
        processId: Int = Int(ProcessInfo.processInfo.processIdentifier),
        report: DoctorReport = Doctor.run(),
        session: SessionHealth = Doctor.currentSession()
    ) -> DaemonReport {
        DaemonReport(
            ready: ready,
            processId: processId,
            endpoint: endpoint,
            session: session,
            permissions: permissions(report),
            capabilities: capabilities(report)
        )
    }

    public static func permissions(_ report: DoctorReport) -> [PermissionState] {
        [
            PermissionState(
                name: HealthPermission.accessibility,
                granted: report.accessibility.status == .trusted,
                reason: report.accessibility.status == .trusted ? nil : HealthReason.accessibilityNotGranted,
                detail: report.accessibility.status == .trusted
                    ? nil
                    : "Approve Axon in System Settings > Privacy & Security > Accessibility"
            ),
            PermissionState(
                name: HealthPermission.screenRecording,
                granted: report.screenRecording.status == .trusted,
                reason: report.screenRecording.status == .trusted ? nil : HealthReason.screenRecordingNotGranted,
                detail: report.screenRecording.status == .trusted
                    ? nil
                    : "Approve Axon in System Settings > Privacy & Security > Screen Recording"
            )
        ]
    }

    /// The complete capability map for macOS, derived from the two grants that gate it.
    ///
    /// Listing running applications goes through `NSWorkspace` and needs no grant, and history
    /// serialization is pure computation. Everything else either drives the Accessibility APIs or
    /// posts synthetic events, both of which macOS refuses to an untrusted process. Screenshots go
    /// through ScreenCaptureKit and answer to Screen Recording alone, which is why a daemon can be
    /// fully trusted for Accessibility and still unable to capture a window.
    public static func capabilities(_ report: DoctorReport) -> [CapabilityState] {
        let accessibility = report.accessibility.status == .trusted
        let screenRecording = report.screenRecording.status == .trusted

        return AxonCapability.allCases.map { capability in
            switch capability {
            case .enumerate, .serializeHistory:
                return CapabilityState(capability, usable: true)
            case .screenshot:
                return CapabilityState(
                    capability,
                    usable: screenRecording,
                    reason: screenRecording ? nil : HealthReason.screenRecordingNotGranted,
                    restriction: screenRecording ? nil : "macOS has not granted Screen Recording to the daemon identity"
                )
            default:
                return CapabilityState(
                    capability,
                    usable: accessibility,
                    reason: accessibility ? nil : HealthReason.accessibilityNotGranted,
                    restriction: accessibility ? nil : "macOS has not granted Accessibility trust to the daemon identity"
                )
            }
        }
    }

    /// The session this process occupies, as macOS Security Services reports it.
    public static func currentSession() -> SessionHealth {
        var attributes = SessionAttributeBits(rawValue: 0)
        let status = SessionGetInfo(callerSecuritySession, nil, &attributes)
        guard status == errSecSuccess else {
            return SessionHealth(
                interactive: false,
                graphical: false,
                reason: HealthReason.unknown,
                detail: "SessionGetInfo failed with OSStatus \(status)"
            )
        }
        return session(attributes: attributes)
    }

    /// Classifies a macOS security session.
    ///
    /// Graphic access is what actually decides whether the Accessibility and window-server APIs can
    /// work, so it is the graphical signal. A session with a terminal but no graphic access — an
    /// SSH login to a Mac — is a real user session that cannot drive the desktop, and the document
    /// says exactly that rather than claiming the machine is unusable.
    public static func session(attributes: SessionAttributeBits) -> SessionHealth {
        let graphical = attributes.contains(.sessionHasGraphicAccess)
        let interactive = graphical || attributes.contains(.sessionHasTTY)

        if graphical {
            return SessionHealth(interactive: true, graphical: true)
        }
        if interactive {
            return SessionHealth(
                interactive: true,
                graphical: false,
                reason: HealthReason.noGraphicalSession,
                detail: "This session has a terminal but no window server; no user is logged in at the console"
            )
        }
        return SessionHealth(
            interactive: false,
            graphical: false,
            reason: HealthReason.notInteractiveSession,
            detail: "This process is not running in a logged-in user session"
        )
    }
}

public struct DoctorReport: Equatable {
    public let accessibility: PermissionReport
    public let screenRecording: PermissionReport

    public init(accessibility: PermissionReport, screenRecording: PermissionReport) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    /// Accessibility alone decides readiness. Screen Recording gates screenshots and nothing else,
    /// so a Mac without it is degraded rather than unusable.
    public var isReady: Bool {
        accessibility.status == .trusted
    }
}

public struct PermissionReport: Equatable {
    public let name: String
    public let status: PermissionStatus

    public init(name: String, status: PermissionStatus) {
        self.name = name
        self.status = status
    }
}

public enum PermissionStatus: String, Equatable {
    case trusted
    case denied
}
