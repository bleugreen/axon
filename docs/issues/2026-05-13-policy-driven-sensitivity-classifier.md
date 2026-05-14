# Policy-Driven Sensitivity Classifier

## Context

The current `sensitive: true` flag is set by the agent at request time. It assumes the agent already knows which fields contain sensitive content, which is exactly the case where it usually doesn't. By the time the agent has the snapshot back, the data has already crossed the boundary.

We want sensitivity to be a property the *system* assigns based on what's actually in the snapshot, not a property the *caller* has to predict. The snapshot pipeline should be able to look at element content in context and apply user-authored redaction rules before anything reaches an agent or gets persisted.

This is the read-side mirror of [Late-Bound Values And Credentials](2026-05-13-late-bound-values-and-credentials.md): a pluggable, policy-driven layer between axon-core and the rest of the world, owned by the user.

## Desired Shape

A `SensitivityClassifier` protocol in the snapshot pipeline. Classifier implementations are registered with axon-core; the active one is selected by user config. The default is a fast heuristic; the upgrade path is a local small model that interprets a natural-language policy.

The classifier sees each element with full context (role, ancestors, labels, value) and returns a verdict per element: clear, or redact with a reason tag (e.g., `financial-data`, `auth-credential`, `pii-identifier`). Verdicts are attached to the snapshot record as metadata, not baked into the values themselves.

A snapshot returned to an agent shows redacted elements as `value: "<redacted: financial-data>"`. The agent sees *that* a value exists and *why* it's hidden — never the value itself. This matters for planning: the agent needs to know "there's a balance field here I shouldn't read but might need to interact with."

User-authored policy lives at `~/.axon/sensitivity-policy.md` (or a configurable path). It's a plain-English document describing what to redact. Example:

```markdown
# Sensitivity Policy

Redact any element that exposes:
- Account balances, transaction amounts, or financial holdings.
- Authentication credentials, API tokens, recovery codes, MFA codes.
- Personal identifiers (SSN, driver license, passport, full DOB).
- Private message bodies in messaging apps. Subject lines and sender names are fine.
- Personal email addresses other than the signed-in user's.

Do not redact:
- Public-facing labels, button text, navigation chrome, app titles.
- The signed-in user's own display name.
```

## Heuristic Floor

Independent of any model, a heuristic layer always runs first and can only *add* redactions, never subtract them:

- `AXSecureTextField` values are always redacted.
- Regex matches for SSN (`\d{3}-\d{2}-\d{4}`), credit card patterns (Luhn-checked), API-key shapes (`sk-[A-Za-z0-9]{32,}`, `ghp_[A-Za-z0-9]{36}`, etc.) always redact.
- Element labels containing `password`, `secret`, `token`, `private key`, `recovery code`, or similar high-signal substrings always redact the corresponding value.
- **Active-credential HMAC index** against the user's currently-active op secrets — verbatim matches always redact. See [Late-Bound Values And Credentials](2026-05-13-late-bound-values-and-credentials.md#active-credential-index) for the design; this ships as part of the op integration work and slots into the floor when the classifier lands.

This is the false-negative floor: a model error in the "miss" direction can never expose a field a regex would have caught. The model can only flag *more* things, not unflag.

## Encoder Classifier With Heads

The upgrade beyond heuristics is a distilled encoder plus per-rule classification heads, exported to CoreML and run on the Apple Neural Engine. This is the runtime classifier — what ships in the app, what fires on every snapshot.

Architecture:

- **Shared backbone.** A pretrained transformer encoder (DistilBERT / MiniLM / sentence-transformer class, ~30M params, ~30 MB on disk) takes a serialized AX element (role, label, value, ancestor) and produces a contextual embedding. The backbone is the same for every user, shipped once.
- **Per-rule heads.** Each rule tag (`financial-data`, `auth-credential`, `pii-identifier`, `private-message`, etc.) is a tiny linear classifier (~50K params) sitting on the backbone output. One forward pass through the backbone feeds all active heads simultaneously.
- **Batch per snapshot.** A snapshot with N elements is one batched forward pass, not N serial inferences. This is the structural reason the encoder path is viable where LLMs are not: latency is O(snapshot), not O(elements-in-snapshot).
- **Local, free, fast.** Neural Engine inference on M-series hardware is sub-watt and sub-50ms for typical snapshots (~200 elements). No network call. No power-budget compromise for the daemon to run continuously.

Built-in heads ship pre-trained, covering the common rule tags. Users can enable / disable each head via the policy file. Disable is zero-cost — the head's output is simply not consulted at runtime.

## Custom Heads (Power-User Workflow)

Behavior beyond the built-in heads is a documented developer-oriented workflow, not in-app UX. Axon ships only the backbone and the built-in heads; the teacher model is **not bundled** with the app.

Sketch of the flow, fully documented in `docs/custom-heads.md` (not yet written):

1. User installs ollama and pulls a teacher model (e.g. `ollama pull gpt-oss-safeguard:20b`). The teacher is the user's responsibility, not axon's distribution.
2. User writes a custom policy clause in plain English describing the new category.
3. User runs `axon train-head --policy <file> --name <head-name> --sample-size <n>` which:
   - Samples N elements from the user's local history (anonymized, never transmitted).
   - Labels each element by calling the local ollama teacher with the user's policy.
   - Trains a new head against the labels — only the head, backbone is frozen.
   - Writes the resulting head weights to `~/.axon/heads/<head-name>.head`.
4. User adds the new head to their active policy. Axon loads it on next snapshot.

This pattern is teacher-student distillation: an expensive policy-reasoning model used once at training time to produce labels, a cheap encoder + head used at runtime. The teacher is the dev-time dependency, the encoder is the user-time runtime. Power users opt into the teacher install; everyone else uses built-in heads.

## What The Agent Sees

A classified snapshot is the same shape as today's, with redacted elements showing:

```json
{
  "id": "s12:19",
  "role": "AXTextField",
  "label": "Account Balance",
  "value": "<redacted: financial-data>",
  "redaction": {
    "policy": "user/sensitivity-policy.md@a3f1b2",
    "rule": "financial-data",
    "classifier": "encoder-v1+heads@a3f1b2/heuristic-floor"
  }
}
```

The agent can plan around redacted fields without seeing them. It can still target them with locators, perform actions against them (clicks, focus changes), and verify post-conditions on their *existence* without reading their content.

For cases where the agent legitimately needs the value, a per-call override flag (`allowSensitive: true` on the read) suppresses redaction but is audit-logged in history with the agent's stated reason. The override is a deliberate, loggable break of the policy, not a default-on capability.

## Policy Evolution

Sensitivity policy is a living document. The user will edit it as they learn what they want redacted. Implications:

- **Snapshots store raw values.** The history store keeps unredacted content; redaction is a *view* applied at read or export time. Storage cost is the trade for being able to apply new policies retroactively.
- **Policy changes retroactively reclassify history.** When `~/.axon/sensitivity-policy.md` changes, axon reclassifies all stored snapshots against the new policy. This is a user-visible operation with a progress UI when history is large. After reclassification, any future read or export reflects the current policy.
- **Already-returned data cannot be unreturned.** Retroactive policy applies to future reads and exports. Snapshots an agent has already received under prior policy live in that agent's conversation; we can't reach into it.
- **`.axn` export uses current policy.** Exporting history to `.axn` runs through the current classifier at export time. Shared `.axn` files reflect the user's current preferences, not historical ones.
- **Policy is content-addressed.** Every classification verdict carries the policy hash that produced it, so re-classification is detectable as a no-op (same hash) and audit trails can prove "this verdict came from policy version X."

## Performance Discipline

Snapshots happen on every observation. The classifier sits in a hot path. With the encoder architecture, classification can be synchronous:

- The heuristic floor runs first and synchronously; single-digit milliseconds even on large snapshots.
- The encoder + heads run as one batched CoreML forward pass per snapshot. Target: <50ms p95 for snapshots up to ~500 elements on M-series Macs, sub-watt power draw.
- Cache hit rate is still useful but no longer load-bearing — the encoder is fast enough that re-classification of unchanged content is cheap. Cache is an optimization, not a survival mechanism.
- Snapshots return fully-classified by default. Async-with-pending was a workaround for LLM latency; the encoder doesn't need it.

## Profiling Results

First-pass profiles via ollama on Apple M4 Max / 128 GB / macOS 14, 2026-05-13. Twenty AX elements (8 clearly sensitive, 6 clearly benign, 6 ambiguous), single-element calls, temperature 0, ~895-char policy in system prompt. These runs are what convinced us the runtime should not be an LLM at all.

### `gpt-oss-safeguard:20b` — strong quality, wrong shape

- **Accuracy on clear-signal set: 14/14.** Every clearly-sensitive case redacted with a correct rule tag, every clearly-benign case left clear.
- **Cold start: 3.1s** (1.2s model load + 1.2s first eval).
- **Warm p50: 1.55s. Warm p95: 2.29s** (excluding tail outlier). Throughput steady at ~90 tok/s, output median 114 tokens.
- **Tail outlier: 10.2s / 848 tokens** on a masked account number (`•••• 4421`). The model went into deep reasoning about whether partial PII is still PII.
- **Memory: 17 GB resident.** Fine on 32 GB+ Macs, untenable on 16 GB.
- **Power: ~100W sustained** on M4 Max during runs. The killer concern — this can't be a service that fires on every snapshot.
- **Policy interpretation quality is the standout positive.** The password help-text case (which many naive classifiers would flag) was correctly left clear because the policy's "mentions sensitive concept without exposing sensitive value" exemption was applied.

### `gemma4:e2b` — confirms smaller LLM doesn't fix the shape

Same harness, same inputs, same policy. Tested on the hypothesis that a smaller LLM would land in a comfortable power/latency envelope.

- **Accuracy on clear-signal set: 14/14.** Same as the 20b, with matching ambiguous verdicts (amb-03 redacted as PII, amb-06 redacted as financial).
- **Warm p50: 3.54s.** *Worse* than the 20b. Output median 431 tokens (vs 114 for the 20b); gemma emits reasoning traces that ollama hides from `.message.content` but still pays for in eval time. Higher tok/s (134 vs 90) does not overcome the ~4x output length.

**The structural takeaway**: an LLM at runtime is fundamentally serial-per-element. Even with a hypothetical chat-trained smaller model with capped output, a snapshot with 200 elements still pays 200 sequential inferences. The encoder architecture is a different shape of computation — one batched forward pass for the whole snapshot — and that is what makes the power/latency envelope sustainable for a service that fires continuously.

The 20b retains exactly one role: an offline teacher for the optional custom-head training workflow, installed by the user via their own ollama setup, never shipped with axon.

Caveats: single-element-per-call (an LLM with batched-elements-per-call would amortize but still pays per-element output tokens), small test set (20 inputs, not statistically conclusive), high-end hardware (M3 / M2 / M1 would be slower).

## Symmetry With Late-Bound Values

This issue and the [late-bound values](2026-05-13-late-bound-values-and-credentials.md) issue are deliberately the same shape, mirrored across the read/write boundary:

- **Reading** state → pluggable classifiers filter what reaches the agent, policy-driven by user-authored text.
- **Writing** values → pluggable resolvers fill in what came from the agent, policy-driven by user-authored references.

Both are small, locally-executed, user-owned policy layers between axon-core and the outside world. The implementations should share infrastructure where natural: protocol registration, redaction conventions in trace output, audit-log format. Axon's contribution to the AX utility-layer story is increasingly *making the boundaries policy-shaped*, not just providing primitives.

## Open Questions

- **Per-call override discipline.** Should `allowSensitive: true` require an agent-stated reason string for the audit log, or is the fact of override sufficient?
- **Policy summary visibility.** Should agents be told the *shape* of the active policy ("financial + auth + PII redaction active") so they can self-limit asks, or is that itself a leak surface?
- **Conflict between policy and explicit user request.** "Read me back my account balance" via the agent — does the policy still redact? Probably yes, and the user-side override is to edit the policy or use the per-call override flag; we should not infer "the user wants this" from agent-side context.
- **Built-in head set for v1.** Which rule tags ship pre-trained out of the box? Probable starting set: `financial-data`, `auth-credential`, `pii-identifier`, `private-message`. Open to add/drop based on what early users actually want.
- **Custom head storage and portability.** Where do `.head` files live (`~/.axon/heads/`?), how does sync work across user machines, what happens if a head was trained against an older backbone version? Probably content-address heads against backbone version and refuse-to-load on mismatch.
- **Head composition.** Built-in rules are mostly independent ("is this financial" / "is this auth"), but real user policies may want logical combinations ("redact financial unless it's my own account"). Composition probably belongs as a policy-file layer above the heads, not as head architecture.

## Non-Goals

- **No LLM at runtime.** The shipped classifier is the encoder + heads. LLMs (teacher or otherwise) only appear in the documented dev-time training workflow.
- **No bundled teacher model.** The 20b safeguard model is large, hardware-restrictive, and only needed for custom-head training. Power users install it themselves via ollama; the default `Axon.app` install ships only the encoder backbone and built-in heads.
- **No cloud classifier.** This was considered when the runtime was going to be an LLM. With the encoder running free-power on the Neural Engine, there is no scenario where cloud inference is better. Cleaner to drop the option entirely.
- **No bespoke encoder trained inside axon.** The backbone is pretrained (DistilBERT / MiniLM / sentence-transformer class) and shipped as fixed. Axon trains heads, not backbones.
- **No attempt to redact pixels in screenshots from this layer.** Screenshot redaction is a separate problem with different mechanics (OCR + spatial masking) and shouldn't be conflated.
- **No model-side suppression of the heuristic floor.** The floor is non-negotiable; head outputs can only flag *more* things, never unflag what the floor matched.

## Next Steps

- Define the `SensitivityClassifier` protocol and the heuristic-floor implementation. Heuristic floor ships first regardless of model layer.
- Pick the encoder backbone. Candidates: DistilBERT (66M), MiniLM-L6 (22M), sentence-transformers/all-MiniLM-L6-v2 (22M), Apple's own foundation models if appropriate. Profile each on the same 20-element set after CoreML export to verify the <50ms per-snapshot target on Apple Neural Engine.
- Build the central head-training pipeline (axon-internal): synthesize a labeled corpus per rule tag using the 20b safeguard as teacher, train heads, export, ship in the app bundle.
- Build the local `axon train-head` CLI for the custom-head workflow. Confirms ollama presence, runs the teacher labeling pass against the user's own history sample, trains and writes a `.head` file. Document thoroughly in `docs/custom-heads.md`.
- Decide the snapshot record schema for classification metadata (active-heads version hash, rule tag, timestamp).
- Wire policy-change detection (file watch on `~/.axon/sensitivity-policy.md`) and the reclassification pass over history. With encoder speed, reclassification of large history becomes tractable in seconds rather than minutes.
- Surface a menubar indicator when classification is operating in degraded mode (encoder unavailable, custom head failed to load, etc.).
