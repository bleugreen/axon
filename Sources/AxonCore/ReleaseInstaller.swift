import CryptoKit
import Foundation
import Security

/// How an Axon install is laid out on disk, which decides how a new bundle replaces it.
///
/// There are exactly two shapes that are not Homebrew's. `install.sh` puts each release in its own
/// version-named directory under `~/.local/lib/axon` and marks it complete; everything else is one
/// bundle sitting where a person dragged it. The marker file is what makes the first shape
/// recognizable rather than guessed: a directory that merely looks version-shaped could be
/// anyone's, and Axon never writes outside a directory it created.
public enum InstallLayout: Equatable, Sendable {
    /// `<root>/<version>/Axon.app`, as written by `install.sh`.
    case versioned(root: URL, version: String)
    /// A bundle at a path of its own, such as `/Applications/Axon.app`.
    case fixedLocation(bundleURL: URL)

    /// The file `install.sh` writes once a version directory is complete, holding that version.
    public static let markerName = ".axon-install-complete"

    public static func detect(bundleURL: URL, fileManager: FileManager = .default) -> InstallLayout {
        let bundleURL = bundleURL.standardizedFileURL
        let versionDirectory = bundleURL.deletingLastPathComponent()
        let version = versionDirectory.lastPathComponent
        let marker = versionDirectory.appendingPathComponent(markerName)
        guard isVersionShaped(version), fileManager.fileExists(atPath: marker.path) else {
            return .fixedLocation(bundleURL: bundleURL)
        }
        return .versioned(root: versionDirectory.deletingLastPathComponent(), version: version)
    }

    /// Whether a directory name is a release version, by the same rule `install.sh` accepts.
    ///
    /// Deliberately narrow: it must start with a digit and carry a dot, so `current`, `bin`, and
    /// `Applications` can never be mistaken for a release.
    public static func isVersionShaped(_ name: String) -> Bool {
        guard let first = name.first, first.isNumber, name.contains(".") else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// Which superseded install directories are safe to remove.
///
/// Every release before the stable-alias work left its own directory under `~/.local/lib/axon` and
/// nothing ever removed one, so a CLI three releases old was still on disk and still serving MCP to
/// whatever client held its absolute path. Pruning is the answer, and it is deliberately timid: it
/// removes only directories Axon itself created, only after a newer one is proven to work, and
/// never one anything still points at.
public enum InstallPruning {
    /// How many version directories survive: the current one and the one before it, so a bad
    /// release can be rolled back to by hand.
    public static let keepCount = 2

    /// Version directories under `root` that may be removed, oldest first.
    ///
    /// A candidate must be version-shaped, carry Axon's completion marker, and contain an
    /// `Axon.app`. That precondition stays strict on purpose: a hand-assembled layout has no marker
    /// and pruning is right to leave it alone. Anything holding a protected path — the live
    /// registration, the running bundle — is never a candidate no matter how old it looks.
    public static func superseded(
        root: URL,
        keeping keepCount: Int = InstallPruning.keepCount,
        protecting protectedPaths: [String],
        fileManager: FileManager = .default
    ) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        let installs = contents
            .filter { InstallLayout.isVersionShaped($0) }
            .map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { directory in
                fileManager.fileExists(atPath: directory.appendingPathComponent(InstallLayout.markerName).path)
                    && fileManager.fileExists(atPath: directory.appendingPathComponent("Axon.app").path)
            }
            .sorted { ReleaseUpdateChecker.isVersion($0.lastPathComponent, newerThan: $1.lastPathComponent) }

        let protected = protectedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        return installs.dropFirst(keepCount)
            .filter { directory in
                let prefix = directory.standardizedFileURL.path + "/"
                return !protected.contains { $0 == directory.standardizedFileURL.path || $0.hasPrefix(prefix) }
            }
            .reversed()
    }
}

/// Where an update landed, and the CLI that finishes it.
public struct InstalledUpdate: Equatable, Sendable {
    public let version: String
    public let bundleURL: URL

    public init(version: String, bundleURL: URL) {
        self.version = version
        self.bundleURL = bundleURL
    }

    /// The CLI inside the placed bundle, which is what re-registers the daemon.
    public var cliURL: URL {
        bundleURL.appendingPathComponent(AppBundle.bundledCLIRelativePath)
    }
}

public enum ReleaseInstallError: Error, CustomStringConvertible {
    case missingAsset(version: String)
    case malformedChecksum
    case checksumMismatch(expected: String, actual: String)
    case archiveLayout(String)
    case versionMismatch(expected: String, found: String)
    case unsignedRunningCopy
    case signatureRejected(String)
    case notWritable(path: String)
    case commandFailed(String, ProcessResult)

    public var description: String {
        switch self {
        case let .missingAsset(version):
            return "Release \(version) does not publish a macOS archive yet; try again shortly or install it by hand."
        case .malformedChecksum:
            return "The published checksum is malformed; nothing was installed."
        case let .checksumMismatch(expected, actual):
            return "Checksum verification failed: expected \(expected) but downloaded \(actual). Nothing was installed."
        case let .archiveLayout(detail):
            return "The downloaded archive is not a usable Axon release: \(detail). Nothing was installed."
        case let .versionMismatch(expected, found):
            return "The downloaded archive reports version \(found), not \(expected). Nothing was installed."
        case .unsignedRunningCopy:
            return "This copy of Axon is not signed with a Developer ID, so it cannot verify a release against itself. Install the update with the installer script instead."
        case let .signatureRejected(detail):
            return "The downloaded archive failed signature verification: \(detail). Nothing was installed."
        case let .notWritable(path):
            return "\(path) is not writable by this user, so the update cannot be placed there."
        case let .commandFailed(command, result):
            return "\(command) failed with exit code \(result.exitCode): \(result.combinedOutput)"
        }
    }
}

/// Downloads a published release, proves it is Axon's, and puts it where the running copy lives.
///
/// Every check happens before anything on disk is touched, and each one refuses the whole update
/// rather than degrading it: a failed download, a mismatched checksum, an archive of the wrong
/// shape, or a signature from anyone but the team that signed the running copy all leave the
/// existing install exactly as it was.
///
/// Placement ends the same way for both layouts — a new bundle in place, and a CLI to run
/// `daemon install` from. That last step is the one the field report proved carries both privacy
/// grants across with no prompt, so the updater performs it rather than inventing its own
/// registration.
public struct ReleaseInstaller {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public typealias Download = @Sendable (URL, URL, @Sendable @escaping (Double) -> Void) async throws -> Void
    public typealias VerifySignature = @Sendable (URL) throws -> Void

    private let fileManager: FileManager
    private let fetch: Fetch
    private let download: Download
    private let verifySignature: VerifySignature

    public init(
        fileManager: FileManager = .default,
        fetch: @escaping Fetch = ReleaseUpdateChecker.defaultFetch,
        download: @escaping Download = ReleaseInstaller.defaultDownload,
        verifySignature: @escaping VerifySignature = ReleaseInstaller.verifyMatchesRunningCode
    ) {
        self.fileManager = fileManager
        self.fetch = fetch
        self.download = download
        self.verifySignature = verifySignature
    }

    /// Installs `update` over the bundle at `bundleURL`, reporting download progress in 0...1.
    public func install(
        update: ReleaseUpdate,
        replacing bundleURL: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> InstalledUpdate {
        guard let assetURL = update.assetURL, let checksumURL = update.checksumURL else {
            throw ReleaseInstallError.missingAsset(version: update.latestVersion)
        }

        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("axon-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let archiveURL = workDirectory.appendingPathComponent(assetURL.lastPathComponent)
        try await download(assetURL, archiveURL, progress)

        let expected = try Self.checksum(fromSidecar: try await fetch(checksumURL))
        let actual = try Self.sha256(ofFileAt: archiveURL)
        guard actual == expected else {
            throw ReleaseInstallError.checksumMismatch(expected: expected, actual: actual)
        }

        // `ditto` is how the archive was created, and it is the only extractor that restores an
        // app bundle's symlinks and permissions faithfully.
        let extractDirectory = workDirectory.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
        try Self.run("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extractDirectory.path])

        let stagedBundle = try verifiedBundle(in: extractDirectory, expectedVersion: update.latestVersion)
        try verifySignature(stagedBundle)

        let layout = InstallLayout.detect(bundleURL: bundleURL, fileManager: fileManager)
        let placed = try place(stagedBundle, version: update.latestVersion, layout: layout)
        return InstalledUpdate(version: update.latestVersion, bundleURL: placed)
    }

    // MARK: - Verification

    /// The single SHA-256 a `shasum`-style sidecar vouches for, by the same first-field rule
    /// `install.sh` applies.
    public static func checksum(fromSidecar data: Data) throws -> String {
        guard
            let text = String(data: data, encoding: .utf8),
            let field = text.split(whereSeparator: \.isNewline).first?
                .split(whereSeparator: \.isWhitespace).first
        else {
            throw ReleaseInstallError.malformedChecksum
        }
        let digest = String(field).lowercased()
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
            throw ReleaseInstallError.malformedChecksum
        }
        return digest
    }

    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The `Axon.app` at the root of an extracted archive, once it is complete enough to install.
    ///
    /// A half-published or repackaged archive is the failure this catches: the bundle must carry
    /// the daemon executable macOS attributes grants to, the CLI that re-registers the daemon, and
    /// the nested editor, all at the version the release claims.
    public func verifiedBundle(in extractDirectory: URL, expectedVersion: String) throws -> URL {
        let bundleURL = extractDirectory.appendingPathComponent("Axon.app", isDirectory: true)
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw ReleaseInstallError.archiveLayout("it has no Axon.app at its root")
        }
        guard let bundle = AppBundle(bundleURL: bundleURL, fileManager: fileManager),
              bundle.identifier == AppBundle.axonDaemonIdentifier,
              bundle.mainExecutablePath != nil
        else {
            throw ReleaseInstallError.archiveLayout("Axon.app does not declare Axon's identity and main executable")
        }
        let cliURL = bundleURL.appendingPathComponent(AppBundle.bundledCLIRelativePath)
        guard fileManager.isExecutableFile(atPath: cliURL.path) else {
            throw ReleaseInstallError.archiveLayout("it has no executable \(AppBundle.bundledCLIRelativePath)")
        }
        guard AppBundle.pairedEditorURL(beside: bundleURL, fileManager: fileManager) != nil else {
            throw ReleaseInstallError.archiveLayout("it has no matching nested Axon Editor.app")
        }
        let version = AppBundle.shortVersion(of: bundleURL) ?? ""
        guard version == expectedVersion else {
            throw ReleaseInstallError.versionMismatch(expected: expectedVersion, found: version.isEmpty ? "none" : version)
        }
        return bundleURL
    }

    /// Accepts a bundle only when it is signed by the same team and identifier as the running copy,
    /// and only when Gatekeeper would launch it.
    ///
    /// Anchoring to the running copy's own signature rather than to a constant is what makes this
    /// meaningful: the requirement an update must satisfy is "signed by whoever signed me". A
    /// development build is ad-hoc signed and has no team to anchor to, so it refuses to pull a
    /// release bundle over itself rather than pretending it verified something.
    public static func verifyMatchesRunningCode(_ bundleURL: URL) throws {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
            throw ReleaseInstallError.signatureRejected("the running copy has no code signature to compare against")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            unsafeBitCast(selfCode, to: SecStaticCode.self),
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let info = information as? [String: Any],
            let identifier = info[kSecCodeInfoIdentifier as String] as? String
        else {
            throw ReleaseInstallError.signatureRejected("the running copy's signing information could not be read")
        }
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
            throw ReleaseInstallError.unsignedRunningCopy
        }

        let requirementText = """
        anchor apple generic and identifier "\(identifier)" \
        and certificate leaf[subject.OU] = "\(team)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else {
            throw ReleaseInstallError.signatureRejected("could not build a signing requirement from this copy")
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            throw ReleaseInstallError.signatureRejected("the downloaded bundle carries no signature")
        }
        let status = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
        guard status == errSecSuccess else {
            throw ReleaseInstallError.signatureRejected(
                "it is not signed by \(team) as \(identifier) (OSStatus \(status))"
            )
        }

        // The signature says who made it; Gatekeeper says whether this machine would run it, which
        // also covers notarization and the stapled ticket.
        try run("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", bundleURL.path])
    }

    // MARK: - Placement

    /// Puts a verified bundle where the layout says it belongs, and returns its new path.
    public func place(_ stagedBundle: URL, version: String, layout: InstallLayout) throws -> URL {
        switch layout {
        case let .fixedLocation(bundleURL):
            return try placeAtFixedLocation(stagedBundle, replacing: bundleURL, version: version)
        case let .versioned(root, _):
            return try placeInVersionedRoot(stagedBundle, root: root, version: version)
        }
    }

    /// Swaps a bundle in place, atomically as far as any observer is concerned.
    ///
    /// The new copy is staged beside the target first so the exchange happens on one volume, which
    /// is what lets `replaceItemAt` do a rename rather than a copy. The window between the swap and
    /// the relaunch is real but tiny, and the running process keeps its own open file references
    /// across it.
    private func placeAtFixedLocation(_ stagedBundle: URL, replacing bundleURL: URL, version: String) throws -> URL {
        let parent = bundleURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw ReleaseInstallError.notWritable(path: parent.path)
        }
        let stagingDirectory = parent.appendingPathComponent(".axon-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let staged = stagingDirectory.appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: stagedBundle, to: staged)

        if fileManager.fileExists(atPath: bundleURL.path) {
            _ = try fileManager.replaceItemAt(
                bundleURL,
                withItemAt: staged,
                backupItemName: "\(bundleURL.lastPathComponent).axon-previous",
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: staged, to: bundleURL)
        }
        return bundleURL
    }

    /// Adds a version directory beside the current one, complete before it is visible.
    ///
    /// The marker is written into the staging directory rather than after the rename, so the
    /// directory that appears under its release name is already one every reader — `install.sh`,
    /// layout detection, and pruning — recognizes as complete.
    private func placeInVersionedRoot(_ stagedBundle: URL, root: URL, version: String) throws -> URL {
        guard fileManager.isWritableFile(atPath: root.path) else {
            throw ReleaseInstallError.notWritable(path: root.path)
        }
        let target = root.appendingPathComponent(version, isDirectory: true)
        let staging = root.appendingPathComponent("\(version).installing", isDirectory: true)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.copyItem(at: stagedBundle, to: staging.appendingPathComponent("Axon.app", isDirectory: true))
        try Data("\(version)\n".utf8).write(to: staging.appendingPathComponent(InstallLayout.markerName))

        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: staging, to: target)

        let placed = target.appendingPathComponent("Axon.app", isDirectory: true)
        repointStableCLILink(into: root, to: placed.appendingPathComponent(AppBundle.bundledCLIRelativePath))
        return placed
    }

    /// Repoints `~/.local/bin/axon` when — and only when — it already points into this root.
    ///
    /// That link is how every MCP client on the machine reaches Axon. Following it is the whole
    /// point of an update; retargeting a link that points somewhere else would be taking over a
    /// path this install does not own.
    private func repointStableCLILink(into root: URL, to cliURL: URL) {
        let link = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/axon")
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
            return
        }
        let resolved = destination.hasPrefix("/")
            ? destination
            : link.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL.path
        guard resolved.hasPrefix(root.standardizedFileURL.path + "/") else {
            return
        }
        try? fileManager.removeItem(at: link)
        try? fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: cliURL.path)
    }

    // MARK: - Process and network defaults

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let result = ProcessResult(
            exitCode: process.terminationStatus,
            output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            error: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
        guard result.exitCode == 0 else {
            throw ReleaseInstallError.commandFailed("\(executable) \(arguments.joined(separator: " "))", result)
        }
        return result
    }

    public static let defaultDownload: Download = { remoteURL, destination, progress in
        var request = URLRequest(url: remoteURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Axon/\(AxonVersion.current)", forHTTPHeaderField: "User-Agent")
        let reporter = DownloadProgressReporter(onProgress: progress)
        let (temporaryURL, response) = try await URLSession.shared.download(for: request, delegate: reporter)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ReleaseUpdateError.invalidHTTPStatus(http.statusCode)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }
}

/// Reports download progress without owning the transfer, so the async `download(for:delegate:)`
/// call stays the one place a failure is raised.
private final class DownloadProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            return
        }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        onProgress(1)
    }
}
