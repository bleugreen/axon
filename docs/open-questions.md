# Axon Open Questions

## Transport

Should the first MCP implementation run over stdio, or should Axon start as a long-lived local daemon with MCP exposed through a local socket?

Stdio is simpler and closer to common MCP server setups. A daemon is more aligned with "set it up and forget about it" and can maintain observers/caches across clients.

## Wrapper Strategy

Should the first Swift version use AXSwift or call `ApplicationServices` directly?

AXSwift may speed up early development, but direct APIs reduce dependency risk and make permission/action behavior easier to reason about.

## Screenshot Support

Should screenshots be part of the first snapshot API?

Accessibility-only operation is cleaner, but screenshots help debugging and make coordinate fallback much easier to inspect.

## App Identity

How much should Axon remember about recently used apps?

The service can list running apps immediately. A richer "recent apps" list requires persistence or LaunchServices usage.

## Locator Schema

Should locator objects be intentionally close to Playwright-style locators, or should they be AX-native from the start?

Playwright-style concepts are familiar, but AX-native locators may expose the real constraints more honestly.

## Cairn Integration

Should Cairn add explicit accessibility labels and identifiers as part of the Axon effort?

General-purpose automation should work without app changes, but Cairn can become a high-quality fixture app if its controls expose stable semantic labels.

