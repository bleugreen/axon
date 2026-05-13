# Observer Layer Follow-Up

## Implemented First Pass

Axon now has a testable observer event path:

- `AppChangeTracker` records app-level change events with monotonic sequence tokens.
- `SnapshotSummary` stores the observation token active when the snapshot was captured.
- `changed_since(snapshotId)` checks observer events before falling back to recapture comparison.
- `AXAppChangeObserverRegistry` registers app-level `AXObserver` notifications on a dedicated run loop thread so the daemon's socket accept loop does not block callbacks.

The first observed notifications are intentionally coarse:

- focused window changed
- focused UI element changed
- window created

## Remaining Work

- Add window-level registrations after capture so title/value/destroyed notifications can mark individual windows.
- Add explicit observer diagnostics to `health` or a debug command, including registered app count and last event sequence.
- Decide whether `changed_since` should optionally return a fresh snapshot even when observer events already prove a change.
- Add a live fixture app for deterministic observer integration tests. Unit tests currently validate the token path; real AX notifications are smoke-tested manually.
