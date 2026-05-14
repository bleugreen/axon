# Tool Naming And Surface Consolidation

## Context

The MCP tool surface is the agent's working vocabulary. Every name an agent reads in its toolbox becomes part of how it plans. The current names are CRUD-shaped (`get_app_state`, `set_value`, `perform_action`) — they read as wrappers over the Accessibility API rather than as actions an agent does. That's a leak of internal shape into the agent's mental model, and it costs us in two places: agents pick the wrong tool when names overlap semantically (`set_value` vs `type_text`), and the surface is larger than it needs to be because related operations are spread across tools that could collapse.

The renaming pass is also a *consolidation* pass. Several current tools are modes of a single verb — `list_apps`, `get_app_state`, `get_children`, `get_screenshot`, and `changed_since` are all "look at something." Treating them as one verb with parameters shrinks the surface and makes the agent's choice space smaller and more obvious.

This is the cheapest moment in axon's life to do this. The project is less than 24 hours old; there are no external consumers; nothing depends on the current names. Six months from now, the same change is a breaking-API migration.

The neural-metaphor framing (see [[axon-neural-metaphor]]) also pulls the same direction. `.axn` files are myelin; the daemon is hippocampal; the tool surface is the motor cortex. Verb-shaped names reinforce that framing; CRUD-shaped names work against it.

## Desired Shape

A small verb-set, grouped by intent:

**Perception** — what the agent can sense:
- `look(target?, since?, screenshot?, depth?)`
- `find(locator)`

**Action** — what the agent can do:
- `click(handle)`
- `type(handle, value)`
- `keyboard(keys)`
- `scroll(handle, direction)`
- `drag(from, to)`
- `invoke(handle, name)`

**Session** — what the agent can preserve or replay:
- `save(path?)`
- `run(actions?, path?)`
- `permit()`

Eleven tools down from sixteen, with cleaner intent boundaries.

## The Consolidations

### `look` absorbs five tools

Today: `list_apps`, `get_app_state`, `get_children`, `get_screenshot`, `changed_since`.
Tomorrow: one verb, parameters specify the lens.

- `look()` — no target, returns the list of apps (was `list_apps`).
- `look(app)` — AX tree for an app (was `get_app_state`).
- `look(handle)` — drill into a node (was `get_children`).
- `look(target, since: snapshotId)` — what changed since a prior snapshot (was `changed_since`). Every `look` return includes a `snapshot_id`; that's the value to pass back here. Handles are pointers to nodes, not moments in time — using a snapshot ID makes the temporal anchor explicit and decouples "diff me" from any particular node.
- `look(target, screenshot: true)` — AX tree + correlated image (was `get_screenshot`, but co-registered with the tree).
- `look(target, screenshot: true, tree: false)` — just the image, for the rare pixel-inspection case.
- `look(target, depth: N)` — how deep to walk.

Defaults stay AX-only because image payloads are big and the structured tree is what 99% of agent decisions are made from. The image, when requested, comes back co-registered with handles — a bare screenshot without a tree is mostly useless for an automation agent.

### `type` vs `keyboard` separates intent from mechanism

Today: `set_value`, `type_text`, `press_key` — three tools that all "write text." Agents routinely pick the wrong one.

Tomorrow:
- `type(handle, value)` — fill a field. Semantic. The 99% case.
- `keyboard(keys)` — press keys. Covers shortcuts (`cmd+s`), raw text injection where no field is targeted, and modifier sequences. The escape hatch.

The split is by *intent*, not mechanism. "I want this field to contain X" is `type`. "I want to press these keys" is `keyboard`. Today's `set_value` is the former; today's `type_text` and `press_key` are both the latter.

### `run` handles batches *and* recordings

Today: `run_batch` for in-memory action lists; the file-replay case is implicit (load file, pass to run_batch).
Tomorrow: `run(actions?, path?)` accepts either a literal list of actions or a `.axn` path (or both — path loaded first, then actions appended, for parameterized replays).

The verb name doesn't lie about what it's doing. `play` would imply file-only; `run` covers "execute this sequence" regardless of provenance.

### `save` writes recordings

`export_script` → `save`. The user (or agent) is saving what just happened to disk. "Export" implies a format conversion; "save" describes the actual operation. Pairs naturally with `run`.

### `find` resolves locators

`resolve` → `find`. The intent is "give me a handle to a thing I'll act on later." Distinct from `look` (snapshot) because the return shape is different — `find` returns a single handle (or null), `look` returns a tree. Keeping them separate signals which output the agent should expect.

## Verb-by-Verb Reference

| Today | Tomorrow | Notes |
|---|---|---|
| `list_apps` | `look()` | No-arg look. |
| `get_app_state` | `look(app)` | App-targeted look. |
| `get_children` | `look(handle)` | Handle-targeted look. |
| `get_screenshot` | `look(target, screenshot: true)` | Screenshot is a modality, not a separate verb. |
| `changed_since` | `look(target, since: snapshotId)` | Diff is a parameter, not a verb. |
| `resolve` | `find(locator)` | Locator → handle. |
| `click` | `click` | Unchanged. |
| `drag` | `drag` | Unchanged. |
| `scroll` | `scroll` | Unchanged. |
| `set_value` | `type(handle, value)` | Semantic field write. |
| `type_text` | `keyboard(keys)` | Raw keystrokes. |
| `press_key` | `keyboard(keys)` | Folds into keyboard. |
| `perform_action` | `invoke(handle, name)` | Precision over vibe — every tool call is an action, but `invoke` specifically names "trigger an AX action by name." |
| `export_script` | `save(path?)` | Write recording to disk. |
| `run_batch` | `run(actions?, path?)` | Accepts list, path, or both. |
| `request_accessibility` | `permit()` | Meta-tool, called once at setup. Short verb still beats the long phrase. |

## Why Verbs Compose Better

A toolbox of verbs reads like a vocabulary of things an agent can do. A toolbox of CRUD operations reads like an API the agent has to navigate. Both can technically express the same actions, but the verb form maps more directly to how an LLM plans — agents reason in actions, not in resource-state mutations.

Concretely: `look → find → click` reads as a sequence a human would describe. `get_app_state → resolve → click` reads as three API calls glued together. The verb form is also more *forgiving* to the agent — when in doubt, "look" works; when in doubt, the agent has to guess between `get_app_state` and `get_children`.

## Decisions

- **`invoke` for the generic AX-action trigger.** Every tool call is technically an "action"; `invoke` precisely names "trigger an AX action by name."
- **`permit` for accessibility permission.** Meta-tool, called once at setup. `permit()` still beats `request_accessibility` even though it's rarely on the agent's hot path.
- **`look(since:)` takes a snapshot ID.** A handle is a pointer to a node, not a moment in time; reusing it for "diff me" would conflate two unrelated concepts. Snapshot IDs come back from every `look` call, and the agent passes one back to get a diff. Decoupling temporal anchor from any specific node also lets `look(app, since: id)` mean "show me what changed about the whole app since then" without forcing the agent to track a specific node.
- **`run(actions, path)` merges as base + append.** Path loads as the base sequence; the `actions` parameter, if present, appends. This is the parameterized-replay shape — load a saved recording, then add a few extra steps. The reverse interpretation (actions replace path) has no useful case; the all-error interpretation forfeits the composition.
- **Screenshot modality is two orthogonal flags, not a tri-state.** `screenshot: true` adds an image to the response; `tree: false` suppresses the AX tree. They compose: `screenshot: true, tree: false` is the pixel-only case. A tri-state `screenshot: "only"` would have conflated "include image" with "exclude tree" into a single dimension, which doesn't generalize if other modalities (e.g., OCR text, layout boxes) get added later.
- **Handles are locator-shorthand with a snapshot provenance stamp, not snapshot-scoped lifetimes.** A handle like `s15:5` is a reference to "the locator I observed at index 5 of snapshot 15." Re-looking and getting `s16:5` for the same underlying element means both `s15:5` and `s16:5` resolve to the same locator and both still work — provided the locator still matches something in the current state. The snapshot prefix is recency provenance, not a scoping boundary. The failure mode is correct as stated: locator no longer matches anything → action fails. No "expiration" or "promotion" machinery needed; the design is already right.

## Non-Goals

- **No CRUD-style aliases.** `get_app_state` is not preserved as a deprecated alias. The whole point of doing this now is zero migration cost; aliases create the very technical debt this pass eliminates.
- **No internal Swift renaming required.** This is a rename of the *MCP tool surface*. The underlying Swift functions, internal types, and AX wrappers can keep their existing names — the MCP layer maps verbs to implementations. Bigger renames internal-side can happen later, separately, if they're worth doing.
- **No semantic changes.** Same operations, same parameters (mostly), same return shapes. The exception is the consolidations — `look` does formally subsume five tools — but each subsumed call still has a direct equivalent in the new surface.
- **No new tools.** This pass renames and consolidates only. Anything that would add capability (e.g., a vision-only `see` distinct from `look`, or a recording-control verb) belongs in a separate issue.
- **No partial migration.** Either the whole surface flips or none of it does. A half-renamed toolbox is worse than either consistent state.

## Next Steps

- Audit every place tool names appear: MCP tool registrations, `axon-core` exports, README, recorder UI labels, `.axn` action `tool:` fields, batch trace tags, history records.
- Migrate `.axn` action `tool:` fields. Existing recordings on disk reference the old names; either rename in-place (small migration script) or accept that pre-rename `.axn` files won't replay until edited. Since the corpus is tiny right now, in-place rename is cheapest.
- Add `snapshot_id` to every `look` return so `look(since:)` has something to anchor on. Decide on the ID shape (UUID, monotonic counter, content hash) when wiring.
- Land the rename as one coordinated commit, not piecemeal. A half-renamed surface is worse than either consistent state.
- Update [[2026-05-13-late-bound-values-and-credentials]] examples that reference `set_value` — switch to `type` so the doc stays current.
- Confirm the `look` consolidation doesn't regress any current call site: every existing tool call should have a direct one-line equivalent in the new surface.
