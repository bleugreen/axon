# Axon

Axon is a local macOS accessibility service that gives agents a typed nerve path into running apps.

The goal is to expose macOS Accessibility as a composable automation substrate: observe app state, resolve durable locators against live UI trees, perform actions, and verify the result.

This repository is currently in planning mode. Start with:

- [Design](docs/design.md)
- [Implementation plan](docs/implementation-plan.md)
- [Decision log](docs/decision-log.md)

## Development

This repo uses Swift 6.3.1 through Swiftly. The repository `.swift-version` pins that toolchain.

```sh
~/.swiftly/bin/swift test
~/.swiftly/bin/swift run axon doctor
```

Run the MCP stdio facade:

```sh
~/.swiftly/bin/swift run axon mcp
```

Codex MCP config points at `.build/debug/axon`. After changing Axon code, run `~/.swiftly/bin/swift build` and restart the Codex session so its MCP server process picks up the rebuilt binary.

Run a local daemon and resolve a locator:

```sh
AXON_SOCKET_PATH=/tmp/axon.sock ~/.swiftly/bin/swift run axon serve
~/.swiftly/bin/swift run axon resolve com.cairn.desktop.dev '{"role":"AXButton","title":{"contains":"Issues"},"actions":["AXPress"]}'
```

For MCP, `get_app_state` defaults to compact output: `indexedNodes` with handles and useful metadata, no full nested `windows` tree, and no screenshot unless requested. Pass `includeTree: true` or `includeScreenshot: true` when the client needs those heavier fields.
