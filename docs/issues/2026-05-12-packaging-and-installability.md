# Packaging and Installability

## Context

Axon is usable from source, but the happy path still assumes the operator remembers Swiftly commands, Codex MCP config shape, daemon restart steps, and macOS permission details. That is fine during rough shaping, but it is not the right long-term install surface for a background service.

The current LaunchAgent installer is valuable because it gives the daemon a stable app bundle identity. A repo-local `Makefile` now covers the most common development commands, but the outer workflow is still developer-shaped:

- build with SwiftPM through the local Swiftly path
- run daemon install/start commands from the checkout
- manually configure Codex MCP to point at `.build/debug/axon`
- restart Codex after MCP facade rebuilds

## Desired Direction

- Provide one repo-local install command that builds, installs/reinstalls the daemon, starts it, checks health, and prints permission/log next steps.
- Provide one repo-local MCP setup helper or clearly documented config snippet that avoids stale names and suffixes.
- Consider installing a stable CLI shim in `~/bin` or `~/.local/bin` so routine commands do not require the Swiftly path.
- Keep the daemon app bundle as the trusted TCC identity; do not point LaunchAgent mode at `.build/debug/axon`.
- Make upgrade/reinstall idempotent and explicit about which binary the daemon is running.
- Add a smoke command that verifies daemon health, Accessibility trust, MCP facade startup, and screenshot capture separately.

## Non-Goals

- Do not add Homebrew, notarization, or a full release pipeline before the local install story is coherent.
- Do not hide macOS permission failures behind retries. Permission state should be reported directly.
- Do not create a second daemon or runner layer for packaging convenience.

## Next Steps

- Expand `make check-local` or add `scripts/check-local` for daemon, MCP facade, and screenshot smoke checks.
- Decide whether Codex config mutation should be a helper command or just precise documentation.
- Add install docs screenshots only if text proves insufficient during repeated setup.
