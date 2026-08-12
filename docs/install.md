# Install Axon

Axon runs locally on your computer and gives an agent access to the accessibility layer already built into macOS, Windows, and Linux. The service is visible, inspectable, and communicates with agent clients over a local socket.

On macOS, the install includes:

- `Axon.app`, the menu bar service that owns accessibility access.
- `Axon Editor.app`, for opening and editing `.axn` files.
- `axon`, the command-line and MCP entrypoint.

## Install

### macOS or Linux

```sh
curl -fsSL https://axn.dev/install.sh | sh
```

### Windows

```powershell
irm https://axn.dev/install.ps1 | iex
```

The installers verify the release checksum, install into a permanent versioned directory, register the daemon from that location, and put its CLI on `PATH`. Pin a release with `AXON_VERSION=0.3.1` on macOS or Linux. In PowerShell, set `$env:AXON_VERSION = '0.3.1'` before running the installer.

### Homebrew on macOS

```sh
brew install --cask bleugreen/tap/axon
axon
```

The direct installer refuses to create a second installation when the Homebrew cask is already installed. Upgrade a Homebrew-managed machine with `brew upgrade --cask bleugreen/tap/axon`.

Running `axon` with no arguments launches the service, checks its local connection, and requests Accessibility permission only when it is missing. Once setup is healthy, continue to [Connect your agent](connect.md).

## Runtime Commands

For a person setting Axon up on their own Mac:

```sh
axon           # launch Axon.app and request permissions when needed
axon start     # launch the installed Axon.app menu bar service
axon status    # describe the daemon, permissions, and capabilities
axon mcp       # the stdio MCP entrypoint clients run
```

`axon setup` remains an explicit alias for no-arg `axon` for scripts that prefer named commands.

For a consumer embedding Axon in something else, the CLI-managed daemon lifecycle is a separate
path from the menu bar app. See [Embedding Axon](embedding.md) for the full contract:

```sh
axon daemon install     # register this install's daemon to start at login, then wait for health
axon daemon restart
axon daemon uninstall
axon shutdown           # stop the daemon, keep the registration
axon status --json      # the machine-readable health-v1 document
axon version
```

The two differ in how you drive Axon, not in what runs. `Axon.app` is the ordinary user
experience: a visible menu bar service to inspect, quit, and approve. The `daemon` verbs put that
same app under launchd so a consumer can manage Axon without a person in the loop — on macOS
`daemon install` registers the enclosing `Axon.app`, so Accessibility and Screen Recording are
granted to the app bundle once and survive every upgrade. See
[Embedding Axon](embedding.md#what-gets-registered) for why. Invoke it from a permanent location
regardless, because launchd still has to find the bundle.

One consequence worth knowing: when a registration is installed, launchd keeps the app alive, so
**Quit** in the menu bar restarts it rather than stopping it. Use `axon shutdown` to stop the
running daemon, or `axon daemon uninstall` to remove the registration as well.

The lower-level socket server still exists:

```sh
axon serve
```

It is what a registration without an enclosing app bundle runs — a development build, for
instance — and it is useful directly when debugging.

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

`axon status` names what is wrong, and `axon status --json` gives the same answer with stable
reason codes. Both exit 0 whatever they find, because describing a broken machine correctly is a
success.

`Daemon: not running` means nothing answered on `/tmp/axon.sock`. Run `axon start` for the menu
bar app, or `axon daemon restart` for the CLI-managed daemon.

`Daemon: running, not ready (version-skew)` means a daemon is serving but is a different version
from the CLI asking it. That is what an upgrade in place looks like before a restart; run
`axon daemon restart`.

`accessibility: not granted` means macOS has not approved the `com.bleugreen.axon` app identity.
Approve it in System Settings > Privacy & Security > Accessibility. `screenRecording: not granted`
costs screenshots and nothing else.

### Removing a duplicate server

Before ownership was enforced, two servers could hold the socket at once and clients reached
whichever bound last. Check for that with:

```sh
lsof /tmp/axon.sock
```

More than one holder means an older install is still running alongside `Axon.app`, usually a
`dev.axon.daemon` LaunchAgent from when the CLI installed a copied daemon bundle into Application
Support. That workflow is gone — `daemon install` now registers a daemon inside the install you
invoke it from, never a copy — so remove the leftover once:

```sh
launchctl bootout gui/$(id -u)/dev.axon.daemon
rm -f ~/Library/LaunchAgents/dev.axon.daemon.plist
rm -rf ~/Library/"Application Support"/Axon/"Axon Daemon.app"
axon start
```

Do this before upgrading. A current Axon refuses to displace a server that is still answering,
including one old enough to predate the lock, so a leftover daemon keeps the new one from serving
instead of being silently replaced by it.
