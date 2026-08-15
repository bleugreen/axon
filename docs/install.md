# Install Axon

Axon runs locally on your computer and gives an agent access to the accessibility layer already built into macOS, Windows, and Linux. The service is visible, inspectable, and communicates with agent clients over a local socket.

On macOS the install is one application, `Axon.app`, containing:

- the menu bar service that owns accessibility access,
- `Axon Editor.app`, for opening and editing `.axn` files, nested at `Contents/Library/Applications`,
- `axon`, the command-line and MCP entrypoint, at `Contents/Resources/bin/axon`.

One application means the release archive extracts to a single bundle you drag into `/Applications`, replacing any copy already there, and the recorder and the editor can never reach different versions.

## Install

### macOS or Linux

```sh
curl -fsSL https://axn.dev/install.sh | sh
```

### Windows

Open an ordinary PowerShell window, then run:

```powershell
irm https://axn.dev/install.ps1 | iex
```

The installer registers a per-user Task Scheduler entry and both steady-state install and uninstall run without Administrator access. The archive contains the `axon-win.exe` command-line interface and its sibling `axon-win-daemon.exe`, which runs without opening a console window. Both executables must be present and validly signed before the installer changes the registration.

The installers verify the release checksum, install into a permanent versioned directory, register the daemon from that immutable location, and put a stable CLI entry point on `PATH`. Linux maintains `~/.local/lib/axon/current`; Windows maintains `%LOCALAPPDATA%\Axon\current` and the stable command name `axon.exe`. Upgrades repoint these aliases, so external MCP configurations do not retain an older bridge. Pin a release with `AXON_VERSION=0.3.1` on macOS or Linux. In PowerShell, set `$env:AXON_VERSION = '0.3.1'` before running the installer.

On macOS, `Axon.app` and the editor nested inside it are one versioned unit. The daemon opens only the editor shipped inside it with the same version and bundle identities; it never falls back to an older Launch Services registration. If the nested editor is missing or mismatched, reinstall Axon rather than copying applications around by hand.

### Updating

The menu bar's **Check for Updates** performs the update itself on every install that Homebrew does not manage. It resolves the newest release from GitHub, downloads the archive, verifies its published checksum and that it is signed by the same developer identity as the copy asking, and then replaces the install in place: a bundle at a fixed path such as `/Applications/Axon.app` is swapped where it stands, and an `install.sh` install gets a new version directory beside the current one. It finishes by re-registering the daemon from the new bundle, which is what carries the Accessibility and Screen Recording approvals across without a new prompt. If any check fails, nothing is replaced and the menu offers both another attempt and the release page.

A Homebrew-managed install still updates through `brew upgrade --cask bleugreen/tap/axon`, which the menu item runs for you.

External MCP clients should use the stable path rather than a versioned directory. Register it from
your shell so the home-directory variable is resolved into the absolute executable path stored by
the client:

```sh
claude mcp add axon -- "$HOME/.local/lib/axon/current/axon-linux" mcp
```

```powershell
$axon = Join-Path $env:LOCALAPPDATA 'Axon\current\axon.exe'
claude mcp add axon -- $axon mcp
```

The installer prints the corresponding Claude and Codex commands with the resolved path.

#### Upgrading an older elevated Windows install

Windows releases installed by the older Administrator-only installer have an elevated scheduled task that an ordinary shell can use but cannot replace or remove. If the installer identifies that legacy registration, it leaves the working task unchanged and prints the one-time migration sequence:

1. Open PowerShell with **Run as administrator**.
2. Run the currently installed `axon daemon uninstall`.
3. Close the Administrator window.
4. Run `irm https://axn.dev/install.ps1 | iex` in ordinary PowerShell.

After that migration, future installs, upgrades, restarts, and uninstalls remain per-user and unelevated.

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

Developers bundling Axon into another product should use the managed lifecycle described in [Embedding Axon](embedding.md).

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

`Orphaned:` lists install directories under `~/.local/lib/axon` that nothing points at. They are
harmless until an MCP client launches one by its absolute path, at which point that client is
talking to whatever release the directory holds. Remove the ones you recognize as old.

### Two identities, two tools

Axon answers to two different names, and using the wrong one is the most common dead end when
repairing an install:

- `dev.axon.daemon` is the **launchd label**. It is what `launchctl` takes, and `axon status`
  prints it beside the registered path: `Registration: dev.axon.daemon -> /Applications/Axon.app/Contents/MacOS/Axon`.
- `com.bleugreen.axon` is the **bundle identifier**. It is what macOS records privacy grants
  against, and what `tccutil` and `open -b` take.

So a full stop-and-reset uses one of each, and neither command accepts the other's name:

```sh
launchctl bootout gui/$(id -u)/dev.axon.daemon      # stop and unregister the login item
tccutil reset Accessibility com.bleugreen.axon      # revoke the Accessibility approval
```

### Two menu bar icons

Two icons means two copies of Axon are running and only one of them owns the socket. The copy that
lost says so: its menu names the version, path, and process id of the copy that is serving, and
offers **Use This Copy**, which re-registers the daemon from the bundle you are looking at and
quits. That is the same repair as running `daemon install` from that bundle's CLI by hand, and it
keeps both privacy grants because the grants follow the bundle identifier rather than the path.

The menu also says **Login item points at ...** when the copy that is serving is not the copy
launchd starts at login, and names a leftover standalone `Axon Editor.app` from before the editor
shipped nested.

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
