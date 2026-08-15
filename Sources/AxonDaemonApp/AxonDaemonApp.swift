import AppKit
import AxonCore
import Darwin
import Foundation
import UniformTypeIdentifiers

/// The copy of Axon that already owns the socket, named exactly.
///
/// Losing the socket race used to surface as the word `failed` in a menu, which told the person
/// looking at two menu bar icons nothing they could act on. The lock file records the incumbent's
/// pid and the incumbent answers `health`, so the copy that lost can say precisely which Axon,
/// which version, and which path is in its way.
struct IncumbentCopy: Sendable {
    let version: String?
    let executablePath: String?
    let processId: Int?

    static func resolve(from error: Error, socketPath: String) -> IncumbentCopy? {
        guard case let SocketError.socketAlreadyServed(_, pid) = error else {
            return nil
        }
        let response = try? SocketClient(path: socketPath, responseTimeoutSeconds: 2)
            .send(JSONRPCRequest(id: .string("incumbent"), method: "health"))
        let report = response.flatMap { try? DaemonReport(jsonObject: $0.result ?? [:]) }
        let processId = pid ?? report?.processId
        return IncumbentCopy(
            version: report?.version,
            executablePath: processId.flatMap(Self.executablePath(ofProcess:)),
            processId: processId
        )
    }

    /// The executable behind a pid. The health protocol does not carry the incumbent's own path,
    /// and asking the kernel is both simpler and true of a daemon too old to have been asked.
    private static func executablePath(ofProcess processId: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(Int32(processId), &buffer, UInt32(buffer.count)) > 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    var summary: String {
        let identity = version.map { "Axon \($0)" } ?? "Another Axon"
        let location = executablePath.map { " at \($0)" } ?? ""
        let owner = processId.map { " (pid \($0))" } ?? ""
        return "\(identity)\(location)\(owner) is already serving"
    }
}

@MainActor
final class AxonDaemonAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private enum UpdateMenuState {
        case idle
        case checking
        case upToDate(version: String)
        case available(ReleaseUpdate, brewManaged: Bool)
        case downloading(version: String, progress: Double)
        case installing(version: String)
        /// The new bundle is in place and launchd has been handed the re-registration.
        case restarting(version: String)
        case failed(reason: String, update: ReleaseUpdate?)
    }

    private enum RecordingDestination {
        case review(scope: UserRecordingScope?)
        case editor(documentID: String, beforeBlockID: String?, scope: UserRecordingScope?)
    }

    nonisolated private static let appBundleIdentifier = AppBundle.axonDaemonIdentifier
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
    private var incumbent: IncumbentCopy?
    private var strayEditorNotice: String?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        appRecency.start()
        configureStatusItem()
        ScreenCaptureRuntime.bootstrapSynchronously()
        Doctor.warmUp()
        // Whatever started this copy, the update scaffolding is the successor's to clear. Doing it
        // here means a finisher that ran, and one that failed and left its plist behind, both end
        // the same way.
        LaunchAgentManager.reapUpdateFinisher()
        strayEditorNotice = Self.strayEditorNotice()
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
                Self.serverEnded("socket server stopped accepting connections", incumbent: nil, app: self)
            } catch {
                Self.serverEnded(
                    "socket server failed: \(String(describing: error))",
                    incumbent: IncumbentCopy.resolve(from: error, socketPath: socketPath),
                    app: self
                )
            }
        }
        serverState = "running"
    }

    /// What to do when the socket server stops, which depends on who is supervising this process.
    ///
    /// Under launchd the daemon must exit so `KeepAlive` restarts it. Losing the socket race at
    /// login is ordinary — an incumbent may still be shutting down — and exiting is what lets the
    /// job take the endpoint as soon as it frees up. `axon serve` has always recovered this way;
    /// staying alive instead would leave launchd supervising a process it believes is healthy while
    /// it answers nothing, recoverable only by a person running `daemon restart`.
    ///
    /// Hand-launched there is nobody to restart it, so the failure belongs in the menu where
    /// someone can read it rather than in a process that vanishes.
    nonisolated private static func serverEnded(
        _ message: String,
        incumbent: IncumbentCopy?,
        app: AxonDaemonAppDelegate
    ) {
        if AxonEnvironment.isLaunchdManaged() {
            FileHandle.standardError.write(Data("axon: \(message)\n".utf8))
            exit(1)
        }
        Task { @MainActor in
            app.serverState = "failed"
            app.serverError = message
            app.incumbent = incumbent
            app.installMenu()
        }
    }

    private func installMenu() {
        let menu = NSMenu()
        menu.addItem(disabledItem("Axon"))

        // A copy that lost the socket race serves nothing, so offering it recording and updates
        // would be theatre. It gets the two things that are actually true of it: who is in its way,
        // and the two ways out.
        if let incumbent {
            menu.addItem(disabledItem(incumbent.summary))
            menu.addItem(.separator())
            menu.addItem(menuItem(title: "Use This Copy", action: #selector(useThisCopy)))
            menu.addItem(menuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
            statusItem.menu = menu
            updateStatusItemAppearance()
            return
        }

        if let serverError {
            menu.addItem(disabledItem("Error: \(serverError)"))
        }
        if let warning = registrationWarning() {
            menu.addItem(disabledItem(warning))
        }
        if let strayEditorNotice {
            menu.addItem(disabledItem(strayEditorNotice))
        }
        menu.addItem(.separator())
        if !AccessibilityPermission.isTrusted() {
            menu.addItem(menuItem(title: "Request Accessibility", action: #selector(requestAccessibility)))
        }
        menu.addItem(menuItem(title: "Browser Automation...", action: #selector(requestBrowserAutomationConsent)))
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
            // Never a dead end: a check that raced a release must be repeatable without relaunching.
            menu.addItem(disabledItem("Up to Date (\(version))"))
            menu.addItem(menuItem(title: "Check Again", action: #selector(checkForUpdates)))
        case let .available(update, _):
            menu.addItem(menuItem(title: "Update to \(update.latestVersion)...", action: #selector(performAvailableUpdate)))
        case let .downloading(version, progress):
            menu.addItem(disabledItem("Downloading \(version)... \(Int((progress * 100).rounded()))%"))
        case let .installing(version):
            menu.addItem(disabledItem("Installing \(version)..."))
        case let .restarting(version):
            menu.addItem(disabledItem("Restarting into \(version)..."))
        case let .failed(reason, update):
            menu.addItem(disabledItem("Update Failed"))
            menu.addItem(disabledItem(reason))
            menu.addItem(menuItem(title: "Check Again", action: #selector(checkForUpdates)))
            if update != nil {
                menu.addItem(menuItem(title: "Open Release Page", action: #selector(openReleasePage)))
            }
        }
    }

    /// Says so when the copy that is serving is not the copy launchd will start next login.
    private func registrationWarning() -> String? {
        guard let registered = LaunchAgentManager.daemonRegistration().path else {
            return nil
        }
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        guard !registered.hasPrefix(bundlePath + "/") else {
            return nil
        }
        return "Login item points at \(registered)"
    }

    /// Names an `Axon Editor.app` standing on its own outside this bundle.
    ///
    /// The editor ships nested, so a standalone copy is residue: either from the releases that
    /// shipped two apps, or from someone who dragged both out of one of those archives. It is
    /// harmless but it is another Launch Services claimant on `.axn`, which is worth saying.
    nonisolated private static func strayEditorNotice() -> String? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Axon Editor.app"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Axon Editor.app")
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            let version = AppBundle.shortVersion(of: candidate).map { " \($0)" } ?? ""
            return "Leftover Axon Editor\(version) at \(candidate.path)"
        }
        return nil
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

    /// The one place Axon asks macOS for Apple Events consent.
    ///
    /// Browser verbs only ever check the existing grant, so this gesture is how a grant is minted at
    /// a moment the user chose. The request blocks while the system dialog is up, so it runs off the
    /// main thread — on the main queue it would freeze the menu bar app, including the menu the
    /// dialog was opened from. Activating first keeps the dialog from opening behind other windows.
    @objc private func requestBrowserAutomationConsent() {
        NSApp.activate()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcomes = BrowserAutomationConsentRequester().requestForRunningBrowsers()
            DispatchQueue.main.async { [weak self] in
                self?.presentBrowserAutomationConsent(outcomes)
            }
        }
    }

    private func presentBrowserAutomationConsent(_ outcomes: [BrowserAutomationConsentOutcome]) {
        installMenu()
        guard !outcomes.isEmpty else {
            showAlert(
                title: "No Supported Browser Running",
                message: "macOS can only grant control of a browser that is running. Open Safari or Google Chrome, then choose Browser Automation... again."
            )
            return
        }
        let lines = outcomes.map { outcome in
            outcome.granted ? "\(outcome.app): allowed" : "\(outcome.app): \(outcome.detail ?? "not granted")"
        }
        showAlert(title: "Browser Automation", message: lines.joined(separator: "\n\n"))
    }

    @objc private func checkForUpdates() {
        updateMenuState = .checking
        installMenu()
        Task { @MainActor in
            do {
                let update = try await updateChecker.check(currentVersion: currentVersion())
                if update.isUpdateAvailable {
                    let installer = homebrewInstaller
                    let brewManaged = await Task.detached(priority: .utility) {
                        (try? installer?.isCaskInstalled(name: Self.homebrewCaskName)) ?? false
                    }.value
                    updateMenuState = .available(update, brewManaged: brewManaged)
                } else {
                    updateMenuState = .upToDate(version: update.currentVersion)
                }
            } catch {
                updateMenuState = .failed(reason: String(describing: error), update: nil)
            }
            installMenu()
        }
    }

    @objc private func openReleasePage() {
        guard case let .failed(_, update) = updateMenuState, let update else {
            return
        }
        NSWorkspace.shared.open(update.releaseURL)
    }

    /// Installs the available update, by whichever mechanism owns this install.
    ///
    /// Homebrew's copy is Homebrew's to replace. Every other install is Axon's own responsibility,
    /// and opening a web page was never an update: it handed the user an archive and a decision.
    @objc private func performAvailableUpdate() {
        guard case let .available(update, brewManaged) = updateMenuState else {
            return
        }
        guard confirmInstall(update: update, brewManaged: brewManaged) else {
            return
        }

        if let installer = homebrewInstaller, brewManaged {
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
            return
        }

        updateMenuState = .downloading(version: update.latestVersion, progress: 0)
        installMenu()
        Task { await performSelfUpdate(update) }
    }

    /// Downloads, verifies, and places the release, then hands the restart to launchd.
    ///
    /// Nothing here terminates this process. `daemon install` bootstraps the daemon job, boots it
    /// out, and bootstraps it again; that bootout is what retires this copy, at the moment its
    /// successor is ready to take the socket.
    private func performSelfUpdate(_ update: ReleaseUpdate) async {
        let bundleURL = Bundle.main.bundleURL
        let version = update.latestVersion
        do {
            let installed = try await ReleaseInstaller().install(update: update, replacing: bundleURL) { fraction in
                Task { @MainActor [weak self] in
                    self?.reportDownloadProgress(version: version, fraction: fraction)
                }
            }
            updateMenuState = .installing(version: installed.version)
            installMenu()
            try LaunchAgentManager.armUpdateFinisher(cliPath: installed.cliURL.path, socketPath: socketPath)
            updateMenuState = .restarting(version: installed.version)
            installMenu()
        } catch {
            let reason = (error as? CustomStringConvertible)?.description ?? String(describing: error)
            updateMenuState = .failed(reason: reason, update: update)
            installMenu()
            showAlert(title: "Update Failed", message: reason)
        }
    }

    private func reportDownloadProgress(version: String, fraction: Double) {
        guard case .downloading = updateMenuState else {
            return
        }
        updateMenuState = .downloading(version: version, progress: min(max(fraction, 0), 1))
    }

    private func finishUpgrade(outcome: Result<Void, Error>, update: ReleaseUpdate) {
        switch outcome {
        case .success:
            if AxonEnvironment.requiresIndependentRelaunch() {
                spawnRelaunchHelper()
            }
            NSApp.terminate(nil)
        case let .failure(error):
            updateMenuState = .available(update, brewManaged: true)
            installMenu()
            showAlert(title: "Update Failed", message: String(describing: error))
        }
    }

    private func confirmInstall(update: ReleaseUpdate, brewManaged: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Update Axon to \(update.latestVersion)?"
        alert.informativeText = brewManaged
            ? "Axon will quit, install the update via Homebrew, and relaunch."
            : """
            Axon will download \(update.latestVersion), verify its checksum and signature, \
            replace \(Bundle.main.bundleURL.path), and restart. Your permissions are kept.
            """
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Makes this copy the registered one, which is the repair a person otherwise performs by hand.
    ///
    /// It runs `daemon install` from this bundle through the same finisher job an update uses, so
    /// the registration moves here and both privacy grants ride the bundle identifier across
    /// untouched. This copy then quits: launchd owns the registration now, and it points here.
    @objc private func useThisCopy() {
        let cliURL = Bundle.main.bundleURL.appendingPathComponent(AppBundle.bundledCLIRelativePath)
        guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            showAlert(
                title: "Cannot Use This Copy",
                message: "This bundle has no CLI at \(cliURL.path), so it cannot register itself."
            )
            return
        }
        do {
            try LaunchAgentManager.armUpdateFinisher(cliPath: cliURL.path, socketPath: socketPath)
        } catch {
            showAlert(title: "Cannot Use This Copy", message: String(describing: error))
            return
        }
        NSApp.terminate(nil)
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
        let expectedEditorURL = Bundle.main.bundleURL
            .appendingPathComponent(AppBundle.nestedEditorRelativePath, isDirectory: true)
        guard let editorAppURL = AppBundle.pairedEditorURL(beside: Bundle.main.bundleURL) else {
            throw CocoaError(.executableNotLoadable, userInfo: [
                NSLocalizedDescriptionKey: "The matching Axon Editor.app was not found at \(expectedEditorURL.path). Reinstall Axon to restore the paired applications."
            ])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", editorAppURL.path, url.absoluteString]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableNotLoadable)
        }
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
