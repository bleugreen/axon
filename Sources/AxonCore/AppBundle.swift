import Foundation

/// A macOS `.app` bundle on disk, found from a path inside it.
///
/// Axon ships one bundle holding two executables: the daemon app at `Contents/MacOS/Axon` and the
/// CLI at `Contents/Resources/bin/axon`. More than one decision depends on finding the enclosing
/// bundle from whichever of them is running — locating the sibling editor app, and choosing the
/// identity `daemon install` registers — so the walk lives here rather than once per caller.
public struct AppBundle: Equatable, Sendable {
    /// The identifier of Axon's own daemon app bundle.
    ///
    /// Three modules assert this string independently — the CLI locating the running app, the app
    /// declaring itself, and `DaemonProgram` deciding whose privacy grants a registration may
    /// inherit — so it lives in one place rather than three that can drift apart.
    public static let axonDaemonIdentifier = "com.bleugreen.axon"

    /// The identifier of the sibling editor app bundle.
    public static let axonEditorIdentifier = "com.bleugreen.axon.editor"

    /// Returns the editor shipped beside a daemon bundle only when both halves identify as Axon
    /// and declare the same release version. Launch Services can retain older registrations for
    /// years, so falling back by bundle identifier would silently pair a current recorder with an
    /// incompatible editor.
    public static func pairedEditorURL(
        beside daemonBundleURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let editorURL = daemonBundleURL.deletingLastPathComponent()
            .appendingPathComponent("Axon Editor.app", isDirectory: true)
        guard fileManager.fileExists(atPath: editorURL.path),
              let daemonInfo = infoDictionary(at: daemonBundleURL.appendingPathComponent("Contents/Info.plist")),
              let editorInfo = infoDictionary(at: editorURL.appendingPathComponent("Contents/Info.plist")),
              daemonInfo["CFBundleIdentifier"] as? String == axonDaemonIdentifier,
              editorInfo["CFBundleIdentifier"] as? String == axonEditorIdentifier,
              let daemonVersion = daemonInfo["CFBundleShortVersionString"] as? String,
              !daemonVersion.isEmpty,
              editorInfo["CFBundleShortVersionString"] as? String == daemonVersion,
              let executable = editorInfo["CFBundleExecutable"] as? String,
              fileManager.isExecutableFile(atPath: editorURL.appendingPathComponent("Contents/MacOS/\(executable)").path)
        else {
            return nil
        }
        return editorURL
    }

    /// The bundle directory, such as `/Applications/Axon.app`.
    public let path: String

    /// `CFBundleIdentifier`, when the bundle declares one.
    public let identifier: String?

    /// `Contents/MacOS/<CFBundleExecutable>`, when the plist names one and that file is executable.
    ///
    /// This is the one executable macOS attributes to the bundle. A privacy grant recorded against
    /// it is keyed by bundle identity; a grant recorded against any other executable in the same
    /// bundle is keyed by that executable's absolute path.
    public let mainExecutablePath: String?

    /// The innermost `.app` directory containing `path`, if there is one.
    public static func enclosing(_ path: String, fileManager: FileManager = .default) -> AppBundle? {
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "app" {
                return AppBundle(bundleURL: url, fileManager: fileManager)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private init(bundleURL: URL, fileManager: FileManager) {
        path = bundleURL.path
        let info = Self.infoDictionary(at: bundleURL.appendingPathComponent("Contents/Info.plist"))
        identifier = info?["CFBundleIdentifier"] as? String
        mainExecutablePath = (info?["CFBundleExecutable"] as? String)
            .map { bundleURL.appendingPathComponent("Contents/MacOS/\($0)").path }
            .flatMap { fileManager.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    private static func infoDictionary(at url: URL) -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else {
            return nil
        }
        return plist as? [String: Any]
    }
}
