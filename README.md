# Axon

Axon is a local macOS accessibility service that gives agents a typed, composable path into running apps.

It runs as a menu bar service app, exposes a small JSON-RPC command surface over a Unix socket, and provides an MCP stdio facade for agent clients. The core loop is:

1. capture app state
2. resolve an honest target
3. perform a primitive action
4. verify or continue with an invocation-scoped plan

## Quick Start

```sh
brew install --cask bleugreen/tap/axon
axon
```

For source checkout development:

```sh
make build
make test
make package-app
```

## Documentation

- [Install and Operations](docs/install.md): build, daemon lifecycle, Codex MCP config, logs, and troubleshooting.
- [Tool Surface](docs/tool-surface.md): MCP/CLI commands, target shapes, screenshots, action semantics, and current caveats.
- [Automation Plans](docs/plans.md): YAML plan schema, control flow, output modes, failure behavior, and examples.
- [Design](docs/design.md): architecture and long-term direction.
- [Decision Log](docs/decision-log.md): durable decisions made while shaping the project.
- [Implementation Plan](docs/implementation-plan.md): phase map and test strategy.
- [Issues](docs/issues): continuity notes for known gaps and follow-up work.

## Current Shape

Axon currently supports:

- building a signed `Axon.app` menu bar service with bundled `axon` CLI for Homebrew cask installation
- a legacy signed local LaunchAgent mode for daemon experiments
- compact app snapshots with per-snapshot handles
- opt-in embedded screenshots returned as MCP image content
- locator resolution over role, subrole, title, value, description, identifier, actions, and ancestors
- primitive actions: click, scroll, drag, perform AX action, set value, type text, press key
- coarse `changed_since(snapshotId)` checks backed by observer hints plus fresh app/window signatures
- invocation-scoped YAML or JSON automation plans with conditionals, waits, repeat loops, assertions, args, dry runs, and compact outputs

Scroll is intentionally AX-native today: Axon resolves an offscreen descendant in the requested direction and requests `AXScrollToVisible`. Drag is still an escape-hatch pointer primitive; see [Drag Targeting and Verification](docs/issues/2026-05-12-drag-targeting-and-verification.md) for the next shape.
