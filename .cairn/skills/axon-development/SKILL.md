---
name: axon-development
description: Use when building, testing, or changing Axon's Swift or Rust code, public tool surface, .axn replay behavior, locator resolution, daemon lifecycle, or live desktop integration on macOS, Windows, or Linux.
---

# Axon Development

Use the repository's Make targets for validation. `make build` and `make test` select the Swiftly toolchain through `$(HOME)/.swiftly/bin/swift`; invoking `swift build` directly may select the Command Line Tools compiler and fail while linking the package manifest.

If a bounded `swift test` run is killed and later SwiftPM commands block silently, inspect `swift-test` and `swiftpm-testing-helper` processes for survivors holding the `.build` lock. Terminate confirmed orphans before retrying, and put a per-command timeout on potentially hanging test runs rather than relying only on the enclosing batch timeout.

## Public tool changes

Treat these as the canonical implementation points:

- `Sources/AxonCore/ToolSurfaceSpec.swift` declares the public tools and parameters used to derive MCP schemas, CLI usage, and documentation signatures.
- `Sources/AxonCore/ToolTarget.swift` owns target polymorphism.
- `docs/tool-surface.md` contains the generated signature block checked by `Tests/AxonCoreTests/ToolSurfaceSpecTests.swift`.

Start a tool-surface change in `ToolSurfaceSpec`, then update the implementation and the documentation signature block. Do not independently hand-edit router schemas or CLI help as separate sources of truth.

The JSON-RPC result envelope is also a public contract. In particular, `MCPRouter.callTool` forwards the socket result into MCP `structuredContent`, so the `run` result's `batch` key is visible to MCP clients. Preserve it unless the work explicitly includes a protocol migration.

When a new tool returns an envelope other than `action`, update `AxnRunner` as well as `CommandRouter`. Audit `primitiveActionSucceeded`, `primitiveActionFailureMessage`, and `resultSummary`; otherwise `.axn` replay can interpret a failed tool result as success or summarize it incorrectly.

The canonical artifact vocabulary uses the `Axn` family (`Axn`, `AxnRunner`, `AxnParameters`, and `AxnDebugSession`). Do not revive the removed `ActionBatch`, `AxonRecipe`, or `Recipe` implementation names. Historical records in `docs/issues/` and `docs/decision-log.md` need not be rewritten to match later terminology.

## Locator changes

`LocatorResolver` is defined in `Sources/AxonCore/LocatorModel.swift`; there is no separate `LocatorResolver.swift`.

Reason about both locator execution shapes:

1. Full snapshots contain siblings and broad context.
2. `AXLiveLocatorResolver` fast-path captures are synthetic root-to-candidate trees.

Signals requiring absent broad context, such as nearby sibling text, must be positive-only hints. Missing context in a fast-path mini-snapshot must not reject or penalize a candidate.

`LocatorCandidate.score` combines the semantic score multiplied by 1000 with a geometry tie-break no greater than 100. `LocatorResolution.confidence` derives from the semantic portion, `score / 1000`; tests constructing candidates with small raw scores such as `1` therefore produce `none`, not high confidence.

## Replay and drag verification

Keep dispatch success distinct from semantic success. A drag without verified `expects` facts reports `success: false` and `semanticStatus: unverified`, and batch replay must fail it even if event dispatch succeeded. Recordings containing bare drags need postcondition facts.

Use `wait_for_value` for settled-state waits. Its default timeout is 5 seconds, capped at 60 seconds, and its outcomes distinguish `satisfied`, `predicate_timeout`, and `target_unresolved_timeout`. Keep `look(since:)` as the coarser change check. For drag verification, the `AxonReorderFixtureApp` target and `scripts/package-reorder-fixture-app` provide a reorderable list whose Accessibility value exposes row order for value facts.

## Daemon lifecycle

AxonCore deliberately owns a Unix socket with `flock` on a `<socket>.lock` sidecar. `flock` is tied to the open file description, so two `SocketServer` instances in one test process contend as separate processes would. Do not replace it with per-process `fcntl` record locking; that would invalidate the in-process ownership tests.

Bound ownership-refusal tests with `waitUntilFinished()`. If a broken server wrongly acquires the path, it blocks in `accept()`; a direct thrown-error assertion turns that regression into a hung suite. Also assume SIGTERM skips Swift `defer` cleanup and leaves the socket path behind. Restart correctness must come from reclaiming the stale socket while holding the ownership lock, not from graceful cleanup.

On macOS, the first `AXIsProcessTrusted` or `CGPreflightScreenCaptureAccess` query from a freshly rebuilt executable can spend several seconds in Transparency, Consent, and Control resolution; later calls are fast, and rebuilding restores the cold cost. `Doctor.warmUp()` deliberately pays this before serving. Preserve the 10-second bound for a first daemon status round trip unless new measurements justify changing it.

Before scoping work from `docs/issues/`, verify the current implementation with symbol or structural searches. Issue status text and quoted test totals are historical observations and can lag the code; rerun tests before citing a baseline.

## Swift Testing

Swift concurrency checking can crash the frontend when a test helper closure captures the object being initialized or a non-Sendable Objective-C object such as `NSObject`. Prefer small Swift reference test doubles marked `@unchecked Sendable` when justified, initialize mutable buffers before invoking behavior, and avoid initializer-time self-captures.

## Live Accessibility verification

Unit tests do not verify behavior that depends on a live macOS Accessibility session. Agent worktrees may lack a graphical session or Accessibility permission, and recording through `UserActionRecorder` requires real user input rather than synthetic events.

For changes touching live Accessibility or daemon behavior, explicitly assign manual verification. `make check-local` rebuilds and restarts the user's running Axon daemon and then checks health; warn before asking the user to run it because it replaces the currently running daemon. Recorder changes should have deterministic automated coverage, but still require a person at the screen for end-to-end recording validation.

### Windows live probes

A Cairn shell on `bglab-win` runs in Windows session 0. UI Automation can still return the desktop root there, but it cannot see the logged-in user's windows, so desktop observations from that shell are false negatives. For a zero-side-effect read, use the already-running Axon daemon's `\\.\pipe\axon-v1` named pipe; it runs in the interactive session and can answer `look` about the real desktop.

When a probe must execute in the interactive desktop, create and run a one-shot scheduled task with `/RU %USERNAME% /IT`, and have it write results beneath the shared user profile. The executor shell is `cmd`; invoke PowerShell explicitly for `Select-String` and other PowerShell operations. For multiline scripts, base64-encode locally and reconstruct the bytes with PowerShell rather than nesting multiline quoting. Delete the scheduled task and probe files afterward.

Treat successful `PostMessageW` calls only as dispatch evidence. Classic Win32 controls may act on posted client-coordinate mouse messages, while `Windows.UI.Core.CoreWindow` surfaces can accept the same sequence without effect. Require readback or declared postconditions for semantic success and restrict background input to UI classes demonstrated to work. Do not require a UI Automation element and its hosting HWND to share a process: UWP surfaces may put the element in the app process and the window in `ApplicationFrameHost`.

### Linux live probes

To probe a fresh Linux daemon without disturbing the installed service, point `XDG_RUNTIME_DIR` at a temporary directory so the probe owns a separate socket, while setting `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus` and `DISPLAY=:0` to reach the real desktop. Send one-line JSON-RPC requests with an `AF_UNIX` client. Never bind a comparison probe to the installed service's shared `/run/user/1000/axon-v1.sock`.
