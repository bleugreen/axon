import Foundation

/// The versioned status document Axon publishes from `axon status --json`.
///
/// This mirrors `rust/axon-core/src/health.rs`; both are described by `schema/health-v1.schema.json`
/// and both are tested against the fixtures in `schema/fixtures/health`. Two types live here and
/// they are deliberately different. `HealthStatus` is the published contract a consumer parses.
/// `DaemonReport` is the internal payload the daemon answers a `health` request with, carrying only
/// the facts the daemon process is authoritative about. Start-at-login registration is not one of
/// them — the CLI owns that — so the CLI composes the two into the published document.
///
/// Degradation is data. A daemon that is not running, a Mac with no logged-in console session, and
/// a denied Accessibility grant all produce schema-valid documents rather than errors.

/// The identity of this contract, distinct from the product SemVer in `HealthStatus.version`.
public let healthSchemaVersion = "health-v1"

public enum HealthSchemaError: Error, CustomStringConvertible {
    case unsupportedSchemaVersion(String)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(found):
            return "unsupported health schema version \"\(found)\"; this build speaks \(healthSchemaVersion)"
        }
    }
}

public struct DaemonProvenance: Codable, Equatable, Sendable {
    public var backend: String
    public var processId: Int
    public var executablePath: String
    public var version: String

    public init(backend: String, processId: Int, executablePath: String, version: String) {
        self.backend = backend
        self.processId = processId
        self.executablePath = executablePath
        self.version = version
    }
}

/// Encodes as the literal `health-v1` and refuses to decode any other schema major.
public struct HealthSchemaVersion: Codable, Equatable, Sendable {
    public init() {}

    public init(from decoder: Decoder) throws {
        let found = try decoder.singleValueContainer().decode(String.self)
        guard found == healthSchemaVersion else {
            throw HealthSchemaError.unsupportedSchemaVersion(found)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(healthSchemaVersion)
    }
}

public enum HealthPlatform: String, Codable, Equatable, Sendable {
    case macos
    case windows
    case linux
}

/// The platform-native mechanism that starts the daemon at login.
public enum RegistrationMechanism: String, Codable, Equatable, Sendable {
    case launchd
    case scheduledTask
    case systemdUser
}

/// Stable machine-readable reason codes.
///
/// New codes may be added within `health-v1`, so a consumer must treat an unrecognized code as an
/// unspecified degradation rather than a parse failure. The registry is documented in
/// `docs/embedding.md`.
public enum HealthReason {
    /// No daemon answered on the local socket.
    public static let daemonNotRunning = "daemon-not-running"
    /// A daemon answered but its accessibility backend has not finished initializing.
    public static let daemonNotReady = "daemon-not-ready"
    /// A daemon appears to exist but the round trip failed or timed out.
    public static let daemonUnreachable = "daemon-unreachable"
    /// No platform-native start-at-login registration is present.
    public static let notRegistered = "not-registered"
    /// The reporting process is in a service session rather than a logged-in user session.
    public static let notInteractiveSession = "not-interactive-session"
    /// The user session has no usable desktop; the host may be at a login window.
    public static let noGraphicalSession = "no-graphical-session"
    /// macOS has not granted Accessibility trust to the daemon identity.
    public static let accessibilityNotGranted = "accessibility-not-granted"
    /// macOS has not granted Screen Recording to the daemon identity.
    public static let screenRecordingNotGranted = "screen-recording-not-granted"
    /// A daemon answered, but not with a health document this build can read. The running daemon
    /// is a different version from the CLI asking it.
    public static let versionSkew = "version-skew"
    /// This build does not implement the capability on this platform.
    public static let notImplemented = "not-implemented"
    /// The state could not be determined and no more specific code applies.
    public static let unknown = "unknown"
}

/// The permission gates Axon reports on macOS.
public enum HealthPermission {
    public static let accessibility = "accessibility"
    public static let screenRecording = "screenRecording"

    /// Every gate macOS applies, in the order health documents report them.
    public static let all = [accessibility, screenRecording]
}

/// The capability vocabulary, mirrored by `Capability` in `rust/axon-core/src/backend.rs` and by
/// `knownCapabilities` in `schema/health-v1.schema.json`.
public enum AxonCapability: String, CaseIterable, Codable, Equatable, Sendable {
    case enumerate
    case capture
    case retainedHandles
    case observeChanges
    case invoke
    case readValue
    case setValue
    case focus
    case scroll
    case pointerInput
    case keyboardInput
    case screenshot
    case hitTest
    case serializeHistory
    case observeGlobalInput
}

public struct DaemonHealth: Codable, Equatable, Sendable {
    public var running: Bool
    public var ready: Bool
    public var endpoint: String
    public var provenance: DaemonProvenance?
    public var processId: Int?
    public var reason: String?
    public var detail: String?

    public init(
        running: Bool,
        ready: Bool,
        endpoint: String,
        provenance: DaemonProvenance? = nil,
        processId: Int? = nil,
        reason: String? = nil,
        detail: String? = nil
    ) {
        self.running = running
        self.ready = ready
        self.endpoint = endpoint
        self.provenance = provenance
        self.processId = processId
        self.reason = reason
        self.detail = detail
    }
}

public struct RegistrationHealth: Codable, Equatable, Sendable {
    public var registered: Bool
    public var mechanism: RegistrationMechanism
    public var path: String?
    public var reason: String?
    public var detail: String?

    public init(
        registered: Bool,
        mechanism: RegistrationMechanism,
        path: String? = nil,
        reason: String? = nil,
        detail: String? = nil
    ) {
        self.registered = registered
        self.mechanism = mechanism
        self.path = path
        self.reason = reason
        self.detail = detail
    }

    public static func absent(mechanism: RegistrationMechanism = .launchd) -> RegistrationHealth {
        RegistrationHealth(registered: false, mechanism: mechanism, reason: HealthReason.notRegistered)
    }

    public static func present(
        mechanism: RegistrationMechanism = .launchd,
        path: String
    ) -> RegistrationHealth {
        RegistrationHealth(registered: true, mechanism: mechanism, path: path)
    }
}

public struct SessionHealth: Codable, Equatable, Sendable {
    public var interactive: Bool
    public var graphical: Bool
    /// Whether the session's own accessibility switch is on, where the platform has one.
    ///
    /// `nil` is no claim rather than false. macOS has no such switch, so this build never sets it;
    /// it is carried because a Linux document reports `org.a11y.Status.IsEnabled` here, and both
    /// languages parse every health document rather than only their own platform's.
    public var accessibilityEnabled: Bool?
    public var reason: String?
    public var detail: String?

    public init(
        interactive: Bool,
        graphical: Bool,
        accessibilityEnabled: Bool? = nil,
        reason: String? = nil,
        detail: String? = nil
    ) {
        self.interactive = interactive
        self.graphical = graphical
        self.accessibilityEnabled = accessibilityEnabled
        self.reason = reason
        self.detail = detail
    }
}

public struct PermissionState: Codable, Equatable, Sendable {
    public var name: String
    public var granted: Bool
    public var reason: String?
    public var detail: String?

    public init(name: String, granted: Bool, reason: String? = nil, detail: String? = nil) {
        self.name = name
        self.granted = granted
        self.reason = reason
        self.detail = detail
    }
}

/// One capability's usability.
///
/// `capability` stays a `String` rather than `AxonCapability` on purpose: a consumer built against
/// an older vocabulary must still parse a document from a newer Axon that reports a capability it
/// has never heard of.
public struct CapabilityState: Codable, Equatable, Sendable {
    public var capability: String
    public var usable: Bool
    public var reason: String?
    public var restriction: String?

    public init(capability: String, usable: Bool, reason: String? = nil, restriction: String? = nil) {
        self.capability = capability
        self.usable = usable
        self.reason = reason
        self.restriction = restriction
    }

    public init(
        _ capability: AxonCapability,
        usable: Bool,
        reason: String? = nil,
        restriction: String? = nil
    ) {
        self.init(capability: capability.rawValue, usable: usable, reason: reason, restriction: restriction)
    }

    /// The complete capability map with every entry unusable for one shared reason, used when no
    /// backend is available to ask — most often because the daemon is not running.
    public static func allUnusable(reason: String) -> [CapabilityState] {
        AxonCapability.allCases.map { CapabilityState($0, usable: false, reason: reason) }
    }
}

/// The daemon-authored answer to a `health` request.
///
/// Internal transport between the CLI and the daemon it manages, not the published contract. It
/// carries no registration because the daemon process does not own that fact.
public struct DaemonReport: Codable, Equatable, Sendable {
    public var version: String
    public var platform: HealthPlatform
    /// True only once the daemon is serving requests, never merely because the socket exists.
    public var ready: Bool
    public var processId: Int
    public var endpoint: String
    public var session: SessionHealth
    public var permissions: [PermissionState]
    public var capabilities: [CapabilityState]

    public init(
        version: String = AxonVersion.current,
        platform: HealthPlatform = .macos,
        ready: Bool,
        processId: Int,
        endpoint: String,
        session: SessionHealth,
        permissions: [PermissionState],
        capabilities: [CapabilityState]
    ) {
        self.version = version
        self.platform = platform
        self.ready = ready
        self.processId = processId
        self.endpoint = endpoint
        self.session = session
        self.permissions = permissions
        self.capabilities = capabilities
    }
}

public extension DaemonReport {
    /// The report as a JSON-RPC result object, which is how the daemon answers a `health` request.
    func jsonObject() throws -> [String: JSONValue] {
        let encoded = try JSONEncoder().encode(self)
        guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: encoded) else {
            throw HealthSchemaError.unsupportedSchemaVersion("non-object daemon report")
        }
        return object
    }

    /// Reads a report back out of a JSON-RPC result object.
    init(jsonObject: [String: JSONValue]) throws {
        let encoded = try JSONEncoder().encode(JSONValue.object(jsonObject))
        self = try JSONDecoder().decode(DaemonReport.self, from: encoded)
    }
}

/// The published `health-v1` document.
public struct HealthStatus: Codable, Equatable, Sendable {
    public var schemaVersion: HealthSchemaVersion
    public var version: String
    public var platform: HealthPlatform
    public var daemon: DaemonHealth
    public var registration: RegistrationHealth
    public var session: SessionHealth
    public var permissions: [PermissionState]
    public var capabilities: [CapabilityState]

    public init(
        version: String,
        platform: HealthPlatform,
        daemon: DaemonHealth,
        registration: RegistrationHealth,
        session: SessionHealth,
        permissions: [PermissionState],
        capabilities: [CapabilityState]
    ) {
        self.schemaVersion = HealthSchemaVersion()
        self.version = version
        self.platform = platform
        self.daemon = daemon
        self.registration = registration
        self.session = session
        self.permissions = permissions
        self.capabilities = capabilities
    }

    /// Composes a daemon's own report with the registration the CLI observed.
    public static func running(
        daemon report: DaemonReport,
        registration: RegistrationHealth
    ) -> HealthStatus {
        HealthStatus(
            version: report.version,
            platform: report.platform,
            daemon: DaemonHealth(
                running: true,
                ready: report.ready,
                endpoint: report.endpoint,
                processId: report.processId,
                reason: report.ready ? nil : HealthReason.daemonNotReady
            ),
            registration: registration,
            session: report.session,
            permissions: report.permissions,
            capabilities: report.capabilities
        )
    }

    /// Describes a daemon that answered with something this build cannot read.
    ///
    /// A consumer that pins a version and upgrades in place will hit exactly this: the new binary
    /// on disk, the old daemon still serving. Calling that "not running" would send an operator
    /// looking for a process that is right there, so the document says a daemon is running, is not
    /// ready, and does not match.
    public static func incompatible(
        version: String = AxonVersion.current,
        platform: HealthPlatform = .macos,
        endpoint: String,
        registration: RegistrationHealth,
        session: SessionHealth,
        detail: String? = nil
    ) -> HealthStatus {
        HealthStatus(
            version: version,
            platform: platform,
            daemon: DaemonHealth(
                running: true,
                ready: false,
                endpoint: endpoint,
                reason: HealthReason.versionSkew,
                detail: detail
            ),
            registration: registration,
            session: session,
            permissions: [],
            capabilities: CapabilityState.allUnusable(reason: HealthReason.versionSkew)
        )
    }

    /// Describes a machine whose daemon did not answer.
    ///
    /// Permissions cannot be confirmed without the daemon — the CLI's own process identity is not
    /// the daemon's, so asking macOS here would answer a different question — so each gate is
    /// reported ungranted with the reason it could not be determined.
    public static func notRunning(
        version: String = AxonVersion.current,
        platform: HealthPlatform = .macos,
        endpoint: String,
        registration: RegistrationHealth,
        session: SessionHealth,
        reason: String,
        detail: String? = nil,
        permissionNames: [String] = HealthPermission.all
    ) -> HealthStatus {
        HealthStatus(
            version: version,
            platform: platform,
            daemon: DaemonHealth(
                running: false,
                ready: false,
                endpoint: endpoint,
                reason: reason,
                detail: detail
            ),
            registration: registration,
            session: session,
            permissions: permissionNames.map {
                PermissionState(name: $0, granted: false, reason: reason)
            },
            capabilities: CapabilityState.allUnusable(reason: reason)
        )
    }

    /// The document as a single line of JSON, which is what `status --json` writes to stdout.
    public func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
