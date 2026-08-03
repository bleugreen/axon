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

Run the executable in the logged-in desktop user's Windows session. A process
in session 0 cannot inspect session 1's UI Automation tree.
