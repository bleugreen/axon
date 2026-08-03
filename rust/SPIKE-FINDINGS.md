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

The real Windows backend should MSAA-touch a target window's child HWNDs before
capturing WebView2 content. It should then poll UI Automation for the
`RootWebArea` document, within a bounded deadline, instead of copying the spike's
fixed sleep. Capture must also avoid a shallow global depth limit: Cairn's document
started twelve control-view edges below the native window. A targeted subtree walk
or cache request rooted at the web document is preferable once it appears.

Because client-side MSAA activation yielded the full semantic tree, the more
intrusive restart-time `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` experiments and an
MSAA/IA2 capture fallback were not necessary. UI Automation is sufficient for this
WebView2 runtime once renderer accessibility is activated.

## Conclusion

The core Windows loop is viable in Rust when it runs in the interactive user
session. UI Automation gives a strong native Notepad tree, locator resolution is
straightforward, and Invoke dispatch can be measured separately from a
post-dispatch state signal. WebView2 also exposes Cairn's semantic page tree after
an MSAA `OBJID_CLIENT` activation touch. The implementation-shaping requirements
are now concrete: the daemon must run per user session, activate Chromium-backed
window subtrees before capture, wait boundedly for `RootWebArea`, and capture deep
enough to reach the web document.
