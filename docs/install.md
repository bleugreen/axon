# Install and Operations

Axon is one Swift executable with three important modes:

- `axon serve`: long-running daemon that owns snapshots, handles, observer state, and visual overlay settings
- `axon mcp`: stdio MCP facade that forwards tool calls to the daemon socket
- `axon daemon ...`: user LaunchAgent installer and lifecycle commands

## Requirements

- macOS 14 or newer
- Swift 6.3.1, pinned by `.swift-version`
- Accessibility permission for the installed daemon identity
- ScreenCaptureKit permission if macOS prompts while using screenshots

The examples use Swiftly's explicit Swift path:

```sh
~/.swiftly/bin/swift build
~/.swiftly/bin/swift test
```

The repo also exposes common commands through `make`:

```sh
make build
make test
make check-local
```

## Foreground Development

Run the socket daemon directly while debugging daemon behavior:

```sh
AXON_SOCKET_PATH=/tmp/axon.sock ~/.swiftly/bin/swift run axon serve
```

In another terminal:

```sh
AXON_SOCKET_PATH=/tmp/axon.sock ~/.swiftly/bin/swift run axon health
AXON_SOCKET_PATH=/tmp/axon.sock ~/.swiftly/bin/swift run axon apps
```

Foreground mode uses the terminal process identity for macOS permissions. LaunchAgent mode uses the installed app bundle identity, so trust can differ between the two.

## LaunchAgent Install

Install and start the background daemon:

```sh
make install-daemon
make start-daemon
make health
```

`daemon install` copies the current built executable into:

```text
~/Library/Application Support/Axon/Axon Daemon.app/Contents/MacOS/axon
```

It writes an app bundle with bundle id `dev.axon.daemon`, signs it with the best available local signing identity or ad-hoc signing, and installs this LaunchAgent:

```text
~/Library/LaunchAgents/dev.axon.daemon.plist
```

The LaunchAgent runs the installed app bundle in `serve` mode, keeps it alive, and exposes the daemon socket at `/tmp/axon.sock` unless `AXON_SOCKET_PATH` is set at install/start time.

## Permissions

Check the daemon process, not just the terminal:

```sh
~/.swiftly/bin/swift run axon health
```

If it reports `accessibility: denied`, open System Settings > Privacy & Security > Accessibility and approve Axon. You can also ask the running daemon identity to prompt macOS:

```sh
make request-accessibility
```

If System Settings shows stale duplicate Axon rows, remove them, restart the daemon, and approve the new `dev.axon.daemon` identity.

## Logs and Status

```sh
make status
make logs
```

Stop, restart, or uninstall:

```sh
make stop-daemon
make start-daemon
make uninstall-daemon
```

After changing Axon code, rebuild and restart the daemon so the installed app bundle receives the new executable:

```sh
make build
make start-daemon
```

`daemon start` reinstalls the current executable before bootstrapping the service.

## Codex MCP Config

Build Axon before starting a Codex session:

```sh
~/.swiftly/bin/swift build
```

Add this MCP server entry to Codex config:

```toml
[mcp_servers.axon]
command = "/Users/mitch/projects/axon/.build/debug/axon"
args = ["mcp"]
```

Print the same snippet for the current checkout:

```sh
make codex-mcp-config
```

The MCP process is intentionally thin. It forwards calls to the daemon at `AXON_SOCKET_PATH` or `/tmp/axon.sock`, and does not own snapshots or observers. Restart the Codex session after rebuilding when you need the MCP facade process to pick up a new `.build/debug/axon` binary.

## Visual Overlay

Target badges are enabled by default:

- planned target flash: 250 ms
- result linger: 1100 ms

Disable or tune at daemon start/install time:

```sh
AXON_VISUAL_OVERLAY=0 ~/.swiftly/bin/swift run axon daemon start
AXON_VISUAL_OVERLAY_PLANNED_MS=400 AXON_VISUAL_OVERLAY_RESULT_MS=1500 ~/.swiftly/bin/swift run axon daemon start
```

The LaunchAgent preserves only Axon-specific environment keys, not the whole shell environment.

## Troubleshooting

`Connection refused` usually means the daemon is not running or has not created `/tmp/axon.sock` yet. Run `make status`, inspect `daemon.err.log`, then `make start-daemon`.

`Connection closed before a full response was received` means the daemon accepted the socket and exited or crashed mid-response. Check `daemon.err.log`, rebuild, and restart.

`accessibility: denied` means the installed daemon identity lacks AX trust. Approving Terminal or Codex is not enough for LaunchAgent mode.

Empty or missing screenshots usually mean ScreenCaptureKit could not capture the target window. Check macOS screen recording prompts and prefer `get_screenshot` for screenshot-only smoke tests.
