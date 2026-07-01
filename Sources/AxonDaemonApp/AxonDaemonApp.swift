import AppKit
import AxonCore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AxonDaemonAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private enum UpdateMenuState {
        case idle
        case checking
        case upToDate(version: String)
        case available(ReleaseUpdate)
        case installing(version: String)
        case failed(String)
    }

    private enum RecordingDestination {
        case review(scope: UserRecordingScope?)
        case editor(documentID: String, beforeBlockID: String?, scope: UserRecordingScope?)
    }

    nonisolated private static let appBundleIdentifier = "com.bleugreen.axon"
    nonisolated private static let editorBundleIdentifier = "com.bleugreen.axon.editor"
    nonisolated private static let homebrewCaskName = "axon"

    private let socketPath = AxonEnvironment.socketPath()
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let serverQueue = DispatchQueue(label: "com.bleugreen.axon.socket-server", qos: .userInitiated)
    private let updateChecker = ReleaseUpdateChecker()
    private let homebrewInstaller: HomebrewInstaller? = HomebrewInstaller.locate().map { HomebrewInstaller(brewURL: $0) }
    private var serverState = "starting"
    private var serverError: String?
    private var refreshTimer: Timer?
    private var updateMenuState: UpdateMenuState = .idle
    private var recorder: UserActionRecorder?
    private var recordingScope: UserRecordingScope?
    private var recordingDestination: RecordingDestination?
    private let appRecency = RecordingAppRecencyStore()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
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

    func application(_ application: NSApplication, open urls: [URL]) {
        forwardToEditor(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        forwardToEditor([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        forwardToEditor(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
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
        let router = AxonDaemonCommandRouter(delegate: self)
        serverQueue.async { [socketPath] in
            do {
                try SocketServer(path: socketPath, router: router).run()
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
            menu.addItem(menuItem(title: "Request Accessibility", action: #selector(requestAccessibility)))
        }
        menu.addItem(menuItem(title: "Open .axn File...", action: #selector(openAxnFromMenu)))
        if let recordingScope {
            menu.addItem(disabledItem("Recording \(recordingScope.displayName)"))
            menu.addItem(menuItem(title: "Stop Recording...", action: #selector(stopRecording)))
        } else {
            menu.addItem(menuItem(title: "Record...", action: #selector(startRecording)))
        }
        addUpdateItem(to: menu)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        updateStatusItemAppearance()
    }

    private func addUpdateItem(to menu: NSMenu) {
        switch updateMenuState {
        case .idle:
            menu.addItem(menuItem(title: "Check for Updates...", action: #selector(checkForUpdates)))
        case .checking:
            menu.addItem(disabledItem("Checking for Updates..."))
        case let .upToDate(version):
            menu.addItem(disabledItem("Up to Date (\(version))"))
        case let .available(update):
            menu.addItem(menuItem(title: "Update to \(update.latestVersion)...", action: #selector(performAvailableUpdate)))
        case let .installing(version):
            menu.addItem(disabledItem("Installing \(version)..."))
        case .failed:
            menu.addItem(disabledItem("Update Check Failed"))
            menu.addItem(menuItem(title: "Check Again", action: #selector(checkForUpdates)))
        }
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
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
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await self?.finishUpgrade(outcome: outcome, update: update)
        }
    }

    private func finishUpgrade(outcome: Result<Void, Error>, update: ReleaseUpdate) {
        switch outcome {
        case .success:
            spawnRelaunchHelper()
            NSApp.terminate(nil)
        case let .failure(error):
            updateMenuState = .available(update)
            installMenu()
            showAlert(title: "Update Failed", message: String(describing: error))
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

    private func spawnRelaunchHelper() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && /usr/bin/open -b \(Self.appBundleIdentifier)"]
        try? task.run()
    }

    @objc private func startRecording() {
        _ = beginRecording(destination: .review(scope: nil))
    }

    func startRecordingFromEditor(documentID: String, beforeBlockID: String?) -> Bool {
        beginRecording(destination: .editor(documentID: documentID, beforeBlockID: beforeBlockID, scope: nil))
    }

    private func beginRecording(destination requestedDestination: RecordingDestination) -> Bool {
        guard recorder == nil else {
            showAlert(title: "Recording Already Active", message: "Stop the current recording before starting another.")
            return false
        }
        guard AccessibilityPermission.isTrusted() else {
            showAlert(title: "Accessibility Required", message: "Axon needs Accessibility permission before it can record user actions.")
            _ = AccessibilityPermission.requestTrustPrompt()
            installMenu()
            return false
        }
        guard let scope = chooseRecordingTarget() else {
            return false
        }
        do {
            let recorder = UserActionRecorder(scope: scope)
            try recorder.start()
            self.recorder = recorder
            recordingScope = scope
            switch requestedDestination {
            case .review:
                recordingDestination = .review(scope: scope)
            case let .editor(documentID, beforeBlockID, _):
                recordingDestination = .editor(documentID: documentID, beforeBlockID: beforeBlockID, scope: scope)
            }
            installMenu()
            return true
        } catch {
            showAlert(title: "Unable to Start Recording", message: String(describing: error))
            return false
        }
    }

    @objc private func stopRecording() {
        guard let recorder else {
            return
        }
        do {
            let source = try recorder.stop()
            let scope = recordingScope
            let destination = recordingDestination ?? .review(scope: scope)
            self.recorder = nil
            recordingScope = nil
            recordingDestination = nil
            installMenu()
            switch destination {
            case let .review(scope):
                try openRecordingReview(source, scope: scope)
            case let .editor(documentID, beforeBlockID, scope):
                try openRecordingInsert(source, documentID: documentID, beforeBlockID: beforeBlockID, scope: scope)
            }
        } catch {
            self.recorder = nil
            recordingScope = nil
            recordingDestination = nil
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

    @objc func openAxnFromMenu() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Open .axn File"
        openPanel.allowedContentTypes = [UTType(filenameExtension: "axn") ?? .yaml, .yaml]
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return
        }
        forwardToEditor([url])
    }

    private func forwardToEditor(_ urls: [URL]) {
        for url in urls {
            let editorURL = url.scheme == AxonEditorURL.scheme ? url : AxonEditorURL.url(forEditing: url)
            do {
                try openEditor(url: editorURL)
            } catch {
                showAlert(title: "Unable to Open Editor", message: String(describing: error))
            }
        }
    }

    private func openRecordingReview(_ source: String, scope: UserRecordingScope?) throws {
        let name = defaultRecordingName(scope: scope)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Axon Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(name)
        try source.write(to: fileURL, atomically: true, encoding: .utf8)
        try openEditor(url: AxonEditorURL.url(forReviewing: fileURL, suggestedName: name))
    }

    private func openRecordingInsert(
        _ source: String,
        documentID: String,
        beforeBlockID: String?,
        scope: UserRecordingScope?
    ) throws {
        let name = defaultRecordingName(scope: scope)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Axon Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(name)
        try source.write(to: fileURL, atomically: true, encoding: .utf8)
        try openEditor(url: AxonEditorURL.url(
            forInserting: fileURL,
            documentID: documentID,
            beforeBlockID: beforeBlockID,
            suggestedName: name
        ))
    }

    private func openEditor(url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let editorAppURL = siblingEditorAppURL() {
            process.arguments = ["-a", editorAppURL.path, url.absoluteString]
        } else {
            process.arguments = ["-b", Self.editorBundleIdentifier, url.absoluteString]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableNotLoadable)
        }
    }

    private func siblingEditorAppURL() -> URL? {
        let candidate = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Axon Editor.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
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

private final class AxonDaemonCommandRouter: JSONRPCCommandHandling, @unchecked Sendable {
    private let fallback = CommandRouter(
        activeCredentialFilterProvider: { ActiveCredentialFilterLoader().loadOrEmpty() }
    )
    private weak var delegate: AxonDaemonAppDelegate?

    init(delegate: AxonDaemonAppDelegate) {
        self.delegate = delegate
    }

    func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        guard request.method == "editor.recordFromHere" else {
            return fallback.handle(request)
        }

        guard case let .object(params)? = request.params,
              let documentID = params["documentId"]?.stringValue,
              !documentID.isEmpty
        else {
            return JSONRPCResponse(id: request.id, error: .invalidParams("editor.recordFromHere requires documentId"))
        }
        let beforeBlockID = params["beforeBlockId"]?.stringValue
        let semaphore = DispatchSemaphore(value: 0)
        let result = RecordingStartResult()
        Task { @MainActor in
            result.set(delegate?.startRecordingFromEditor(documentID: documentID, beforeBlockID: beforeBlockID) ?? false)
            semaphore.signal()
        }
        semaphore.wait()
        guard result.value else {
            return JSONRPCResponse(id: request.id, error: .internalError("Recording was not started"))
        }
        return JSONRPCResponse(id: request.id, result: ["recording": .bool(true)])
    }
}

private final class RecordingStartResult: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        started = value
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

private extension JSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }
}

@main
final class AxonDaemonAppMain: NSObject {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AxonDaemonAppDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate
    }
}
