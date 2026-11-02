import Foundation

/// A macOS `.app` bundle on disk, found from a path inside it.
///
/// Axon ships one bundle. It holds two executables — the daemon app at `Contents/MacOS/Axon` and
/// the CLI at `Contents/Resources/bin/axon` — and the editor app nested at
/// `Contents/Library/Applications/Axon Editor.app`. More than one decision depends on finding one
/// of these from another — locating the editor from the daemon, the CLI from the editor, and the
/// identity `daemon install` registers — so the walks live here rather than once per caller.
public struct AppBundle: Equatable, Sendable {
    /// The identifier of Axon's own daemon app bundle.
    ///
    /// Three modules assert this string independently — the CLI locating the running app, the app
    /// declaring itself, and `DaemonProgram` deciding whose privacy grants a registration may
    /// inherit — so it lives in one place rather than three that can drift apart.
    public static let axonDaemonIdentifier = "com.bleugreen.axon"

    /// The identifier of the sibling editor app bundle.
    public static let axonEditorIdentifier = "com.bleugreen.axon.editor"

    /// Where the editor lives inside the daemon bundle.
    ///
    /// `Contents/Library/Applications` is the location macOS reserves for a nested application, and
    /// nesting is what makes the pair inseparable: one bundle to drag, one bundle to replace, and
    /// no way for the recorder and the editor to reach different versions.
    public static let nestedEditorRelativePath = "Contents/Library/Applications/Axon Editor.app"

    /// The relative path of the CLI inside the daemon bundle.
    public static let bundledCLIRelativePath = "Contents/Resources/bin/axon"

    /// Returns the editor nested inside a daemon bundle only when both halves identify as Axon and
    /// declare the same release version. Launch Services can retain older registrations for years,
    /// so falling back by bundle identifier would silently pair a current recorder with an
    /// incompatible editor. Nesting makes version skew impossible to produce by installation, but
    /// the guards still catch a bundle that was corrupted or assembled by hand.
    public static func pairedEditorURL(
        beside daemonBundleURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let editorURL = daemonBundleURL.appendingPathComponent(nestedEditorRelativePath, isDirectory: true)
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

    /// Returns the CLI of the daemon bundle that encloses a nested editor.
    ///
    /// The editor's only reliable route to a matching CLI is the bundle it was shipped inside. It
    /// cannot ask Launch Services, which happily answers with whichever Axon it saw most recently,
    /// and it cannot look for a sibling, which is the pre-nesting layout. Identity is checked on
    /// the enclosing bundle for the same reason `DaemonProgram.resolved` checks it: any consumer
    /// may embed the editor, and that layout is indistinguishable from Axon's own by shape alone.
    public static func pairedDaemonCLIURL(
        from editorBundleURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        var daemonBundleURL = editorBundleURL.standardizedFileURL
        // Axon Editor.app / Applications / Library / Contents -> the enclosing .app
        for _ in 0..<4 {
            daemonBundleURL.deleteLastPathComponent()
        }
        guard daemonBundleURL.pathExtension == "app",
              let bundle = AppBundle(bundleURL: daemonBundleURL, fileManager: fileManager),
              bundle.identifier == axonDaemonIdentifier
        else {
            return nil
        }
        let cliURL = daemonBundleURL.appendingPathComponent(bundledCLIRelativePath)
        guard fileManager.isExecutableFile(atPath: cliURL.path) else {
            return nil
        }
        return cliURL
    }

    /// `CFBundleShortVersionString` of the bundle at `bundleURL`, when it declares one.
    public static func shortVersion(of bundleURL: URL) -> String? {
        infoDictionary(at: bundleURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
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
                return AppBundle(existingBundleURL: url, fileManager: fileManager)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// The bundle at `bundleURL`, or nil when nothing there declares itself one.
    public init?(bundleURL: URL, fileManager: FileManager = .default) {
        guard Self.infoDictionary(at: bundleURL.appendingPathComponent("Contents/Info.plist")) != nil else {
            return nil
        }
        self.init(existingBundleURL: bundleURL, fileManager: fileManager)
    }

    private init(existingBundleURL bundleURL: URL, fileManager: FileManager) {
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
