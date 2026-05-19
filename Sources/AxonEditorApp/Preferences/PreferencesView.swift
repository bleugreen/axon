import AppKit
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
                let response = try SocketClient(path: AxonEnvironment.socketPath(), responseTimeoutSeconds: 2)
                    .send(JSONRPCRequest(id: .string("preferences.health"), method: "health"))
                if let error = response.error {
                    status = "Error: \(error.message)"
                    trusted = false
                } else if case let .string(accessibility)? = response.result?["accessibility"] {
                    status = "Running (\(accessibility))"
                    trusted = accessibility == PermissionStatus.trusted.rawValue
                } else {
                    status = "Running"
                    trusted = false
                }
            } catch {
                status = "Unavailable"
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
                let response = try SocketClient(path: AxonEnvironment.socketPath(), responseTimeoutSeconds: 5)
                    .send(JSONRPCRequest(id: .string("preferences.permit"), method: "permit"))
                if let error = response.error {
                    status = "Error: \(error.message)"
                    trusted = false
                } else if case let .string(accessibility)? = response.result?["accessibility"] {
                    status = "Running (\(accessibility))"
                    trusted = accessibility == PermissionStatus.trusted.rawValue
                } else {
                    status = "Running"
                    trusted = false
                }
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
            process.arguments = ["restart"]
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

    nonisolated private static func bundledCLIURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        let siblingDaemonCLI = bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Axon.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/bin/axon")
        if FileManager.default.isExecutableFile(atPath: siblingDaemonCLI.path) {
            return siblingDaemonCLI
        }
        return Bundle.main.url(forResource: "axon", withExtension: nil, subdirectory: "bin")
    }
}
