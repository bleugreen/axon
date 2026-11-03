import AxonClient
import Darwin
import Foundation
import Security

/// The session this process occupies, which the CLI reports when no daemon answers.
///
/// Permissions are not here: the daemon is the TCC subject and reports its own grants in `health`,
/// and this process's trust says nothing about the daemon's.
public enum SessionDetection {
    /// The session this process occupies, as macOS Security Services reports it.
    public static func current() -> SessionHealth {
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
