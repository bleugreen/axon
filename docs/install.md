# Install Axon

Axon runs locally on your computer and gives an agent access to the accessibility layer already built into macOS, Windows, and Linux. The service is visible, inspectable, and communicates with agent clients over a local socket.

On macOS the install is one application, `Axon.app`, containing:

- the Axon daemon, the bundle's main executable at `Contents/MacOS/Axon`. It serves the local socket and is the one process macOS grants Accessibility and Screen Recording to,
- `Axon Menu.app`, the menu bar app, nested at `Contents/Library/Applications`. It shows the daemon's state and holds no permission of its own,
- `Axon Editor.app`, for opening and editing `.axn` files, nested beside the menu,
- `axon`, the command-line and MCP entrypoint, at `Contents/Resources/bin/axon`. `axon mcp` runs the daemon's own MCP facade: it replaces itself with `Contents/MacOS/Axon mcp` from the same bundle, so MCP clients on macOS get the same tool list and result shapes as on Windows and Linux.

One application means the release archive extracts to a single bundle you drag into `/Applications`, replacing any copy already there, and the daemon, the menu, and the editor can never reach different versions.

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

On macOS, `Axon.app` and the apps nested inside it are one versioned unit. Axon opens only the editor shipped inside the same bundle with the same version and bundle identities; it never falls back to an older Launch Services registration. If the nested menu or editor is missing or mismatched, reinstall Axon rather than copying applications around by hand.

### Updating

The menu bar's **Check for Updates** performs the update itself on every install that Homebrew does not manage. It resolves the newest release from GitHub, downloads the archive, verifies its published checksum, that it is signed by the same developer identity as the copy asking, and that it carries the daemon, the CLI, the nested menu, and the nested editor at the release's version, and then replaces the install in place: a bundle at a fixed path such as `/Applications/Axon.app` is swapped where it stands, and an `install.sh` install gets a new version directory beside the current one. It finishes by re-registering the daemon and the menu from the new bundle, which is what carries the Accessibility and Screen Recording approvals across without a new prompt. If any check fails, nothing is replaced and the menu offers both another attempt and the release page.

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

Running `axon` with no arguments starts Axon, checks its local connection, and requests Accessibility permission only when it is missing. Once setup is healthy, continue to [Connect your agent](connect.md).

## Starting Axon on macOS

The daemon and the menu run as two separate login items, the launchd jobs `dev.axon.daemon` and `dev.axon.menu`. Axon installs, restarts, stops, and removes them together, because a daemon without its menu has no visible presence and a menu without its daemon can only show an error.

Opening `Axon.app` from Finder, Spotlight, or `open` never starts a second daemon. It runs the bundled `axon start` and exits, and `axon start` acts on what launchd has registered:

- **Nothing is registered**, as on the first open after a drag install or a Homebrew install, or **this copy is registered by an older release**, as after dragging 0.4.0 over a 0.3.x install: it registers this copy's daemon and menu to start at login and starts them.
- **This copy is registered**: it starts whichever of the two is not running. This is how a menu you quit comes back.
- **A different copy is registered**: it changes nothing, starts that copy's menu, and prints which copy is registered and how to switch to the one you opened.

A copy running from a temporary location, such as an app opened straight from Downloads that macOS runs from a translocated path, is not registered: move `Axon.app` to Applications first.

After dragging 0.4.0 over a running 0.3.x, or after `brew upgrade`, run `axon start` from a terminal. Opening `Axon.app` while the 0.3.x app is still running may only bring that running app forward instead of starting the new bundle; `axon start` does not depend on Launch Services.

**Quit Axon Menu** quits only the menu bar app. The daemon keeps serving agents, and the menu stays quit until you open `Axon.app` again or run `axon start`. Nothing in the menu stops the daemon; `axon shutdown` does.

## Runtime Commands

For a person setting Axon up on their own Mac:

```sh
axon           # start Axon, then request Accessibility when it is missing
axon start     # register this Axon.app if needed, then start the daemon and its menu
axon status    # describe the daemon, both login items, permissions, and capabilities
axon shutdown  # stop the daemon and the menu, leaving both registered
axon mcp       # the stdio MCP entrypoint clients run: the daemon's facade, Contents/MacOS/Axon mcp
```

`axon mcp` works only from inside `Axon.app`, because the facade it runs ships in the same bundle. A copy of the CLI outside the bundle refuses and says so. The facade answers `initialize` with protocol version `2025-03-26` whatever version the client asks for, which MCP version negotiation allows: a client that supports `2025-03-26` proceeds with it, and one that does not disconnects.

`axon setup` remains an explicit alias for no-arg `axon` for scripts that prefer named commands.

`axon shutdown` leaves both login items registered, so they return at the next login or the next `axon start`. `axon daemon uninstall` stops both and removes their registrations, after which removing `Axon.app` is an ordinary delete.

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

Screen Recording is a separate approval for the same `Axon.app`. Without it, screenshots and screen text are unavailable and everything else keeps working.

## Troubleshooting

`axon status` names what is wrong, and `axon status --json` gives the same answer with stable
reason codes. Both exit 0 whatever they find, because describing a broken machine correctly is a
success.

`Daemon: not running` means nothing answered on `/tmp/axon.sock`. Run `axon start`, which loads
whichever login item is not loaded, or `axon daemon restart`, which restarts both registered jobs.

`Daemon: running, not ready (daemon-not-ready)` beside `accessibility: not granted` is what a
daemon waiting for its Accessibility approval looks like; approve `Axon.app` as described above.

`Daemon: running, not ready (version-skew)` means a daemon is serving but is a different version
from the CLI asking it. That is what an upgrade in place looks like before a restart; run
`axon daemon restart`.

`accessibility: not granted` means macOS has not approved the `com.bleugreen.axon` app identity.
Approve it in System Settings > Privacy & Security > Accessibility. `screenRecording: not granted`
costs screenshots and screen text and nothing else.

`axon status` also prints one line for each login item, `dev.axon.daemon` and `dev.axon.menu`,
saying whether launchd has it loaded and running and which program its plist names. A daemon that
is registered but not loaded is what `axon shutdown` leaves behind; `axon start` loads it again.

`Orphaned:` lists install directories under `~/.local/lib/axon` that nothing points at. They are
harmless until an MCP client launches one by its absolute path, at which point that client is
talking to whatever release the directory holds. Remove the ones you recognize as old.

### Two identities, two tools

Axon answers to two different names, and using the wrong one is the most common dead end when
repairing an install:

- `dev.axon.daemon` and `dev.axon.menu` are the **launchd labels**. They are what `launchctl`
  takes, and `axon status` prints them beside the registered paths:
  `Registration: dev.axon.daemon -> /Applications/Axon.app/Contents/MacOS/Axon`.
- `com.bleugreen.axon` is the **bundle identifier**. It is what macOS records privacy grants
  against, and what `tccutil` takes. The nested menu has an identifier of its own,
  `com.bleugreen.axon.menu`, which holds no grant.

So a full stop-and-reset uses both kinds, and neither command accepts the other's name:

```sh
launchctl bootout gui/$(id -u)/dev.axon.menu        # stop the menu login item
launchctl bootout gui/$(id -u)/dev.axon.daemon      # stop the daemon login item
tccutil reset Accessibility com.bleugreen.axon      # revoke the Accessibility approval
```

Boot the menu out before the daemon, which is the order `axon shutdown` uses; a menu left running
without its daemon can only report that it is gone.

### Another copy is serving

Only one Axon menu runs at a time: a second copy's menu exits as soon as it starts. When the
daemon answering on the socket is not the one inside the menu's own `Axon.app`, because another copy
is registered or a development daemon holds the socket, the menu names the version, path, and
process id of the daemon that is serving and offers **Use This Copy**. That re-registers the daemon
and the menu from the bundle the menu belongs to, then quits. It is the same repair as running that
bundle's `Contents/Resources/bin/axon daemon install` by hand, and it keeps both privacy grants
because the grants follow the bundle identifier rather than the path.

The menu also says **Login item points at ...** when the copy launchd starts at login is not the
copy the menu belongs to, and names a leftover standalone `Axon Editor.app` from before the editor
shipped nested.

**Incompatible daemon at ...** means the daemon answering does not speak the menu's contract. A
daemon from before 0.4.0 publishes no contract at all, so this is what a 0.4.0 menu shows over a
0.3.x daemon; see [Going back to 0.3.6](#going-back-to-036) for the one way that arises on purpose.

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

### `axon refresh-secrets` was retired

Releases before 0.4.0 could redact values found in a 1Password-backed index that
`axon refresh-secrets` built. 0.4.0 removes that capability: Axon now redacts only secrets bound to
a run's arguments and values matching its deterministic credential patterns. `axon refresh-secrets`
exits with an error that says so.

The first `daemon install` of 0.4.0 deletes the old index at
`~/Library/Application Support/Axon/active-credential-index.json` and prints that it did. An in-app
update runs it, and so does opening `Axon.app` or running `axon start` after any other upgrade from
0.3.x.
The file held HMAC digests and is inert without its key. The key itself stays in your Keychain,
because deleting another program's Keychain item can raise a prompt in the middle of an upgrade that
is otherwise silent. Remove it yourself with:

```sh
security delete-generic-password -s com.bleugreen.axon.active-credential-index -a hmac-key-v1
```

### Going back to 0.3.6

0.3.6 is the last release whose daemon is the Swift app. It knows nothing about the menu login
item, so remove that first, then register the 0.3.6 bundle with its own CLI:

```sh
launchctl bootout gui/$(id -u)/dev.axon.menu
rm ~/Library/LaunchAgents/dev.axon.menu.plist
/path/to/0.3.6/Axon.app/Contents/Resources/bin/axon daemon install
```

Skipping the first two lines leaves the 0.4.0 menu running over the 0.3.6 daemon, where it shows
**Incompatible daemon** because a 0.3.6 daemon publishes no menu contract. Both releases share the
bundle identifier and signing team that the privacy grants are recorded against.
