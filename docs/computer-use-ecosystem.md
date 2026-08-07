# Patterns from the Computer-use Ecosystem

This research surveys roughly twenty computer-use projects and extracts ideas
that fit Axon's semantic-first, honest-result design. Three sources were
especially relevant:

- [cua-driver](https://github.com/trycua/cua) covers the same macOS, Linux, and
  Windows backends and independently arrived at explicit degradation contracts.
- [OpenAdapt Flow](https://github.com/OpenAdaptAI/openadapt-flow) is the closest
  parallel to Axon's record, compile, and replay model.
- [agent-desktop](https://github.com/lahfir/agent-desktop) uses a similar
  macOS accessibility vocabulary and has strong context-budget ergonomics.

The findings below are an idea harvest, not current Axon behavior. Existing
equivalents are called out so future work does not rebuild them.

## Background delivery should be a contract

cua-driver's no-foreground contract makes desktop disruption explicit. It uses
a per-action escalation ladder:

1. perform an element action in the background;
2. if necessary, act by pixel against the same window without moving the real
   pointer; and
3. only when requested, foreground that window for the single action, wait for
   transient UI, then restore the previously frontmost application.

The result reports which delivery rung was used. This turns focus stealing and
pointer movement from incidental implementation details into caller-visible
policy. A synthetic cursor overlay can show background activity without moving
the user's pointer.

Axon already prefers accessibility actions over synthetic input, but callers
cannot require background-only delivery or discover that foreground delivery
was necessary. The natural design crosses the action parameters, command
router, result envelope, and platform capability model. This is the highest
value follow-up because it changes what running Axon feels like while a person
continues to use the desktop.

## Replay should close the loop

OpenAdapt treats recorded quantities as hints and the next semantic target as
the authority. For example, scrolling continues until the next target resolves
rather than replaying a fixed delta. Axon's `AXScrollToVisible` already follows
this principle for scroll; future recorded numeric actions should preserve it.

### Healing must be reviewable

When a locator resolves through weaker or changed evidence, replay can emit a
heal event and optionally write a revised workflow. An Axon equivalent such as
`run --heal-to <path>` should produce a new `.axn` and a human-readable diff,
never silently rewrite the source recording. The report should include the
resolution rung, confidence, and elapsed time for each step, plus a run-level
histogram. A passing run whose steps all used strong structural evidence is not
equivalent to one that survived through weak fallbacks.

### Postconditions can be compiled, with strict exclusions

Axon has an `expects` fact vocabulary, but `save` does not derive expectations
from recorded state transitions. Compiling conservative postconditions would
make saved workflows verified by default. Two exclusions are essential and are
now part of the canonical `.axn` documentation:

- never assert parameterized values, even when they appear in downstream state;
- never assert clicked-target labels, because labels are mutable locator
  evidence rather than invariants.

Parameter proposals should also require one-shot operator confirmation. Turning
a demonstrated constant into a run-varying input affects secrets, invocation,
and verification. Unconfirmed proposals should remain byte-for-byte constants.

### Weak resolution should gate irreversible actions

For irreversible or externally visible steps, weak resolution should stop for
human confirmation rather than act. Resolution confidence is a better gate than
a brittle list of dangerous primitives because Axon already computes it from
the evidence available for the specific target. Ambiguous independent choices
must halt rather than average coordinates or fall through to a weaker model.

### Recordings should become discoverable tools

An emitter could wrap a `.axn` as an Agent Skills directory or a standalone MCP
tool. That makes a recorded workflow discoverable and callable by name instead
of relying on a person or agent to remember a file path.

OpenAdapt's drift benchmark is also useful external evidence for Axon's core
bet: its structural automation succeeded in all 21 tested drift cases, while
compiled visual replay succeeded in 6. Their design moved from vision-first to
deterministic structural automation with visual fallback.

## Perception must respect context budgets

Dense accessibility trees need limits and projection rather than ever larger
responses.

- **Skeleton-first traversal.** A shallow overview should preserve handles on
  truncated containers and report child counts, making each truncation point a
  drill-down target rather than a dead-end notice.
- **Query projection.** A `look` query can return matching elements and their
  ancestor chains while preserving original handle numbering and reporting both
  total and filtered counts. This complements `find`: one narrows an actionable
  view, while the other resolves one target.
- **A total-node ceiling.** Depth and per-parent child limits do not protect
  against a broad 10,000-node web view. Markdown and structured forms must
  truncate identically.
- **Stable dual representation.** If Axon adds paired text and structured
  observations, new fields should land only in the structured side so text
  parsers remain stable.

Axon's `s12:19` handles already carry snapshot identity. Any future shorthand
should only accept a bare element reference alongside an explicit snapshot.

## Degradation should preserve every truthful component

When one observation component cannot be proven, return the components that
remain true with a structured degradation reason. For example, an unresolved
accessibility window can still return a screenshot, while an unproven screenshot
coordinate transform can be omitted without discarding the accessibility tree.
This extends the discipline of Axon's `health-v1` capability document to each
response.

Published support levels should be evidence-based:

- **Supported** means a canonical harness proves results against application-
  or desktop-owned state.
- **Supported with limits** means unsupported paths return structured refusal.
- **Experimental** means coverage is incomplete and unlisted actions cannot be
  assumed.

Linux support should be documented per compositor. X11, Sway, GNOME/Mutter,
KWin, and XWayland have different delivery and helper constraints; "Wayland"
is not one capability profile.

## Debugging affordances have disproportionate value

- A pixel action can optionally capture a fresh screenshot and draw a crosshair
  at the dispatched point. This makes screen, window, screenshot, and Retina
  scaling mistakes visible immediately.
- A single-file HTML trace can embed the timeline and screenshots for offline
  review. Such a trace must be handled as sensitively as the screenshots it
  contains.
- Action failures should name the failed actionability condition: present,
  visible, stable, receives events, enabled, or editable. Axon's pre-dispatch
  hit testing already covers part of receives-events; naming the complete set
  makes failures actionable.

## Concurrency needs explicit identity

Multi-agent desktop use introduces races that single-agent designs hide:

- Snapshot namespaces should be session-scoped so agents cannot resolve each
  other's handles. Even agents sharing a session must act from their own
  snapshot rather than assuming a global latest snapshot remains unchanged.
- Launch APIs may need a force-new-instance capability because single-instance
  applications otherwise hand multiple sessions the same window.
- Mutations against changing enumerations should carry a fingerprint from the
  listing that produced the selected item. A notification, window, or row that
  arrives between list and mutation must not shift an index onto another item.

## Investigate where the accessibility tree lies

cua-driver specifically reports false or misleading accessibility state from
Electron, Catalyst, and virtualized off-screen rows. This challenges Axon's
honest-result guarantee without overturning its semantic-first stance.

A bounded experiment should use purpose-built Electron and Mac Catalyst
fixtures to compare `AXValue` readback after `type` with application-owned
state. If accessibility readback can echo a write the application did not
accept, Axon's type verification has a false-positive path that needs a second
source of evidence.

## Existing equivalents

These ecosystem patterns already have canonical Axon implementations:

| Ecosystem pattern | Axon equivalent |
| --- | --- |
| Poll until repeated stable frames | `wait_for_stability` over semantic observation signatures |
| Retrying assertions | `wait_for_value` predicates |
| Ephemeral element references | Snapshot-scoped handles |
| Structured refusal | Dispatch success separated from goal success |
| Capability discovery | `health-v1` capability vocabulary |
| Semantic scrolling | `AXScrollToVisible` |
| Redundant selector signals | Locator filters separated from scoring signals |

## Recommended sequence

1. Define and implement the background-delivery contract.
2. Add reviewable `.axn` healing.
3. Emit an Agent Skill or MCP tool from a `.axn`.
4. Compile conservative postconditions using the documented exclusions.
5. Gate irreversible actions on weak resolution.
6. Add coordinate crosshairs and per-step resolution evidence to traces.
7. Add a total-node ceiling and query projection to `look`.
8. Run the Electron and Catalyst readback experiment.

## Primary sources

- [cua no-foreground contract](https://cua.ai/docs/concepts/the-no-foreground-contract)
- [cua-driver MCP tools](https://cua.ai/docs/reference/cua-driver/mcp-tools)
- [OpenAdapt Flow design](https://raw.githubusercontent.com/OpenAdaptAI/openadapt-flow/main/DESIGN.md)
- [agent-desktop README](https://raw.githubusercontent.com/lahfir/agent-desktop/main/README.md)
- [Playwright actionability](https://playwright.dev/docs/actionability)