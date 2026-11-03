# Releasing Axon

This is the contributor reference for building, signing, packaging, and publishing Axon. For ordinary setup, see [Install Axon](install.md).

## Product Layout

The release artifact is a signed and preferably notarized zip:

```text
Axon-<version>-macos-aarch64.zip
└── Axon.app
    └── Contents
        ├── MacOS
        │   └── Axon                  the Rust daemon (axon-mac), the only TCC subject
        ├── Library
        │   └── Applications
        │       ├── Axon Menu.app     the unprivileged menu bar shell
        │       │   └── Contents
        │       │       └── MacOS
        │       │           └── AxonMenu
        │       └── Axon Editor.app   the .axn editor
        │           └── Contents
        │               └── MacOS
        │                   └── AxonEditor
        └── Resources
            └── bin
                └── axon              the Swift CLI, a client of the daemon
```

The archive root is the application itself, so extracting it yields one `Axon.app` to drag into
`/Applications`, where Finder offers to replace an existing install. The menu and the editor are
nested rather than shipped beside it: one bundle to move, one bundle for the in-app updater to swap,
and no way for the daemon, the menu, and the editor to reach different versions. Each nested app is
a TCC subject of its own that asks macOS for nothing; the outer bundle keeps the identity every
grant is recorded against, and nothing but the daemon sits in `Contents/MacOS`, where a second
executable would become a path-keyed privacy subject. The outer bundle is signed last so its
signature seals the nested code, and only the outer bundle is stapled — its notarization ticket
covers everything inside.

`scripts/check-app-layout` is the one definition of this shape. It requires the main executable to
be the Rust daemon at the release version (it answers `version` itself and links no Swift runtime),
the CLI to report the same version, both nested apps to carry their identifiers and the version,
nothing else in `Contents/MacOS`, and the entitlements below; with `--team` it also requires the
designated requirement to be `com.bleugreen.axon` anchored to that Developer ID team, which is what
the grants are recorded against.

The Homebrew cask installs the one app and links `Axon.app/Contents/Resources/bin/axon`.

The archive layout and its consumers — `site/public/install.sh`, the tap cask written by
`release.yml`, and the site's instructions — must ship in one release cut. `install.sh` accepts both
this layout and the older `Axon-<version>/` directory holding two apps, so a pinned `AXON_VERSION`
still resolves.

`Axon.app` uses bundle id:

```text
com.bleugreen.axon
```

That bundle id, under team `JBS95V8M7P`, is the stable macOS Accessibility and Screen Recording
trust identity. It did not change when the main executable became the Rust daemon in 0.4.0, which is
what lets grants from earlier releases carry across.

`Axon Menu.app` and `Axon Editor.app` use bundle ids:

```text
com.bleugreen.axon.menu
com.bleugreen.axon.editor
```

## Building a Release Artifact

Build the app bundle and zip:

```sh
make package-app
```

`scripts/package-app` needs both toolchains. It builds the daemon with
`cargo build --release --locked -p axon-mac` (for the same minimum macOS the bundle declares), then
the Swift CLI, menu, and editor products with SwiftPM, and assembles them into the layout above. It
writes:

```text
dist/Axon.app
dist/Axon-0.4.0-macos-aarch64.zip
dist/Axon-0.4.0-macos-aarch64.zip.sha256
```

The version comes from the repository-root `VERSION` file. `Sources/AxonClient/AxonVersion.swift`,
the Rust workspace package in `rust/Cargo.toml`, `sdk/ts/package.json`,
`sdk/python/pyproject.toml`, and the `productVersion` in `schema/tool-surface-v1.json` are derived
copies, and every product crate, `axon-mac` included, must inherit the workspace version rather than
pin its own. After editing `VERSION`, run `./scripts/check-version --write` to synchronize them.
Archives are named with the version and the target so a consumer pinning a release can name the
artifact it wants; see [Embedding Axon](embedding.md).

It also prints the SHA-256. The Homebrew cask is written by the release workflow's publish job
alone.

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

The daemon sends Apple events to Safari and Google Chrome for `navigate`, `windows`, and `tabs`.
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

Only the daemon carries the entitlement. The CLI, the menu, and the editor send no Apple events, so
they keep the empty entitlement set the hardened runtime gives them by default, and
`scripts/check-app-entitlements` refuses a nested menu or editor that carries any entitlement.

For notarization, configure a notarytool keychain profile and pass it during packaging:

```sh
AXON_CODESIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
AXON_NOTARY_PROFILE="axon-notary" \
make package-app
```

When `AXON_NOTARY_PROFILE` is set, the packager submits the zip to Apple, staples the accepted ticket to the outer bundle, and recreates the zip.

The release workflow's macOS job installs a Rust toolchain for the daemon build, then verifies the
result twice with `scripts/check-app-layout --team JBS95V8M7P`: once on the stapled bundle and once
on the bundle extracted from the archive users download. The test workflow's package smoke step runs
the same script without `--team`, and `scripts/check-tool-surface` runs in CI so the generated
`schema/tool-surface-v1.json` cannot drift from `ToolSurfaceSpec.swift`.

### The Windows and Linux daemons

The macOS daemon is built by `scripts/package-app` above. The Windows and Linux daemons build
natively on their own hosts:

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

PyPI and npm differ on whether a package name can be brought into existence by a workflow, and that
difference decides the order of operations for each.

**PyPI** supports a *pending* trusted publisher, registered under the account's Publishing page
rather than a project's, which creates the project on first use. No manual upload is needed. The
form takes:

| Field | Value |
| --- | --- |
| PyPI Project Name | `axon-cmd` |
| Owner | `bleugreen` |
| Repository name | `axon` |
| Workflow name | `release.yml` |
| Environment name | `pypi` |

A pending publisher reserves nothing. If another account registers `axon-cmd` before the first
publish lands, the pending publisher is invalidated and the name is gone.

**npm** has no equivalent: a trusted publisher is configured in an existing package's settings, so
`axon-cmd` has to exist on npm before automated publishing can work at all. A maintainer publishes
once by hand, then fills in Trusted Publisher under the package's settings:

| Field | Value |
| --- | --- |
| Organization or user | `bleugreen` |
| Repository | `axon` |
| Workflow filename | `release.yml` |
| Environment name | `npm` |
| Allowed actions | `npm publish` (the release job publishes directly rather than staging) |

Afterwards, set Settings → Publishing access to require two-factor authentication and disallow
tokens. Trusted publishing keeps working, because it is not token authentication, and the manual
credential that bootstrapped the package stops being a way in.

Both environments, `pypi` and `npm`, must exist in the repository's GitHub settings. They carry no
secrets — the only credential either job has is the OIDC token GitHub mints for it — but the
environment name is part of the identity each registry checks, so a missing or renamed environment
is a publish failure rather than a warning. They are also where a required reviewer would go if a
release should pause for approval before it uploads.

## Homebrew Cask

The intended tap command is:

```sh
brew install --cask bleugreen/tap/axon
```

The cask shape:

```ruby
cask "axon" do
  version "0.4.0"
  sha256 "<printed by scripts/package-app>"

  url "https://github.com/bleugreen/axon/releases/download/v#{version}/Axon-#{version}-macos-aarch64.zip"
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

## Development

On macOS the daemon is the Rust `axon-mac` binary, and the Swift CLI, menu, and editor are its
clients. Run a development daemon with cargo, and give it a socket path of its own, because the
default one is owned by whatever is already installed and running:

```sh
cd rust && AXON_SOCKET_PATH=/tmp/axon-dev.sock cargo run -p axon-mac -- serve
```

Then point the Swift clients at the same path:

```sh
make build
make test
AXON_SOCKET_PATH=/tmp/axon-dev.sock swift run axon status
```

The explicit `serve` matters: a development binary outside any bundle serves without it, but the
same binary inside a bundle and started without a verb or launchd's managed key takes the launcher
path instead (see [Embedding Axon](embedding.md#what-gets-registered)). A daemon started from a
terminal is attributed to that terminal for privacy purposes, so it holds whatever Accessibility
grant the terminal holds.

To develop against the default path instead, stop the installed daemon first with `axon shutdown`.
`axon status` reports the endpoint and, through `daemon.provenance`, the executable serving it, so a
surprising result is diagnosable.

`daemon install` registers only a packaged `Axon.app`; run from `.build/debug/axon` it refuses and
says so. To exercise the real lifecycle, package with `scripts/package-app` and install from the
resulting bundle at a path that will outlive the session.

Branch builds on the bench machines run under a separate identity, `dev.axon.mac-bench`, staged by
`scripts/stage-macos-shell-bench` as two launchd jobs of their own. That is a different product
from the release layout, with grants of its own, and it never touches `dev.axon.daemon`,
`dev.axon.menu`, or `/tmp/axon.sock`.

The signed qualification of a release that changes what the bundle's main executable is happens on
the bench before merge, driven by `scripts/macos-cutover-qualification` with its evidence under
`scripts/macos-toolkit-acceptance/live/axn125/`: first against private labels with production
untouched, then as a real in-place upgrade in an operator-approved window.
