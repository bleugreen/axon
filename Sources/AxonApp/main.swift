import AppKit
import AxonCore
import Foundation

@MainActor
final class AxonAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let socketPath = AxonEnvironment.socketPath()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let serverQueue = DispatchQueue(label: "com.bleugreen.axon.socket-server", qos: .userInitiated)
    private var serverState = "starting"
    private var serverError: String?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "Axon"
        ScreenCaptureRuntime.bootstrapSynchronously()
        startServer()
        installMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.installMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    private func startServer() {
        serverQueue.async { [socketPath] in
            do {
                try SocketServer(path: socketPath).run()
            } catch {
                let message = String(describing: error)
                Task { @MainActor in
                    self.serverState = "failed"
                    self.serverError = message
                    self.installMenu()
                }
            }
        }
        serverState = "running"
    }

    private func installMenu() {
        let menu = NSMenu()
        menu.addItem(disabledItem("Axon"))
        menu.addItem(disabledItem("Service: \(serviceStatus())"))
        menu.addItem(disabledItem("Accessibility: \(accessibilityStatus())"))
        menu.addItem(disabledItem("Socket: \(socketPath)"))
        if let serverError {
            menu.addItem(disabledItem("Error: \(serverError)"))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Request Accessibility", action: #selector(requestAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Codex MCP Config", action: #selector(copyMCPConfig), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Axon", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func serviceStatus() -> String {
        guard serverState == "running" else {
            return serverState
        }
        do {
            let response = try SocketClient(path: socketPath, responseTimeoutSeconds: 1)
                .send(JSONRPCRequest(id: .string("menu-health"), method: "health"))
            if response.error == nil {
                return "running"
            }
            return "error"
        } catch {
            return "starting"
        }
    }

    private func accessibilityStatus() -> String {
        AccessibilityPermission.isTrusted() ? "trusted" : "denied"
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func requestAccessibility() {
        _ = AccessibilityPermission.requestTrustPrompt()
        installMenu()
    }

    @objc private func copyMCPConfig() {
        let config = """
        [mcp_servers.axon]
        command = "axon"
        args = ["mcp"]
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AxonAppDelegate()
app.delegate = delegate
app.run()
