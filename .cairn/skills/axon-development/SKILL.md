---
name: axon-development
description: Use when building, testing, or changing Axon's Swift or Rust code, public tool surface, .axn replay behavior, locator resolution, daemon lifecycle, or live desktop integration on macOS, Windows, or Linux.
---

# Axon Development

## Build and test

SwiftPM sandboxes its own manifest compile, and that sandbox cannot nest inside a Cairn build slot. Plain `swift build`, plain `swift test`, and the `make build` / `make test` targets therefore die before compiling anything with `sandbox-exec: sandbox_apply: Operation not permitted`, reported as `Invalid manifest`. Pass `--disable-sandbox`. The Make targets do not pass it, so invoke SwiftPM directly rather than through `make`.

Select the toolchain deliberately. The Command Line Tools do not ship swift-testing, so a suite run under them fails every file with `no such module 'Testing'` while `swift build` still succeeds — a green build says nothing about whether tests can run. Where a Swiftly toolchain is installed, use it, which is what the Makefile's `SWIFT ?= $(HOME)/.swiftly/bin/swift` is reaching for:

```sh
~/.swiftly/bin/swift test --disable-sandbox
```

Where only the Command Line Tools are present, with neither Swiftly nor Xcode, point the compiler and the linker at the framework SwiftPM leaves off the search path. Both rpaths are load-bearing: without the second the tests build and link but die at launch with `Library not loaded: @rpath/lib_TestingInterop.dylib`.

```sh
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null swift test --disable-sandbox \
  --scratch-path /tmp/axn-spm-clt \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

The `GIT_CONFIG_*` overrides neutralize a global `insteadOf` rewrite of `https://github.com/` to `git@github.com:`; without them a fresh scratch path cannot resolve dependencies, because the sandbox cannot read `~/.ssh/known_hosts` and every fetch fails with `Host key verification failed`. CI is unaffected by any of this — the GitHub macOS runner has Xcode, which is why the workflows can call bare `swift test`.

When a build dies with `clang frontend command failed due to signal` or `module '_DarwinFoundation1' is defined in both`, the cause is a stale shared `.build`, not a compiler bug. The slot's build directory holds artifacts from whichever toolchain, or whichever case-spelling of the slot path, ran last, and the mixed module cache brings the frontend down. Give the run its own build directory with `--scratch-path` and it compiles cleanly. Such a crash often reports a stack naming a type and its `Sendable` conformance, which reads exactly like the concurrency-checking crash described under Swift Testing; look for the `defined in both` line before believing the stack.

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

## Cross-platform verification

`rust/axon-linux/src/lib.rs` gates `mod platform` behind `#[cfg(target_os = "linux")]`, and `rust/axon-win/src/lib.rs` gates its own behind `#[cfg(windows)]`. Running `cargo test -p axon-linux` on macOS therefore compiles none of the backend under review and reports a confident pass indistinguishable at a glance from the real thing; `cargo check --all-targets` and `cargo clippy` are equally hollow there. Test counts alone are a poor tell, because they drift as the code grows. Ask directly whether the platform module ran:

```sh
cargo test -p axon-linux 2>&1 | grep -c 'platform::tests'
```

Zero means the host skipped the backend entirely. Route the run to a machine that compiles it — `fedora` or `bglab-ub` for Linux, `bglab-win` for Windows — and treat any claim about a platform backend that was not verified on that platform as unverified:

```js
run({executor:{name:"fedora"}, commands:[{command:"cd rust && cargo test -p axon-linux"}]})
```

Reproducing the `Rust Linux` CI lane's `cargo test -p axon-linux -- --ignored` sweep needs both a session bus and an X server. `fedora` carries `Xvfb` and `dbus-daemon`; it has no `xdpyinfo`, so substitute a sleep for the lane's display-readiness poll.

Hermetic Unix-socket tests must not build paths from `std::env::temp_dir()`. On the Linux executors `TMPDIR` is the build-slot scratch directory, around 68 characters, while `sockaddr_un` caps a socket path near 108 bytes; a `dbus-daemon` handed a `<listen>` address under it refuses to start at all with `Socket name too long`. Bind under `/tmp` directly, as `rust/axon-linux/tests/atspi_activation.rs` does. A private bus configuration also needs `<allow receive_sender="*"/>` alongside `<allow send_destination="*"/>`: a bus denies receiving by default, method replies and the driver's own `NameAcquired` signals included, and a client whose reply is dropped does not error — it hangs.

## Live Accessibility verification

Unit tests do not verify behavior that depends on a live macOS Accessibility session. Agent worktrees may lack a graphical session or Accessibility permission, and recording through `UserActionRecorder` requires real user input rather than synthetic events.

For changes touching live Accessibility or daemon behavior, explicitly assign manual verification. `make check-local` rebuilds and restarts the user's running Axon daemon and then checks health; warn before asking the user to run it because it replaces the currently running daemon. Recorder changes should have deterministic automated coverage, but still require a person at the screen for end-to-end recording validation.

### macOS live probes

`bglab-mac`, the `axon-live-mac` self-hosted runner running as user `dev` with uid 501, carries more than one Axon install, and the one on `PATH` is not the live one. `/opt/homebrew/bin/axon` points into `/Applications/Axon.app` at a build old enough to predate the `shutdown`, `version`, and `daemon restart` subcommands: it answers `axon: unknown command: version` and prints the pre-health-v1 human-readable `status`. The daemon that actually serves is the `dev.axon.daemon` LaunchAgent, whose plist registers a versioned bundle under `~/.local/lib/axon/<version>/`. Read that plist's `ProgramArguments` rather than assuming a path, because the version and the bundle layout move with releases. No `Axon.app` process runs there, so `pgrep -x Axon` never matches; the daemon is a CLI process logging to `~/Library/Logs/Axon/daemon.out.log`. Invoke the build under test by full path whenever the version matters, and never let a script shell out to bare `axon`.

To ask whether start-at-login is genuinely live, use the LaunchAgent's load state rather than the daemon's own report. `launchctl print gui/501/dev.axon.daemon` exits 113 when the label is not loaded and 0 when it is, printing `pid = N` for a loaded job. `axon shutdown` boots the agent out while leaving the plist on disk, so `registration.registered` keeps reporting true for an agent that will never start.

### Windows live probes

A Cairn shell on `bglab-win` runs in Windows session 0. UI Automation can still return the desktop root there, but it cannot see the logged-in user's windows, so desktop observations from that shell are false negatives. For a zero-side-effect read, use the already-running Axon daemon's `\\.\pipe\axon-v1` named pipe; it runs in the interactive session and can answer `look` about the real desktop.

When a probe must execute in the interactive desktop, create and run a one-shot scheduled task with `/RU %USERNAME% /IT`, and have it write results beneath the shared user profile. The executor shell is `cmd`; invoke PowerShell explicitly for `Select-String` and other PowerShell operations. For multiline scripts, base64-encode locally and reconstruct the bytes with PowerShell rather than nesting multiline quoting. Delete the scheduled task and probe files afterward.

The `scripts/test-windows-live-recovery.ps1` rehearsal harness needs PowerShell and cannot run on the macOS machines; run it on `bglab-win`, the same machine the `Test` workflow's `rust-windows` job uses. Its mutation doctrine wants a deliberately broken probe: copy `.github/scripts/windows-live-probe.ps1` to a sibling path inside `.github/scripts`, mutate the copy, assert the replacement actually changed the text, and pass it as `-ProbeScript`. The copy has to stay in that directory, because the probe derives `$RepositoryRoot` from its own `$PSScriptRoot`; a copy in a scratch directory resolves the wrong root and fails for a reason unrelated to the mutation.

Treat successful `PostMessageW` calls only as dispatch evidence. Classic Win32 controls may act on posted client-coordinate mouse messages, while `Windows.UI.Core.CoreWindow` surfaces can accept the same sequence without effect. Require readback or declared postconditions for semantic success and restrict background input to UI classes demonstrated to work. Do not require a UI Automation element and its hosting HWND to share a process: UWP surfaces may put the element in the app process and the window in `ApplicationFrameHost`.

### Linux live probes

To probe a fresh Linux daemon without disturbing the installed service, point `XDG_RUNTIME_DIR` at a temporary directory so the probe owns a separate socket, while setting `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus` and `DISPLAY=:0` to reach the real desktop. Send one-line JSON-RPC requests with an `AF_UNIX` client. Never bind a comparison probe to the installed service's shared `/run/user/1000/axon-v1.sock`.

`bglab-ub` cannot serve as a neutral environment for AT-SPI experiments: it runs Orca with `toolkit-accessibility` already true, so any Chromium or Electron tree there is awake for reasons that have nothing to do with Axon. An isolated rig is four pieces. Start a private `dbus-daemon --session --print-address --fork` with its own `XDG_RUNTIME_DIR`. Launch `/usr/libexec/at-spi-bus-launcher --launch-immediately` against that bus with `GSETTINGS_BACKEND=memory`, so the launcher cannot write `toolkit-accessibility` into the real dconf. Export `AT_SPI_BUS_ADDRESS` for the application under test. Then leak-check against the real bus in every phase. The export is not optional: libatspi consults the X root window's `AT_SPI_BUS` property before it consults the session bus, so an application sharing the desktop's display silently joins the desktop's accessibility bus, and the isolation looks airtight while measuring the wrong thing.
