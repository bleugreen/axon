//! The measured Linux acceptance table: which toolkits act on a background, window-targeted
//! `XSendEvent`, which action each one accepts, and how the event has to be sent to be acted on.
//!
//! This is the Linux counterpart of the window-class allowlist in `rust/axon-win/src/pixel.rs`,
//! and it exists for the same reason. `XSendEvent` reports success as soon as the X server accepts
//! the request, and every event it delivers carries `send_event`, which a toolkit is free to
//! ignore. Nothing on the sending side can tell acceptance from silence, so a completed send
//! proves the server took the request and never proves the target acted on it. No runtime
//! pre-flight closes that gap either: a probe that produces no observable effect proves nothing,
//! and one that produces an effect has already mutated the user's window.
//!
//! So the fact is measured once, offline, and committed. `scripts/linux-toolkit-acceptance/` opens
//! a window per toolkit, holds the focus in a decoy, parks the real pointer clear of the target,
//! delivers window-targeted events, and reads back whether the target acted — with two controls, a
//! real-pointer click and a focused keystroke, so a silent target cannot be confused with a
//! misaimed harness. Every entry below cites the fixture rows it was earned from, so the evidence
//! for it is one hop away.
//!
//! An entry is keyed on the AT-SPI toolkit name and version the application declares about itself.
//! That is a fact read at dispatch time rather than an inference from `WM_CLASS` or from loaded
//! libraries, but it is only as precise as the toolkit chooses to be, and these entries claim
//! exactly as much as that signature can carry and no more. Entries name a release series rather
//! than a patch level because that is the granularity a toolkit's own version string supports.
//!
//! Toolkit releases invalidate this table; commits to this repository do not. Re-measure with
//! `scripts/linux-toolkit-acceptance/run`, and again with `--current-display` against a real
//! session.

use std::fmt;

/// How an event has to be sent for a toolkit that accepts it to act on it.
///
/// Measured per toolkit rather than chosen. The two are different routing rules inside the X
/// server, and a toolkit that honours one ignores the other: GTK 3 acts only on `Owner`, while Qt
/// and Chromium act only on `Targeted`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SendVariant {
    /// Sent with the event mask matching the event, which the server routes to whichever clients
    /// selected for it on the destination window.
    Targeted,
    /// Sent with an empty event mask, which the server routes to the client that created the
    /// destination window whatever that client selected for.
    Owner,
}

impl SendVariant {
    /// The name this variant is reported under, matching the `variant` field of the fixtures.
    pub fn key(self) -> &'static str {
        match self {
            SendVariant::Targeted => "targeted",
            SendVariant::Owner => "owner",
        }
    }
}

/// The two actions this backend can carry at the pixel rung.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PixelAction {
    Click,
    Keyboard,
}

impl PixelAction {
    fn described(self) -> &'static str {
        match self {
            PixelAction::Click => "a background click",
            PixelAction::Keyboard => "background keystrokes",
        }
    }
}

/// What an application declares about itself over the AT-SPI `Application` interface: the only
/// dispatch-time signature this table can be keyed on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Toolkit {
    pub name: String,
    pub version: String,
}

impl fmt::Display for Toolkit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.version.is_empty() {
            return write!(f, "{}", self.name);
        }
        write!(f, "{} {}", self.name, self.version)
    }
}

/// Which versions of a toolkit an entry speaks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Versions {
    /// Every version this toolkit reports, because it reports a constant that carries no version.
    /// Only Chromium is like this, and the widening that follows from it is set out below.
    Any,
    /// One release series, named `major.minor`. A version outside it refuses, because a series
    /// nobody measured is a series nobody measured.
    Series(&'static str),
}

impl Versions {
    fn covers(self, version: &str) -> bool {
        match self {
            Versions::Any => true,
            Versions::Series(series) => series_of(version) == series_of(series),
        }
    }

    fn described(self) -> String {
        match self {
            Versions::Any => "any version".to_string(),
            Versions::Series(series) => format!("{series}.x"),
        }
    }
}

/// The `major.minor` prefix of a version string, which is the granularity an entry keys on.
fn series_of(version: &str) -> (&str, &str) {
    let mut parts = version.split('.');
    (parts.next().unwrap_or_default(), parts.next().unwrap_or_default())
}

/// What the harness measured for one toolkit and one action.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Measured {
    /// The toolkit acted on the event, sent this way, with the session focus and the real pointer
    /// provably unchanged, on both lanes.
    Accepted(SendVariant),
    /// The toolkit was measured and the rung is still refused, for the reason given. Carried as
    /// prose rather than as a bare absence because "unsupported" tells a caller nothing they can
    /// act on, and because two of these are judgement calls a reader deserves to see argued.
    Refused(&'static str),
}

/// One toolkit signature, what it accepts, and the evidence.
struct Entry {
    /// Matched case-insensitively: GTK 3 reports `gtk` and GTK 4 reports `GTK`, and a toolkit's
    /// choice of casing is not a fact worth keying on. The version series is what separates them.
    toolkit: &'static str,
    versions: Versions,
    click: Measured,
    keyboard: Measured,
    /// The fixture rows this entry was earned from, cited by path so the evidence is one hop away.
    evidence: &'static str,
}

/// The measured table. A toolkit absent from it refuses, and a toolkit is never added because it
/// looks like it should work.
///
/// Two absences are deliberate rather than untested. **GTK 4** is excluded twice over: it acts on
/// neither event, and its AT-SPI extents report correct sizes at `(0, 0)` origins, so a pixel rung
/// would have no usable coordinate source there even if delivery worked. **Firefox** is excluded
/// despite accepting keystrokes, because it publishes no AT-SPI application at all: the target
/// cannot be identified, its coordinates cannot be converted through resolved geometry, and
/// nothing can be revalidated before dispatch, so every precondition the contract puts on the rung
/// fails before delivery is even reached. It has no signature to key an entry on, which is why its
/// absence here is structural rather than a decision.
///
/// ## The Chromium entry is family-wide, because its signature is
///
/// Chromium reports itself as toolkit `Chromium` version `1.0` — a constant carrying neither the
/// engine version nor the application. No dispatch-time signature distinguishes one Chromium
/// application from another, so an entry keyed on it necessarily authorizes the whole family:
/// every Electron application, every Chromium-based browser, and every future engine release.
/// There is no narrower key to move to, so the choice is this entry or no click rung on Linux at
/// all.
///
/// It is therefore held to a higher evidentiary bar than the rest: three engine generations
/// spanning roughly three years, each measured as its own row on both lanes, rather than one. The
/// residual risk is a future Chromium that begins filtering these events, which would be
/// undetectable by signature — and which degrades to silent non-delivery, a state the contract
/// already refuses to promote to success, because dispatch at this rung is evidence and `success`
/// still requires readback or an `expects` postcondition. The only defence is re-running the
/// harness when the family releases, and that is the maintenance obligation this entry carries.
const ACCEPTANCE: &[Entry] = &[
    Entry {
        toolkit: "Chromium",
        versions: Versions::Any,
        click: Measured::Accepted(SendVariant::Targeted),
        keyboard: Measured::Accepted(SendVariant::Targeted),
        evidence: "scripts/linux-toolkit-acceptance/RESULTS.md and RESULTS-live-x11.md, rows \
                   electron-22 (Chromium 108.0.5359.215), electron-30 (Chromium 124.0.6367.243) \
                   and electron (Chromium 150.0.7871.212): every generation acted on a background \
                   click and on background keystrokes, on both the hermetic Xvfb lane and a live \
                   Xfce X11 session, with the pointer and the session focus unchanged and both \
                   controls reacting",
    },
    Entry {
        toolkit: "gtk",
        versions: Versions::Series("3.24"),
        click: Measured::Refused(
            "GTK 3 does not act on a background click at all. The only synthetic clicks it honours \
             arrive while the real cursor is already inside the target window — the boundary is \
             the window's own edge — and arranging that means moving the user's pointer, which is \
             the foreground rung by definition",
        ),
        keyboard: Measured::Accepted(SendVariant::Owner),
        evidence: "scripts/linux-toolkit-acceptance/RESULTS.md and RESULTS-live-x11.md, rows gtk3 \
                   (GTK 3.24.51) and webkitgtk (WebKitGTK 2.50.4, which reports gtk 3.24.51): \
                   background keystrokes typed into the focused field on both lanes with the \
                   window holding no X input focus, and the background click was refused on both",
    },
    Entry {
        toolkit: "Qt",
        versions: Versions::Series("6.11"),
        click: Measured::Refused(
            "Qt 6 acts on a background click but requests activation while doing so: the X input \
             focus moved on the lane with no window manager, and was held only by xfwm4's \
             focus-stealing prevention on the live one. An acceptance that survives only while a \
             window manager declines to honour the application is not a background delivery",
        ),
        keyboard: Measured::Accepted(SendVariant::Targeted),
        evidence: "scripts/linux-toolkit-acceptance/RESULTS.md and RESULTS-live-x11.md, row qt6 \
                   (Qt 6.11.1): background keystrokes accepted on both lanes without requesting \
                   activation, which is visible because each phase re-establishes and re-proves \
                   the background before it sends anything",
    },
];

/// A cleared toolkit: how the event has to be sent, and the measurement that cleared it.
///
/// The citation travels with the permission rather than sitting beside it, so a dispatch result
/// can say which fixture rows authorized background input into someone's window. That is the
/// question anyone auditing one of these results actually has, and an answer that has to be looked
/// up separately is an answer that goes unread.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Acceptance {
    pub variant: SendVariant,
    pub evidence: &'static str,
}

/// Whether this toolkit was measured to act on this action in the background, and how the event
/// has to be sent if so.
///
/// `Err` carries the whole refusal message, naming the toolkit that refused. A caller told only
/// "unsupported" cannot tell a GTK 4 window from an unmeasured Qt release from a Chromium build
/// that Axon would happily have driven, and those need different things done about them.
pub fn accepts(action: PixelAction, toolkit: &Toolkit) -> Result<Acceptance, String> {
    if toolkit.name.is_empty() {
        return Err(format!(
            "the target application declares no AT-SPI toolkit, so there is no measured signature \
             to decide whether it acts on {} delivered to its window",
            action.described()
        ));
    }
    let named: Vec<&Entry> = ACCEPTANCE
        .iter()
        .filter(|entry| entry.toolkit.eq_ignore_ascii_case(&toolkit.name))
        .collect();
    let Some(entry) = named
        .iter()
        .find(|entry| entry.versions.covers(&toolkit.version))
    else {
        // A toolkit whose name is in the table but whose series is not was not measured, and a
        // series nobody measured refuses while naming what was. A name that is absent entirely
        // refuses more plainly, because there is nothing to compare it against.
        if let Some(known) = named.first() {
            return Err(format!(
                "the target application reports AT-SPI toolkit {toolkit}, and background \
                 window-targeted delivery was measured for {} {} only; a version series nobody \
                 measured refuses rather than being assumed to behave like one that was",
                known.toolkit,
                known.versions.described(),
            ));
        }
        return Err(format!(
            "the target application reports AT-SPI toolkit {toolkit}, which \
             scripts/linux-toolkit-acceptance has not measured as acting on window-targeted \
             XSendEvent delivery"
        ));
    };
    match action {
        PixelAction::Click => entry.click,
        PixelAction::Keyboard => entry.keyboard,
    } {
        Measured::Accepted(variant) => Ok(Acceptance {
            variant,
            evidence: entry.evidence,
        }),
        Measured::Refused(reason) => Err(format!(
            "the target application reports AT-SPI toolkit {toolkit}, which does not accept {} in \
             the background: {reason}",
            action.described()
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toolkit(name: &str, version: &str) -> Toolkit {
        Toolkit {
            name: name.into(),
            version: version.into(),
        }
    }

    #[test]
    fn the_table_offers_exactly_what_the_fixtures_measured() {
        // Chromium: both actions, targeted, at any version, because its signature carries none.
        for version in ["1.0", "999.0"] {
            assert_eq!(
                accepts(PixelAction::Click, &toolkit("Chromium", version)),
                Ok(SendVariant::Targeted)
            );
            assert_eq!(
                accepts(PixelAction::Keyboard, &toolkit("Chromium", version)),
                Ok(SendVariant::Targeted)
            );
        }
        // GTK 3 types but does not click, and types only through the owner variant. WebKitGTK
        // reports this same signature, which is how it inherits the entry.
        assert_eq!(
            accepts(PixelAction::Keyboard, &toolkit("gtk", "3.24.51")),
            Ok(SendVariant::Owner)
        );
        assert!(accepts(PixelAction::Click, &toolkit("gtk", "3.24.51")).is_err());
        // Qt types through the targeted variant; its click acceptance asks to be activated and is
        // therefore not a background delivery.
        assert_eq!(
            accepts(PixelAction::Keyboard, &toolkit("Qt", "6.11.1")),
            Ok(SendVariant::Targeted)
        );
        assert!(accepts(PixelAction::Click, &toolkit("Qt", "6.11.1")).is_err());
    }

    #[test]
    fn gtk_4_refuses_both_actions_however_its_name_is_spelled() {
        // GTK 4 reports `GTK` where GTK 3 reports `gtk`, so a case-sensitive key would have
        // excluded it by accident rather than on the measurement. The version series is what
        // excludes it, and it has to keep excluding it if the casing ever converges.
        for name in ["GTK", "gtk"] {
            for action in [PixelAction::Click, PixelAction::Keyboard] {
                let refusal = accepts(action, &toolkit(name, "4.20.3"))
                    .expect_err("GTK 4 acts on neither event and has unusable extents");
                assert!(refusal.contains("4.20.3"), "{refusal}");
                assert!(refusal.contains("3.24.x"), "{refusal}");
            }
        }
    }

    #[test]
    fn an_unmeasured_version_series_refuses_and_names_what_was_measured() {
        // The next Qt release is not this Qt release. Nothing here may assume a series behaves
        // like the one beside it.
        let refusal = accepts(PixelAction::Keyboard, &toolkit("Qt", "6.12.0"))
            .expect_err("a series nobody measured refuses");
        assert!(refusal.contains("Qt 6.12.0"), "{refusal}");
        assert!(refusal.contains("6.11.x"), "{refusal}");
    }

    #[test]
    fn an_unmeasured_toolkit_refuses_by_name() {
        let refusal = accepts(PixelAction::Click, &toolkit("Enlightenment", "0.27"))
            .expect_err("a toolkit nobody measured refuses");
        assert!(refusal.contains("Enlightenment 0.27"), "{refusal}");
    }

    #[test]
    fn an_application_with_no_toolkit_signature_refuses_rather_than_matching_an_empty_name() {
        // Firefox is the case: it accepts keystrokes and publishes no AT-SPI application, so it
        // has no signature at all. An empty name must never fall through to a table lookup.
        let refusal = accepts(PixelAction::Keyboard, &toolkit("", ""))
            .expect_err("no signature is not a match");
        assert!(refusal.contains("no AT-SPI toolkit"), "{refusal}");
    }

    #[test]
    fn every_refusal_names_the_toolkit_that_refused() {
        // The refusal reaches a caller as the `backgroundPixelUnsupported` message, and its whole
        // job is to say which toolkit declined and why rather than "unsupported".
        for (name, version) in [
            ("GTK", "4.20.3"),
            ("gtk", "3.24.51"),
            ("Qt", "6.11.1"),
            ("Qt", "6.12.0"),
            ("Enlightenment", "0.27"),
        ] {
            let refusal = accepts(PixelAction::Click, &toolkit(name, version))
                .expect_err("only Chromium accepts a background click");
            assert!(refusal.contains(name), "{refusal}");
            assert!(refusal.contains(version), "{refusal}");
        }
    }
}
