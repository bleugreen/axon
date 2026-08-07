# Reviewable locator self-healing

Status: In progress.

## Context

Recorded `.axn` locators can continue to identify the right accessibility
element after an application changes a title, value, nearby label, ancestor, or
layout. The resolver already knows which saved evidence matched, but replay has
historically discarded that information. Users therefore have no durable,
reviewable way to refresh a locator that succeeded through tolerated drift.

Self-healing must not become a second matching system or silently rewrite an
automation source. The existing `LocatorResolver` remains the sole authority for
whether a locator is unique and how confident that resolution is.

## Decision

Resolution carries structured evidence accounting and the real live-resolution
path back through the command router. Replay classifies non-matching evidence and
may propose a locator re-derived with the same rules used during recording.
Detection is always on because it reuses work already performed by resolution.
Writing a revised document is opt-in through `run(..., healedPath:)` or
`axon run --healed-path <file>`.

The output is a new review artifact. Axon opens the source read-only, revises only
the locator objects of affected actions, and serializes to the requested path.
It never edits the source file in place.

## Safety contract

1. Ambiguity never heals. Any non-unique resolution records a halted proposal.
2. A proposed locator is resolved again against the same observation before it
   is emitted. It must be unique and have confidence no lower than the current
   resolution.
3. Evidence unavailable to a path-scoped observation is marked unevaluated and
   carried forward. Missing siblings must not be mistaken for nearby-text drift.
4. Frame changes are supporting evidence, not identity. Frame-only drift does
   not produce a revised file.
5. Secret-tainted locator values halt emission rather than placing either the
   secret or a non-runnable redaction placeholder in a workflow.
6. Dry runs do not write a healed file.

The heal event and generated document share one readable locator diff so MCP,
CLI, and file review do not offer competing accounts of the change.

## Scope

This pass heals element locator targets used by replay actions. It does not
change matching scores or semantics, mutate source `.axn` files, auto-apply a
proposal, or heal point and text-location targets. Fact locators used by
`expects` resolve through a separate evaluator and require a follow-up extension
of the same evidence and proposal contract.

## Verification

Resolver tests cover tolerated, absent, and unevaluated evidence and confirm
that observed locators use recording's canonical builder. Runner fixtures cover
a drifted workflow that emits and cleanly replays a healed copy, source-byte
immutability, ambiguity, secret-tainted values, and dry-run behavior. The tool
surface test keeps the generated MCP signature synchronized with
`docs/tool-surface.md`.