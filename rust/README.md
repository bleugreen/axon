# Rust platform work

This directory is an experimental Cargo workspace for non-macOS Axon platform
work. Its placement in the monorepo is a recommendation under evaluation, not a
settled project structure.

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
