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

Working estimate: AXSwift may save early boilerplate, but direct APIs likely add days, not weeks, and reduce long-term dependency risk.

## Screenshot Support

Decision: Screenshots are required.

Snapshots and screenshot tools should return embedded image data. Screenshots are needed for coordinate fallback, visual debugging, and human inspection of failures. File output can be added later as a CLI/debug convenience, but embedded responses are the primary API.

## App Identity

Decision: Keep app identity simple at first.

The first version should list running apps and resolve apps by bundle id, name, and pid. Recently used app tracking is not important enough to justify extra persistence or LaunchServices complexity yet.

## Locator Schema

Decision: Locators should be AX-native, honest, and intuitive.

Borrow useful ideas from browser automation only where they map cleanly. Do not force Playwright concepts onto macOS Accessibility if they hide important constraints.

## Action Batches and `.axn` Files

Decision: composable automation is an invocation-scoped batch of normal tool calls, not a separate plan language.

The daemon should remain a stable local accessibility service. It can execute a submitted multi-step batch because that is just composition over its primitives, but it should not own a persistent recipe registry, cache, or app-specific workflow pack. Reusable batches live on disk as `.axn` files beside the codebase or task context that gives them meaning, and are passed to the daemon by path or source.

A batch is a flat list of `{ tool, ...args }` objects using the same shape as the standalone tool calls. Earlier sketches included a richer plan language with `if`, `wait_until`, `repeat_until`, `assert`, and bound outputs. That language has been removed: if a missing capability is needed for composition, the right move is to add it to the underlying tool set so that batches stay a flat sequence of real tool calls. Two ways of doing the same thing is worse than either one alone.

YAML is the preferred on-disk format for `.axn` files because it is compact and easy to edit. JSON-RPC remains the daemon transport, and structured JSON batch objects remain acceptable when a caller already has data in memory.

## Deferred Design Notes

These are not blocking questions. They are details that should be decided when implementation reaches the relevant layer.

- Protocol versioning and compatibility should be designed when the JSON-RPC message schema starts to stabilize.
- Fixture app design should be chosen when integration tests begin, aiming for the best coverage through simplicity: small enough to reason about, rich enough to exercise real AX behavior.
