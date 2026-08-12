# Axon

Axon is a local accessibility service that gives agents a typed, composable path into running apps on macOS, Windows, and Linux. It is the connective layer between an agent's intent and an app's UI — semantic locators over coordinates, a flat set of primitive actions, honest results, and recordable sessions that replay as plain text files.

On macOS it runs as a menu bar service; on Windows and Linux the sibling Rust daemons (`axon-win`, `axon-linux`) serve the same surface. Each exposes a small JSON-RPC command surface over local IPC and provides an MCP stdio facade for agent clients. What is proven to work where — separated into Supported, Supported with limits, and Experimental tiers — is recorded in the [cross-platform support matrix](docs/cross-platform.md#support-matrix). The core loop is:

1. look at app state
2. find an honest target
3. perform a primitive action
4. record the call so it can be replayed

## Quick Start

macOS or Linux:

```sh
curl -fsSL https://axn.dev/install.sh | sh
```

Windows PowerShell:

```powershell
irm https://axn.dev/install.ps1 | iex
```

Or install on macOS with Homebrew:

```sh
brew install --cask bleugreen/tap/axon
axon
```

Then register the installed CLI with an MCP client:

```sh
claude mcp add axon -- axon mcp   # or: codex mcp add axon -- axon mcp
```

On macOS, `axon` with no arguments launches `Axon.app`, checks the socket, and requests Accessibility permission if it is missing. Approve `Axon.app` in **System Settings → Privacy & Security → Accessibility**. Once accessibility is trusted, the setup output prints the register-with-MCP commands shown above.

## Why Axon

Every desktop platform already ships a semantic description of its running apps — Accessibility on macOS, UI Automation on Windows, AT-SPI2 on Linux. These APIs expose what is actually on screen as roles, labels, values, and actions, so a button can be addressed as a button rather than a region of pixels. Axon is a small, local, open-source utility layer over that surface: one consistent tool shape across platforms, nothing gated, hosted, or proprietary. The APIs were always public; Axon is the thing that makes everything downstream easier.

The unit of memory is the **`.axn` file** (axon // action) — a saved sequence of past tool calls that an agent or user can replay, edit, and share. Sessions become re-runnable artifacts rather than ephemeral chat history. If an axon is a neuron's path to muscle, a `.axn` is a myelinated one: a route taken often enough that it gets wrapped in insulation and becomes a reflex.

The four guarantees Axon tries to make:

- **Semantic targets, not coordinates.** Locators use AX role, label, identifier, window scope, ancestry, nearby text, action support, value signals, and weak frame tie-breakers. Point targets are an escape hatch.
- **Honest results.** Dispatch success and goal success are distinct. A click that posted but produced no UI change does not return "success."
- **Stable contracts.** The JSON-RPC socket protocol and the `.axn` file format are intended as durable shapes that downstream tools can build on.
- **Local and inspectable.** The service is a menu bar app you can see, quit, restart, and approve. `.axn` files are human-readable text.

## Documentation

- [Install and Operations](docs/install.md) — build, daemon lifecycle, MCP setup, logs, troubleshooting
- [Cross-platform](docs/cross-platform.md) — the evidence-based support matrix, backend design, and live verification lanes
- [Embedding Axon](docs/embedding.md) — the contract for bundling Axon: versioned artifacts, lifecycle verbs, and the `health-v1` status document
- [Tool Surface](docs/tool-surface.md) — MCP/CLI commands, target shapes, screenshots, action semantics
- [The `.axn` File](docs/axn.md) — file schema, history export, replay
- [Design](docs/design.md) — architecture and long-term direction
- [Decision Log](docs/decision-log.md) — durable decisions made while shaping the project
- [Open Issues](docs/issues) — known gaps and active follow-up work

## Current Shape

- signed `Axon.app` menu bar service with bundled `axon` CLI, installed via Homebrew cask
- compact app snapshots with per-snapshot handles
- opt-in embedded screenshots returned as MCP image content
- scored locator resolution over role, subrole, title, value, description, identifier, actions, window scope, nearby text, frame hints, and ancestors
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
