# Windows UI Automation spike findings

Tested on `bglab-win` on 2026-08-02. The Rust workspace location is the recommended monorepo shape from AXN-25, but it is not yet settled.

## Interactive desktop access

SSH ran as `bglab-win\mitch` in Windows session 0. `WTSGetActiveConsoleSessionId()` returned 1, and `qwinsta` reported session 1 as the active console session for the same user. Explorer and Edge processes ran in session 1.

UI Automation initialized in session 0, but the desktop root had exactly zero children. The same binary, launched by the user from PowerShell in session 1, enumerated 11 top-level elements. The Windows Axon daemon must therefore start in the logged-in user's session, with remote agents connecting over a named pipe. A service-session workaround is neither needed nor appropriate.

## Crate assessment

The spike uses `uiautomation` 0.25.0. It made enumeration, property access, control-view walking, and typed `InvokePattern` dispatch concise enough to validate the core loop quickly.

Feature selection exposed rough edges. Building with only `pattern` failed because core imports the feature-gated input module. Adding `input` alone then failed because a transitive Windows API feature was not enabled. The supported default feature set compiled, but pulls in more than this spike needs.

For the real daemon, provisionally prefer evaluating direct `windows` crate COM
bindings for Axon's narrow UI Automation surface. They are more verbose, but
would make COM initialization, cache requests, HRESULT handling, timeouts, and
Windows features explicit. This spike did not implement that alternative, so a
direct-binding prototype covering cache requests and timeout behavior is still
needed before making the architectural choice. The wrapper remains useful as
executable reference material.

## Notepad capture

The session-1 run captured 46 nodes from modern Notepad at depth 6, with control type, name, AutomationId, and bounding rectangle. The semantic tree included:

- `Document` / `Text editor`
- tabs with `Tabs`, `TabListView`, `CloseButton`, and `AddButton`
- File, Edit, and View `MenuItem` controls with matching AutomationIds
- named formatting and settings buttons
- cursor position, character count, line-ending, and encoding status text
- title-bar Minimize, Maximize, and Close buttons

First-substring window matching initially selected a terminal title containing “cairn” before the exact app title. The spike now ranks an exact case-insensitive title above a contains match. The real locator scorer must similarly rank exact evidence above partial evidence.

## Invoke dispatch and verification

The locator `control type = MenuItem` plus `name contains = File` resolved the Notepad File menu item. `InvokePattern::Invoke` reported:

    dispatch_success=true

After 500 ms, an independent recapture observed the tree grow from 61 to 91
nodes, evidence consistent with the menu opening:

    verified_outcome=true
    verification=bounded_tree_changed before_nodes=61 after_nodes=91

This proves dispatch and a coarse independent change signal can be represented
separately. Whole-tree inequality does not prove action-specific goal success:
an unrelated UI mutation could satisfy it. Real actions need action-specific
predicates and bounded waits rather than a fixed sleep.

## WebView2 observation

Cairn's exact `cairn` window was reachable, but an unactivated WebView2 subtree was
poor. At depth 12 it contained 23 nodes: native window chrome plus nested anonymous
`Pane` elements. It had no web document, page control, or page text. This confirms
that merely creating a UI Automation client did not activate Chromium renderer
accessibility.

The spike's `--activate-msaa` mode calls `AccessibleObjectFromWindow` for
`OBJID_CLIENT` on the selected top-level HWND and every child HWND, releases each
returned `IAccessible`, and waits 1.5 seconds before the UI Automation capture. All
six queries against Cairn returned an accessible object. At depth 12, the next UIA
capture gained a `Document` named `cairn` with `AutomationId=RootWebArea`. This is
direct evidence that the MSAA touch activated Chromium's renderer accessibility.

The root web document was exactly at the depth-12 boundary, so a depth-30 capture
was necessary to test semantic descendants. That capture contained 49 nodes, of
which 32 had names and three had AutomationIds. Its control-type histogram was:

    Button:13, Document:1, Group:4, MenuBar:1, MenuItem:1,
    Pane:16, Text:11, TitleBar:1, Window:1

The WebView2 subtree included real application semantics:

- `Document` / `cairn` / `RootWebArea`
- `Group` / `Navigation sidebar`
- buttons named `Collapse sidebar`, `Go back`, `Go forward`, and
  `Open command palette`
- project navigation buttons named `Expand project Workspace`, `Workspace`, and
  `Open settings for Workspace`
- page text including `Welcome to Cairn`, `Backend Providers`, `Claude`, and
  `Codex`
- buttons named `Install Claude`, `Install Codex`, and `Continue`

The activation test therefore produced a usable semantic UIA tree without
restarting Cairn or forcing renderer accessibility through a WebView2 environment
variable. AutomationIds remain sparse; activation exposes the identifiers supplied
by Chromium and the page but cannot manufacture developer identifiers absent from
the markup.

The real Windows backend should MSAA-touch the selected target HWND and all of
its descendant HWNDs before capturing WebView2 content. It should then poll UI Automation for the
`RootWebArea` document, within a bounded deadline, instead of copying the spike's
fixed sleep. Capture must also avoid a shallow global depth limit: Cairn's document
started twelve control-view edges below the native window. A targeted subtree walk
or cache request rooted at the web document is preferable once it appears.

Because client-side MSAA activation yielded a usable semantic tree for the tested
Cairn page and runtime, the more intrusive restart-time
`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` experiments and an MSAA/IA2 capture
fallback were not necessary. UI Automation is sufficient for this WebView2 runtime
once renderer accessibility is activated.

## Conclusion

The core Windows loop is viable in Rust when it runs in the interactive user
session. UI Automation gives a strong native Notepad tree, locator resolution is
straightforward, and Invoke dispatch can be measured separately from a
post-dispatch state signal. WebView2 also exposes Cairn's semantic page tree after
an MSAA `OBJID_CLIENT` activation touch. The implementation-shaping requirements
are now concrete: the daemon must run per user session, activate Chromium-backed
window subtrees before capture, wait boundedly for `RootWebArea`, and capture deep
enough to reach the web document.


## Binding evaluation: direct `windows` COM

AXN-29 added the experimental `uia-binding-eval` workspace crate and tested
`windows` 0.62.2 directly on `bglab-win` in interactive session 1. The crate
uses an explicit feature set rather than `uiautomation`'s coupled defaults. It
initializes an MTA, configures UIA provider timeouts, performs the proven MSAA
activation, polls for `RootWebArea`, and exposes benchmark, pattern, and event
probes.

### Capture and search measurements

A Cairn `RootWebArea` capture returned 26 descendants (27 nodes including the
root). One interactive run measured:

    FindAll + four Current property reads:       18.230 ms
    FindAllBuildCache + four Cached reads:        9.787 ms
    manual ControlView TreeWalker (no properties): 13.261 ms

The cached path fetched ControlType, Name, AutomationId, and BoundingRectangle in
one build-cache operation and was 46% faster than the equivalent uncached
property path on this small tree. The difference should grow with tree size and
provider-process boundaries. The manual walker number is not directly comparable
because it intentionally reads no properties; it demonstrates that recursion is
already slower than condition-based bulk search before adding property round
trips.

The wrapper's existing bounded depth-30 capture took 1954.954 ms end to end for
49 nodes. That includes its fixed 1500 ms post-MSAA sleep, leaving roughly 455 ms
for capture and printing, so it is code-shape and end-to-end context rather than
a same-workload performance comparison. The wrapper spike has no public bulk
cache path equivalent; a production benchmark must use identical roots, nodes,
properties, and timing boundaries.

A subtle COM semantic matters: the cache request passed to
`FindAllBuildCache` must use `TreeScope_Element` to populate each returned
match. `TreeScope_Descendants` asks for each match's descendants instead;
attempting `CachedControlType` on the match then fails with `E_INVALIDARG`.
Direct bindings expose this precisely, but require tests around cache shape.

`CreatePropertyCondition` plus `FindFirst` found `RootWebArea` during a
bounded poll and found a named Cairn control for pattern testing.
`CreateTrueCondition` plus `FindAll` supplied bulk capture. For known
properties and bounded subtrees this is both clearer and faster than recursive
`TreeWalker`; retain the walker only where hierarchy reconstruction requires
parent/child edges.

### Pattern ergonomics

On Cairn's `Collapse sidebar` control, typed
`GetCurrentPatternAs<T>` calls reported:

    Invoke=true, Value=false, ScrollItem=true
    ScrollIntoView succeeded
    Invoke succeeded

Unsupported patterns arrive as failed typed interface queries and are mapped to
an `Unsupported` operation error when the requested action requires one. Value
set is implemented by the evaluator but was not issued against Cairn because the
chosen control correctly lacked ValuePattern and changing an arbitrary editable
field would be destructive. Value get/set remains a backend integration-test
requirement. Compared with the wrapper, direct pattern dispatch
adds a generic interface query and explicit HRESULT mapping; the resulting code
is still small and makes unsupported-pattern behavior unambiguous.

### Events and threading

A focus-changed handler was registered and removed from an MTA owner thread for
20 seconds while the user clicked in the interactive desktop. Seven callbacks
arrived. One callback ran on the registration thread and six ran on another COM
callback thread.

The daemon must therefore own UIA clients, elements, cache requests, and patterns
on a dedicated MTA thread, but must not assume callbacks run there. Handler
implementations must do no blocking work and no UIA re-entry. They should copy
the minimal event data into owned records and enqueue those records to the
daemon. Registration lifetime and explicit removal remain the owner's
responsibility. Automation-event and structure-changed handlers have the same
generated ownership shape, but live registration and delivery were only
observed for focus changes. The real backend must integration-test all three.

### Timeouts, cancellation, and typed errors

The evaluator queries `IUIAutomation2` and sets both connection and transaction
timeouts to 1000 ms. These are UIA's controls for disconnected or non-responsive
providers, but this evaluation did not have a controlled hung provider and did
not observe their elapsed-time behavior. The `RootWebArea` activation poll has
a five-second operation deadline and checks it between calls. The prototype
does not cancel an individual in-flight COM call. The real backend should
combine these provider timeouts with operation deadlines and cancellation checks
between calls, rather than moving UIA interfaces across worker threads.

The prototype maps element-unavailable HRESULTs to
`ProviderUnavailable`, deadline expiry to `Timeout`, absent patterns to
`Unsupported`, and lookup misses to `NotFound`. Other native failures become
a typed `Native` operation error with the Windows message retained only as
diagnostic detail. No HRESULT is part of the public error category, matching the
cross-platform contract.

### Decision

**Use direct `windows` crate COM bindings for the real Windows backend.**

The decisive reasons are the public `CacheRequest` bulk path, explicit
`IUIAutomation2` timeout control, transparent apartment and callback ownership,
precise typed pattern queries, and freedom from `uiautomation` 0.25.0's default
feature coupling. The direct path is more verbose and unsafe at generated call
sites, but the backend's surface is narrow enough to contain that cost in one
adapter.

That adapter must rebuild the wrapper conveniences deliberately: COM apartment
RAII, exact-then-contains window selection, property and control-type conversion,
cache-request construction, bounded condition search, hierarchy reconstruction,
typed pattern lookup, event-handler lifetime management, and HRESULT-to-domain
error mapping. These are backend policy rather than generic convenience, so
owning them is preferable to accepting a wider wrapper boundary whose caching,
timeouts, features, and threading behavior Axon cannot control.
