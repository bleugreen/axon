import AxonClient
import Foundation

/// Turns a stopped recording into a file and hands it to the editor.
///
/// The file goes under `~/Library/Application Support/Axon/Recordings`, not the temporary
/// directory: a recording is something the user made, and a purged `$TMPDIR` would lose one whose
/// editor was never saved. `~/Library` sits outside the folders macOS's Files and Folders
/// protections cover, so writing there costs the shell no grant.
struct RecordingHandoff {
    var directory: URL = RecordingHandoff.defaultDirectory
    var now: () -> Date = Date.init
    var openEditor: (URL) throws -> Void
    var fileManager: FileManager = .default

    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Axon/Recordings", isDirectory: true)
    }

    /// Writes the script and opens the editor: insert mode when the recording was started from an
    /// editor document, review mode otherwise. Returns the file written.
    @discardableResult
    func deliver(_ result: RecordingResult, scope: RecordingScope?) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = fileName(scope: scope)
        let fileURL = directory.appendingPathComponent(name)
        try result.script.write(to: fileURL, atomically: true, encoding: .utf8)
        let editorURL: URL
        if let destination = result.destination {
            editorURL = AxonEditorURL.url(
                forInserting: fileURL,
                documentID: destination.documentId,
                beforeBlockID: destination.beforeBlockId,
                suggestedName: name
            )
        } else {
            editorURL = AxonEditorURL.url(forReviewing: fileURL, suggestedName: name)
        }
        try openEditor(editorURL)
        return fileURL
    }

    func fileName(scope: RecordingScope?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let app = scope.map { $0.displayName.replacingOccurrences(of: "/", with: "-") } ?? "recording"
        return "\(formatter.string(from: now()))-\(app).axn"
    }
}

/// The update finisher the shell arms, for every path that re-registers from a bundle.
enum UpdateFinisher {
    /// `<bundle>/Contents/Resources/bin/axon daemon install`, as shell-v1 fixes it.
    static func configuration(enclosingBundle: URL, socketPath: String) -> LaunchAgentConfiguration {
        LaunchAgentConfiguration.updateFinisher(
            cliPath: enclosingBundle.appendingPathComponent(AppBundle.bundledCLIRelativePath).path,
            socketPath: socketPath
        )
    }

    static func arm(enclosingBundle: URL, socketPath: String) throws {
        try LaunchAgentManager(configuration: configuration(enclosingBundle: enclosingBundle, socketPath: socketPath)).start()
    }
}
