# Install and Operations

Axon's deployed shape is a menu bar app plus a bundled CLI:

- `Axon.app` owns the long-running socket service in the user's Aqua session.
- `axon` is the CLI and MCP entrypoint installed on `PATH`.
- MCP clients run `axon mcp`, which forwards to the app-owned socket.

## Install

```sh
brew install --cask bleugreen/tap/axon
axon
```

With no arguments, `axon` launches `Axon.app`, checks the local socket, and requests Accessibility permission only when it is missing.

## Product Layout

The release artifact is a signed and preferably notarized zip:

```text
Axon-<version>.zip
└── Axon.app
    └── Contents
        ├── MacOS
        │   └── Axon
        └── Resources
            └── bin
                └── axon
```

The Homebrew cask installs `Axon.app` and links `Axon.app/Contents/Resources/bin/axon`.

`Axon.app` uses bundle id:

```text
com.bleugreen.axon
```

That bundle id is the stable macOS Accessibility trust identity.

## Building a Release Artifact

Build the app bundle and zip:

```sh
make package-app
```

The script writes:

```text
dist/Axon.app
dist/Axon-0.1.3.zip
```

It also prints the SHA-256 and a Homebrew cask stanza for `bleugreen/tap`.

For release signing, provide a Developer ID identity:

```sh
AXON_CODESIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" make package-app
```

For notarization, configure a notarytool keychain profile and pass it during packaging:

```sh
AXON_CODESIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
AXON_NOTARY_PROFILE="axon-notary" \
make package-app
```

When `AXON_NOTARY_PROFILE` is set, the packager submits the zip to Apple, staples the accepted ticket to `Axon.app`, and recreates the zip.

## Homebrew Cask

The intended tap command is:

```sh
brew install --cask bleugreen/tap/axon
```

The cask shape:

```ruby
cask "axon" do
  version "0.1.3"
  sha256 "<printed by scripts/package-app>"

  url "https://github.com/bleugreen/axon/releases/download/v#{version}/Axon-#{version}.zip"
  name "Axon"
  desc "Local macOS accessibility service for agents"
  homepage "https://github.com/bleugreen/axon"

  depends_on macos: ">= :sonoma"

  app "Axon.app"
  binary "#{appdir}/Axon.app/Contents/Resources/bin/axon"

  zap trash: [
    "~/Library/Application Support/Axon",
    "~/Library/Logs/Axon",
  ]
end
```

## Runtime Commands

```sh
axon
axon start
axon status
axon mcp
axon restart
axon quit
```

`axon setup` remains an explicit alias for no-arg `axon` for scripts that prefer named commands.

The lower-level development socket server still exists:

```sh
axon serve
```

That mode is useful for debugging, but it is not the deployed product center.

## Register with an Agent

Agent clients talk to Axon over MCP stdio. `axon mcp` is the stdio entrypoint; it forwards to the running `Axon.app` socket.

For Claude Code:

```sh
claude mcp add axon -- axon mcp
```

For Codex:

```sh
codex mcp add axon -- axon mcp
```

Other clients accept the same shape. The command to launch is `axon` (an absolute path is fine if `PATH` isn't propagated) with a single argument `mcp`.

After registering, the no-arg `axon` setup output reprints these commands whenever Accessibility is trusted, so it is safe to re-run as a "where do I paste this again" check.

## Permissions

macOS Accessibility approval cannot be automated. The app can only request the prompt and report status.

Normal first run:

```sh
axon
```

If Accessibility is denied, approve `Axon.app` in System Settings > Privacy & Security > Accessibility, then run:

```sh
axon status
```

ScreenCaptureKit may also prompt when screenshot capture is first used.

## Troubleshooting

`Socket: unreachable` means `Axon.app` is not running or could not bind `/tmp/axon.sock`. Run `axon start`, then `axon status`.

`Accessibility: denied` means macOS has not approved the `com.bleugreen.axon` app identity.

If an old development LaunchAgent is still running, stop it before testing `Axon.app`:

```sh
swift run axon daemon stop
```

## Development

Source checkout development uses Swift directly against the socket:

```sh
make build
make test
AXON_SOCKET_PATH=/tmp/axon.sock swift run axon serve
```

A legacy LaunchAgent installer remains for daemon experiments. It is not the deployed product path, but is useful for short-loop development without rebuilding the app bundle:

```sh
swift run axon daemon install
swift run axon daemon start
swift run axon daemon stop
```

For the installed product, prefer `Axon.app` — it gives the user a visible service to inspect, quit, restart, and approve.
