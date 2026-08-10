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
    (
        parts.next().unwrap_or_default(),
        parts.next().unwrap_or_default(),
    )
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
/// Some absences are deliberate rather than untested. **GTK 4** is excluded twice over: it acts on
/// neither event, and its AT-SPI extents report correct sizes at `(0, 0)` origins, so a pixel rung
/// would have no usable coordinate source there even if delivery worked. **Firefox** is excluded
/// despite accepting keystrokes, because it publishes no AT-SPI application at all: the target
/// cannot be identified, its coordinates cannot be converted through resolved geometry, and
/// nothing can be revalidated before dispatch, so every precondition the contract puts on the rung
/// fails before delivery is even reached. It has no signature to key an entry on, which is why its
/// absence here is structural rather than a decision.
///
/// The rest are `Refused` rather than absent, so the argument against each one is readable beside
/// the evidence for the entry it sits in, and a caller is told which of them declined.
///
/// One of those three refuses a row the fixtures record as accepted, and it is worth being plain
/// about why. Chromium's keyboard row was measured immediately after its click row, on the same
/// window, and Chromium routes background key events to a window only once a background click has
/// landed there. The fixture therefore records the post-click state; a window that has not been
/// clicked drops every delivered key event in silence. AXN-102 tracks re-measuring it against a
/// target that received nothing else. Until then the entry claims only the click, which is what
/// was measured independently and what was reconfirmed through the daemon on real Chromium.
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
        keyboard: Measured::Refused(
            "Chromium acts on background keystrokes only once a background click has already \
             landed in the same window. Delivered to a window that has not been clicked, every \
             key event is dropped in silence — so offering the rung here would report a \
             successful dispatch for keystrokes that reliably do nothing. The committed fixture's \
             `text` row for this family records the post-click state rather than an independent \
             acceptance, because the harness measures its keyboard phase after its click phase; \
             AXN-102 tracks re-measuring it on a target that was never clicked",
        ),
        evidence: "scripts/linux-toolkit-acceptance/RESULTS.md and RESULTS-live-x11.md, rows \
                   electron-22 (Chromium 108.0.5359.215), electron-30 (Chromium 124.0.6367.243) \
                   and electron (Chromium 150.0.7871.212): every generation acted on a background \
                   click, on both the hermetic Xvfb lane and a live Xfce X11 session, with the \
                   pointer and the session focus unchanged and both controls reacting. Confirmed \
                   again through the daemon on the fedora bench against Electron 43 (Chromium \
                   150.0.7871.212), where the page reported the click as isTrusted while the X \
                   input focus and the real pointer were unchanged either side of it",
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
    let measured = match action {
        PixelAction::Click => entry.click,
        PixelAction::Keyboard => entry.keyboard,
    };
    match measured {
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

    fn variant(action: PixelAction, name: &str, version: &str) -> Option<SendVariant> {
        accepts(action, &toolkit(name, version))
            .ok()
            .map(|acceptance| acceptance.variant)
    }

    #[test]
    fn the_table_offers_exactly_what_the_fixtures_measured() {
        // Chromium clicks at any version, because its signature carries none. Its keystrokes are
        // refused: they land only on a window a background click has already reached, and a
        // window that has not been clicked drops them in silence.
        for version in ["1.0", "999.0"] {
            assert_eq!(
                variant(PixelAction::Click, "Chromium", version),
                Some(SendVariant::Targeted)
            );
            assert_eq!(variant(PixelAction::Keyboard, "Chromium", version), None);
        }
        // GTK 3 types but does not click, and types only through the owner variant. WebKitGTK
        // reports this same signature, which is how it inherits the entry.
        assert_eq!(
            variant(PixelAction::Keyboard, "gtk", "3.24.51"),
            Some(SendVariant::Owner)
        );
        assert_eq!(variant(PixelAction::Click, "gtk", "3.24.51"), None);
        // Qt types through the targeted variant; its click acceptance asks to be activated and is
        // therefore not a background delivery.
        assert_eq!(
            variant(PixelAction::Keyboard, "Qt", "6.11.1"),
            Some(SendVariant::Targeted)
        );
        assert_eq!(variant(PixelAction::Click, "Qt", "6.11.1"), None);
    }

    /// The two committed measurements, by the path each entry cites.
    const FIXTURES: [(&str, &str); 2] = [
        (
            "RESULTS.md",
            include_str!("../../../scripts/linux-toolkit-acceptance/results.json"),
        ),
        (
            "RESULTS-live-x11.md",
            include_str!("../../../scripts/linux-toolkit-acceptance/results-live-x11.json"),
        ),
    ];

    /// Every acceptance this table grants, held against the fixtures it cites — on both lanes.
    ///
    /// The table is prose and constants, and the measurement is JSON in another directory; nothing
    /// but this test stops the two from drifting. A re-measurement that flips a row, changes the
    /// variant a toolkit honours, or renames a toolkit's signature would otherwise leave the table
    /// authorizing background input into a window on the strength of evidence that no longer says
    /// so. Which is the one failure mode an evidence-keyed allowlist cannot tolerate.
    ///
    /// Deliberately one-directional. It asserts the table never claims more than was measured, and
    /// says nothing about the reverse, because three rows the harness measured as accepting are
    /// refused anyway: Qt's click asks to be activated, GTK's click needs the real cursor already
    /// inside the target, and Chromium's keystrokes were measured on a window its own click phase
    /// had just clicked. Those arguments live in the table's `Refused` reasons, where a reader can
    /// disagree with them; a test that demanded the table match the fixtures in both directions
    /// would be demanding it stop making them.
    #[test]
    fn no_entry_claims_more_than_both_fixtures_measured() {
        for (lane, fixture) in FIXTURES {
            let measured: serde_json::Value =
                serde_json::from_str(fixture).expect("a committed fixture parses");
            let rows = measured["results"]
                .as_array()
                .expect("a fixture is a list of rows");
            let mut checked = 0;
            for row in rows {
                let (Some(name), Some(version)) = (
                    row["atspiToolkit"]["name"].as_str(),
                    row["atspiToolkit"]["version"].as_str(),
                ) else {
                    // Firefox publishes no AT-SPI application, so it has no signature to key on.
                    continue;
                };
                let target = row["target"].as_str().unwrap_or("?");
                for (action, phase, control) in [
                    (PixelAction::Click, "click", "pointerClick"),
                    (PixelAction::Keyboard, "text", "focusedText"),
                ] {
                    let Some(offered) = variant(action, name, version) else {
                        continue;
                    };
                    checked += 1;
                    let phase = &row["background"][phase];
                    assert_eq!(
                        phase["accepted"],
                        serde_json::json!(true),
                        "{lane}: the table offers {name} {version} for {target}, and this lane \
                         did not measure that acceptance"
                    );
                    assert_eq!(
                        phase["variant"].as_str(),
                        Some(offered.key()),
                        "{lane}: the table sends {target} the {} variant, and this lane measured \
                         a different one",
                        offered.key()
                    );
                    // A row whose control failed carries no verdict at all: a background refusal
                    // there is a statement about the harness, and an acceptance is luck.
                    assert_eq!(
                        row["controls"][control],
                        serde_json::json!(true),
                        "{lane}: {target}'s {control} control did not react, so this row cannot \
                         support an entry"
                    );
                }
                // A toolkit offered any rung needs a coordinate source, and GTK 4 is the reason
                // that is not automatic. The keyboard path converts no coordinates, but the same
                // extents are what a `look` at that application reports, so an entry offered for a
                // target with unusable geometry would be aiming a caller at rectangles that lie.
                if variant(PixelAction::Click, name, version).is_some()
                    || variant(PixelAction::Keyboard, name, version).is_some()
                {
                    assert_eq!(
                        row["geometry"]["extentsUsable"],
                        serde_json::json!(true),
                        "{lane}: {target} is offered a rung and its AT-SPI extents were measured \
                         unusable"
                    );
                }
            }
            assert!(
                checked >= 4,
                "{lane}: the fixture matched almost none of the table, which means the signatures \
                 no longer line up rather than that the table is small"
            );
        }
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
    fn chromium_keystrokes_refuse_and_say_what_they_would_do_instead_of_working() {
        // The failure mode this refusal exists to stop is silent: the events are delivered, the
        // server accepts them, the invariants all hold, and the application does nothing. A
        // caller who is told "unsupported" can escalate; one who is told "delivered" cannot.
        let refusal = accepts(
            PixelAction::Keyboard,
            &toolkit("Chromium", "1.0"),
        )
        .expect_err("Chromium keystrokes need a click to have landed first");
        assert!(refusal.contains("Chromium 1.0"), "{refusal}");
        assert!(refusal.contains("click"), "{refusal}");
        assert!(refusal.contains("silence"), "{refusal}");
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
