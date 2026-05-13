import AppKit
import AxonCore
import Foundation

@MainActor
final class AxonAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private enum UpdateMenuState {
        case idle
        case checking
        case upToDate(version: String)
        case available(ReleaseUpdate)
        case failed(String)
    }

    private let socketPath = AxonEnvironment.socketPath()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let serverQueue = DispatchQueue(label: "com.bleugreen.axon.socket-server", qos: .userInitiated)
    private let updateChecker = ReleaseUpdateChecker()
    private var serverState = "starting"
    private var serverError: String?
    private var refreshTimer: Timer?
    private var updateMenuState: UpdateMenuState = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
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

    private func configureStatusItem() {
        statusItem.length = NSStatusItem.squareLength
        guard let button = statusItem.button else {
            return
        }
        guard let image = NSImage(named: "AxonMenuBarTemplate") else {
            button.title = "Axon"
            return
        }
        image.isTemplate = true
        image.size = NSSize(width: 22, height: 22)
        button.title = ""
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "Axon"
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
        if let serverError {
            menu.addItem(disabledItem("Error: \(serverError)"))
        }
        menu.addItem(.separator())
        if !AccessibilityPermission.isTrusted() {
            menu.addItem(NSMenuItem(title: "Request Accessibility", action: #selector(requestAccessibility), keyEquivalent: ""))
        }
        addUpdateItem(to: menu)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func addUpdateItem(to menu: NSMenu) {
        switch updateMenuState {
        case .idle:
            menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""))
        case .checking:
            menu.addItem(disabledItem("Checking for Updates..."))
        case let .upToDate(version):
            menu.addItem(disabledItem("Up to Date (\(version))"))
        case let .available(update):
            menu.addItem(NSMenuItem(title: "Update to \(update.latestVersion)...", action: #selector(openAvailableUpdate), keyEquivalent: ""))
        case .failed:
            menu.addItem(disabledItem("Update Check Failed"))
            menu.addItem(NSMenuItem(title: "Check Again", action: #selector(checkForUpdates), keyEquivalent: ""))
        }
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

    @objc private func checkForUpdates() {
        updateMenuState = .checking
        installMenu()
        Task { @MainActor in
            do {
                let update = try await updateChecker.check(currentVersion: currentVersion())
                updateMenuState = update.isUpdateAvailable ? .available(update) : .upToDate(version: update.currentVersion)
            } catch {
                updateMenuState = .failed(String(describing: error))
            }
            installMenu()
        }
    }

    @objc private func openAvailableUpdate() {
        guard case let .available(update) = updateMenuState else {
            return
        }
        NSWorkspace.shared.open(update.releaseURL)
    }

    private func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AxonVersion.current
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AxonAppDelegate()
app.delegate = delegate
app.run()
