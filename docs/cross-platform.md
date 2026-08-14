# Cross-platform support

Axon uses the native accessibility system on macOS, Windows, and Linux. The platforms expose different capabilities, so Axon reports what it can actually do rather than presenting one lowest-common-denominator promise.

The matrix below is the current user-facing contract. Contributors can consult the exhaustive [tool-by-platform capability census](platform-capability-matrix.md) and the deeper [cross-platform internals](cross-platform-internals.md) for evidence, refusal behavior, backend architecture, and verification procedures.

## Support matrix

**Supported** means live evidence backs the capability. **Supported with limits** names a restriction you should plan around. **Experimental** is implemented without current live proof. **Refused** and **Not implemented** are explicit gaps that Axon reports rather than hiding.

| environment | semantic actions | input | images | requirements and limits |
| --- | --- | --- | --- | --- |
| macOS 14+ | **Supported** | **Experimental** | **Experimental** | Accessibility permission is required. Screen Recording permission is required for screenshots. |
| Windows 10+ | **Supported with limits** — semantic activation uses `InvokePattern` | **Pointer supported with limits** for a small set of controls; keyboard is **refused** | **Supported** | Must run in an interactive user session. Elevated targets require matching elevation or UIAccess. |
| Linux X11 | **Supported** | **Supported with limits** — background delivery depends on toolkit; Chromium keyboard delivery is refused | **Supported** | Requires AT-SPI, an EWMH window manager, and XTEST. GTK 4 element positions are not reliable for pointer targeting. |
| Linux GNOME/Mutter on Wayland | **Supported** | **Refused** — Wayland does not provide Axon a safe unattended input path | **Not implemented** | Requires AT-SPI with accessibility enabled. GTK 4 element positions are not reliable for pointer targeting. |
| Linux KWin or wlroots on Wayland | **Experimental** | **Refused (expected)** | **Not implemented** | No live verification environment currently backs these desktop sessions. |
| XWayland apps in a Wayland session | **Supported** for semantic access | **Refused** | **Not implemented** | Axon follows the Wayland session's safety constraints even when an individual app uses XWayland. |

## Platform notes

### macOS

Axon is most complete at semantic actions such as pressing a button or setting a field value. Pointer, keyboard, and screenshot paths exist but remain experimental until they have live end-to-end verification.

Browser `navigate`, `windows`, and `tabs` use Apple Events in addition to Accessibility. The first
request for a browser can therefore show macOS's Automation consent prompt. Grants are per browser:
allowing Axon to control Safari does not allow it to control Google Chrome. A rejected or unavailable
grant returns JSON-RPC `-32603` with structured reason `automation-not-granted`, the target app, and
an authorization state of `denied` or `notDetermined`. Axon does not collapse these independent
target grants into the global health document.

### Windows

Window capture and semantic inspection are supported in an interactive desktop session. Axon installs an unelevated, per-user scheduled task that launches a dedicated windowless daemon; the command-line interface remains a separate console executable. Background pointer delivery is deliberately narrow, and Axon refuses actions when it cannot prove a safe target-bound mechanism. Global keyboard delivery is not available.

External MCP clients should launch the resolved absolute form of `%LOCALAPPDATA%\Axon\current\axon.exe mcp`; the installer prints ready-to-run registration commands. The installer updates this stable path on every release while daemon registration continues to name the immutable versioned executable.

### Linux

Semantic access uses AT-SPI. On X11, some toolkits accept target-bound pointer and keyboard events while others do not, so Axon names those refusals at runtime. On Wayland, synthetic pointer and keyboard input is refused rather than silently becoming global input.

External MCP clients should launch the resolved absolute form of `~/.local/lib/axon/current/axon-linux mcp`; the installer prints ready-to-run registration commands. The installer atomically repoints this symlink on upgrade while systemd continues to name the immutable versioned executable.

Across Linux backends, delta scrolling, drag, change observation, and session recording are not yet available. Chromium-family apps also require the desktop accessibility switch to be enabled before they appear on the AT-SPI bus.

For the exact status of the running service, use:

```sh
axon status
axon status --json
```

The machine-readable status is authoritative for session-specific permission and capability gates.
