import Darwin
import Foundation

/// The daemon-to-menu-shell contract, shell-v1.
///
/// The macOS menu shell (`Axon Menu.app`) holds no privacy grant and links only this module. It
/// reaches the daemon over the same newline-delimited JSON-RPC socket every other client uses, and
/// everything it shows or does is one of the calls below. The Rust daemon answers them in
/// `rust/axon-mac/src/socket.rs`; the shapes are pinned by `schema/fixtures/shell`, which both
/// languages are tested against. The contract is documented in `docs/cross-platform-internals.md`
/// under "macOS daemon and menu shell contract".
public enum ShellContract {
    /// The `shellContract` value a daemon must publish in `health` for this shell to drive it.
    public static let version = 1

    /// How long the shell waits for each kind of call before keeping what it last knew.
    public enum Timeout {
        /// `health`, `recording.status`, and `automation.status`, which the shell polls.
        public static let poll: TimeInterval = 2
        /// `recording.start`, `recording.stop`, and `permit`.
        public static let action: TimeInterval = 30
        /// `automation.request`, which blocks while a person answers a consent dialog.
        public static let consentRequest: TimeInterval = 300
    }

    /// The CLI arguments the shell arms `dev.axon.updater` with, after the enclosing bundle's
    /// `Contents/Resources/bin/axon`. This is the shell's one process-spawning dependency in the
    /// contract, so it is a path and a command and nothing that only one CLI implementation has.
    public static let finisherArguments = ["daemon", "install"]
}

// MARK: - Recording

/// The application a recording is scoped to, by the identity the daemon resolves it with.
public struct RecordingApp: Codable, Equatable, Sendable {
    public let name: String
    public let bundleIdentifier: String?

    public init(name: String, bundleIdentifier: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

/// `{scope:"application", app:{...}}` or `{scope:"allApplications"}`.
///
/// There is no pid: the daemon does not take one, so the shell cannot single out one instance of an
/// application and its picker lists each application once.
public enum RecordingScope: Codable, Equatable, Sendable {
    case application(RecordingApp)
    case allApplications

    private enum CodingKeys: String, CodingKey {
        case scope
        case app
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .scope) {
        case "application":
            self = .application(try container.decode(RecordingApp.self, forKey: .app))
        case "allApplications":
            self = .allApplications
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .scope, in: container, debugDescription: "unknown recording scope \(other)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .application(app):
            try container.encode("application", forKey: .scope)
            try container.encode(app, forKey: .app)
        case .allApplications:
            try container.encode("allApplications", forKey: .scope)
        }
    }

    public var displayName: String {
        switch self {
        case let .application(app): return app.name
        case .allApplications: return "All Running Apps"
        }
    }

    /// The recording picker the menu and the editor both show: each running application once,
    /// then every application.
    ///
    /// The daemon scopes a recording by name and bundle identifier and takes no pid, so two
    /// instances of one application are one choice.
    public static func pickerScopes(for apps: [AppIdentity]) -> [RecordingScope] {
        var seen = Set<String>()
        var scopes: [RecordingScope] = []
        for app in apps {
            let key = app.bundleIdentifier ?? "name:\(app.name)"
            guard seen.insert(key).inserted else { continue }
            scopes.append(.application(RecordingApp(name: app.name, bundleIdentifier: app.bundleIdentifier)))
        }
        return scopes + [.allApplications]
    }

    /// This scope as the `scope` value of `recording.start` and `editor.recordFromHere`.
    public func jsonValue() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
    }
}

/// The editor document a recording started from the editor is inserted into.
public struct RecordingDestination: Codable, Equatable, Sendable {
    public let documentId: String
    public let beforeBlockId: String?

    public init(documentId: String, beforeBlockId: String?) {
        self.documentId = documentId
        self.beforeBlockId = beforeBlockId
    }
}

/// The result of `recording.start` and `recording.status`.
public struct RecordingStatus: Codable, Equatable, Sendable {
    public let recording: Bool
    public let sessionId: String?
    public let scope: RecordingScope?
    public let destination: RecordingDestination?

    public init(recording: Bool, sessionId: String? = nil, scope: RecordingScope? = nil, destination: RecordingDestination? = nil) {
        self.recording = recording
        self.sessionId = sessionId
        self.scope = scope
        self.destination = destination
    }

    public static let idle = RecordingStatus(recording: false)
}

/// The result of `recording.stop`.
public struct RecordingResult: Codable, Equatable, Sendable {
    public let sessionId: String
    /// Present as `null` for a recording with no editor destination, which is reviewed instead.
    public let destination: RecordingDestination?
    public let script: String
    public let actionCount: Int

    public init(sessionId: String, destination: RecordingDestination?, script: String, actionCount: Int) {
        self.sessionId = sessionId
        self.destination = destination
        self.script = script
        self.actionCount = actionCount
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, destination, script, actionCount
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(destination, forKey: .destination)
        try container.encode(script, forKey: .script)
        try container.encode(actionCount, forKey: .actionCount)
    }
}

// MARK: - Permissions

public enum AccessibilityTrust: String, Codable, Equatable, Sendable {
    case trusted
    case denied
}

/// The result of `permit`: the prompt was requested, and the daemon's trust read back afterwards.
public struct PermitResult: Codable, Equatable, Sendable {
    public let accessibility: AccessibilityTrust
    public let prompted: Bool
}

public enum AutomationAuthorization: String, Codable, Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    case failed
}

public enum AutomationLeg: String, Codable, Equatable, Sendable {
    case checked
    case prompted
    /// Reserved for browser verbs, which the Rust daemon does not yet have.
    case executed
}

/// Whether the Browser Automation item exists, and what choosing it will do.
public enum ConsentNeed: String, Codable, Equatable, Sendable {
    case none
    case request
    case explain
}

public struct BrowserConsentState: Codable, Equatable, Sendable {
    public let app: String
    public let bundleIdentifier: String
    public let running: Bool
    public let status: AutomationAuthorization?
    public let leg: AutomationLeg?
    public let detail: String?
}

public struct AutomationStatusReport: Codable, Equatable, Sendable {
    public let need: ConsentNeed
    public let browsers: [BrowserConsentState]

    public init(need: ConsentNeed, browsers: [BrowserConsentState]) {
        self.need = need
        self.browsers = browsers
    }
}

public struct ConsentOutcome: Codable, Equatable, Sendable {
    public let app: String
    public let bundleIdentifier: String
    public let granted: Bool
    public let detail: String?

    public init(app: String, bundleIdentifier: String, granted: Bool, detail: String?) {
        self.app = app
        self.bundleIdentifier = bundleIdentifier
        self.granted = granted
        self.detail = detail
    }
}

public struct AutomationRequestReport: Codable, Equatable, Sendable {
    public let need: ConsentNeed
    /// Empty when no supported browser is running.
    public let outcomes: [ConsentOutcome]

    public init(need: ConsentNeed, outcomes: [ConsentOutcome]) {
        self.need = need
        self.outcomes = outcomes
    }
}

// MARK: - Errors the shell renders

/// The typed refusals shell-v1 names, read off a JSON-RPC error.
public enum DaemonRefusal: Equatable, Sendable {
    /// `-32004` with `code: accessibility-denied`: the daemon lacks the Accessibility grant.
    case accessibilityDenied
    /// `-32005` `recording-active`.
    case recordingActive
    /// `-32005` `recording-inactive`.
    case recordingInactive
    /// `-32005` `consent-in-progress`.
    case consentInProgress
    /// `-32004` `capability-unavailable`: the daemon has no code path for this tool at all, such as
    /// `DebugSession` for the `debug.*` methods or `PointerDrag` for `drag` on macOS.
    case notImplemented(capability: String)

    public init?(_ error: JSONRPCError) {
        switch (error.code, error.data?["code"]?.stringValue, error.data?["reason"]?.stringValue) {
        case (-32004, "accessibility-denied", _): self = .accessibilityDenied
        case (-32004, "capability-unavailable", _):
            guard let capability = error.data?["capability"]?.stringValue else { return nil }
            self = .notImplemented(capability: capability)
        case (-32005, _, "recording-active"): self = .recordingActive
        case (-32005, _, "recording-inactive"): self = .recordingInactive
        case (-32005, _, "consent-in-progress"): self = .consentInProgress
        default: return nil
        }
    }

    /// The capability the editor's debugger needs; a daemon without it answers every `debug.*`
    /// method with `.notImplemented(capability: debugSessionCapability)`.
    public static let debugSessionCapability = "DebugSession"
}

/// Why a call to the daemon produced no result.
public enum DaemonCallError: Error, Equatable, CustomStringConvertible {
    /// Nothing is listening on the socket.
    case notRunning(socketPath: String)
    /// The daemon did not answer within the call's bound.
    case timedOut(method: String)
    /// The daemon answered with a JSON-RPC error.
    case rejected(JSONRPCError)
    /// The daemon answered with something this shell cannot read.
    case unreadable(method: String, reason: String)
    case transport(String)

    public var refusal: DaemonRefusal? {
        guard case let .rejected(error) = self else { return nil }
        return DaemonRefusal(error)
    }

    public var description: String {
        switch self {
        case let .notRunning(path): return "Axon daemon not running (\(path))"
        case let .timedOut(method): return "The Axon daemon did not answer \(method) in time"
        case let .rejected(error): return error.message
        case let .unreadable(method, reason): return "The Axon daemon's \(method) answer could not be read: \(reason)"
        case let .transport(reason): return reason
        }
    }
}

/// The shell's view of the daemon: one typed method per shell-v1 call.
public struct DaemonClient: Sendable {
    public typealias Transport = @Sendable (_ request: JSONRPCRequest, _ timeout: TimeInterval) throws -> JSONRPCResponse

    public let socketPath: String
    private let transport: Transport

    public init(socketPath: String) {
        self.init(socketPath: socketPath) { request, timeout in
            try SocketClient(path: socketPath, responseTimeoutSeconds: timeout).send(request)
        }
    }

    public init(socketPath: String, transport: @escaping Transport) {
        self.socketPath = socketPath
        self.transport = transport
    }

    public func health() throws -> DaemonReport {
        try call("health", timeout: ShellContract.Timeout.poll)
    }

    public func recordingStatus() throws -> RecordingStatus {
        try call("recording.status", timeout: ShellContract.Timeout.poll)
    }

    public func startRecording(scope: RecordingScope) throws -> RecordingStatus {
        try call("recording.start", params: .object(["scope": try scope.jsonValue()]), timeout: ShellContract.Timeout.action)
    }

    public func stopRecording() throws -> RecordingResult {
        try call("recording.stop", timeout: ShellContract.Timeout.action)
    }

    public func permit() throws -> PermitResult {
        try call("permit", timeout: ShellContract.Timeout.action)
    }

    public func automationStatus() throws -> AutomationStatusReport {
        try call("automation.status", timeout: ShellContract.Timeout.poll)
    }

    public func requestAutomation() throws -> AutomationRequestReport {
        try call("automation.request", timeout: ShellContract.Timeout.consentRequest)
    }

    private func call<T: Decodable>(
        _ method: String,
        params: JSONValue = .object([:]),
        timeout: TimeInterval
    ) throws -> T {
        let response: JSONRPCResponse
        do {
            response = try transport(JSONRPCRequest(id: .string("menu"), method: method, params: params), timeout)
        } catch let SocketError.operationFailed(operation, code) where operation == "connect" && [ENOENT, ECONNREFUSED].contains(code) {
            throw DaemonCallError.notRunning(socketPath: socketPath)
        } catch SocketError.readTimedOut {
            throw DaemonCallError.timedOut(method: method)
        } catch let error as DecodingError {
            throw DaemonCallError.unreadable(method: method, reason: String(describing: error))
        } catch {
            throw DaemonCallError.transport(String(describing: error))
        }
        if let error = response.error {
            throw DaemonCallError.rejected(error)
        }
        do {
            let encoded = try JSONEncoder().encode(JSONValue.object(response.result ?? [:]))
            return try JSONDecoder().decode(T.self, from: encoded)
        } catch {
            throw DaemonCallError.unreadable(method: method, reason: String(describing: error))
        }
    }
}
