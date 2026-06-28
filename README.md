# Axon

Axon is a local macOS accessibility service that gives agents a typed, composable path into running apps. It is the connective layer between an agent's intent and an app's UI — semantic locators over coordinates, a flat set of primitive actions, honest results, and recordable sessions that replay as plain text files.

It runs as a menu bar service, exposes a small JSON-RPC command surface over a Unix socket, and provides an MCP stdio facade for agent clients. The core loop is:

1. look at app state
2. find an honest target
3. perform a primitive action
4. record the call so it can be replayed

## Quick Start

```sh
brew install --cask bleugreen/tap/axon
axon
claude mcp add axon -- axon mcp   # or: codex mcp add axon -- axon mcp
```

`axon` with no arguments launches `Axon.app`, checks the socket, and requests Accessibility permission if it is missing. Approve `Axon.app` in **System Settings → Privacy & Security → Accessibility**. Once accessibility is trusted, the setup output prints the register-with-MCP commands shown above.

## Why Axon

Computer Use APIs ship as closed-source pixel-pushing services. Axon takes the opposite stance: it is a small, local, open-source utility layer over the macOS Accessibility API. Nothing about it is gated, hosted, or proprietary. AX is public-by-mandate; this is just the thing that makes everything downstream easier.

The unit of memory is the **`.axn` file** (axon // action) — a saved sequence of past tool calls that an agent or user can replay, edit, and share. Sessions become re-runnable artifacts rather than ephemeral chat history. If an axon is a neuron's path to muscle, a `.axn` is a myelinated one: a route taken often enough that it gets wrapped in insulation and becomes a reflex.

The four guarantees Axon tries to make:

- **Semantic targets, not coordinates.** Locators use AX role, label, identifier, ancestry, action support, and value signals. Point targets are an escape hatch.
- **Honest results.** Dispatch success and goal success are distinct. A click that posted but produced no UI change does not return "success."
- **Stable contracts.** The JSON-RPC socket protocol and the `.axn` file format are intended as durable shapes that downstream tools can build on.
- **Local and inspectable.** The service is a menu bar app you can see, quit, restart, and approve. `.axn` files are human-readable text.

## Documentation

- [Install and Operations](docs/install.md) — build, daemon lifecycle, MCP setup, logs, troubleshooting
- [Tool Surface](docs/tool-surface.md) — MCP/CLI commands, target shapes, screenshots, action semantics
- [Action Batches and `.axn` Files](docs/plans.md) — batch schema, history export, replay
- [Design](docs/design.md) — architecture and long-term direction
- [Decision Log](docs/decision-log.md) — durable decisions made while shaping the project
- [Open Issues](docs/issues) — known gaps and active follow-up work

## Current Shape

- signed `Axon.app` menu bar service with bundled `axon` CLI, installed via Homebrew cask
- compact app snapshots with per-snapshot handles
- opt-in embedded screenshots returned as MCP image content
- scored locator resolution over role, subrole, title, value, description, identifier, actions, and ancestors
- primitive actions: `click`, `type`, `keyboard`, `scroll`, `drag`, `invoke`
- coarse `look(since:)` checks backed by observer hints plus fresh app/window signatures
- `run` and `.axn` files: ordered tool-call sequences, replayable from CLI or MCP
- `save`: turn recorded session history into an editable `.axn` file

Scroll is intentionally AX-native: Axon resolves an offscreen descendant in the requested direction and requests `AXScrollToVisible`. Drag is still an escape-hatch pointer primitive; see [Drag Targeting and Verification](docs/issues/2026-05-12-drag-targeting-and-verification.md) for the next shape.

## Building from Source

```sh
make build
make test
make package-app
```

See [Install and Operations](docs/install.md) for signing, notarization, and the development socket workflow.

## Contributing

Bug reports, fixture apps, and locator-quality improvements are all welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and the stability contracts to be aware of.

## License

MIT — see [LICENSE](LICENSE).
