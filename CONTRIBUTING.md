# Contributing to Axon

Thanks for the interest. This document covers the practical bits — setup, the test/build loop, and a few load-bearing shapes worth knowing before you change them.

## Prerequisites

- macOS 14 (Sonoma) or newer
- Xcode 15+ command line tools
- Swift 6.2+ (the project pins via `.swift-version`)

If your system Swift toolchain is unhealthy, [Swiftly](https://www.swift.org/install/macos/swiftly/) manages a user-local toolchain without touching the system one.

## Build and Test

```sh
make build
make test
```

Run the CLI against a local socket without packaging the app:

```sh
AXON_SOCKET_PATH=/tmp/axon.sock swift run axon serve
swift run axon snapshot com.apple.finder
```

Build a signed app bundle (unsigned ad-hoc by default, suitable for local testing):

```sh
make package-app
```

For signing and notarization options, see [docs/install.md](docs/install.md).

## Releasing

Releases are fully automated by [`.github/workflows/release.yml`](.github/workflows/release.yml), triggered by pushing a `vX.Y.Z` tag. CI builds, signs, **notarizes and staples** the bundle, publishes the GitHub release, and updates the `bleugreen/homebrew-tap` cask. The procedure is:

1. Bump the version in all three places: `Sources/AxonCore/AxonVersion.swift`, `scripts/package-app`, and `docs/install.md`.
2. `make test` to confirm green.
3. Commit as `Bump to X.Y.Z` with a one-paragraph summary of what shipped since the last release.
4. `git tag vX.Y.Z && git push origin main vX.Y.Z`.
5. Watch CI with `gh run watch` and confirm the release asset and tap cask land.

Do **not** run `make package-app` or `gh release create` as part of a release. `make package-app` produces a local, **non-notarized** bundle for testing only; a hand-created release publishes that non-notarized zip until the CI run overwrites it. The tag push is the entire release action — everything else is CI's job.

## Accessibility for Development

The daemon needs macOS Accessibility permission. The deployed `Axon.app` carries a stable bundle identity (`com.bleugreen.axon`) for TCC, so once approved it survives rebuilds.

For source-checkout development against `.build/debug/axon`, TCC trust can be invalidated by rebuilds. If you hit `Accessibility: denied` after a rebuild, toggle the entry off and on in **System Settings → Privacy & Security → Accessibility**.

## Stability Contracts

Two shapes are intended as durable contracts. Changes to either need a deliberate decision, ideally captured in [docs/decision-log.md](docs/decision-log.md):

- **The JSON-RPC socket protocol.** Method names, parameter shapes, and error envelopes. The CLI and MCP facade are both clients of this protocol; downstream tools may be too.
- **The `.axn` file format.** A `.axn` file is a saved batch — `{ version, actions: [{ tool, ...args }] }`. New tools must keep their batch arguments backward compatible with existing recorded files; removing or renaming a tool breaks playback.

Implementation details below those two surfaces — the snapshot internals, locator scoring, the observer layer — are free to evolve.

## Tests

- Unit tests for locator scoring and ambiguity behavior use saved synthetic trees.
- Integration tests exercise real AX behavior against fixture apps where possible.
- Manual smoke tests against Finder, System Settings, and a browser are useful for verifying observer and screenshot behavior.

Add tests with the change. New tools, locator features, and batch behavior should ship with unit coverage against fixture trees.

## Reporting Issues

File bugs at the GitHub repo. Useful info:

- `axon status` output
- macOS version and target app (bundle id helps a lot)
- The minimal sequence of tool calls or `.axn` file that reproduces the issue
- If applicable, a redacted snapshot from `axon snapshot <app>` showing what the tree looked like

Accessibility behavior varies enormously by app, so a concrete reproduction is often the difference between a one-line fix and a wild goose chase.

## Design Direction

Before proposing a substantial new feature, skim [docs/design.md](docs/design.md) and the open notes in [docs/issues](docs/issues). The project favors:

- AX-native primitives over event-faking
- Honest dispatch-vs-goal results over optimistic success
- Composing existing tools over inventing new control-flow surfaces
- Recordable, human-readable artifacts over opaque session state

When in doubt, the existing tool surface is usually the right place to land new capability rather than a parallel layer above it.
