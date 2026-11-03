import Foundation

public enum AxonEnvironment {
    public static let defaultSocketPath = "/tmp/axon.sock"

    /// Set in the registered daemon's environment to tell it that launchd will restart it.
    ///
    /// The daemon behaves differently depending on whether anything is supervising it, and it
    /// cannot infer that from the process alone.
    public static let launchdManagedKey = "AXON_DAEMON_MANAGED_BY_LAUNCHD"

    public static func socketPath(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["AXON_SOCKET_PATH"] ?? defaultSocketPath
    }

    public static func isLaunchdManaged(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[launchdManagedKey] == "1"
    }

    public static func applicationSupportDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Axon", isDirectory: true)
    }

    /// The 1Password active-credential index that releases before 0.4.0 wrote.
    ///
    /// It holds HMAC digests of secret values, keyed by a Keychain item, and nothing reads it any
    /// more; `daemon install` deletes it. Kept as a location only so that deletion has one answer.
    public static func retiredActiveCredentialIndexURL() -> URL {
        applicationSupportDirectory()
            .appendingPathComponent("active-credential-index.json", isDirectory: false)
    }

    /// Whether this process must arrange its own replacement after an in-app update.
    ///
    /// A launchd-managed daemon already has `KeepAlive`; launching the app independently as well
    /// races that supervisor and can leave a second menu-bar process contending for the socket.
    public static func requiresIndependentRelaunch(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !isLaunchdManaged(environment)
    }
}
