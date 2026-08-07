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
than letting a call fail later.

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
