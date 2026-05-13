# MCP Next Tool Surface

Phase 4 exposes the operations Axon already implements:

- `list_apps`
- `get_app_state`
- `get_screenshot`
- `resolve`
- `click`
- `perform_action`
- `set_value`
- `type_text`
- `press_key`

The next MCP-facing tools should be added only after the underlying primitives exist in `AxonCore`:

- `scroll(target, direction, pages)`
- `drag(app, from, to)` or `drag(target, to)`
- `verify(app, locator | predicate)` for post-action checks

Implemented since this note was opened:

- `changed_since(snapshotId)` now performs a coarse recapture and compares app/window signatures for retained snapshots. It does not yet use AXObserver event history or element-level invalidation.

Do not add MCP tools that only mimic future behavior. The facade should stay a thin protocol adapter over real core capabilities.
