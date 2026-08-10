# Semantic element name prototype study

Date: 2026-08-10

## Scope and harness

`SemanticNameDeriver` is an experimental pure function over the JSON boundary emitted by `axon look --json`. It does not alter `ToolSurfaceSpec` or render names in normal observations. The `SemanticNameStudy` executable reads one or more saved snapshots, emits per-element names and distributions, and compares adjacent captures.

The prototype normalizes native roles to Axon's observation vocabulary, ignores geometry and snapshot handles, rejects `_NS:<number>` and accessibility pointer identifiers, bounds each slug to 32 characters, and skips anonymous `item`, `cell`, `row`, `group`, `scroll`, and `splitter` wrappers. Anonymous menu bars contribute one `menu` landmark. It starts with at most three trailing semantic segments, deepens only colliding paths, uses a role qualifier when equal paths describe different roles, and uses an ordinal only for duplicates that remain.

The checked-in fixture is synthetic so the repository does not retain private text from live applications. Live snapshots stayed in temporary storage.

## Live measurements

Two read-only captures were taken several seconds apart. Segment and character columns are minimum / median / 90th percentile / maximum. “Collision-free” means the name was unique before an ordinal was appended. Stability excludes identities that were already indistinguishable within the first capture, but counts a missing identity in the second capture as a break.

| Application | Eligible elements | Collision-free | Segments | Characters | Capture time (seconds) | Stable names |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Notes | 318 | 304 (95.6%) | 2 / 3 / 3 / 5 | 9 / 25 / 40 / 57 | 1.10, 1.30 | 308 / 308 (100%) |
| Finder | 1,196 | 618 (51.7%) | 1 / 3 / 4 / 4 | 5 / 32 / 54 / 71 | 7.40, 8.44 | 621 / 626 (99.2%) |
| ChatGPT | 463 | 426 (92.0%) | 1 / 3 / 8 / 8 | 7 / 63 / 139 / 155 | 2.53, 2.95 | 426 / 426 (100%) |
| Linear | 248 | 225 (90.7%) | 1 / 3 / 3 / 4 | 13 / 50 / 68 / 92 | 1.84, 2.07 | 231 / 231 (100%) |
| Firefox | 43 | 43 (100%) | 1 / 3 / 3 / 3 | 24 / 56 / 73 / 76 | 0.46, 0.29 | 43 / 43 (100%) |

Finder had 570 elements whose semantic identity was already ambiguous and therefore could not provide honest same-element ground truth. Notes had 10, ChatGPT 37, Linear 17, and Firefox none. Finder's five breaks were elements that disappeared between captures, not geometry-induced renames.

### Representative names

| Application | Element | Prototype name |
| --- | --- | --- |
| Notes | Apple menu, About This Mac | `menu/apple/about-this-mac` |
| Notes | Apple menu, System Information | `menu/apple/system-information` |
| Finder | Sidebar Eject buttons | `cairn/sidebar/eject-1` through `eject-4` |
| ChatGPT | Search | `codex/scheduled-task-folders/search` |
| Linear | Create new issue | `my-issues-created/create-new-issue` |
| Firefox | Close tab | `browser-tabs/identity-validation-microsoft/close-tab` |

The deterministic fixture verifies the intended baseline `menu/file/new-note`, anonymous-wrapper skipping, role disambiguation (`done-button` versus `done-text`), ordinal assignment, bounded Unicode slugging, rejection of `_NS:341`, and stability across changed handles and frames.

## Collision and length findings

The menu baseline works. Menus provide semantic scaffolding almost for free, and rejecting `_NS:<number>` does not reduce their usability.

True duplicates are common and application-specific:

- Finder exposes 182 identical `Folder` text nodes, 178 disclosure triangles with value `0`, 28 `move` images, and repeated `Eject` controls. These are not made meaningfully durable by adding deeper anonymous structure.
- Notes duplicates include repeated menu commands such as `Block Quote`, `Default`, bidirectional text commands, and recent items with the same visible title.
- ChatGPT repeats per-row controls such as `Pin chat` and `Archive chat`; the row title is the useful disambiguator when it is stable.
- Linear repeats priority images and short avatar or team text such as `ML` and `BL`.
- Firefox tab close buttons disambiguate cleanly through the tab title.

Deepening until global uniqueness is not an acceptable primary policy. ChatGPT needed eight segments at the 90th percentile and produced names up to 155 characters. Even where paths remained near three segments, long mutable document titles made median names 50 to 63 characters in Linear and ChatGPT. This violates the intended short vocabulary despite technically improving uniqueness.

## Stability conditions and capture cost

Time-separated captures show that names are independent of snapshot IDs and ordinary capture churn. Finder's changed elements were the only observed time breaks among uniquely matchable identities.

The requested move/resize and relaunch trials were authorized, but macOS rejected both Finder bounds scripting and Firefox quit scripting with automation privilege error `-10004` before either application changed. Those conditions are therefore unmeasured in this execution rather than reported as successes. The deterministic test proves geometry independence at the algorithm boundary, but it is not a substitute for a live resize result.

Full capture cost is material:

- TextEdit, currently including an Open dialog, exceeded a 30-second bound.
- Mail exceeded a 30-second bound.
- System Settings exceeded a 30-second bound.
- Finder took 7.4 to 8.4 seconds.
- A target of `Safari` resolved quickly to the running `AutoFill (Stream Deck)` Safari helper with no windows, exposing a separate fuzzy-app-targeting hazard; it was excluded from semantic metrics.

These results support a cached semantic map or diff layer independently of the naming decision. Requiring a full capture merely to refresh handles remains too expensive on large trees.

## Recommendation

Adopt a strict three-segment budget for the agent-facing name, with four segments allowed only when a stable, human-readable ancestor resolves a real collision. Do not keep prepending ancestors until a name is unique. Long paths are verbose locators disguised as names and inherit volatility from every ancestor.

Use these segment rules:

1. Preserve one canonical region landmark such as `menu`, a stable window or document label, or a labeled list/sidebar.
2. Preserve one nearest labeled container or row title when it disambiguates repeated controls.
3. Use the leaf's human-readable title, label, text, or non-volatile value. A stable explicit identifier is fallback evidence, not preferred prose.
4. Reject framework allocation identifiers, pointer descriptions, redaction placeholders, generic state values such as `0`, and generic repeated nouns such as `Folder` as naming identity.
5. Qualify by normalized role only when equal visible labels denote different element kinds.
6. Append ordinals only for true duplicates within the same stable semantic parent. Treat the ordinal as a local presentation fallback, not durable identity evidence.

Names should resolve through Axon's existing semantic locator scoring rather than encode every locator fact into the string. When three or four segments remain ambiguous, return ambiguity with candidates instead of manufacturing a long or falsely stable name. This preserves the short vocabulary while letting durable locators, cached handles, and geometry tie-breaks remain internal resolution machinery.
