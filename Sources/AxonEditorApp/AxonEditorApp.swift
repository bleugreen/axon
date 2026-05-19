import AppKit
import AxonCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AxonEditorAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var editorWindows: [RecipeEditorWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let controller = editorWindows.first {
            controller.showWindow(nil)
        } else if !flag {
            openRecipeFromMenu()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenedURLs(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleRecipeFileOpen(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames.forEach { handleRecipeFileOpen(URL(fileURLWithPath: $0)) }
        sender.reply(toOpenOrPrint: .success)
    }

    private func handleOpenedURLs(_ urls: [URL]) {
        for url in urls {
            if url.scheme == AxonEditorURL.scheme {
                do {
                    try openEditorURL(url)
                } catch {
                    showAlert(title: "Unable to Open Editor", message: String(describing: error))
                }
            } else if url.isFileURL {
                handleRecipeFileOpen(url)
            }
        }
    }

    private func openEditorURL(_ url: URL) throws {
        let fileURL = try AxonEditorURL.fileURL(from: url)
        if url.host == AxonEditorURL.reviewHost {
            try openRecordingReview(
                fileURL: fileURL,
                suggestedName: AxonEditorURL.suggestedName(from: url) ?? fileURL.lastPathComponent
            )
        } else if url.host == AxonEditorURL.insertHost {
            try insertRecording(
                fileURL: fileURL,
                documentID: AxonEditorURL.documentID(from: url),
                beforeBlockID: AxonEditorURL.beforeBlockID(from: url),
                suggestedName: AxonEditorURL.suggestedName(from: url) ?? fileURL.lastPathComponent
            )
        } else {
            try openRecipeInEditor(url: fileURL)
        }
    }

    private func handleRecipeFileOpen(_ url: URL) {
        do {
            try openRecipeInEditor(url: url)
        } catch {
            showAlert(title: "Unable to Open Recipe", message: String(describing: error))
        }
    }

    func openRecipeFromMenu() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Open Axon Recipe"
        openPanel.allowedContentTypes = [.axonRecipe, UTType(filenameExtension: "axn") ?? .yaml]
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return
        }
        handleRecipeFileOpen(url)
    }

    func saveActiveDocument() {
        guard let controller = activeEditorWindowController() else {
            return
        }
        controller.saveDocument()
    }

    private func activeEditorWindowController() -> RecipeEditorWindowController? {
        if let keyWindow = NSApp.keyWindow,
           let controller = editorWindows.first(where: { $0.window === keyWindow }) {
            return controller
        }
        return editorWindows.last
    }

    private func openRecipeInEditor(url: URL) throws {
        let source = try String(contentsOf: url, encoding: .utf8)
        try openRecipeSourceInEditor(
            source,
            fileURL: url,
            review: false,
            suggestedName: url.lastPathComponent,
            suggestedDirectory: url.deletingLastPathComponent()
        )
    }

    private func openRecordingReview(fileURL: URL, suggestedName: String) throws {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        try openRecipeSourceInEditor(
            source,
            fileURL: nil,
            review: true,
            suggestedName: suggestedName,
            suggestedDirectory: defaultRecordingsDirectory()
        )
    }

    private func openRecipeSourceInEditor(
        _ source: String,
        fileURL: URL?,
        review: Bool,
        suggestedName: String,
        suggestedDirectory: URL
    ) throws {
        let recipe = try AxonRecipe(source: source)
        openEditorWindow(
            document: AxonDocument(recipe: recipe),
            fileURL: fileURL,
            review: review,
            suggestedName: suggestedName,
            suggestedDirectory: suggestedDirectory
        )
    }

    private func insertRecording(
        fileURL: URL,
        documentID: String?,
        beforeBlockID: String?,
        suggestedName: String
    ) throws {
        guard let documentID,
              let controller = editorWindows.first(where: { $0.documentID == documentID })
        else {
            try openRecordingReview(fileURL: fileURL, suggestedName: suggestedName)
            return
        }
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        try controller.insertRecording(source, beforeBlockID: beforeBlockID)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openEditorWindow(
        document: AxonDocument,
        fileURL: URL?,
        review: Bool,
        suggestedName: String,
        suggestedDirectory: URL
    ) {
        let controller = RecipeEditorWindowController(
            document: document,
            fileURL: fileURL,
            review: review,
            suggestedName: suggestedName,
            suggestedDirectory: suggestedDirectory
        ) { [weak self] closed in
            self?.editorWindows.removeAll { $0 === closed }
        }
        controller.recordFromHere = { [weak self] controller, beforeBlockID in
            self?.requestRecordFromHere(controller: controller, beforeBlockID: beforeBlockID)
        }
        editorWindows.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestRecordFromHere(controller: RecipeEditorWindowController, beforeBlockID: String?) {
        var params: [String: JSONValue] = [
            "documentId": .string(controller.documentID)
        ]
        if let beforeBlockID {
            params["beforeBlockId"] = .string(beforeBlockID)
        }

        Task.detached(priority: .userInitiated) {
            let result: Result<Void, Error>
            do {
                let response = try SocketClient(
                    path: AxonEnvironment.socketPath(),
                    responseTimeoutSeconds: SocketClient.defaultBatchResponseTimeoutSeconds
                ).send(JSONRPCRequest(
                    id: .string("editor.record-from-here"),
                    method: "editor.recordFromHere",
                    params: .object(params)
                ))
                if let error = response.error {
                    throw error
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                if case let .failure(error) = result {
                    self.showAlert(title: "Unable to Start Recording", message: String(describing: error))
                }
            }
        }
    }

    private func defaultRecordingsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Axon Recordings", isDirectory: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@MainActor
private final class RecipeEditorWindowController: NSWindowController, NSWindowDelegate {
    private var axonDocument: AxonDocument
    private var fileURL: URL?
    private var review: Bool
    let documentID = UUID().uuidString
    private let suggestedName: String
    private let suggestedDirectory: URL
    private let onClose: (RecipeEditorWindowController) -> Void
    var recordFromHere: ((RecipeEditorWindowController, String?) -> Void)?

    init(
        document: AxonDocument,
        fileURL: URL?,
        review: Bool,
        suggestedName: String,
        suggestedDirectory: URL,
        onClose: @escaping (RecipeEditorWindowController) -> Void
    ) {
        self.axonDocument = document
        self.fileURL = fileURL
        self.review = review
        self.suggestedName = suggestedName
        self.suggestedDirectory = suggestedDirectory
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: 1040, height: 620)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = fileURL?.lastPathComponent ?? "Unsaved Recording"
        window.representedURL = fileURL
        window.isDocumentEdited = review || fileURL == nil

        super.init(window: window)

        window.delegate = self
        window.contentViewController = NSHostingController(rootView: makeDocumentView())
        shouldCascadeWindows = true
    }

    private func makeDocumentView() -> DocumentView {
        DocumentView(
            document: Binding(
                get: { [weak self] in self?.axonDocument ?? AxonDocument() },
                set: { [weak self] document in
                    self?.axonDocument = document
                    self?.window?.isDocumentEdited = true
                }
            ),
            isReview: review,
            documentID: documentID,
            saveDocument: showsToolbarSave ? { [weak self] in self?.saveDocument() } : nil,
            discardDocument: review ? { [weak self] in self?.close() } : nil,
            recordFromHere: { [weak self] beforeBlockID in
                guard let self else {
                    return
                }
                self.recordFromHere?(self, beforeBlockID)
            }
        )
    }

    private var showsToolbarSave: Bool {
        review || fileURL == nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func saveDocument() {
        do {
            let targetURL = try saveURL()
            let source = try axonDocument.recipe.yamlString()
            try source.write(to: targetURL, atomically: true, encoding: .utf8)
            fileURL = targetURL
            review = false
            window?.representedURL = targetURL
            window?.title = targetURL.lastPathComponent
            window?.isDocumentEdited = false
            if let hostingController = window?.contentViewController as? NSHostingController<DocumentView> {
                hostingController.rootView = makeDocumentView()
            }
        } catch CocoaError.userCancelled {
            return
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to Save Recipe"
            alert.informativeText = String(describing: error)
            alert.addButton(withTitle: "OK")
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    private func saveURL() throws -> URL {
        if let fileURL {
            return fileURL
        }
        try FileManager.default.createDirectory(at: suggestedDirectory, withIntermediateDirectories: true)
        let savePanel = NSSavePanel()
        savePanel.title = review ? "Save Axon Recording" : "Save Axon Recipe"
        savePanel.directoryURL = suggestedDirectory
        savePanel.nameFieldStringValue = suggestedName
        savePanel.allowedContentTypes = [.axonRecipe, UTType(filenameExtension: "axn") ?? .yaml]
        savePanel.canCreateDirectories = true
        guard savePanel.runModal() == .OK, let url = savePanel.url else {
            throw CocoaError(.userCancelled)
        }
        return url
    }

    func insertRecording(_ source: String, beforeBlockID: String?) throws {
        let recording = try AxonRecipe(source: source)
        axonDocument.recipe.insertRecordedBlocks(recording.blocks, beforeBlockID: beforeBlockID)
        axonDocument.recipe.assignMissingBlockIDs()
        window?.isDocumentEdited = true
        window?.title = fileURL?.lastPathComponent ?? "Unsaved Recording"
        if let hostingController = window?.contentViewController as? NSHostingController<DocumentView> {
            hostingController.rootView = makeDocumentView()
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose(self)
    }
}

@main
struct AxonEditorAppMain: App {
    @NSApplicationDelegateAdaptor(AxonEditorAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            PreferencesView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Recipe...") {
                    appDelegate.openRecipeFromMenu()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    appDelegate.saveActiveDocument()
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
        }
    }
}
