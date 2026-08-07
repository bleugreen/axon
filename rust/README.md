# Rust platform work

This directory is a Cargo workspace for the non-macOS Axon platform backends.
Its placement in the monorepo is a recommendation under evaluation, not a
settled project structure.

Every crate inherits the workspace version, which is kept in step with the
repository-root `VERSION` file by `scripts/check-version`.

## Daemon lifecycle

`axon-win` and `axon-linux` expose the same lifecycle verbs as the macOS CLI —
`daemon install`, `daemon uninstall`, `daemon restart`, `shutdown`,
`status [--json]`, and `version` — with the same exit codes: 0 for success or a
status that described any state, 1 for an operation that could not be completed,
2 for wrong usage. `daemon install` registers the path of the executable you
invoked, so run it from a permanent location.

The consumer-facing contract, including the `health-v1` status document, is
[docs/embedding.md](../docs/embedding.md).

The lifecycle, session classification, and status assembly for both platforms
live in ungated `lifecycle` modules and are unit-tested on any host; only the
calls that touch Task Scheduler, systemd, and the local transport are behind
target gates. `cargo test -p axon-win` and `cargo test -p axon-linux` therefore
cover them from a development machine of any kind.

## Windows backend

`axon-win` is the production Windows UI Automation backend. Build and start it
from the logged-in desktop user's session, not a service or SSH session:

    cd rust
    cargo build --release -p axon-win
    target\release\axon-win.exe serve

The daemon owns UI Automation objects on a dedicated multithreaded COM apartment
and listens on `\\.\pipe\axon-v1`. The pipe rejects remote network clients and
uses a protected access control list granting access only to the user SID from the
launching process token. Start `axon-win.exe mcp` as the short-lived JSON-lines MCP facade.
The facade preserves daemon results under `structuredContent`, including the
canonical `batch` wrapper returned by `run`.
Run the live probes from the interactive session before integration:

    axon-win.exe probe value Notepad
    axon-win.exe probe events cairn 15
    axon-win.exe probe timeout cairn 1000

The value probe validates set/read/restore on an editable ValuePattern target. The
event probe separately records automation, structure, and focus callbacks while
the user interacts with the target. The timeout probe reports the configured
IUIAutomation2 provider timeouts and measured call, or honestly reports that the
extended interface is unavailable. UI Automation cannot cross session 0/session
1, and controls above the daemon's integrity level require matching elevation or
signed UIAccess.

Capture matches an application by top-level window title (exact then substring)
or process identifier. Locator `role` values use native UIA control type names
such as `Button`, `Edit`, `Document`, `MenuItem`, and `TreeItem`; locator actions
use UIA pattern names `Invoke`, `Value`, and `ScrollItem`.

UIA exposes `InvokePattern` rather than an open-ended named-action vocabulary, so
`invoke` performs `Invoke` and reports that, instead of claiming a name it cannot
honour.

## Delivery

Both backends implement the delivery contract described in
[`../docs/platform-spec.md`](../docs/platform-spec.md). Every mutating tool takes
an optional `deliveryPolicy` (`backgroundOnly` by default), and every action
result carries `deliveryPolicy`, `delivery`, `dispatchSuccess`, and `refusal`.
The policy is decoded before the target is resolved, so an unrecognized value is
a JSON-RPC `-32602` error and never reaches a native call.

| action | Windows rung | Linux rung |
| --- | --- | --- |
| `invoke` | `semantic` (UIA `InvokePattern`) | `semantic` (AT-SPI `Action.DoAction`) |
| `type` | `semantic` (UIA `ValuePattern` + readback) | `semantic` (AT-SPI `EditableText.SetTextContents` + readback) |
| `scroll` | `semantic` (UIA `ScrollItemPattern`) | `semantic` (AT-SPI `Component.ScrollTo`) |
| `click` | refused: the foreground rung is withheld | refused: the foreground rung is withheld |
| `keyboard` | refused: the foreground rung is withheld | refused: the foreground rung is withheld |

The semantic paths no longer call `SetFocus` or AT-SPI focus. Focus is a
system-wide side effect, and an action that changes it is foreground however it
finally mutates the target, so these set the value directly and read it back.

Neither backend implements the pixel rung. Windows has no HWND-targeted
client-coordinate delivery yet, and Linux has neither X11 window-targeted
delivery nor a Wayland portal path, so both refuse with
`backgroundPixelUnsupported` and a message naming what is missing.
`SendInput` and `XTest` are global devices and would always be classified
`foreground`, however narrowly they are aimed.

Neither backend offers the foreground rung either. The foreground rung is global
input that hands the session back: capture the prior foreground, activate the
target, prove it came forward, dispatch exactly once, restore. These backends
cannot yet do that, so pointer and keyboard actions refuse rather than dispatch
unrestored `SendInput` or `XTest` while claiming a guarantee they do not keep.

To light the rung up, a backend overrides three `PlatformBackend` methods:
`supports_foreground_transaction`, `frontmost_application`, and
`activate_application`. The transaction itself — capture, activate, prove,
dispatch once, restore, and report the evidence — is shared in
`axon-core/src/delivery.rs` and is already covered by fake-backend tests in both
crates, including activation that cannot be proved (nothing is dispatched) and
restoration that fails after dispatch (evidence kept, overall failure).

Stable refusal reasons a caller will see from these backends:

| reason | when |
| --- | --- |
| `backgroundPixelUnsupported` | Only visible when the rungs above it are available, since a policy boundary is more actionable otherwise. |
| `foregroundNotPermitted` | The backend can deliver transactionally and the session can reach global input, but the action did not opt in. |
| `noDeliveryCandidate` | The rung does not exist here: the backend cannot run a foreground transaction, or the session cannot reach global input at all (Wayland, session 0, a noninteractive window station, an integrity boundary). Opting in changes nothing, and the refusal says so rather than sending the caller after a useless permission. |

The health-v1 capability overlay feeds the same decision that dispatches, so
`status` and a refused action agree about what this session can do.

## Linux backend

`axon-linux` is the AT-SPI backend. It serves the mode-0600 socket at
`$XDG_RUNTIME_DIR/axon-v1.sock` and is registered as a systemd user unit bound to
`graphical-session.target`:

    cd rust
    cargo build --release -p axon-linux
    target/release/axon-linux daemon install
    target/release/axon-linux status --json

The unit template lives at `axon-linux/systemd/axon.service.in` and ships inside
the release archive, so what will be registered can be read before installing.
Under Wayland, synthetic pointer and keyboard input and unmediated screenshots
are unavailable; `status` reports each as unusable with a stable reason rather
than letting a call fail later, and pointer and keyboard actions refuse with
`noDeliveryCandidate` carrying that same reason.

## Windows UI Automation spike

axon-spike-win enumerates top-level UI Automation elements, captures a bounded
control-view subtree, resolves a control-type and name-contains locator, and can
dispatch InvokePattern. Dispatch and verification fields are always printed
separately. Failed dispatch or an unchanged verification capture produces a
nonzero exit status.

    cd rust
    cargo run -p axon-spike-win
    cargo run -p axon-spike-win -- --window Notepad --max-depth 8 --max-nodes 500
    cargo run -p axon-spike-win -- --window Notepad --type Button --name-contains Save --invoke
    cargo run -p axon-spike-win -- --window cairn --activate-msaa --max-depth 12 --max-nodes 1000

Run the executable in the logged-in desktop user's Windows session. A process
in session 0 cannot inspect session 1's UI Automation tree.

The optional MSAA activation queries `OBJID_CLIENT` on the selected native window
and every child HWND, waits for Chromium to initialize renderer accessibility,
and then performs the normal UI Automation capture. Capture output includes
counts of named and identified nodes plus a control-type histogram.
