import AppKit
import AxonClient
import AxonCore
import SwiftUI

struct PreferencesView: View {
    @State private var accessibilityTrusted = false
    @State private var daemonStatus = "Checking..."
    @State private var socketPath = AxonEnvironment.socketPath()

    var body: some View {
        Form {
            Section("Accessibility") {
                HStack {
                    Label(
                        accessibilityTrusted ? "Permission granted" : "Permission required",
                        systemImage: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(accessibilityTrusted ? .green : .orange)
                    Spacer()
                    Button("Open System Settings") {
                        requestDaemonAccessibility()
                    }
                }
            }

            Section("Daemon") {
                LabeledContent("Socket", value: socketPath)
                LabeledContent("Status", value: daemonStatus)
                HStack {
                    Button("Refresh") {
                        refresh()
                    }
                    Button("Restart") {
                        restartDaemon()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        socketPath = AxonEnvironment.socketPath()
        daemonStatus = "Checking..."
        Task.detached(priority: .utility) {
            let status: String
            let trusted: Bool
            do {
                let report = try DaemonClient(socketPath: AxonEnvironment.socketPath()).health()
                trusted = report.permissions.first { $0.name == HealthPermission.accessibility }?.granted == true
                status = "Running (pid \(report.processId), version \(report.version))"
            } catch {
                status = "Unavailable: \(error)"
                trusted = false
            }
            await MainActor.run {
                accessibilityTrusted = trusted
                daemonStatus = status
            }
        }
    }

    private func requestDaemonAccessibility() {
        daemonStatus = "Requesting accessibility..."
        Task.detached(priority: .userInitiated) {
            let status: String
            let trusted: Bool
            do {
                try Self.ensureDaemonAvailable()
                let result = try DaemonClient(socketPath: AxonEnvironment.socketPath()).permit()
                trusted = result.accessibility == .trusted
                status = "Running (Accessibility \(result.accessibility.rawValue))"
            } catch {
                status = "Unavailable: \(error)"
                trusted = false
            }
            await MainActor.run {
                accessibilityTrusted = trusted
                daemonStatus = status
            }
        }
    }

    private func restartDaemon() {
        guard let cliURL = Self.bundledCLIURL() else {
            daemonStatus = "Bundled CLI unavailable"
            return
        }
        daemonStatus = "Restarting..."
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = cliURL
            process.arguments = ["daemon", "restart"]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                await MainActor.run {
                    daemonStatus = "Restart failed: \(error)"
                }
                return
            }
            await MainActor.run {
                refresh()
            }
        }
    }

    nonisolated private static func ensureDaemonAvailable() throws {
        if canReachDaemon() {
            return
        }
        guard let cliURL = bundledCLIURL() else {
            throw CocoaError(.executableNotLoadable)
        }
        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["start"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableNotLoadable)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if canReachDaemon() {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    nonisolated private static func canReachDaemon() -> Bool {
        do {
            let response = try SocketClient(path: AxonEnvironment.socketPath(), responseTimeoutSeconds: 1)
                .send(JSONRPCRequest(id: .string("preferences.ping"), method: "health"))
            return response.error == nil
        } catch {
            return false
        }
    }

    /// The CLI this editor was shipped with.
    ///
    /// The editor ships nested inside `Axon.app`, so the enclosing bundle is the one install whose
    /// version is guaranteed to match. The `Bundle.main` fallback covers an editor built and run
    /// standalone, which is what a development build is.
    nonisolated private static func bundledCLIURL() -> URL? {
        if let nestedDaemonCLI = AppBundle.pairedDaemonCLIURL(from: Bundle.main.bundleURL) {
            return nestedDaemonCLI
        }
        return Bundle.main.url(forResource: "axon", withExtension: nil, subdirectory: "bin")
    }
}
