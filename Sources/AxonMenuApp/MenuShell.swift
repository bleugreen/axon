import AppKit
import AxonClient
import Darwin
import Foundation
import UniformTypeIdentifiers

/// The Axon menu bar item: a presentation of the daemon, holding no privacy grant of its own.
///
/// Everything it shows comes from the daemon over the socket (shell-v1, `ShellContract`), and
/// everything it does that needs a grant (recording, the Accessibility prompt, Automation consent)
/// is a request the daemon carries out under its own identity. What is left here needs none:
/// menus and alerts, reading launchd plists and bundle Info.plists, writing the user's recordings
/// under `~/Library`, handing files to the editor, and the updater.
@MainActor
final class MenuShell: NSObject, NSApplicationDelegate, NSMenuDelegate {
    nonisolated private static let homebrewCaskName = "axon"

    private let socketPath = AxonEnvironment.socketPath()
    private lazy var client = DaemonClient(socketPath: socketPath)
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let enclosingBundle = AppBundle.enclosingApp(ofNested: Bundle.main.bundleURL)
    private let updateChecker = ReleaseUpdateChecker()
    private let homebrewInstaller: HomebrewInstaller? = HomebrewInstaller.locate().map { HomebrewInstaller(brewURL: $0) }
    private let appRecency = RecordingAppRecencyStore()
    private var inputs: MenuInputs
    private var pollInFlight = false
    private var pollTimer: Timer?
    private weak var openMenu: NSMenu?

    override init() {
        let enclosing = AppBundle.enclosingApp(ofNested: Bundle.main.bundleURL)
        inputs = MenuInputs(
            enclosingBundlePath: enclosing?.path,
            shellVersion: enclosing.flatMap(AppBundle.shortVersion(of:))
                ?? AppBundle.shortVersion(of: Bundle.main.bundleURL)
                ?? AxonVersion.current,
            socketPath: AxonEnvironment.socketPath()
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        appRecency.start()
        statusItem.button?.imagePosition = .imageOnly
        // Whatever started this copy, an update's scaffolding is the successor's to clear.
        LaunchAgentManager.reapUpdateFinisher()
        inputs.registrationWarning = registrationWarning()
        inputs.strayEditorNotice = strayEditorNotice()
        render()
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: ShellContract.Timeout.poll, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        appRecency.stop()
    }

    // MARK: - Polling

    /// `health` and `recording.status`, off the main thread, one round at a time. A round that
    /// times out keeps what the shell last knew rather than replacing it with a guess.
    private func poll() {
        guard !pollInFlight else { return }
        pollInFlight = true
        let client = client
        Task.detached(priority: .utility) {
            let health = Result { try client.health() }
            let recording = Result { try client.recordingStatus() }
            await MainActor.run { [weak self] in
                self?.apply(health: health, recording: recording)
            }
        }
    }

    private func apply(health: Result<DaemonReport, Error>, recording: Result<RecordingStatus, Error>) {
        pollInFlight = false
        switch health {
        case let .success(report):
            inputs.daemon = .answered(report, stale: false)
            inputs.daemonExecutablePath = report.provenance?.executablePath ?? Self.executablePath(ofProcess: report.processId)
        case let .failure(error):
            switch (error as? DaemonCallError, inputs.daemon) {
            case (.notRunning?, _):
                inputs.daemon = .notRunning(socketPath: socketPath)
                inputs.daemonExecutablePath = nil
            case let (.unreadable(_, reason)?, _):
                inputs.daemon = .unreadable(reason)
            case let (_, .answered(report, _)):
                inputs.daemon = .answered(report, stale: true)
            default:
                inputs.daemon = .unreachable(String(describing: error))
            }
        }
        switch recording {
        case let .success(status):
            inputs.recording = status
        case let .failure(error):
            if case .notRunning? = error as? DaemonCallError {
                inputs.recording = .idle
            }
        }
        inputs.registrationWarning = registrationWarning()
        render()
    }

    /// The executable behind a pid, for a daemon whose health does not say where it lives.
    private static func executablePath(ofProcess processId: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(Int32(processId), &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Rendering

    private func render() {
        let menu = NSMenu()
        menu.delegate = self
        populate(menu)
        statusItem.menu = menu
        updateStatusImage()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    /// Whether Browser Automation is offered is asked of the daemon only when a person opens the
    /// menu, so no Automation determination happens earlier than their own use of Axon. The menu
    /// opens with the last answer and is rebuilt in place when the new one arrives.
    func menuWillOpen(_ menu: NSMenu) {
        openMenu = menu
        guard case .compatible = MenuModel.standing(inputs) else { return }
        let client = client
        Task.detached(priority: .userInitiated) {
            let status = try? client.automationStatus()
            await MainActor.run { [weak self] in
                guard let self, let status, status.need != self.inputs.consentNeed else { return }
                self.inputs.consentNeed = status.need
                if let open = self.openMenu {
                    self.menuNeedsUpdate(open)
                }
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenu = nil
    }

    private func populate(_ menu: NSMenu) {
        for entry in MenuModel.entries(inputs) {
            switch entry {
            case let .label(title):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case let .action(title, action, enabled, key):
                let item = ActionItem(title: title, action: #selector(chooseMenuAction(_:)), keyEquivalent: key)
                item.menuAction = action
                item.target = self
                item.isEnabled = enabled
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
        menu.autoenablesItems = false
    }

    @objc private func chooseMenuAction(_ sender: ActionItem) {
        guard let action = sender.menuAction else { return }
        switch action {
        case .useThisCopy: useThisCopy()
        case .requestAccessibility: requestAccessibility()
        case .browserAutomation: requestBrowserAutomation()
        case .openAxnFile: openAxnFile()
        case .record: startRecording()
        case .stopRecording: stopRecording()
        case .checkForUpdates: checkForUpdates()
        case .performUpdate: performAvailableUpdate()
        case .openReleasePage: openReleasePage()
        case .quit: NSApp.terminate(nil)
        }
    }

    private func updateStatusImage() {
        guard let button = statusItem.button else { return }
        let recording = MenuModel.isRecording(inputs)
        button.title = ""
        button.image = statusImage(recording: recording)
        button.toolTip = recording ? "Axon Recording" : "Axon"
    }

    private func statusImage(recording: Bool) -> NSImage? {
        guard let base = NSImage(named: "AxonMenuBarTemplate") else {
            statusItem.button?.title = recording ? "REC" : "Axon"
            return nil
        }
        base.size = NSSize(width: 22, height: 22)
        guard recording else {
            base.isTemplate = true
            return base
        }
        let image = NSImage(size: NSSize(width: 22, height: 22))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 20, height: 20)).fill()
        base.isTemplate = true
        base.draw(in: NSRect(x: 3, y: 3, width: 16, height: 16), from: .zero, operation: .destinationOut, fraction: 1)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: - Permissions

    private func requestAccessibility() {
        let client = client
        Task.detached(priority: .userInitiated) {
            let result = Result { try client.permit() }
            await MainActor.run { [weak self] in
                if case let .failure(error) = result {
                    self?.showAlert(title: "Could Not Request Accessibility", message: String(describing: error))
                }
                self?.poll()
            }
        }
    }

    /// Asks the daemon to request Automation consent for the running browsers. The daemon presents
    /// the dialog, so the grant is minted for the daemon's identity; this process only waits.
    private func requestBrowserAutomation() {
        let client = client
        Task.detached(priority: .userInitiated) {
            let result = Result { try client.requestAutomation() }
            await MainActor.run { [weak self] in self?.presentConsent(result) }
        }
    }

    private func presentConsent(_ result: Result<AutomationRequestReport, Error>) {
        switch result {
        case let .success(report):
            inputs.consentNeed = report.need
            render()
            guard !report.outcomes.isEmpty else {
                showAlert(
                    title: "No Supported Browser Running",
                    message: "macOS can only grant control of a browser that is running. Open Safari or Google Chrome, then choose Browser Automation... again."
                )
                return
            }
            let lines = report.outcomes.map { outcome in
                outcome.granted ? "\(outcome.app): allowed" : "\(outcome.app): \(outcome.detail ?? "not granted")"
            }
            showAlert(title: "Browser Automation", message: lines.joined(separator: "\n\n"))
        case let .failure(error):
            if (error as? DaemonCallError)?.refusal == .consentInProgress {
                showAlert(title: "Browser Automation", message: "A consent dialog is already open. Answer it, then choose Browser Automation... again if anything is left.")
            } else {
                showAlert(title: "Browser Automation", message: String(describing: error))
            }
        }
    }

    // MARK: - Recording

    private func startRecording() {
        let apps = AppResolver().recordableApps(recency: appRecency.snapshot())
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let scopes = MenuModel.pickerScopes(for: apps)
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        scopes.forEach { picker.addItem(withTitle: $0.displayName) }
        let alert = NSAlert()
        alert.messageText = "Running Apps (with UI)"
        alert.informativeText = "Choose the app whose actions Axon should record."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let scope = scopes[picker.indexOfSelectedItem]
        let client = client
        Task.detached(priority: .userInitiated) {
            let result = Result { try client.startRecording(scope: scope) }
            await MainActor.run { [weak self] in self?.recordingStarted(result) }
        }
    }

    private func recordingStarted(_ result: Result<RecordingStatus, Error>) {
        switch result {
        case let .success(status):
            inputs.recording = status
            render()
        case let .failure(error):
            switch (error as? DaemonCallError)?.refusal {
            case .accessibilityDenied?:
                let alert = NSAlert()
                alert.messageText = "Accessibility Required"
                alert.informativeText = "The Axon daemon needs Accessibility permission before it can record user actions."
                alert.addButton(withTitle: "Request Accessibility")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate()
                if alert.runModal() == .alertFirstButtonReturn {
                    requestAccessibility()
                }
            case .recordingActive?:
                showAlert(title: "Recording Already Active", message: "Stop the current recording before starting another.")
                poll()
            default:
                showAlert(title: "Unable to Start Recording", message: String(describing: error))
            }
        }
    }

    private func stopRecording() {
        let scope = inputs.recording.scope
        let client = client
        Task.detached(priority: .userInitiated) {
            let result = Result { try client.stopRecording() }
            await MainActor.run { [weak self] in self?.recordingStopped(result, scope: scope) }
        }
    }

    private func recordingStopped(_ result: Result<RecordingResult, Error>, scope: RecordingScope?) {
        inputs.recording = .idle
        render()
        do {
            let recording = try result.get()
            try RecordingHandoff(openEditor: { [weak self] url in try self?.openEditor(url: url) })
                .deliver(recording, scope: scope)
        } catch {
            showAlert(title: "Unable to Stop Recording", message: String(describing: error))
        }
        poll()
    }

    // MARK: - Editor

    private func openAxnFile() {
        let panel = NSOpenPanel()
        panel.title = "Open .axn File"
        panel.allowedContentTypes = [UTType(filenameExtension: "axn") ?? .yaml, .yaml]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try openEditor(url: AxonEditorURL.url(forEditing: url))
        } catch {
            showAlert(title: "Unable to Open Editor", message: String(describing: error))
        }
    }

    /// Hands a URL to the editor nested in the same `Axon.app`, through Launch Services.
    private func openEditor(url: URL) throws {
        guard let enclosingBundle, let editor = AppBundle.pairedEditorURL(beside: enclosingBundle) else {
            let expected = enclosingBundle?.appendingPathComponent(AppBundle.nestedEditorRelativePath).path
                ?? AppBundle.nestedEditorRelativePath
            throw CocoaError(.executableNotLoadable, userInfo: [
                NSLocalizedDescriptionKey: "The matching Axon Editor.app was not found at \(expected). Reinstall Axon to restore the paired applications."
            ])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", editor.path, url.absoluteString]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableNotLoadable)
        }
    }

    // MARK: - Registration

    /// Says so when launchd's daemon registration points outside the bundle this menu is in.
    private func registrationWarning() -> String? {
        guard let registered = LaunchAgentManager.daemonRegistration().path, let enclosingBundle else {
            return nil
        }
        guard !registered.hasPrefix(enclosingBundle.standardizedFileURL.path + "/") else {
            return nil
        }
        return "Login item points at \(registered)"
    }

    /// Names an `Axon Editor.app` standing on its own outside the bundle: residue from releases
    /// that shipped two apps, and another Launch Services claimant on `.axn`.
    private func strayEditorNotice() -> String? {
        var candidates = [URL(fileURLWithPath: "/Applications/Axon Editor.app")]
        if let enclosingBundle {
            candidates.append(enclosingBundle.deletingLastPathComponent().appendingPathComponent("Axon Editor.app"))
        }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            let version = AppBundle.shortVersion(of: candidate).map { " \($0)" } ?? ""
            return "Leftover Axon Editor\(version) at \(candidate.path)"
        }
        return nil
    }

    /// Makes the enclosing bundle the registered one, through the same finisher an update uses,
    /// then quits: launchd owns the registration now, and it points here.
    private func useThisCopy() {
        guard let enclosingBundle else {
            showAlert(title: "Cannot Use This Copy", message: "This menu is not inside an Axon.app, so there is no bundle to register.")
            return
        }
        let cli = enclosingBundle.appendingPathComponent(AppBundle.bundledCLIRelativePath)
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            showAlert(title: "Cannot Use This Copy", message: "This bundle has no CLI at \(cli.path), so it cannot register itself.")
            return
        }
        do {
            try UpdateFinisher.arm(enclosingBundle: enclosingBundle, socketPath: socketPath)
        } catch {
            showAlert(title: "Cannot Use This Copy", message: String(describing: error))
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Updates

    private func setUpdate(_ state: UpdateState) {
        inputs.update = state
        render()
    }

    private func checkForUpdates() {
        setUpdate(.checking)
        let current = inputs.shellVersion
        Task { @MainActor in
            do {
                let update = try await updateChecker.check(currentVersion: current)
                if update.isUpdateAvailable {
                    let installer = homebrewInstaller
                    let brewManaged = await Task.detached(priority: .utility) {
                        (try? installer?.isCaskInstalled(name: Self.homebrewCaskName)) ?? false
                    }.value
                    setUpdate(.available(update, brewManaged: brewManaged))
                } else {
                    setUpdate(.upToDate(version: update.currentVersion))
                }
            } catch {
                setUpdate(.failed(reason: String(describing: error), update: nil))
            }
        }
    }

    private func openReleasePage() {
        guard case let .failed(_, update) = inputs.update, let update else { return }
        NSWorkspace.shared.open(update.releaseURL)
    }

    /// Installs the available update over the enclosing `Axon.app` (never this nested bundle), by
    /// whichever mechanism owns the install, then hands re-registration to launchd. Nothing here
    /// terminates this process: the finisher's `daemon install` re-registers the jobs, and that is
    /// what retires this copy.
    private func performAvailableUpdate() {
        guard case let .available(update, brewManaged) = inputs.update else { return }
        guard let enclosingBundle else {
            showAlert(title: "Update Unavailable", message: "This menu is not inside an Axon.app, so there is nothing for it to update.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Update Axon to \(update.latestVersion)?"
        alert.informativeText = brewManaged
            ? "Axon will install the update via Homebrew and restart."
            : "Axon will download \(update.latestVersion), verify its checksum and signature, replace \(enclosingBundle.path), and restart. Your permissions are kept."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let socketPath = socketPath
        if let installer = homebrewInstaller, brewManaged {
            setUpdate(.installing(version: update.latestVersion))
            Task.detached(priority: .userInitiated) {
                let outcome = Result {
                    _ = try installer.upgradeCask(name: Self.homebrewCaskName)
                    // The cask re-registers nothing on upgrade, so the finisher does it, from the
                    // bundle Homebrew just put in the same place.
                    try UpdateFinisher.arm(enclosingBundle: enclosingBundle, socketPath: socketPath)
                }
                await MainActor.run { [weak self] in
                    switch outcome {
                    case .success:
                        self?.setUpdate(.restarting(version: update.latestVersion))
                    case let .failure(error):
                        self?.setUpdate(.available(update, brewManaged: true))
                        self?.showAlert(title: "Update Failed", message: String(describing: error))
                    }
                }
            }
            return
        }

        setUpdate(.downloading(version: update.latestVersion, progress: 0))
        let version = update.latestVersion
        Task { @MainActor in
            do {
                let installed = try await ReleaseInstaller().install(update: update, replacing: enclosingBundle) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.inputs.update else { return }
                        self.setUpdate(.downloading(version: version, progress: min(max(fraction, 0), 1)))
                    }
                }
                setUpdate(.installing(version: installed.version))
                try UpdateFinisher.arm(enclosingBundle: installed.bundleURL, socketPath: socketPath)
                setUpdate(.restarting(version: installed.version))
            } catch {
                let reason = String(describing: error)
                setUpdate(.failed(reason: reason, update: update))
                showAlert(title: "Update Failed", message: reason)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}

/// A menu item that carries the model's action, so one selector serves every entry.
private final class ActionItem: NSMenuItem {
    var menuAction: MenuAction?
}

/// Which applications were used most recently, so the recording picker lists them first.
///
/// NSWorkspace activation notifications only; reading them needs no grant.
@MainActor
private final class RecordingAppRecencyStore {
    private let defaultsKey = "recordingAppRecency"
    private let maxEntries = 24
    private var entries: [AppRecencyEntry] = []
    private var activationObserver: NSObjectProtocol?

    func start() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let snapshot = try? JSONDecoder().decode(AppRecencySnapshot.self, from: data) {
            entries = snapshot.entries
        }
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
            MainActor.assumeIsolated { self?.record(app) }
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
        guard !app.isTerminated, app.activationPolicy == .regular else { return }
        let bundleIdentifier = app.bundleIdentifier
        let processIdentifier = app.processIdentifier
        entries.removeAll { entry in
            entry.processIdentifier == processIdentifier
                || (bundleIdentifier != nil && entry.bundleIdentifier == bundleIdentifier)
        }
        entries.insert(
            AppRecencyEntry(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier,
                lastActivatedAt: Date().timeIntervalSince1970
            ),
            at: 0
        )
        entries = Array(entries.prefix(maxEntries))
        if let data = try? JSONEncoder().encode(AppRecencySnapshot(entries: entries)) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

@main
enum AxonMenuMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let shell = MenuShell()
            app.delegate = shell
            withExtendedLifetime(shell) { app.run() }
        }
    }
}
