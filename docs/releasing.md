# Releasing Axon

This is the contributor reference for building, signing, packaging, and publishing Axon. For ordinary setup, see [Install Axon](install.md).

## Product Layout

The release artifact is a signed and preferably notarized zip:

```text
Axon-<version>-macos-aarch64.zip
└── Axon.app
    └── Contents
        ├── MacOS
        │   └── Axon
        ├── Library
        │   └── Applications
        │       └── Axon Editor.app
        │           └── Contents
        │               └── MacOS
        │                   └── AxonEditor
        └── Resources
            └── bin
                └── axon
```

The archive root is the application itself, so extracting it yields one `Axon.app` to drag into
`/Applications`, where Finder offers to replace an existing install. The editor is nested rather
than shipped beside it: one bundle to move, one bundle for the in-app updater to swap, and no way
for the recorder and editor to reach different versions. The outer bundle is signed last so its
signature seals the nested code, and only the outer bundle is stapled — its notarization ticket
covers everything inside.

The Homebrew cask installs the one app and links `Axon.app/Contents/Resources/bin/axon`.

The archive layout and its consumers — `site/public/install.sh`, the tap cask written by
`release.yml`, and the site's instructions — must ship in one release cut. `install.sh` accepts both
this layout and the older `Axon-<version>/` directory holding two apps, so a pinned `AXON_VERSION`
still resolves.

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

### Signing and entitlements

Everything is signed with the hardened runtime, inside out, so the outer bundle's signature seals
final bytes. `Axon.app` is signed with the entitlements in `Assets/Axon.entitlements`, which holds
exactly one:

```text
com.apple.security.automation.apple-events
```

The daemon app sends Apple events to Safari and Google Chrome for `navigate`, `windows`, and `tabs`.
Under the hardened runtime a process without that entitlement may not even ask: macOS refuses
instantly, presents no consent dialog, records no TCC row, and the app never appears in System
Settings > Privacy & Security > Automation. Such a build verifies, notarizes, staples, launches, and
passes every other release check while its browser automation surface is dead — which is how it
shipped through 0.3.6.

`scripts/check-app-entitlements` therefore asserts the packaged bundle's entitlements as a whole set,
and refuses an extra one as firmly as a missing one, since every entitlement reopens a hole the
hardened runtime otherwise closes. `scripts/package-app` runs it immediately after signing, the test
workflow's package smoke step runs it beside the `Info.plist` assertions, and the release job runs it
again on the stapled bundle, which is the last look at the bytes users install.

Only the daemon app carries the entitlement. The nested CLI and the editor send no Apple events, so
they keep the empty entitlement set the hardened runtime gives them by default.

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
