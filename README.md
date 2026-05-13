# Axon

Axon is a local macOS accessibility service that gives agents a typed nerve path into running apps.

The goal is to expose macOS Accessibility as a composable automation substrate: observe app state, resolve durable locators against live UI trees, perform actions, and verify the result.

Start with:

- [Design](docs/design.md)
- [Implementation plan](docs/implementation-plan.md)
- [Decision log](docs/decision-log.md)

## Development

This repo uses Swift 6.3.1 through Swiftly. The repository `.swift-version` pins that toolchain.

```sh
~/.swiftly/bin/swift test
~/.swiftly/bin/swift run axon doctor
```

Run the daemon in the foreground while developing:

```sh
AXON_SOCKET_PATH=/tmp/axon.sock ~/.swiftly/bin/swift run axon serve
```

Install and manage the user LaunchAgent:

```sh
~/.swiftly/bin/swift run axon daemon install
~/.swiftly/bin/swift run axon daemon start
~/.swiftly/bin/swift run axon daemon status
~/.swiftly/bin/swift run axon daemon stop
~/.swiftly/bin/swift run axon daemon uninstall
```

The daemon installer copies the current executable into `~/Library/Application Support/Axon/Axon Daemon.app`, signs that app bundle with the stable identifier `dev.axon.daemon`, and points the LaunchAgent at the bundled executable instead of `.build/debug/axon`. The LaunchAgent runs that binary in `serve` mode, keeps it alive, and writes logs under `~/Library/Logs/Axon/`.

After the first daemon install, macOS may require approving the installed daemon identity in Privacy & Security > Accessibility. Check the daemon process, not only the terminal process:

```sh
~/.swiftly/bin/swift run axon health
```

If health still reports `accessibility: denied`, ask the running daemon identity to prompt macOS directly:

```sh
~/.swiftly/bin/swift run axon request-accessibility
```

Target badges are enabled by default with a 250ms planned flash and a 1.1s result linger. Set `AXON_VISUAL_OVERLAY=0` to disable them, or override timing with `AXON_VISUAL_OVERLAY_PLANNED_MS` and `AXON_VISUAL_OVERLAY_RESULT_MS`.

Run the MCP stdio facade:

```sh
~/.swiftly/bin/swift run axon mcp
```

The MCP facade forwards tool calls to the daemon over `AXON_SOCKET_PATH`; it does not own snapshots, handles, observer state, or overlay configuration itself. Codex MCP config points at `.build/debug/axon`. After changing Axon code, run `~/.swiftly/bin/swift build` and restart the Codex session so its MCP server process picks up the rebuilt binary.

Resolve a locator through the daemon:

```sh
~/.swiftly/bin/swift run axon resolve com.cairn.desktop.dev '{"role":"AXButton","title":{"contains":"Issues"},"actions":["AXPress"]}'
```

For MCP, `get_app_state` defaults to compact output: `indexedNodes` with handles and useful metadata, no full nested `windows` tree, and no screenshot unless requested. Pass `includeTree: true` or `includeScreenshot: true` when the client needs those heavier fields.
