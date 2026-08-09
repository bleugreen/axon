# Embedding Axon

This is the contract a consumer relies on when it bundles Axon with something else. Cairn's
executor is the first such consumer, but nothing here is specific to it: Cairn uses the same
facade, the same lifecycle verbs, and the same status document as any other client.

Axon's trust boundary is deliberately local and does not move. There is no remote protocol, no
network listener, and no authentication layer, and there never will be. A consumer that needs to
reach Axon across a machine boundary supplies its own transport and its own authorization; Axon
only ever speaks to the same user on the same machine.

## Pin a version

A release is one product version built natively for three targets and published together. Pin an
exact version and upgrade deliberately; nothing in the contract resolves a mutable "latest".

| Target | Artifact | Contains |
| --- | --- | --- |
| macos/aarch64 | `Axon-<version>-macos-aarch64.zip` | signed `Axon.app`, `Axon Editor.app`, and the bundled `axon` CLI |
| windows/x86_64 | `axon-win-<version>-windows-x86_64.zip` | `axon-win.exe` |
| linux/x86_64 | `axon-linux-<version>-linux-x86_64.tar.gz` | `axon-linux` and its systemd user unit template |

Every archive ships a `.sha256` sibling. The publishing job refuses to create a release unless all
three archives and all three checksums are present, and it re-verifies the checksums against the
bytes that reach the release rather than trusting the job that produced them.

The repository-root `VERSION` file is the release source. The Swift and Rust literals are derived
copies, `scripts/check-version` fails the build when they drift, and a release tag that disagrees
with `VERSION` is rejected rather than producing artifacts named after something else. The same
version appears in `status --json`, in `version`, and in the MCP `serverInfo`, so a consumer can
confirm that the binary it installed is the one that is running.

## The one client surface

`<axon binary> mcp` over stdio is the canonical way to drive Axon. It is the surface every client
uses, and it is the only one covered by compatibility expectations.

```sh
axon mcp            # macOS
axon-win.exe mcp    # Windows
axon-linux mcp      # Linux
```

The facade is a short-lived process that forwards to the long-lived daemon over local IPC. It is
not a second implementation of the tool surface; if the daemon is not running, the facade reports
the failure rather than answering on its own.

Everything else in this document is lifecycle and status. Those use local CLI-to-daemon IPC only:
a mode-0600 Unix socket on macOS and Linux, and a DACL'd named pipe restricted to the current
user's SID on Windows.

## Lifecycle verbs

Four verbs mean the same thing on every platform, each implemented with that platform's native
mechanism.

| Verb | Effect |
| --- | --- |
| `daemon install` | Register this install's daemon to start at login, then wait for the daemon to answer a health request |
| `daemon uninstall` | Stop the daemon and remove the registration |
| `daemon restart` | Restart the daemon that is already registered, without changing the registration |
| `shutdown` | Stop the running daemon, leaving the registration in place |

`daemon install` is the only verb that writes a registration. **`daemon restart` never re-registers**:
it restarts whatever is installed, regardless of which binary invokes it, and fails with exit 1
directing the caller to `daemon install` when nothing is registered. This matters because the
alternative reintroduces the failure the permanent-path rule exists to prevent — an agent that
restarts from a temporary build directory would silently repoint a working installation at a path
about to disappear.

Install and uninstall are idempotent: installing over an existing registration rewrites it, and
uninstalling an absent registration succeeds. A consumer can run `daemon install` on every deploy
without checking first.

`shutdown` is idempotent only when nothing is listening. A daemon that accepts a connection and
then fails to answer, or a platform stop command that fails, is reported as an operational failure
rather than success; the command confirms the endpoint is gone before claiming it stopped
anything. Reporting a stop that did not happen would leave a process holding the endpoint while
whoever asked believes the machine is clear.

Registration is platform-native:

| Platform | Mechanism | Where |
| --- | --- | --- |
| macOS | LaunchAgent | `~/Library/LaunchAgents/dev.axon.daemon.plist`, `LimitLoadToSessionType=Aqua` |
| Windows | Scheduled task | `Axon Windows Daemon`, `ONLOGON`, restricted to the current interactive user |
| Linux | systemd user unit | `~/.config/systemd/user/axon.service`, bound to `graphical-session.target` |

### What gets registered

`daemon install` registers a daemon that lives inside the install it was invoked from. It never
copies the binary anywhere. Which executable of that install it names depends on the platform, and
on macOS the answer is decided by the operating system's privacy model rather than by convenience.

On macOS the release ships one `Axon.app` holding two executables: the daemon app at
`Contents/MacOS/Axon` and the CLI at `Contents/Resources/bin/axon`. **`daemon install` registers the
app**, argument-less. macOS attributes a privacy grant — Accessibility, Screen Recording — to a
bundle identity only for that bundle's *main* executable; anything else, including a helper binary
under `Contents/Resources`, is recorded against its absolute path. Because every release installs
at its own versioned path, registering the CLI made each upgrade a new subject in System Settings
and demanded a fresh human approval, while grants held by the app carried across untouched.
Registering the app makes every grant ride `CFBundleIdentifier`, so permissions survive upgrades
and moves alike. Code signing plays no part in this; the designated requirements were already
stable across releases.

The app is a complete daemon in its own right — the same server and command router on the same
socket, plus the menu bar and recorder — so it needs no arguments, and `axon serve` remains a
development and probe entry point rather than a second thing to install.

When the invoking CLI is not inside a bundle, which is what a development build is, it is
registered as itself with `serve` and keeps the path-keyed identity that implies. A bundle that
cannot name a usable main executable degrades the same way: a daemon that starts with a path-keyed
identity is worth more than a registration that starts nothing. `daemon install` prints the
identity it registered, because which of the two rules applies is not visible from the path alone
and decides whether the next upgrade needs a human in System Settings.

Windows and Linux have no equivalent per-application grant, and register the invoking executable
with `serve`.

### Install from a permanent path

**The registered path is the one you invoked from; nothing is copied.** Invoking `daemon install`
from a build directory, an unpacked temporary directory, or a CI workspace registers a path that
disappears, leaving a registration that can never start again. Install from the permanent location
the binary will live at. This holds for the app registration too: the path stops mattering to
permissions, but launchd still has to find the bundle.

The CLI resolves symlinks before registering, and warns on stderr when the resolved path looks
temporary or build-scoped. The warning is not a refusal; a consumer that knows better can proceed.

Any path the filesystem allows is registered faithfully, including one containing spaces or a
literal `%`. On Linux the executable is quoted and escaped for the systemd unit, because
`ExecStart=` is tokenized on whitespace and `%` introduces a specifier; an install from
`/opt/Axon Stable/axon-linux` would otherwise register a unit that tries to run `/opt/Axon`.

`status --json` reports the registered path, so a consumer that pinned a version can compare the
registration against the install path it expects instead of assuming they agree.

### Readiness

A socket file or a named pipe existing proves only that some process bound it, which is exactly
what a half-started daemon leaves behind. Readiness is a successful authenticated health round
trip and nothing weaker. `daemon install` and `daemon restart` wait for that round trip before
returning.

### Exclusive ownership

One server owns an endpoint at a time. A second daemon refuses to start rather than displacing the
running one, so an embedding consumer cannot install its way past an `Axon.app` already serving the
default path: stop that server, or give the daemon an endpoint of its own with `AXON_SOCKET_PATH`.
Ownership is released when the owning process exits, including when it crashes, so a restart never
needs a cleanup step.

On macOS ownership is an exclusive advisory lock taken before the socket is bound, and the refusal
names the process holding it. On Windows the pipe is created as a single instance and the operating
system enforces the same rule.

On Linux, a host with no graphical session is the one exception: the unit is enabled but
deliberately not started, because it is bound to `graphical-session.target` and has no desktop to
automate yet. Install reports the registration, names the reason, and exits 0.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | A lifecycle operation succeeded, or status successfully described any state — including a daemon that is not running |
| 1 | The command was used correctly and could not be completed |
| 2 | The command was used wrongly |

Diagnostics go to stderr, so `status --json` stdout stays a single parseable line.

### Interactive session

Axon automates a logged-in desktop, so the daemon must run in one. A daemon in a Windows service
session can bind its pipe and answer requests while being structurally unable to see a window, and
a Linux host at the greeter has no accessibility bus at all. Both are reported as degraded status
rather than treated as failures — see `session` below.

## The health-v1 status document

`status --json` emits one document described by `schema/health-v1.schema.json`. The fixtures in
`schema/fixtures/health/` are the shared examples, and both the Swift and Rust implementations are
tested against those same files.

Degradation is data. A daemon that is not running, a host at a login greeter, and a denied
Accessibility grant all produce schema-valid documents rather than transport errors, and all exit
0. A consumer that only handles the healthy shape is misreading the contract.

```json
{
  "schemaVersion": "health-v1",
  "version": "0.2.2",
  "platform": "macos",
  "daemon": { "running": true, "ready": true, "endpoint": "/tmp/axon.sock", "processId": 4210 },
  "registration": { "registered": true, "mechanism": "launchd", "path": "/Applications/Axon.app/Contents/MacOS/Axon" },
  "session": { "interactive": true, "graphical": true },
  "permissions": [{ "name": "accessibility", "granted": true }],
  "capabilities": [{ "capability": "enumerate", "usable": true }]
}
```

### Fields

- **`schemaVersion`** is this contract's identity. **`version`** is the product SemVer. They are
  versioned independently: a product release never changes the schema major on its own.
- **`daemon`** describes the process. `running` means a daemon answered on the local transport;
  `ready` means it answered after its accessibility backend finished initializing. `endpoint` is
  the local socket path or pipe name — always local.
- **`registration`** describes the start-at-login entry and is owned by the CLI, not the daemon.
  `path` is what the platform will actually run.
- **`session`** describes the session the reported daemon occupies, or the session the reporting
  CLI occupies when no daemon is running. `interactive` is a logged-in user session rather than a
  service session; `graphical` is a usable desktop rather than a greeter.
- **`permissions`** lists the operating-system grants that gate automation. An absent entry means
  the platform has no such gate, not that it is granted. macOS reports `accessibility` and
  `screenRecording`; Linux reports `accessibilityBus`; Windows applies no per-application gate and
  reports an empty list.
- **`capabilities`** always carries one entry per known capability. A capability the running build
  cannot serve is reported present and unusable rather than omitted, so a consumer can tell "not
  supported here" from "this Axon is older than my vocabulary".

### Reason codes

`reason` is a stable kebab-case code meant to be branched on. `detail` and `restriction` are
human-readable prose and must never be parsed.

| Code | Meaning |
| --- | --- |
| `daemon-not-running` | No daemon answered on the local transport |
| `daemon-not-ready` | A daemon answered before its backend finished initializing |
| `daemon-unreachable` | A daemon accepted a connection and then failed to answer |
| `version-skew` | A daemon answered, but not with a document this build can read: the running daemon is a different version from the CLI asking it |
| `not-registered` | No start-at-login registration is present |
| `not-interactive-session` | The reporting process is in a service session |
| `no-graphical-session` | The user session has no usable desktop |
| `accessibility-not-granted` | macOS has not granted Accessibility trust to the daemon identity |
| `screen-recording-not-granted` | macOS has not granted Screen Recording to the daemon identity |
| `session-bus-unavailable` | The user's session D-Bus is not reachable |
| `atspi-unavailable` | The AT-SPI accessibility bus is absent or refused a connection |
| `wayland-restricted` | Wayland's security model forbids the operation for an unprivileged client |
| `portal-authorization-required` | A desktop portal authorization flow is required first |
| `no-x-display` | No X display is reachable, so there is no synthetic input device |
| `no-window-manager` | The X11 session has no EWMH-capable window manager, so the foreground can be neither read nor activated |
| `no-xtest` | The X server does not provide the XTEST extension, so synthetic input cannot be posted |
| `not-implemented` | This build does not implement the capability on this platform |
| `unknown` | The state could not be determined and no more specific code applies |

New codes may be added within `health-v1`. Treat an unrecognized code as an unspecified
degradation rather than a parse failure.

### Capability vocabulary

`enumerate`, `capture`, `retainedHandles`, `observeChanges`, `invoke`, `readValue`, `setValue`,
`focus`, `scroll`, `pointerInput`, `keyboardInput`, `screenshot`, `hitTest`, `serializeHistory`,
`observeGlobalInput`.

The list is published as `$defs/knownCapabilities` in the schema and grows additively. It is not
closed; a consumer must tolerate a capability key it has never seen.

### Degraded examples

Each of these is a fixture in `schema/fixtures/health/`, and each is a state a consumer should
expect to see in production.

- **No daemon.** `daemon.running` and `daemon.ready` are false with reason `daemon-not-running`,
  every capability is unusable for the same reason, and permissions the CLI cannot confirm without
  the daemon are reported ungranted with that reason rather than guessed at.
- **macOS Accessibility denied.** The daemon is ready, `accessibility` is ungranted, and every
  capability that drives the Accessibility APIs is unusable. Listing applications and taking
  screenshots survive, because neither answers to that grant.
- **Windows service session.** `session.interactive` is false with reason
  `not-interactive-session`. This is what a remote-shell install looks like, and it is why
  registration alone is not evidence that automation will work.
- **Linux at the greeter.** `session.graphical` is false with reason `no-graphical-session` and
  `accessibilityBus` is ungranted with reason `atspi-unavailable`. The registration can still be
  present and correct; the desktop simply is not up yet.
- **Linux under Wayland.** The daemon is ready, but `pointerInput` and `keyboardInput` are unusable
  with reason `wayland-restricted`, and `screenshot` is unusable with reason
  `portal-authorization-required`. `observeGlobalInput` is unusable with reason `not-implemented`,
  because that one is a gap in this build rather than something the compositor withholds — an X11
  session reports it exactly the same way.

### Compatibility

Within `health-v1`:

- Producers may add fields and capability keys. Consumers must ignore what they do not recognize.
- Required fields keep their names and their meanings.
- Removing a required field, or changing what one means, requires a new schema major.

Product releases are versioned independently and may add fields within the same schema major. A
consumer should validate `schemaVersion` and refuse a major it does not implement; both Axon
implementations do exactly that and reject an unknown major rather than parsing it optimistically.

## Non-goals

These are settled and will not change:

- No remote protocol, no network listener, no authentication layer. Axon's authorization is the
  operating system's own same-user access control on a local socket or pipe.
- No Cairn-specific code paths. Cairn consumes the same facade as any other MCP client.
