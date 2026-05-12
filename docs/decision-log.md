# Axon Decision Log

## Transport

Decision: Axon should be daemon-first.

A long-lived service is needed for observer state, cache invalidation, and "user changed X since last checked" behavior. Use one binary with multiple modes instead of multiple installable components:

```text
axon serve
axon doctor
axon snapshot <app>
axon mcp
```

The daemon should own the persistent state. The MCP facade can speak to the daemon through JSON-RPC over a local Unix domain socket if stdio compatibility is required.

## Daemon Socket Protocol

Decision: Use JSON-RPC first.

JSON-RPC is simple, debuggable, and maps cleanly to request/response commands without inventing a bespoke protocol. It is also neutral enough that the daemon protocol can stay separate from MCP transport details.

## Wrapper Strategy

Decision: Prefer direct `ApplicationServices` unless a spike proves AXSwift saves enough work to justify the dependency.

Direct `ApplicationServices` is more verbose, but not a large conceptual expansion. The additional work is mostly typed wrappers, error normalization, and attribute/action helpers. The project complexity still lives in daemon lifecycle, snapshots, locator scoring, screenshots, observers, and action verification.

Working estimate: AXSwift may save early boilerplate in Phase 1, but direct APIs likely add days, not weeks, and reduce long-term dependency risk.

## Screenshot Support

Decision: Screenshots are required.

Snapshots and screenshot tools should return embedded image data. Screenshots are needed for coordinate fallback, visual debugging, and human inspection of failures. File output can be added later as a CLI/debug convenience, but embedded responses are the primary API.

## App Identity

Decision: Keep app identity simple at first.

The first version should list running apps and resolve apps by bundle id, name, and pid. Recently used app tracking is not important enough to justify extra persistence or LaunchServices complexity yet.

## Locator Schema

Decision: Locators should be AX-native, honest, and intuitive.

Borrow useful ideas from browser automation only where they map cleanly. Do not force Playwright concepts onto macOS Accessibility if they hide important constraints.

## Cairn Integration

Decision: Cairn should have good accessibility labels, but not as an Axon-specific dependency.

Axon should work against arbitrary apps. Cairn can still be a high-quality fixture app because it should expose good AX labels for its own sake, not because Axon requires special treatment.

## Deferred Design Notes

These are not blocking questions. They are details that should be decided when implementation reaches the relevant layer.

- Protocol versioning and compatibility should be designed when the JSON-RPC message schema starts to stabilize.
- Fixture app design should be chosen when integration tests begin, aiming for the best coverage through simplicity: small enough to reason about, rich enough to exercise real AX behavior.
