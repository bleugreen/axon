# Stable Accessibility Identity For The Daemon

## Problem

Axon can run as a LaunchAgent, but macOS Accessibility trust is fragile while the daemon executable is `/.build/debug/axon`.

Observed behavior:

- `axon doctor` launched from the terminal reports Accessibility as trusted.
- The same rebuilt binary launched by `launchd` can report `Accessibility permission is not trusted`.
- Toggling Axon in Privacy & Security fixes the current daemon build.
- Rebuilding `.build/debug/axon` can invalidate that trust again for the LaunchAgent process.

This makes the daemon awkward during active development and will be unacceptable for a set-and-forget local service.

## Likely Cause

TCC is treating the debug executable as an unstable client identity. Rebuilding changes the executable identity enough that the LaunchAgent process no longer matches the previously approved Accessibility client, even though the path is the same.

## Desired Direction

Give Axon a stable local identity before relying on LaunchAgent mode as the normal path.

Options to investigate:

- Install a stable built binary outside `.build`, then only replace it intentionally.
- Ad-hoc or developer-id sign the installed binary in a consistent post-build step.
- Wrap the daemon in a small `.app`/helper with a stable bundle identifier if TCC behaves better for bundled apps.
- Add `axon daemon doctor` that checks Accessibility trust from the daemon process, not only from the invoking terminal.

## Acceptance

- Rebuilding the development package does not silently break the installed LaunchAgent's Accessibility trust.
- `axon daemon status` or a daemon health call reports whether the daemon process itself is AX-trusted.
- The documented install path makes clear when the user must re-approve Accessibility permissions.
