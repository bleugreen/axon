import AppKit
import AxonCore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AxonAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private enum UpdateMenuState {
        case idle
        case checking
        case upToDate(version: String)
        case available(ReleaseUpdate)
        case installing(version: String)
        case failed(String)
    }

    nonisolated private static let appBundleIdentifier = "com.bleugreen.axon"
    nonisolated private static let homebrewCaskName = "axon"

    private let socketPath = AxonEnvironment.socketPath()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let serverQueue = DispatchQueue(label: "com.bleugreen.axon.socket-server", qos: .userInitiated)
    private let updateChecker = ReleaseUpdateChecker()
    private let homebrewInstaller: HomebrewInstaller? = HomebrewInstaller.locate().map { HomebrewInstaller(brewURL: $0) }
    private var serverState = "starting"
    private var serverError: String?
    private var refreshTimer: Timer?
    private var updateMenuState: UpdateMenuState = .idle
    private var recorder: UserActionRecorder?
    private var recordingScope: UserRecordingScope?
    private var openFileRuns: [Process] = []
    private let appRecency = RecordingAppRecencyStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appRecency.start()
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
        appRecency.stop()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        runAxnFile(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.localizedCaseInsensitiveCompare("axn") == .orderedSame {
            runAxnFile(url)
        }
    }

    private func configureStatusItem() {
        statusItem.length = NSStatusItem.squareLength
        guard let button = statusItem.button else {
            return
        }
        button.imagePosition = .imageOnly
        updateStatusItemAppearance()
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
        if let recordingScope {
            menu.addItem(disabledItem("Recording \(recordingScope.displayName)"))
            menu.addItem(NSMenuItem(title: "Stop Recording...", action: #selector(stopRecording), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Record...", action: #selector(startRecording), keyEquivalent: ""))
        }
        addUpdateItem(to: menu)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        updateStatusItemAppearance()
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
            menu.addItem(NSMenuItem(title: "Update to \(update.latestVersion)...", action: #selector(performAvailableUpdate), keyEquivalent: ""))
        case let .installing(version):
            menu.addItem(disabledItem("Installing \(version)..."))
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

    @objc private func performAvailableUpdate() {
        guard case let .available(update) = updateMenuState else {
            return
        }

        let installer = homebrewInstaller
        let brewManaged = (try? installer?.isCaskInstalled(name: Self.homebrewCaskName)) ?? false
        guard let installer, brewManaged else {
            NSWorkspace.shared.open(update.releaseURL)
            return
        }

        guard confirmInstall(update: update) else {
            return
        }

        updateMenuState = .installing(version: update.latestVersion)
        installMenu()

        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<Void, Error>
            do {
                _ = try installer.upgradeCask(name: Self.homebrewCaskName)
                try Self.reinstallDaemonFromCurrentBundle()
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }

            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .success:
                    self.spawnRelaunchHelper()
                    NSApp.terminate(nil)
                case let .failure(error):
                    self.updateMenuState = .available(update)
                    self.installMenu()
                    self.showAlert(
                        title: "Update Failed",
                        message: String(describing: error)
                    )
                }
            }
        }
    }

    private func confirmInstall(update: ReleaseUpdate) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Update Axon to \(update.latestVersion)?"
        alert.informativeText = "Axon will quit, install the update via Homebrew, and relaunch."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private nonisolated static func reinstallDaemonFromCurrentBundle() throws {
        let workspace = NSWorkspace.shared
        guard let bundleURL = workspace.urlForApplication(withBundleIdentifier: appBundleIdentifier) else {
            throw HomebrewInstallerError.caskNotInstalled(name: homebrewCaskName)
        }
        let cliURL = bundleURL
            .appendingPathComponent("Contents/Resources/bin/axon")

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["install"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderr = String(decoding: data, as: UTF8.self)
            throw HomebrewInstallerError.commandFailed(
                arguments: ["install"],
                status: process.terminationStatus,
                stderr: stderr
            )
        }
    }

    private func spawnRelaunchHelper() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && /usr/bin/open -b \(Self.appBundleIdentifier)"]
        try? task.run()
    }

    @objc private func startRecording() {
        guard AccessibilityPermission.isTrusted() else {
            showAlert(title: "Accessibility Required", message: "Axon needs Accessibility permission before it can record user actions.")
            _ = AccessibilityPermission.requestTrustPrompt()
            installMenu()
            return
        }
        guard let scope = chooseRecordingTarget() else {
            return
        }
        do {
            let recorder = UserActionRecorder(scope: scope)
            try recorder.start()
            self.recorder = recorder
            self.recordingScope = scope
            installMenu()
        } catch {
            showAlert(title: "Unable to Start Recording", message: String(describing: error))
        }
    }

    @objc private func stopRecording() {
        guard let recorder else {
            return
        }
        do {
            let source = try recorder.stop()
            self.recorder = nil
            let scope = recordingScope
            self.recordingScope = nil
            installMenu()
            try saveRecording(source, scope: scope)
        } catch {
            self.recorder = nil
            self.recordingScope = nil
            installMenu()
            showAlert(title: "Unable to Stop Recording", message: String(describing: error))
        }
    }

    private func chooseRecordingTarget() -> UserRecordingScope? {
        let apps = AppResolver().recordableApps(recency: appRecency.snapshot())
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !apps.isEmpty else {
            showAlert(title: "No Apps Available", message: "There are no running apps with a regular UI available to record.")
            return nil
        }

        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        let scopes = UserRecordingScope.pickerOptions(for: apps)
        for scope in scopes {
            picker.addItem(withTitle: recordingPickerTitle(for: scope))
        }

        let alert = NSAlert()
        alert.messageText = "Running Apps (with UI)"
        alert.informativeText = "Choose the app whose actions Axon should record."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return scopes[picker.indexOfSelectedItem]
    }

    private func recordingPickerTitle(for scope: UserRecordingScope) -> String {
        switch scope {
        case let .app(app):
            return "\(app.name) (pid \(app.processIdentifier))"
        case .all:
            return "All Running Apps"
        }
    }

    private func saveRecording(_ source: String, scope: UserRecordingScope?) throws {
        let directory = defaultRecordingsDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let savePanel = NSSavePanel()
        savePanel.title = "Save Axon Recording"
        savePanel.directoryURL = directory
        savePanel.nameFieldStringValue = defaultRecordingName(scope: scope)
        savePanel.allowedContentTypes = [UTType(filenameExtension: "axn") ?? .yaml]
        savePanel.canCreateDirectories = true
        guard savePanel.runModal() == .OK, let url = savePanel.url else {
            return
        }
        try source.write(to: url, atomically: true, encoding: .utf8)
    }

    private func runAxnFile(_ url: URL) {
        guard let cliURL = bundledCLIURL() else {
            showAlert(title: "Unable to Run Recording", message: "The bundled axon CLI could not be found.")
            return
        }
        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["run", url.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] process in
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let message = AxnRunSummary.failureMessage(
                fileName: url.lastPathComponent,
                terminationStatus: process.terminationStatus,
                stdout: output,
                stderr: errorOutput
            )
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.openFileRuns.removeAll { $0 === process }
                guard let message else {
                    return
                }
                self.showAlert(title: "Recording Failed", message: message)
            }
        }
        do {
            try process.run()
            openFileRuns.append(process)
        } catch {
            showAlert(title: "Unable to Run Recording", message: String(describing: error))
        }
    }

    private func bundledCLIURL() -> URL? {
        Bundle.main.url(forResource: "axon", withExtension: nil, subdirectory: "bin")
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else {
            return
        }
        let isRecording = recorder != nil
        button.title = ""
        button.image = statusImage(recording: isRecording)
        button.toolTip = isRecording ? "Axon Recording" : "Axon"
    }

    private func statusImage(recording: Bool) -> NSImage? {
        guard let base = NSImage(named: "AxonMenuBarTemplate") else {
            statusItem.button?.title = recording ? "REC" : "Axon"
            return nil
        }
        base.size = NSSize(width: 22, height: 22)
        if !recording {
            base.isTemplate = true
            return base
        }

        let image = NSImage(size: NSSize(width: 22, height: 22))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 20, height: 20)).fill()
        base.isTemplate = true
        base.draw(
            in: NSRect(x: 3, y: 3, width: 16, height: 16),
            from: .zero,
            operation: .destinationOut,
            fraction: 1
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func defaultRecordingsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Axon Recordings", isDirectory: true)
    }

    private func defaultRecordingName(scope: UserRecordingScope?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let app = scope?.displayName.replacingOccurrences(of: "/", with: "-") ?? "recording"
        return "\(formatter.string(from: Date()))-\(app).axn"
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AxonVersion.current
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
private final class RecordingAppRecencyStore {
    private let defaultsKey = "recordingAppRecency"
    private let maxEntries = 24
    private var entries: [AppRecencyEntry] = []
    private var activationObserver: NSObjectProtocol?

    func start() {
        load()
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            record(frontmost)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.record(app)
            }
        }
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    func snapshot() -> AppRecencySnapshot {
        AppRecencySnapshot(entries: entries)
    }

    private func record(_ app: NSRunningApplication) {
        guard !app.isTerminated, app.activationPolicy == .regular else {
            return
        }
        let bundleIdentifier = app.bundleIdentifier
        let processIdentifier = app.processIdentifier
        entries.removeAll { entry in
            if entry.processIdentifier == processIdentifier {
                return true
            }
            if let bundleIdentifier, entry.bundleIdentifier == bundleIdentifier {
                return true
            }
            return false
        }
        entries.insert(
            AppRecencyEntry(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier,
                lastActivatedAt: Date().timeIntervalSince1970
            ),
            at: 0
        )
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(AppRecencySnapshot.self, from: data)
        else {
            entries = []
            return
        }
        entries = snapshot.entries
    }

    private func save() {
        let snapshot = AppRecencySnapshot(entries: entries)
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

let app = NSApplication.shared
let delegate = AxonAppDelegate()
app.delegate = delegate
app.run()
