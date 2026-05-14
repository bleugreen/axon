import AppKit
import AxonCore
import SwiftUI

struct PreferencesView: View {
    @State private var accessibilityTrusted = AccessibilityPermission.isTrusted()
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
                        _ = AccessibilityPermission.requestTrustPrompt()
                        refresh()
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
        accessibilityTrusted = AccessibilityPermission.isTrusted()
        socketPath = AxonEnvironment.socketPath()
        daemonStatus = "Checking..."
        Task.detached(priority: .utility) {
            let status: String
            do {
                let response = try SocketClient(path: AxonEnvironment.socketPath(), responseTimeoutSeconds: 2)
                    .send(JSONRPCRequest(id: .string("preferences.health"), method: "health"))
                if let error = response.error {
                    status = "Error: \(error.message)"
                } else if case let .string(accessibility)? = response.result?["accessibility"] {
                    status = "Running (\(accessibility))"
                } else {
                    status = "Running"
                }
            } catch {
                status = "Unavailable"
            }
            await MainActor.run {
                daemonStatus = status
            }
        }
    }

    private func restartDaemon() {
        guard let cliURL = Bundle.main.url(forResource: "axon", withExtension: nil, subdirectory: "bin") else {
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
}
