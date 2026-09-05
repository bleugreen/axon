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

The version comes from the repository-root `VERSION` file. `Sources/AxonCore/AxonVersion.swift`,
the Rust workspace package in `rust/Cargo.toml`, `sdk/ts/package.json`, and
`sdk/python/pyproject.toml` are derived copies. After editing `VERSION`, run
`./scripts/check-version --write` to synchronize them. Archives are named with the version and the
target so a consumer pinning a release can name the artifact it wants; see
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

## The SDK packages

The two daemon clients are published together under one name, `axon-cmd`: the wheel and sdist built
from `sdk/python` go to PyPI, and the tarball built from `sdk/ts` goes to npm. They are part of the
Axon release rather than a lifecycle of their own — same `VERSION`, same commit, same workflow run
— because `Axon.connect()` compares the daemon's version against the one its generated client was
built from, and a client released on its own schedule would make that comparison meaningless.

The `Build SDK packages` job runs on every release, publishing or not. It builds both packages and
hands each to its packaging check, which asserts the artifact's contents against the tracked
sources, asserts the metadata an index will display, and installs the artifact into an empty
environment to prove it imports. A dry run therefore exercises everything a real release does up to
the moment of upload. The same two checks run on every pull request, so a packaging regression is
found by the change that causes it; neither reaches a registry.

What those jobs inspect is what the publish jobs upload. The checks take an output directory, the
release points them at one, and the publish jobs upload those files rather than rebuilding — so no
artifact is published that was not inspected.

### Trusted publishing

Neither registry credential exists in this repository. Each publish job presents a GitHub OIDC
token and receives a short-lived, workflow-scoped upload token in return, the same arrangement the
Windows signing job has with Azure. `id-token: write` is granted per job rather than workflow-wide,
and the workflow's default permission is now read.

| Registry | Publisher identity |
| --- | --- |
| PyPI | project `axon-cmd`, repository `bleugreen/axon`, workflow `release.yml`, environment `pypi` |
| npm | package `axon-cmd`, organization/user `bleugreen`, repository `axon`, workflow `release.yml`, environment `npm` |

Those values are matched exactly and case-sensitively at publish time, and neither registry
validates them when they are saved. Renaming the workflow file or an environment silently revokes
the ability to publish until the registry-side configuration is updated to match.

Both uploads carry provenance. PyPI receives PEP 740 attestations signed with the same identity
that authorized the upload; npm generates provenance automatically for a trusted publish from a
public repository, and `publishConfig` in `sdk/ts/package.json` pins public access and provenance
so a publish by any other route cannot quietly drop either.

### Retrying a release

A published version is immutable on both registries: it can never be overwritten, only matched or
contradicted. So a release re-run after a partial failure asks a better question than "does this
version exist" — `scripts/verify-published-sdk` asks whether what the registry serves is what this
build produced, comparing file by file inside each artifact rather than byte by byte over the
archive, since two archives with identical contents can still differ in gzip framing and recorded
timestamps.

Its three answers drive the release:

- **Not published yet.** Upload.
- **Published, contents match.** Skip the upload; that work is already done.
- **Published, contents differ.** Stop. Publishing again cannot fix it, so the release is either
  being re-run from the wrong commit or genuinely needs a new `VERSION`.

The same check runs again after each upload, because a registry accepts an upload before it serves
it, and once more from the release job before the GitHub release is created. That last one is the
completion gate: the release is not cut while either registry is missing its package.

### One-time setup

PyPI and npm differ on whether a name can be created by a workflow. PyPI supports a *pending*
trusted publisher, configured under the account's Publishing page, which creates the project on
first use — so no manual upload is needed to establish `axon-cmd` there. npm has no equivalent: a
trusted publisher is configured in an existing package's settings, so the first `axon-cmd` version
must be published manually by a maintainer, after which the trusted publisher is registered and
token publishing should be disallowed under Settings → Publishing access.

A pending PyPI publisher reserves nothing. If another account registers `axon-cmd` before the first
publish lands, the pending publisher is invalidated.

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
