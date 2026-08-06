//! The versioned status document Axon publishes from `status --json` on every platform.
//!
//! Two types live here and they are deliberately different. [`HealthReport`] is the published
//! `health-v1` contract described by `schema/health-v1.schema.json`; it is what a consumer parses.
//! [`DaemonReport`] is the internal payload the daemon answers a `health` RPC with, carrying only
//! the facts the daemon process is authoritative about. Start-at-login registration is not one of
//! them — it is owned by the CLI — so the CLI composes the two into the published document.
//!
//! Degradation is data. A daemon that is not running, a host sitting at a login greeter, and a
//! denied Accessibility grant all produce schema-valid documents rather than transport errors.

use crate::{Capability, CapabilityInfo};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// The identity of this contract. Distinct from the product SemVer in [`HealthReport::version`].
pub const HEALTH_SCHEMA_VERSION: &str = "health-v1";

/// Stable machine-readable reason codes.
///
/// New codes may be added within `health-v1`, so a consumer must treat an unrecognized code as an
/// unspecified degradation rather than a parse failure. The registry is documented in
/// `docs/embedding.md`.
pub mod reason {
    /// No daemon answered on the local transport.
    pub const DAEMON_NOT_RUNNING: &str = "daemon-not-running";
    /// A daemon answered but its accessibility backend has not finished initializing.
    pub const DAEMON_NOT_READY: &str = "daemon-not-ready";
    /// A daemon appears to exist but the round trip failed or timed out.
    pub const DAEMON_UNREACHABLE: &str = "daemon-unreachable";
    /// No platform-native start-at-login registration is present.
    pub const NOT_REGISTERED: &str = "not-registered";
    /// The reporting process is in a service session rather than a logged-in user session.
    pub const NOT_INTERACTIVE_SESSION: &str = "not-interactive-session";
    /// The user session has no usable desktop; the host may be at a login greeter.
    pub const NO_GRAPHICAL_SESSION: &str = "no-graphical-session";
    /// macOS has not granted Accessibility trust to the daemon identity.
    pub const ACCESSIBILITY_NOT_GRANTED: &str = "accessibility-not-granted";
    /// macOS has not granted Screen Recording to the daemon identity.
    pub const SCREEN_RECORDING_NOT_GRANTED: &str = "screen-recording-not-granted";
    /// The user's session D-Bus is not reachable.
    pub const SESSION_BUS_UNAVAILABLE: &str = "session-bus-unavailable";
    /// The AT-SPI accessibility bus is absent or refused a connection.
    pub const ATSPI_UNAVAILABLE: &str = "atspi-unavailable";
    /// Wayland's security model forbids the operation for an unprivileged client.
    pub const WAYLAND_RESTRICTED: &str = "wayland-restricted";
    /// A desktop portal authorization flow is required before the operation can run.
    pub const PORTAL_AUTHORIZATION_REQUIRED: &str = "portal-authorization-required";
    /// This build does not implement the capability on this platform.
    pub const NOT_IMPLEMENTED: &str = "not-implemented";
    /// The state could not be determined and no more specific code applies.
    pub const UNKNOWN: &str = "unknown";
}

/// Serializes as the literal `health-v1` and refuses to deserialize any other schema major.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct HealthSchemaVersion;

impl Serialize for HealthSchemaVersion {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(HEALTH_SCHEMA_VERSION)
    }
}

impl<'de> Deserialize<'de> for HealthSchemaVersion {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        if value == HEALTH_SCHEMA_VERSION {
            Ok(Self)
        } else {
            Err(serde::de::Error::custom(format!(
                "unsupported health schema version {value:?}; this build speaks {HEALTH_SCHEMA_VERSION}"
            )))
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HealthPlatform {
    Macos,
    Windows,
    Linux,
}

/// The platform-native mechanism that starts the daemon at login.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RegistrationMechanism {
    Launchd,
    ScheduledTask,
    SystemdUser,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DaemonHealth {
    pub running: bool,
    pub ready: bool,
    pub endpoint: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub process_id: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegistrationHealth {
    pub registered: bool,
    pub mechanism: RegistrationMechanism,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl RegistrationHealth {
    pub fn absent(mechanism: RegistrationMechanism) -> Self {
        Self {
            registered: false,
            mechanism,
            path: None,
            reason: Some(reason::NOT_REGISTERED.into()),
            detail: None,
        }
    }

    pub fn present(mechanism: RegistrationMechanism, path: impl Into<String>) -> Self {
        Self {
            registered: true,
            mechanism,
            path: Some(path.into()),
            reason: None,
            detail: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionHealth {
    pub interactive: bool,
    pub graphical: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl SessionHealth {
    pub fn usable(detail: Option<String>) -> Self {
        Self {
            interactive: true,
            graphical: true,
            reason: None,
            detail,
        }
    }

    pub fn degraded(
        interactive: bool,
        graphical: bool,
        reason: &str,
        detail: Option<String>,
    ) -> Self {
        Self {
            interactive,
            graphical,
            reason: Some(reason.into()),
            detail,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionState {
    pub name: String,
    pub granted: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// One capability's usability.
///
/// `capability` stays a `String` rather than an enum on purpose: a consumer built against an older
/// vocabulary must still parse a document from a newer Axon that reports a capability it has never
/// heard of.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityState {
    pub capability: String,
    pub usable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restriction: Option<String>,
}

impl CapabilityState {
    /// Builds the complete capability map from what a backend reported.
    ///
    /// The published document always carries one entry per known capability. A backend that simply
    /// omits a capability it does not implement would otherwise be indistinguishable, to a
    /// consumer, from an Axon older than the consumer's own vocabulary; reporting it present and
    /// unusable answers the question instead of leaving a hole.
    pub fn complete(reported: &[CapabilityInfo]) -> Vec<Self> {
        Capability::ALL
            .iter()
            .map(|capability| {
                match reported.iter().find(|info| info.capability == *capability) {
                    Some(info) if info.usable => Self {
                        capability: capability.key().into(),
                        usable: true,
                        reason: None,
                        restriction: None,
                    },
                    Some(info) => Self {
                        capability: capability.key().into(),
                        usable: false,
                        reason: Some(
                            info.restriction
                                .as_deref()
                                .map_or(reason::NOT_IMPLEMENTED, classify_restriction)
                                .into(),
                        ),
                        restriction: info.restriction.clone(),
                    },
                    None => Self {
                        capability: capability.key().into(),
                        usable: false,
                        reason: Some(reason::NOT_IMPLEMENTED.into()),
                        restriction: None,
                    },
                }
            })
            .collect()
    }

    /// The complete capability map with every entry unusable for one shared reason, used when no
    /// backend is available to ask — most often because the daemon is not running.
    pub fn all_unusable(code: &str) -> Vec<Self> {
        Capability::ALL
            .iter()
            .map(|capability| Self {
                capability: capability.key().into(),
                usable: false,
                reason: Some(code.into()),
                restriction: None,
            })
            .collect()
    }
}

/// Maps a backend's human-readable restriction onto a stable reason code.
///
/// Backends explain themselves in prose, which is useful to a person and useless to a program.
/// This is the one place that prose is turned into something a consumer can branch on.
fn classify_restriction(restriction: &str) -> &'static str {
    let lowered = restriction.to_ascii_lowercase();
    if lowered.contains("wayland") {
        reason::WAYLAND_RESTRICTED
    } else if lowered.contains("portal") {
        reason::PORTAL_AUTHORIZATION_REQUIRED
    } else {
        reason::NOT_IMPLEMENTED
    }
}

/// The daemon-authored answer to a `health` RPC.
///
/// Internal transport between a CLI and the daemon it manages, not the published contract. It
/// carries no registration because the daemon process does not own that fact.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DaemonReport {
    pub version: String,
    pub platform: HealthPlatform,
    /// True only once the accessibility backend finished initializing, never merely because the
    /// transport accepted a connection.
    pub ready: bool,
    pub process_id: u32,
    pub endpoint: String,
    pub session: SessionHealth,
    pub permissions: Vec<PermissionState>,
    pub capabilities: Vec<CapabilityState>,
}

/// The published `health-v1` document.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthReport {
    pub schema_version: HealthSchemaVersion,
    pub version: String,
    pub platform: HealthPlatform,
    pub daemon: DaemonHealth,
    pub registration: RegistrationHealth,
    pub session: SessionHealth,
    pub permissions: Vec<PermissionState>,
    pub capabilities: Vec<CapabilityState>,
}

impl HealthReport {
    /// Composes a daemon's own report with the registration the CLI observed.
    pub fn running(daemon: DaemonReport, registration: RegistrationHealth) -> Self {
        Self {
            schema_version: HealthSchemaVersion,
            version: daemon.version,
            platform: daemon.platform,
            daemon: DaemonHealth {
                running: true,
                ready: daemon.ready,
                endpoint: daemon.endpoint,
                process_id: Some(daemon.process_id),
                reason: (!daemon.ready).then(|| reason::DAEMON_NOT_READY.into()),
                detail: None,
            },
            registration,
            session: daemon.session,
            permissions: daemon.permissions,
            capabilities: daemon.capabilities,
        }
    }

    /// Describes a machine whose daemon did not answer.
    ///
    /// The caller supplies the permissions because what the CLI can honestly say about them varies:
    /// a gate the CLI can rule out from the session alone is worth reporting as such, while one
    /// only the daemon could have answered is reported ungranted with the reason it could not be
    /// determined.
    pub fn not_running(
        version: impl Into<String>,
        platform: HealthPlatform,
        endpoint: impl Into<String>,
        registration: RegistrationHealth,
        session: SessionHealth,
        code: &str,
        detail: Option<String>,
        permissions: Vec<PermissionState>,
    ) -> Self {
        Self {
            schema_version: HealthSchemaVersion,
            version: version.into(),
            platform,
            daemon: DaemonHealth {
                running: false,
                ready: false,
                endpoint: endpoint.into(),
                process_id: None,
                reason: Some(code.into()),
                detail,
            },
            registration,
            session,
            permissions,
            capabilities: CapabilityState::all_unusable(code),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn info(capability: Capability, usable: bool, restriction: Option<&str>) -> CapabilityInfo {
        CapabilityInfo {
            capability,
            usable,
            restriction: restriction.map(Into::into),
        }
    }

    #[test]
    fn complete_map_reports_every_known_capability() {
        let states = CapabilityState::complete(&[info(Capability::Enumerate, true, None)]);

        assert_eq!(states.len(), Capability::ALL.len());
        assert!(states[0].usable);
        let unreported = states
            .iter()
            .find(|state| state.capability == "screenshot")
            .unwrap();
        assert!(!unreported.usable);
        assert_eq!(unreported.reason.as_deref(), Some(reason::NOT_IMPLEMENTED));
    }

    #[test]
    fn backend_restrictions_become_stable_reason_codes() {
        let states = CapabilityState::complete(&[
            info(
                Capability::PointerInput,
                false,
                Some("Wayland does not permit unrestricted synthetic pointer input"),
            ),
            info(
                Capability::Screenshot,
                false,
                Some("a desktop portal authorization flow is required"),
            ),
            info(
                Capability::Scroll,
                false,
                Some("AT-SPI has no portable delta-scroll operation"),
            ),
        ]);
        let reason_for = |key: &str| {
            states
                .iter()
                .find(|state| state.capability == key)
                .unwrap()
                .reason
                .clone()
                .unwrap()
        };

        assert_eq!(reason_for("pointerInput"), reason::WAYLAND_RESTRICTED);
        assert_eq!(
            reason_for("screenshot"),
            reason::PORTAL_AUTHORIZATION_REQUIRED
        );
        assert_eq!(reason_for("scroll"), reason::NOT_IMPLEMENTED);
        // The prose survives alongside the code; a person still gets the explanation.
        assert_eq!(
            states
                .iter()
                .find(|state| state.capability == "scroll")
                .unwrap()
                .restriction
                .as_deref(),
            Some("AT-SPI has no portable delta-scroll operation")
        );
    }

    #[test]
    fn an_unready_daemon_is_running_but_not_ready() {
        let report = HealthReport::running(
            DaemonReport {
                version: "0.1.7".into(),
                platform: HealthPlatform::Windows,
                ready: false,
                process_id: 12,
                endpoint: r"\\.\pipe\axon-v1".into(),
                session: SessionHealth::usable(None),
                permissions: vec![],
                capabilities: CapabilityState::all_unusable(reason::DAEMON_NOT_READY),
            },
            RegistrationHealth::absent(RegistrationMechanism::ScheduledTask),
        );

        assert!(report.daemon.running);
        assert!(!report.daemon.ready);
        assert_eq!(report.daemon.reason.as_deref(), Some(reason::DAEMON_NOT_READY));
    }

    #[test]
    fn a_future_schema_major_is_refused() {
        let mut document = json!({
            "schemaVersion": "health-v2",
            "version": "9.0.0",
            "platform": "linux",
            "daemon": {"running": false, "ready": false, "endpoint": "/run/user/1000/axon-v1.sock"},
            "registration": {"registered": false, "mechanism": "systemdUser"},
            "session": {"interactive": true, "graphical": true},
            "permissions": [],
            "capabilities": []
        });

        let error = serde_json::from_value::<HealthReport>(document.clone()).unwrap_err();
        assert!(error.to_string().contains("unsupported health schema version"));

        // The same document at the supported major parses.
        document["schemaVersion"] = json!(HEALTH_SCHEMA_VERSION);
        assert!(serde_json::from_value::<HealthReport>(document).is_ok());
    }

    #[test]
    fn unknown_fields_and_capability_keys_are_tolerated() {
        // Forward compatibility within health-v1: a consumer on this build must still parse a
        // document from a newer Axon that added fields and capabilities it has never heard of.
        let document = json!({
            "schemaVersion": "health-v1",
            "version": "0.9.0",
            "platform": "macos",
            "tenancy": "whatever-comes-next",
            "daemon": {"running": true, "ready": true, "endpoint": "/tmp/axon.sock", "uptimeSeconds": 12},
            "registration": {"registered": true, "mechanism": "launchd"},
            "session": {"interactive": true, "graphical": true},
            "permissions": [],
            "capabilities": [{"capability": "holography", "usable": true}]
        });

        let report: HealthReport = serde_json::from_value(document).unwrap();

        assert_eq!(report.capabilities[0].capability, "holography");
    }
}
