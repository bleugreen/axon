# Late-Bound Values And Credentials

## Context

Two adjacent problems land in the same place:

1. **Parameterization.** As `.axn` files accumulate, the most reusable ones are not the ones that hard-code every value. The path "open the report folder, drag yesterday's CSV into the upload field, click Submit" is generic; the literal filename is not. We want a way to define holes in a recording that get filled at replay time.
2. **Secrets.** Some fields cannot be recorded literally — passwords, tokens, MFA codes, signing keys. Today the recorder either has to refuse those moments or silently drop them. Neither preserves the workflow.

Both problems want the same shape: **values that are references at rest and resolve at replay**. Secrets are the first species of a broader late-bound value story. The credential case is also the one with the cleanest UX precedent on macOS — 1Password's `op` CLI already owns secure storage and consent, and we don't need to invent either.

## Desired Shape

`.axn` actions gain a templated string syntax in any `value`-shaped field, plus an optional `resolveAs` tag for resolver-specific behavior:

```yaml
- tool: set_value
  target: { role: AXSecureTextField, ancestor: { title: "Gmail" } }
  value: "op://Personal/Gmail/password"
  resolveAs: secret

- tool: type_text
  target: ...
  value: "Hello {{arg://recipient}}, the file is at {{env://REPORT_DIR}}/{{prompt://"which date?"}}.csv"
```

The syntax is borrowed deliberately:

- Bare `op://...` strings (no braces) are recognized as 1Password references — same shape as `op inject` and `op read`. This keeps the common case ungarnished.
- `{{scheme://path}}` is the general template form for embedding any resolver result inside a larger string.
- A `resolveAs` tag is metadata for the executor, not the resolver. `resolveAs: secret` means "do not log this value at any layer, redact in traces, fail loudly if the resolver isn't available." Future tags (`resolveAs: path`, etc.) can carry similar policies.

The resolver itself is a protocol axon-core exposes; integrations register implementations by scheme. axon-core stays agnostic. The first registered resolver is `op://`; the obvious additional resolvers are `env://`, `prompt://`, and `arg://`.

## The 1Password Resolver

At replay, an `op://vault/item/field` reference is resolved by shelling out to `op read 'op://...'`. The op CLI handles auth, consent (typically Touch ID), and session caching (~8 minutes by default). Axon does not cache resolved secrets at any layer — every call goes through op.

Resolution rules:

- If `op` is not installed or not signed in, fail the action with a clear "credential reference unresolved" error. Do not soft-fail into the literal reference string.
- If op returns an error, surface op's error message verbatim. Never substitute or guess.
- Resolved secret values pass directly into the AX call. They are not echoed into history records, batch traces, stdout, or log files.
- Failed resolutions log the *reference*, never the (unresolved) value placeholder or any partial.

## Recording UX

The recorder treats `AXSecureTextField` focus as a hard signal: **never store the literal keystrokes**. When the recorder detects that secure input has just landed, it pauses and prompts via the menubar:

1. **Bind to 1Password item.** Opens a system sheet listing the user's op vaults and items; the user picks one, the recorder writes an `op://...` reference into the `.axn`.
2. **Mark as prompt at replay.** Writes `{{prompt://"<inferred label>"}}` — at replay the executor pops a UI asking for the value.
3. **Skip this action.** The keystrokes never enter the file; replay will need a manual edit.

The default has to be option 2 — fail-safe to "ask at replay" if the user doesn't actively pick a binding. macOS `IsSecureEventInputEnabled()` already blocks the recorder from seeing keystrokes inside secure fields, which dovetails with this design: the recorder *can't* accidentally capture, so the only question is what shape to write in place of the missing data.

Non-secure fields can also be bound to references explicitly — the menubar can offer a "promote this value to a parameter" affordance during or after recording. That's how the broader parameterization story shows up at record time.

## Replay Behavior

The executor walks each action, scans every `value`-shaped field for templates and bare references, and resolves them in order. Resolver calls happen *before* the AX action; if any resolver fails, the action errors before any UI side effect.

- `op://...` → shell out to op, substitute.
- `{{env://NAME}}` → read from process env, substitute.
- `{{arg://name}}` → read from `run_batch` / CLI args, substitute. Missing args are an error unless a default is declared at the top of the `.axn`.
- `{{prompt://"label"}}` → block on a system prompt for input. Sensible default to mark these as `resolveAs: secret` unless the recording knew otherwise.

Traces emitted for the action redact resolved values when `resolveAs: secret` is set. The trace shows the *reference*, not the resolution.

## Active-Secret Bloom Filter (Read-Side Protection)

The resolver is the *write* side of the op integration — it tells axon how to put secrets into the world. The *read* side has the symmetric problem: AX snapshots can return values that happen to be the user's active credentials, even when the agent didn't ask for them. A misconfigured app showing a password in plain text, a 2FA seed visible in account settings, a recovery code displayed for backup — all become text in the AX tree, and today axon would echo them straight back to the agent.

This is op's mirror role. Op already knows every active credential the user has. We don't need to classify, learn, or pattern-match — we can ask op what's currently active and refuse to emit those values, full stop. This is the "active passwords cannot appear in `get_app_state`" guarantee, shippable independently of the broader [sensitivity classifier](2026-05-13-policy-driven-sensitivity-classifier.md) work.

### How it works

A local bloom filter of `sha256(<value>)` for every currently-active credential value in the user's op vaults. At snapshot-time, every AX element value gets hashed and checked. A hit means the value is verbatim a known active credential; the snapshot returns it as `<redacted: active-credential>` instead of the literal.

- **Filter size**: ~30 KB for tens of thousands of secrets at a 1-in-a-million false-positive rate.
- **Per-element cost**: one SHA-256 hash plus a bloom lookup. Microseconds. Fits trivially in the synchronous snapshot path.
- **No model weights, no leakage surface.** The filter is hashes; it cannot be reverse-engineered into the values. Storing it on disk is safe.

### What gets hashed

Op items have typed fields. We only fingerprint the high-stakes types:

- `password`
- `recovery_code` / `recovery_key`
- `otp` secrets (the seed, not the rotating code)
- `concealed` fields (op's generic "this is secret" type)
- API keys / tokens / SSH keys / signing keys, marked concealed

We skip lower-stakes typed fields:

- `username`, `email`, `url`, `notes` — too likely to legitimately appear elsewhere, too high a false-positive nuisance rate. The classifier work handles these via the `pii-identifier` head later.

### Rotation behavior

A rotated secret is no longer in op, so it leaves the filter on next refresh. This is correct: a rotated credential is no longer active, no longer authentication-equivalent, and no longer needs the same protection. Stale-but-leaked is a lower-stakes leak than active-and-leaked.

### Length and entropy threshold

Hashing short values produces nuisance false positives. A 4-digit PIN shares the hash universe with `"3 of 12"` items remaining counts. The filter only ingests values whose length and entropy exceed a threshold — probably ≥8 characters and ≥3.5 bits of entropy per character. Anything shorter is left to the heuristic regex layer or skipped entirely.

### Refresh strategy

The filter cannot auto-refresh in the background because op's CLI session expires (~8 min default) and we should not be prompting the user for op auth on a timer. Instead, opportunistic refresh:

- Refresh whenever axon successfully resolves an `op://` reference for a `set_value` (we already have op auth in that flow).
- Refresh on explicit `axon refresh-secrets` (manual, user-initiated).
- Refresh on `axon train-head` and other op-authed workflows.
- Cache the filter encrypted at rest, key in macOS Keychain (the natural trust boundary for user secrets on macOS).

Between refreshes the filter may be stale. Newly-added op items aren't covered until the next refresh; rotated secrets stay in the filter until refresh and may produce one spurious redaction. Both failure modes are graceful — the worst case is a brief over-redaction on a rotated value.

### Position in the pipeline

The bloom filter is a heuristic-floor protection: synchronous, deterministic, no ML. When the [sensitivity classifier](2026-05-13-policy-driven-sensitivity-classifier.md) lands, this filter slots in as one of the heuristic-floor rules alongside the `AXSecureTextField` and SSN-regex checks. Until then, it ships as a standalone snapshot-pipeline step driven by op.

The classifier's encoder + heads add a second layer of protection: catches credential-shaped values that *aren't* in op (developer credentials in `.env` files visible in editors, partial values, paraphrased displays). The two layers compose — bloom filter is the precise verbatim catch; classifier is the pattern-match safety net.

## Privacy And Safety

- Resolved secrets are never written to disk, never put in history, never echoed in errors.
- An `.axn` containing only references (no literals) is safe to commit to a repo or share with a collaborator. The `op://` reference reveals *that* a credential is used and which item, but not its value. (See open questions on reference-redaction.)
- The op CLI's confirmation (Touch ID or master password) is the canonical human-in-the-loop checkpoint at replay. Axon does not add a second prompt by default; one consent moment is enough, and op already owns it.
- Resolver failures fail loudly. The executor never proceeds with a partially-resolved or fallback value.
- **Active credentials cannot appear in `get_app_state` output.** The bloom filter guarantees that any verbatim match against a currently-active op secret is redacted before the snapshot reaches an agent, regardless of how the value ended up in an AX tree.

## Other Resolvers

Once the resolver protocol exists, these come along nearly for free and round out the parameterization story:

- `env://NAME` — process environment.
- `arg://name` — `.axn` runtime arguments passed through `run_batch` params or `axon run --arg name=...`.
- `prompt://"label"` — interactive prompt at replay. Useful as the fallback at the secure-field record-time branch.

Possible later additions: `aws-secrets://...`, `gcloud-secrets://...`, `pass://...`, `keychain://...`. Each is a thin shim implementing the same resolver protocol.

## Open Questions

- **Argument schema.** `.axn` files that take args should declare them at the top (name, type, default, description) so the file is self-documenting and `axon run` can produce a usage line. What does that header look like?
- **Reference leakage.** `op://Work/Acme-Internal/api-key` reveals you have a credential by that path even when shared safely. Worth a `redact-references: true` sharing mode, or YAGNI for now?
- **Recorder bind UX.** How heavy is the menubar prompt during recording? If the user is mid-flow filling out a login form, a modal sheet between keystrokes is disruptive. Possible alternative: defer all secure-field bindings to a post-recording review screen and write placeholders inline during capture.
- **Op session expiry.** Long chained `.axn` runs may need to re-prompt mid-sequence. Should the executor announce this explicitly ("about to request credentials; you may see a 1Password prompt") or let op's native UI speak for itself?
- **Determinism of `prompt://`.** Re-running a file with prompts is by definition non-deterministic. Should we offer to capture prompt answers into a sibling `.values` file for replay reproducibility, with the same redaction rules as for secrets?

## Non-Goals

- No bespoke credential store inside Axon. Credentials live in op (or whatever resolver the user registered); Axon never persists them.
- No automatic detection of "sensitive-looking" non-secure fields. AXSecureTextField is the hard signal; everything else is up to the user to mark explicitly.
- No silent fallback from `op://` to `prompt://` (or any other resolver) when op is unavailable. Resolution failure is an error, not a downgrade path.
- No template language beyond simple `{{scheme://path}}` substitution. No conditionals, loops, or expressions inside `.axn` values — if logic is needed, it belongs in batch flow, not in a value template.

## Next Steps

- Define the resolver protocol in axon-core: scheme registration, resolve call, error shape, redaction policy.
- Implement the `op://` resolver as the first concrete instance. Confirm the `op read` UX path on macOS, including session-cache behavior and Touch ID prompts.
- **Build the active-secret bloom filter as an immediate read-side protection.** Field-type filtering, length/entropy thresholds, encrypted-at-rest storage, Keychain-held key, opportunistic refresh on op-authed operations. This ships independently of the classifier work and gives the "active passwords cannot appear in `get_app_state`" guarantee right away.
- Implement `env://`, `arg://`, `prompt://` as core resolvers — they're small and exercise the same protocol.
- Extend the `.axn` schema with an optional `args:` header block declaring `arg://` parameters.
- Wire the recorder's secure-field branch to write `{{prompt://"<inferred label>"}}` by default, with a menubar affordance to upgrade to an `op://` binding.
- Audit every place values flow through the system (history store, batch trace, MCP response payloads, log lines) and confirm `resolveAs: secret` redaction holds end-to-end.
