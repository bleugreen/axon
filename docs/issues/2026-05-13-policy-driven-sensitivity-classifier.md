# Policy-Driven Sensitivity Classifier

## Context

The current `sensitive: true` flag is set by the agent at request time. It assumes the agent already knows which fields contain sensitive content, which is exactly the case where it usually doesn't. By the time the agent has the snapshot back, the data has already crossed the boundary.

We want sensitivity to be a property the *system* assigns based on what's actually in the snapshot, not a property the *caller* has to predict. The snapshot pipeline should be able to look at element content in context and apply user-authored redaction rules before anything reaches an agent or gets persisted.

This is the read-side mirror of [Late-Bound Values And Credentials](2026-05-13-late-bound-values-and-credentials.md): a pluggable, policy-driven layer between axon-core and the rest of the world, owned by the user.

## Desired Shape

The pipeline is layered, cheapest first. A **deterministic layer** (regex library, role rules, op-backed bloom filter) carries the bulk of redactions — anything with a known shape or a known value goes through fast, free, exact rules. A **classifier layer** sits on top for the cases regex structurally can't reach: textural categories with no shape, context-dependent sensitivity, and the custom-head workflow that lets users describe a policy and get a redactor for it. Don't pay for a model where a filter works.

Implementation-wise: a `SensitivityClassifier` protocol in the snapshot pipeline. The deterministic layer always runs first; the encoder-based classifier (when active) only sees elements the deterministic layer didn't already redact, and can only *add* redactions, never subtract.

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

## Deterministic Layer (Primary Defense)

The first and most load-bearing layer. Cheap, exact, no model. This is where most redactions happen — the classifier layer above it exists for cases this layer structurally can't handle, not as a "real" classifier that the deterministic layer "floors."

**Role-based rules:**
- `AXSecureTextField` values are always redacted regardless of content.
- Element labels containing `password`, `secret`, `token`, `private key`, `recovery code`, or similar high-signal substrings always redact the corresponding value.

**Pattern matching:**
- Structured PII: SSN format (`\d{3}-\d{2}-\d{4}`), credit cards (Luhn-checked), phone numbers, passport numbers.
- Token shapes for known issuers: `sk-...`, `sk_live_...`, `ghp_...`, `xoxb-...`, `AKIA...`, JWT-shaped values. A small library that grows as new formats appear — ongoing maintenance, not architecture.
- Financial-context heuristics: `$N.NN` or other currency literals near a "balance" / "total" / "amount" label trigger `financial-data`.

**Active-credential HMAC index:**
- Any element value that hits the active-credential index is verbatim-known to be one of the user's current op secrets and redacts as `auth-credential`. See [Late-Bound Values And Credentials](2026-05-13-late-bound-values-and-credentials.md#active-credential-index) for the design — this shipped as the first deliverable of the op integration work.
- The index doubles as a **training signal** when heads do come into play: anything it flags is a high-confidence positive label for `auth-credential` training data, no teacher pass needed.

**Coverage by rule tag (rough architectural estimate, not measured):**
- `auth-credential` — HMAC index + secure-field role + token-shape regex covers ~95% of practical cases. Residual: free-form plaintext passwords shown in UI without secure-field semantics; novel token formats not yet in the regex library.
- `financial-data` — currency + label-context heuristic + Luhn check covers ~85%. Residual: free-form descriptions of finances ("I have $3000 saved up") without label scaffolding.
- `pii-identifier` — structured PII regex covers the structured shapes well. Names and addresses are genuinely contextual and fall to the classifier layer when active.
- `private-message` — no deterministic answer. Pure texture. The classifier owns this entirely.

Redactions from this layer can only be *added* by anything above it; nothing can subtract them. A model verdict of "this isn't sensitive" cannot override a regex match.

## Where The Classifier Earns Its Keep

The classifier is not "the real redactor with regex as a fallback." It is the flexibility layer for what regex structurally cannot do. Four cases earn it its place:

1. **Textural categories with no shape.** Private message bodies, medical notes, internal communications. No regex captures "this reads like a private message"; only an encoder embedding can. The classifier does irreplaceable work here.
2. **Context-dependent sensitivity.** The same literal value being sensitive in one ancestor chain and benign in another. "John Smith" next to "Patient ID:" is PII; "John Smith" in a movie credits roll is not. A regex would need a regex-pair per context; an encoder with ancestor context handles this naturally.
3. **The custom-head workflow.** Users describe a policy in markdown that no shippable regex library could anticipate ("redact anything related to project Foobar", "redact non-public commit hashes from this private repo"). The head learns the user's specific concept. This is the headline value of having head infrastructure at all.
4. **Novel-format adaptation.** A locally-trained head picks up new credential-shaped formats from real usage without a code release. Lower priority than the others — adding a regex is cheap — but real value over a long horizon.

The first two are why we ship any built-in head at all. The third is why the training infrastructure exists. The fourth is a side benefit.

## Encoder Classifier With Heads

The flexibility layer's mechanism. A distilled encoder plus per-rule classification heads, exported to CoreML and run on the Apple Neural Engine. Runs after the deterministic layer; sees only elements the deterministic layer didn't already resolve.

Architecture:

- **Shared backbone.** A pretrained transformer encoder (DistilBERT / MiniLM / sentence-transformer class, ~30M params, ~30 MB on disk) takes a serialized AX element (role, label, value, ancestor) and produces a contextual embedding. The backbone is the same for every user, shipped once.
- **Per-rule heads.** Each rule tag (`financial-data`, `auth-credential`, `pii-identifier`, `private-message`, etc.) is a tiny linear classifier (~50K params) sitting on the backbone output. One forward pass through the backbone feeds all active heads simultaneously.
- **Batch per snapshot.** A snapshot with N elements is one batched forward pass, not N serial inferences. This is the structural reason the encoder path is viable where LLMs are not: latency is O(snapshot), not O(elements-in-snapshot).
- **Local, free, fast.** Neural Engine inference on M-series hardware is sub-watt and sub-50ms for typical snapshots (~200 elements). No network call. No power-budget compromise for the daemon to run continuously.

The built-in head set stays minimal: a head ships only for categories the deterministic layer structurally cannot reach. Today that anchors at `private-message`; `pii-identifier` may justify a head specifically for contextual cases (names / addresses); `auth-credential` and the bulk of `financial-data` do not get built-in heads because the deterministic layer covers them. Users can enable / disable each head via the policy file. Disable is zero-cost — the head's output is simply not consulted at runtime.

## Custom Heads (Power-User Workflow)

The headline reason any head infrastructure ships at all. Built-in heads cover the textural categories axon knows about up front; everything beyond that is the user's own policy, expressed via a documented developer-oriented workflow. Axon ships only the backbone and the minimal built-in head set; the teacher model is **not bundled** with the app.

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
    "classifier": "deterministic-layer@v3"
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

- The deterministic layer runs first and synchronously; single-digit milliseconds even on large snapshots, and the bulk of redactions land here.
- The encoder + heads run as one batched CoreML forward pass per snapshot for whatever the deterministic layer didn't already resolve. Target: <50ms p95 for snapshots up to ~500 elements on M-series Macs, sub-watt power draw.
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
- **Built-in head set for v1.** Which textural rule tags warrant a shipped head given the deterministic-first reframe? Lean position: `private-message` is the clear one; `pii-identifier` may be worth a head specifically for contextual name/address cases; `auth-credential` and most of `financial-data` are deterministic-only since the residual is small. Audit the actual miss patterns once the deterministic layer is in place before committing.
- **Promotion path between layers.** When a category currently handled deterministically accumulates enough residual misses to justify a head — or when a head's behavior crystallizes into a clean regex — what triggers the move? Probably a manual call based on observed miss patterns, not an automated threshold.
- **Custom head storage and portability.** Where do `.head` files live (`~/.axon/heads/`?), how does sync work across user machines, what happens if a head was trained against an older backbone version? Probably content-address heads against backbone version and refuse-to-load on mismatch.
- **Head composition.** Built-in rules are mostly independent ("is this financial" / "is this auth"), but real user policies may want logical combinations ("redact financial unless it's my own account"). Composition probably belongs as a policy-file layer above the heads, not as head architecture.

## Non-Goals

- **No LLM at runtime.** The shipped classifier is the encoder + heads. LLMs (teacher or otherwise) only appear in the documented dev-time training workflow.
- **No bundled teacher model.** The 20b safeguard model is large, hardware-restrictive, and only needed for custom-head training. Power users install it themselves via ollama; the default `Axon.app` install ships only the encoder backbone and built-in heads.
- **No cloud classifier.** This was considered when the runtime was going to be an LLM. With the encoder running free-power on the Neural Engine, there is no scenario where cloud inference is better. Cleaner to drop the option entirely.
- **No bespoke encoder trained inside axon.** The backbone is pretrained (DistilBERT / MiniLM / sentence-transformer class) and shipped as fixed. Axon trains heads, not backbones.
- **No attempt to redact pixels in screenshots from this layer.** Screenshot redaction is a separate problem with different mechanics (OCR + spatial masking) and shouldn't be conflated.
- **No head for a category the deterministic layer covers well.** If a regex/role-rule/bloom-filter handles a class with high recall, don't ship a head for it. Heads exist for what the deterministic layer structurally can't reach (textural, contextual, user-custom). Duplicating effort is its own anti-pattern.
- **No model-side suppression of the deterministic layer.** The deterministic layer is non-negotiable; head outputs can only flag *more* things, never unflag what a deterministic rule matched.

## Next Steps

- Define the `SensitivityClassifier` protocol and ship the deterministic layer as the primary defense: regex library for known credential / PII / financial shapes, role-rule library, op-backed bloom filter wiring. This is most of the v1 sensitivity story and stands on its own without any model.
- Pick the encoder backbone for the flexibility layer. Candidates: DistilBERT (66M), MiniLM-L6 (22M), sentence-transformers/all-MiniLM-L6-v2 (22M), Apple's own foundation models if appropriate. Profile each on the same 20-element set after CoreML export to verify the <50ms per-snapshot target on Apple Neural Engine.
- Build the central head-training pipeline (axon-internal) for the minimal set of *textural* built-in heads (currently scoped to `private-message`, possibly contextual `pii-identifier`). Use the deterministic layer as a labeling oracle wherever it applies and the 20b teacher to fill gaps the deterministic layer can't label.
- Build the local `axon train-head` CLI for the custom-head workflow. Confirms ollama presence, runs the teacher labeling pass against the user's own history sample, trains and writes a `.head` file. Document thoroughly in `docs/custom-heads.md`.
- Decide the snapshot record schema for classification metadata (active-heads version hash, rule tag, timestamp).
- Wire policy-change detection (file watch on `~/.axon/sensitivity-policy.md`) and the reclassification pass over history. With encoder speed, reclassification of large history becomes tractable in seconds rather than minutes.
- Surface a menubar indicator when classification is operating in degraded mode (encoder unavailable, custom head failed to load, etc.).
