//! Whether this process can use the Accessibility API *right now*.
//!
//! `AXIsProcessTrusted()` answers with a per-process verdict that HIServices resolves once and does
//! not revisit. Measured on bglab-mac (2026-09-03) it is frozen in both directions: a daemon that
//! was trusted at launch keeps reporting trusted after the user revokes the grant, and a daemon
//! that started untrusted keeps reporting untrusted after the user restores it. Only a fresh
//! process is honest.
//!
//! The API's behaviour and the cached verdict disagree, and the cached verdict is the wrong one:
//! in the same measurement, AX reads failed on a process whose cached verdict still said trusted.
//! Behaviour is therefore the source this module asks, and the cached verdict is only the fallback
//! for a status that does not settle the question.
//!
//! Which `AXError` a withdrawn grant produces has not been measured yet — `kAXErrorAPIDisabled` is
//! the documented meaning of "the API is off for this caller", and it is what `classify` keys on,
//! but the live revoke/re-grant run that confirms it is still pending. That is why the ladder
//! below is built to fail safe rather than to be right: every status it does not recognise leaves
//! the pre-existing answer untouched. `axon-mac probe trust` is the harness that closes it.
//! See docs/cross-platform-internals.md.

use std::{
    ffi::{CString, c_char, c_void},
    ptr::null,
};

type CFTypeRef = *const c_void;
type CFStringRef = *const c_void;
type CFDictionaryRef = *const c_void;
type AXUIElementRef = *const c_void;

const UTF8: u32 = 0x0800_0100;

pub(crate) const AX_ERROR_SUCCESS: i32 = 0;
pub(crate) const AX_ERROR_CANNOT_COMPLETE: i32 = -25204;
pub(crate) const AX_ERROR_ATTRIBUTE_UNSUPPORTED: i32 = -25205;
pub(crate) const AX_ERROR_API_DISABLED: i32 = -25211;
pub(crate) const AX_ERROR_NO_VALUE: i32 = -25212;

/// Seconds the probe will wait for the frontmost application to answer.
///
/// `health` is documented as a probe that stays a truthful liveness signal, and it now runs this
/// call. Without an explicit bound a hung frontmost application would stall it for the AX default.
const PROBE_TIMEOUT_SECONDS: f32 = 0.25;

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) -> bool;
    fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    fn AXUIElementCreateApplication(pid: i32) -> AXUIElementRef;
    fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: *mut CFTypeRef,
    ) -> i32;
    fn AXUIElementSetMessagingTimeout(element: AXUIElementRef, timeout: f32) -> i32;
}
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringCreateWithCString(
        alloc: *const c_void,
        text: *const c_char,
        encoding: u32,
    ) -> CFStringRef;
    fn CFRelease(value: CFTypeRef);
}

struct Owned(CFTypeRef);
impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CFRelease(self.0) }
        }
    }
}

/// What an Accessibility call just said about this process's access.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AxAccess {
    /// The call was served, so the API is on for this process.
    Granted,
    /// The API answered `kAXErrorAPIDisabled`, so it is off for this process.
    Denied,
    /// The status does not distinguish an unresponsive target from a denial.
    Unknown,
}

impl AxAccess {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Granted => "granted",
            Self::Denied => "denied",
            Self::Unknown => "unknown",
        }
    }

    /// Combine two observations from one sweep of AX calls.
    ///
    /// `Denied` wins, because a single `kAXErrorAPIDisabled` proves the API is off for the whole
    /// process; a target that merely failed to answer cannot outvote it. `Granted` outranks
    /// `Unknown` for the mirror reason: one served call proves the API is on.
    pub(crate) fn fold(self, other: Self) -> Self {
        match (self, other) {
            (Self::Denied, _) | (_, Self::Denied) => Self::Denied,
            (Self::Granted, _) | (_, Self::Granted) => Self::Granted,
            _ => Self::Unknown,
        }
    }
}

/// What an `AXError` says about access, erring toward leaving today's answer in place.
///
/// `kAXErrorNoValue` and `kAXErrorAttributeUnsupported` mean the call was *served* — a session with
/// nothing focused must not read as denied. `kAXErrorCannotComplete` is ambiguous between an
/// unresponsive target and a denial, so it defers to the cached verdict rather than flipping it.
/// Only `kAXErrorAPIDisabled` makes a trusted-looking process denied, which is why this ladder is
/// safe to run ahead of the live measurement: in the granted case it can only answer `Granted` or
/// `Unknown`, and both preserve the pre-existing behaviour.
pub(crate) fn classify(status: i32) -> AxAccess {
    match status {
        AX_ERROR_SUCCESS | AX_ERROR_NO_VALUE | AX_ERROR_ATTRIBUTE_UNSUPPORTED => AxAccess::Granted,
        AX_ERROR_API_DISABLED => AxAccess::Denied,
        _ => AxAccess::Unknown,
    }
}

fn cfstring(value: &str) -> Option<Owned> {
    let text = CString::new(value).ok()?;
    let value = unsafe { CFStringCreateWithCString(null(), text.as_ptr(), UTF8) };
    (!value.is_null()).then(|| Owned(value))
}

/// The raw `AXError` from reading an attribute off an element, releasing anything it hands back.
fn read_status(element: AXUIElementRef, attribute: &str) -> i32 {
    let Some(attribute) = cfstring(attribute) else {
        return AX_ERROR_CANNOT_COMPLETE;
    };
    if element.is_null() {
        return AX_ERROR_CANNOT_COMPLETE;
    }
    let element = Owned(element);
    unsafe { AXUIElementSetMessagingTimeout(element.0, PROBE_TIMEOUT_SECONDS) };
    let mut value = null();
    let status = unsafe { AXUIElementCopyAttributeValue(element.0, attribute.0, &mut value) };
    drop((!value.is_null()).then(|| Owned(value)));
    status
}

/// The raw `AXError` from asking the system-wide element for the focused application.
pub(crate) fn system_wide_status() -> i32 {
    read_status(
        unsafe { AXUIElementCreateSystemWide() },
        "AXFocusedApplication",
    )
}

/// The raw `AXError` from the `AXTitle` read that application enumeration actually makes.
pub(crate) fn application_title_status(pid: i32) -> i32 {
    read_status(unsafe { AXUIElementCreateApplication(pid) }, "AXTitle")
}

/// Ask the Accessibility API to do a trivial piece of work and classify what it says.
pub(crate) fn probe() -> AxAccess {
    classify(system_wide_status())
}

/// The one answer the backend acts on: behaviour first, the cached verdict only when behaviour is
/// inconclusive.
pub(crate) fn granted() -> bool {
    match probe() {
        AxAccess::Granted => true,
        AxAccess::Denied => false,
        AxAccess::Unknown => cached_trust(),
    }
}

/// `AXIsProcessTrusted()` — the verdict resolved at process start.
pub(crate) fn cached_trust() -> bool {
    unsafe { AXIsProcessTrusted() }
}

/// `AXIsProcessTrustedWithOptions(NULL)` — the candidate cheap live check, measured by the probe.
pub(crate) fn trust_with_options() -> bool {
    unsafe { AXIsProcessTrustedWithOptions(null()) }
}

/// One sample of every trust signal side by side, so a revoke/re-grant toggle separates "the
/// verdict is cached" from "the API is disabled" without any inference.
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TrustObservation {
    pub ax_is_process_trusted: bool,
    pub ax_is_process_trusted_with_options: bool,
    pub system_wide_status: i32,
    pub pid: Option<i32>,
    pub pid_status: Option<i32>,
    pub derived: &'static str,
    pub granted: bool,
}

pub(crate) fn observe(pid: Option<i32>) -> TrustObservation {
    let system_wide_status = system_wide_status();
    let derived = classify(system_wide_status);
    let cached = cached_trust();
    TrustObservation {
        ax_is_process_trusted: cached,
        ax_is_process_trusted_with_options: trust_with_options(),
        system_wide_status,
        pid,
        pid_status: pid.map(application_title_status),
        derived: derived.name(),
        granted: match derived {
            AxAccess::Granted => true,
            AxAccess::Denied => false,
            AxAccess::Unknown => cached,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The safety argument for the whole design, so this one is exhaustive over the statuses that
    /// carry meaning: only `kAXErrorAPIDisabled` may flip a trusted-looking process to denied.
    #[test]
    fn classify_maps_every_meaningful_status() {
        for (status, expected) in [
            (AX_ERROR_SUCCESS, AxAccess::Granted),
            (AX_ERROR_NO_VALUE, AxAccess::Granted),
            (AX_ERROR_ATTRIBUTE_UNSUPPORTED, AxAccess::Granted),
            (AX_ERROR_API_DISABLED, AxAccess::Denied),
            (AX_ERROR_CANNOT_COMPLETE, AxAccess::Unknown),
            (-25202, AxAccess::Unknown),
            (-1, AxAccess::Unknown),
        ] {
            assert_eq!(classify(status), expected, "AXError {status}");
        }
    }

    #[test]
    fn denied_wins_a_fold_and_granted_outranks_unknown() {
        assert_eq!(
            AxAccess::Granted.fold(AxAccess::Denied),
            AxAccess::Denied,
            "one disabled call proves the API is off for the process"
        );
        assert_eq!(AxAccess::Denied.fold(AxAccess::Granted), AxAccess::Denied);
        assert_eq!(AxAccess::Unknown.fold(AxAccess::Granted), AxAccess::Granted);
        assert_eq!(AxAccess::Unknown.fold(AxAccess::Unknown), AxAccess::Unknown);
    }

    /// Manual: run from a terminal whose responsible process lacks the Accessibility grant.
    ///
    /// `cargo test -p axon-mac -- --ignored probe_reports_denied_without_accessibility_trust`
    /// Left out of the CI gate because it asserts on host TCC state the build slot cannot set. The
    /// first assertion guards the premise: run inside a trusted process this measures nothing, and
    /// saying so is more useful than a verdict mismatch.
    #[test]
    #[ignore = "asserts on host Accessibility TCC state"]
    fn probe_reports_denied_without_accessibility_trust() {
        assert!(
            !cached_trust(),
            "this process holds the Accessibility grant, so it cannot measure a denial; run the \
             test from a terminal whose responsible process is not in the Accessibility list"
        );
        assert_eq!(
            probe(),
            AxAccess::Denied,
            "system-wide status {}",
            system_wide_status()
        );
        assert!(!granted());
    }
}
