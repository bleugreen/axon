# Install and Operations

Axon's deployed shape is a menu bar daemon, a separate editor app, and a bundled CLI:

- `Axon.app` owns the long-running socket service in the user's Aqua session.
- `Axon Editor.app` owns document windows, normal app menus, and `.axn` editing.
- `axon` is the CLI and MCP entrypoint installed on `PATH`.
- MCP clients run `axon mcp`, which forwards to the app-owned socket.

## Install

Install the latest release directly on macOS or Linux:

```sh
curl -fsSL https://axn.dev/install.sh | sh
```

On Windows PowerShell:

```powershell
irm https://axn.dev/install.ps1 | iex
```

The installers verify the release checksum, install into a permanent versioned directory, register
the daemon from that location, and put its CLI on `PATH`. Pin a release with
`AXON_VERSION=0.3.1` on macOS or Linux. In PowerShell, the one-liner can be pinned with
`$env:AXON_VERSION = '0.3.1'; irm https://axn.dev/install.ps1 | iex`; a saved copy also accepts
`-Version 0.3.1`.

On macOS, Homebrew remains an alternative:

```sh
brew install --cask bleugreen/tap/axon
axon
```

The direct installer refuses to create a second installation when the Homebrew cask is already
installed. Upgrade a Homebrew-managed machine with `brew upgrade --cask bleugreen/tap/axon`.

With no arguments, `axon` launches `Axon.app`, checks the local socket, and requests Accessibility permission only when it is missing.

## Product Layout

The release artifact is a signed and preferably notarized zip:

```text
Axon-<version>-macos-aarch64.zip
└── Axon-<version>
    ├── Axon.app
    │   └── Contents
    │       ├── MacOS
    │       │   └── Axon
    │       └── Resources
    │           └── bin
    │               └── axon
    └── Axon Editor.app
        └── Contents
            └── MacOS
                └── AxonEditor
```

The Homebrew cask installs both apps and links `Axon.app/Contents/Resources/bin/axon`.

`Axon.app` uses bundle id:

```text
com.bleugreen.axon
```

That bundle id is the stable macOS Accessibility trust identity.

`Axon Editor.app` uses bundle id:

```text
com.bleugreen.axon.editor
```

## Building a Release Artifact

Build the app bundle and zip:

```sh
make package-app
```

The script writes:

```text
dist/Axon.app
dist/Axon Editor.app
dist/Axon-0.2.2-macos-aarch64.zip
dist/Axon-0.2.2-macos-aarch64.zip.sha256
```

The version comes from the repository-root `VERSION` file. Archives are named with the version and
the target so a consumer pinning a release can name the artifact it wants; see
[Embedding Axon](embedding.md).

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

When `AXON_NOTARY_PROFILE` is set, the packager submits the zip to Apple, staples the accepted ticket to both apps, and recreates the zip.

### The Rust daemons

The Windows and Linux daemons build natively on their own hosts:

```sh
make package-win      # on Windows
make package-linux    # on Linux
```

Packaging has two phases, and `scripts/package-rust` runs both unless told otherwise. Staging
builds the binary and lays out the directory that becomes the archive; archiving compresses that
directory and writes the `.sha256`. They are separable so that code signing can run in between:

```sh
scripts/package-rust axon-win --stage-only
# sign dist/axon-win-<version>-windows-x86_64/axon-win.exe here
scripts/package-rust axon-win --archive-only
```

A signature applied after archiving would not be inside the archive, and one applied after
checksumming would leave the checksum describing bytes that no longer exist.

Because the staging directory is named for the version alone, one left behind by a different
commit is indistinguishable by name from the build you meant to publish. Staging therefore records
what it built beside the directory, and archiving refuses a staging directory it does not recognize
rather than publishing another revision's bytes under this version. A dirty worktree is recorded as
dirty and cannot be identified more precisely than that, so restage after editing.

### Windows code signing

Releases sign `axon-win.exe` with [Azure Artifact
Signing](https://learn.microsoft.com/azure/artifact-signing/) (formerly Trusted Signing). The
release workflow's Windows job does this in the seam above, then verifies the signature from inside
the published archive and fails the release if it is not valid and timestamped. See
[Embedding Axon](embedding.md#signed-release-binaries) for why an unsigned Windows daemon is a
functional problem rather than a cosmetic one.

The job authenticates with a GitHub OIDC federated credential, so no signing secret is stored in
the repository. The credential's subject is scoped to the `release` GitHub environment, which is
why the job declares `environment: release` — renaming or removing that environment revokes the
job's ability to sign. The configuration it reads:

| Name | Kind | Purpose |
| --- | --- | --- |
| `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_SUBSCRIPTION_ID` | secrets | the Entra app registration that holds the Certificate Profile Signer role |
| `AZURE_SIGNING_ENDPOINT`, `AZURE_SIGNING_ACCOUNT`, `AZURE_SIGNING_PROFILE` | variables | which signing account and certificate profile to sign with |

Windows release signing is mandatory: missing signing configuration or an invalid or untimestamped
signature fails the release job.

## Homebrew Cask

The intended tap command is:

```sh
brew install --cask bleugreen/tap/axon
```

The cask shape:

```ruby
cask "axon" do
  version "0.2.2"
  sha256 "<printed by scripts/package-app>"

  url "https://github.com/bleugreen/axon/releases/download/v#{version}/Axon-#{version}-macos-aarch64.zip"
  name "Axon"
  desc "Local macOS accessibility service for agents"
  homepage "https://github.com/bleugreen/axon"

  depends_on macos: ">= :sonoma"

  app "Axon-#{version}/Axon.app"
  app "Axon-#{version}/Axon Editor.app"
  binary "#{appdir}/Axon.app/Contents/Resources/bin/axon"

  zap trash: [
    "~/Library/Application Support/Axon",
    "~/Library/Logs/Axon",
  ]
end
```

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

### Socket ownership

Exactly one server owns a socket path at a time, and the server enforces that itself rather than
trusting a caller to check first. Before it touches the pathname it takes an exclusive advisory
lock on a sidecar file — `/tmp/axon.sock.lock` for the default path — and holds that lock for as
long as it is listening. A server that finds the lock already held refuses to start, and names the
process holding it:

```text
axon: socket server failed: Another Axon server is already serving /tmp/axon.sock (pid 73376). Stop it, or set AXON_SOCKET_PATH to a different path.
```

The owning process is read out of the lock file rather than asked over the socket, so a server
that is wedged and answering nothing is still identified.

A server that crashes or is terminated leaves its socket file behind. Nothing needs cleaning up:
the next server reclaims the path once it holds the lock. What a server will not do is remove a
socket it does not own — it records the inode it bound and unlinks only while the pathname still
resolves to that same socket, so an orphan shutting down late cannot delete a successor's
endpoint.

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

## Development

Source checkout development uses Swift directly against the socket. Give the development server a
path of its own, because the default one is owned by whatever is already installed and running:

```sh
make build
make test
AXON_SOCKET_PATH=/tmp/axon-dev.sock swift run axon serve
```

To develop against the default path instead, stop the installed server first. `axon status`
reports the endpoint and the process serving it, so a surprising result is diagnosable.

`make install-daemon` registers the LaunchAgent against `.build/debug/axon` for a short
development loop. That is a build directory, so the CLI warns: the registration stops working the
moment the build is cleaned. Never install that way for real.
