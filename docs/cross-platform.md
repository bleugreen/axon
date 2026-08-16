# Cross-platform support

Axon uses the native accessibility system on macOS, Windows, and Linux. The platforms expose different capabilities, so Axon reports what it can actually do rather than presenting one lowest-common-denominator promise.

The matrix below is the current user-facing contract. Contributors can consult the exhaustive [tool-by-platform capability census](platform-capability-matrix.md) and the deeper [cross-platform internals](cross-platform-internals.md) for evidence, refusal behavior, backend architecture, and verification procedures.

## Support matrix

**Supported** means live evidence backs the capability. **Supported with limits** names a restriction you should plan around. **Experimental** is implemented without current live proof. **Refused** and **Not implemented** are explicit gaps that Axon reports rather than hiding.

| environment | semantic actions | input | images | requirements and limits |
| --- | --- | --- | --- | --- |
| macOS 14+ | **Supported** | **Experimental** | **Experimental** | Accessibility permission is required. Screen Recording permission is required for screenshots. |
| Windows 10+ | **Supported with limits** — semantic activation uses `InvokePattern` | **Pointer supported with limits** for a small set of controls; keyboard is **refused** | **Supported** | Must run in an interactive user session. Elevated targets require matching elevation or UIAccess. |
| Linux X11 | **Supported** | **Supported with limits** — background delivery depends on toolkit; Chromium keyboard delivery is refused | **Supported** | Requires AT-SPI and an EWMH window manager. OCR additionally requires Tesseract and an installed English language pack; input requires XTEST. GTK 4 element positions are not reliable for pointer targeting. |
| Linux GNOME/Mutter on Wayland | **Supported** | **Refused** — Wayland does not provide Axon a safe unattended input path | **Supported with limits** — `capture_screen` returns a distinctly labeled user-authorized ScreenCast source; app-scoped `look` screenshots remain refused | Requires AT-SPI with accessibility enabled. ScreenCast authorization can require the desktop chooser. GTK 4 element positions are not reliable for pointer targeting. |
| Linux KWin or wlroots on Wayland | **Experimental** | **Refused (expected)** | **Not implemented** | No live verification environment currently backs these desktop sessions. |
| XWayland apps in a Wayland session | **Supported** for semantic access | **Refused** | **Not implemented** | Axon follows the Wayland session's safety constraints even when an individual app uses XWayland. |

## Platform notes

### macOS

Axon is most complete at semantic actions such as pressing a button or setting a field value. Pointer, keyboard, and screenshot paths exist but remain experimental until they have live end-to-end verification.

Browser `navigate`, `windows`, and `tabs` use Apple Events in addition to Accessibility. Those verbs
only check the existing Automation grant; they never present macOS's consent prompt. The prompt
blocks until a person answers it, and an agent's call must not hang on a dialog nobody asked for.
Consent is a deliberate act instead: open the Axon menu bar item and choose **Browser Automation...**,
which asks macOS for each supported browser that is running. Grants are per browser: allowing Axon to
control Safari does not allow it to control Google Chrome. A missing grant returns JSON-RPC `-32603`
with structured reason `automation-not-granted`, the target app, an authorization state of `denied`
or `notDetermined`, and the `leg` that produced the decision. Axon does not collapse these
independent target grants into the global health document.

Being allowed to *ask* is itself a signing property. The daemon app runs under the hardened runtime,
which forbids Apple events outright unless the signature carries
`com.apple.security.automation.apple-events`, and forbids them silently: TCC refuses instantly,
presents no dialog, records no row, and Axon never appears in System Settings > Privacy & Security >
Automation. `NSAppleEventsUsageDescription` in the bundle's `Info.plist` supplies the dialog's
wording and the entitlement permits the dialog to exist; both halves are required, and packaging
asserts the entitlement rather than assuming it. See [Releasing Axon](releasing.md#signing-and-entitlements).

macOS resolves an Apple Events authorization inside the daemon process once that process holds an
answer for a browser, so a grant changed after the daemon started — including by `tccutil reset` — is
not visible until the daemon restarts. When Axon has already answered for that browser in the current
session it says so, and names the restart as the remediation.

Remediation is written for the surface that was refused. A browser verb's refusal can send the user
to the menu bar's consent gesture, because that is a step they have not taken. The gesture's own
refusal cannot: it distinguishes a denial already recorded in TCC, which is fixed by enabling the
browser beneath Axon in the Automation pane, from a request macOS refused without recording anything,
which no setting on the machine can change. Guidance that pointed the gesture back at the gesture was
the defect that made a mis-signed build unreportable.

### Windows

Window capture and semantic inspection are supported in an interactive desktop session. Axon installs an unelevated, per-user scheduled task that launches a dedicated windowless daemon; the command-line interface remains a separate console executable. Background pointer delivery is deliberately narrow, and Axon refuses actions when it cannot prove a safe target-bound mechanism. Global keyboard delivery is not available.

External MCP clients should launch the resolved absolute form of `%LOCALAPPDATA%\Axon\current\axon.exe mcp`; the installer prints ready-to-run registration commands. The installer updates this stable path on every release while daemon registration continues to name the immutable versioned executable.

### Linux

Semantic access uses AT-SPI. X11 window screenshots use direct X11 capture without portal authorization. `screenText` and screenshot-sourced text locations run the system `tesseract` executable and require English language data (commonly the `tesseract-ocr` and `tesseract-ocr-eng` packages). Missing OCR dependencies fail only the requested OCR operation; semantic AT-SPI access remains available. On Wayland, `look` continues to refuse app-scoped screenshots because the portal exposes no verifiable app identity. The separate `capture_screen` operation requests a WINDOW ScreenCast source chosen by the user and labels it as user-authorized rather than associating it with an app. Restore tokens are private optimistic hints; authorization timeout or cancellation is reported as `portal-authorization-required`. Synthetic pointer and keyboard input remains refused rather than silently becoming global input.

External MCP clients should launch the resolved absolute form of `~/.local/lib/axon/current/axon-linux mcp`; the installer prints ready-to-run registration commands. The installer atomically repoints this symlink on upgrade while systemd continues to name the immutable versioned executable.

Across Linux backends, delta scrolling, drag, change observation, and session recording are not yet available. Chromium-family apps also require the desktop accessibility switch to be enabled before they appear on the AT-SPI bus.

For the exact status of the running service, use:

```sh
axon status
axon status --json
```

The machine-readable status is authoritative for session-specific permission and capability gates.
