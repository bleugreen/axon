# Cross-platform support

Axon uses the native accessibility system on macOS, Windows, and Linux. The platforms expose different capabilities, so Axon reports what it can actually do rather than presenting one lowest-common-denominator promise.

The matrix below is the current user-facing contract. Detailed evidence, backend architecture, and verification procedures remain in the contributor reference, [Cross-platform internals](../docs/cross-platform-internals.md).

## Support matrix

**Supported** means live evidence backs the capability. **Supported with limits** names a restriction you should plan around. **Experimental** is implemented without current live proof. **Refused** and **Not implemented** are explicit gaps that Axon reports rather than hiding.

| environment | inspect and act semantically | pointer and keyboard | screenshots | important requirements and limits |
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

### Windows

Window capture and semantic inspection are supported in an interactive desktop session. Background pointer delivery is deliberately narrow, and Axon refuses actions when it cannot prove a safe target-bound mechanism. Global keyboard delivery is not available.

### Linux

Semantic access uses AT-SPI. On X11, some toolkits accept target-bound pointer and keyboard events while others do not, so Axon names those refusals at runtime. On Wayland, synthetic pointer and keyboard input is refused rather than silently becoming global input.

Across Linux backends, delta scrolling, drag, change observation, and session recording are not yet available. Chromium-family apps also require the desktop accessibility switch to be enabled before they appear on the AT-SPI bus.

For the exact status of the running service, use:

```sh
axon status
axon status --json
```

The machine-readable status is authoritative for session-specific permission and capability gates.
