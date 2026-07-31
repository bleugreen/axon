---
name: axon-development
description: Use when building, testing, or changing Axon's Swift code, public tool surface, .axn replay behavior, locator resolution, or live macOS Accessibility integration.
---

# Axon Development

Use the repository's Make targets for validation. `make build` and `make test` select the Swiftly toolchain through `$(HOME)/.swiftly/bin/swift`; invoking `swift build` directly may select the Command Line Tools compiler and fail while linking the package manifest.

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

Before scoping work from `docs/issues/`, verify the current implementation with symbol or structural searches. Issue status text and quoted test totals are historical observations and can lag the code; rerun tests before citing a baseline.

## Swift Testing

Swift concurrency checking can crash the frontend when a test helper closure captures the object being initialized or a non-Sendable Objective-C object such as `NSObject`. Prefer small Swift reference test doubles marked `@unchecked Sendable` when justified, initialize mutable buffers before invoking behavior, and avoid initializer-time self-captures.

## Live Accessibility verification

Unit tests do not verify behavior that depends on a live macOS Accessibility session. Agent worktrees may lack a graphical session or Accessibility permission, and recording through `UserActionRecorder` requires real user input rather than synthetic events.

For changes touching live Accessibility or daemon behavior, explicitly assign manual verification. `make check-local` rebuilds and restarts the user's running Axon daemon and then checks health; warn before asking the user to run it because it replaces the currently running daemon. Recorder changes should have deterministic automated coverage, but still require a person at the screen for end-to-end recording validation.
