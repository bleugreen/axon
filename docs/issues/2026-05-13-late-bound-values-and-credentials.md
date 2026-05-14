# Active-Secret Redaction And Late-Bound Credentials

## Context

This issue started from two adjacent write-side problems:

1. **Parameterization.** Reusable `.axn` files need holes that are filled at replay time instead of hard-coded literal values.
2. **Secrets.** Passwords, tokens, MFA seeds, signing keys, and similar values cannot safely be recorded as literals.

Those problems still matter, but they depend on a better parameter model for `.axn` files: typed args, runtime prompts, secure parameter entry, defaults, validation, and trace redaction. Adding `secret` as a parameter type before the parameter surface exists would force the credential work into the wrong shape.

The first shippable milestone is the read-side security boundary:

> If Axon has a fingerprint for an active credential value, that raw value must not appear in any external textual Axon output.

This reframes 1Password integration as an always-on output guard first. Late-bound credential writes remain the natural follow-up once `.axn` parameterization is better defined.

## Current Problem

The current `sensitive: true` flag is not a security boundary. It is caller-selected, and MCP `look` currently defaults it to `false`. That means the caller has to know in advance that a snapshot may contain sensitive values, which is exactly the case where the caller usually does not know.

The right model is:

- Active-credential redaction is always on for external textual output when a provider-backed index is available.
- The caller does not opt into this redaction and cannot turn it off through normal read APIs.
- The existing `sensitive` mode can remain as a broader aggressive-redaction/debug-suppression mode, but it is no longer the boundary that protects active credentials.

## First Milestone: Always-On Look Redactor

Add an `ActiveSecretRedactor` to the external perception boundary. With the consolidated tool surface, that boundary is mostly `look`: app snapshots, child pages, change summaries, screenshots, OCR text, and CLI formatting all flow through the same verb.

Axon may keep raw AX values inside the local process long enough to resolve locators, compare state, and execute supervised actions, but every external textual representation must pass through the redactor before leaving Axon.

Covered outputs:

- MCP `look()` app lists if app/window text ever includes string-bearing state.
- MCP `look(target: app)`, including observation and debug structured content.
- MCP `look(target: handle)` child pages.
- MCP `look(since: snapshot)` change summaries.
- MCP `find(app, locator)` candidate summaries when they include AX-derived strings.
- CLI `axon look`, including formatted and `--json` output.
- Any future batch trace, history export, or observation artifact that includes snapshot values.

The redactor checks string-bearing AX fields such as `title`, `value`, `description`, `help`, and `identifier`. A match returns a non-prefix-preserving replacement:

```json
{
  "value": "<redacted: active-credential>",
  "redaction": {
    "fields": ["value"],
    "reasons": {
      "value": "active-credential"
    },
    "providers": {
      "value": "1password"
    },
    "references": {
      "value": ["op://Personal/Gmail/password"]
    }
  }
}
```

The value itself is never preserved in the output, not even as a short prefix. Prefix-preserving redaction is useful for generic token-shaped heuristics; active credentials are authentication-equivalent and should leak zero literal characters.

## Active Credential Index

Use a provider-backed exact index. It answers "does this observed value match a known active credential?" and, on hit, returns the provider reference needed to make the redaction comprehensible without exposing the secret.

The index is built from keyed fingerprints:

```text
fingerprint = HMAC-SHA256(indexKey, credentialValue)
```

The `indexKey` lives in macOS Keychain. The on-disk cache stores keyed fingerprints mapped to provider references such as `op://vault/item/field`, plus metadata. It never stores credential plaintext and never stores the HMAC key.

This avoids storing credentials locally while still making the normal `look` path cheap:

1. Axon reads an AX value.
2. Axon computes `HMAC(indexKey, observedValue)`.
3. Axon checks the exact index.
4. On hit, Axon redacts the output field and includes the matching provider reference in redaction metadata.

There are no probabilistic false positives in the normal path. False negatives come from missing/stale index data or values that were intentionally excluded by policy.

## 1Password Refresh

1Password is the first provider. Refresh is explicit and local:

```sh
axon refresh-secrets
```

During refresh, Axon shells out to `op`, lets 1Password own authentication and consent, lists items, reads concealed fields per item, fingerprints active high-stakes secret fields, stores keyed fingerprints with their `op://` references, and immediately discards plaintext.

Fields to include:

- Password fields.
- Concealed fields.
- Recovery codes and recovery keys.
- OTP seeds, not rotating OTP codes.
- API keys, tokens, SSH keys, and signing keys when represented as concealed/secret fields.

Fields to skip:

- Usernames.
- Email addresses.
- URLs.
- Notes and other long free-text fields unless 1Password exposes a typed concealed value.

Short or low-entropy values should be skipped to avoid nuisance redaction. A starting threshold is length >= 8 and estimated entropy >= 3.5 bits per character. Four-digit PINs and similarly short values need separate policy/classifier treatment later.

## Freshness Checks

Normal `look` calls must not invoke `op` and must not trigger surprise authentication prompts.

Instead, Axon stores the index creation time and can run a user-initiated or pre-run metadata check:

```sh
op item list --long --format=json
```

If any item metadata reports `updated_at` later than the index creation time, Axon marks the index as stale and asks whether to refresh. If the user declines, Axon continues using the existing stale index.

Filter states:

| State | Behavior |
| --- | --- |
| `fresh` | Redaction runs with the current index. |
| `stale` | Redaction still runs with the old index; Axon warns or prompts at pre-run/status checkpoints. |
| `missing` with 1Password configured | Axon warns and offers refresh; if declined, it continues with provider redaction unavailable. |
| `unconfigured` / no 1Password | Axon runs normally with built-in heuristic redaction only. |
| `corrupt` | Axon ignores the broken index, warns, and offers rebuild. |

No background timer should call `op`. Metadata checks belong at explicit checkpoints: CLI status, daemon startup, pre-run, menu bar "check protection", or user-requested refresh.

The guarantee is intentionally precise:

> If Axon has an active credential index entry for a value, that value cannot appear in external textual output.

It is not:

> Axon guarantees every active credential in every provider is covered even when the user has never configured or refreshed a provider.

## Screenshot Modality

The consolidated `look` surface makes screenshot policy simpler because screenshots are a modality of perception, not a separate tool path.

For the first milestone:

- `look(..., screenText: true)` must run OCR text through the same active-secret redactor before returning it.
- `look(..., screenshot: true)` must not return pixels known to contain an active credential.
- Until spatial pixel masking exists, if the AX/OCR text path detects an active credential and `screenshot: true` is requested for the same response, Axon should refuse the screenshot modality or return the tree without the image plus an explicit warning.

This does not prove that every secret visible in pixels was detected. OCR can miss text, and some apps expose pixels without corresponding AX text. Full pixel safety is tracked separately in [Screenshot Pixel Secret Redaction](2026-05-14-screenshot-pixel-secret-redaction.md).

## Inline References

Normal redacted output includes provider references such as `op://Personal/Gmail/password` directly in redaction metadata. The reference is not secret material, and including it makes the output comprehensible without a second authenticated lookup path.

This removes the need for a transient registry or a separate lookup operation. The index lookup already has the matching reference at the moment it decides to redact.

## Position Relative To Sensitivity Classifier

The active-secret index is the deterministic floor for authentication-equivalent values. It should eventually become one heuristic-floor rule inside the broader sensitivity classifier:

- Active-secret index: exact, provider-backed, synchronous, no model.
- Regex heuristics: catch common token/API-key shapes.
- AX secure-field rules: redact values from secure controls.
- Classifier heads: catch sensitive values not known to a provider, including developer secrets in editors, partial credentials, personal identifiers, financial data, and private messages.

The active-secret index ships independently because it is useful before the classifier exists.

## Later: Late-Bound Write Values

Once `.axn` parameterization is better defined, the write side can reuse the same security language.

Possible future shape:

```yaml
version: 1
params:
  recipient:
    type: string
    description: Email recipient
  gmail_password:
    type: secret
    provider: op
    reference: op://Personal/Gmail/password

actions:
  - tool: type
    target: { app: Gmail, locator: { role: AXSecureTextField } }
    value: "{{param://gmail_password}}"
    resolveAs: secret
```

Future value resolvers:

- `param://name` for typed `.axn` parameters.
- `env://NAME` for process environment values.
- `prompt://"label"` for interactive replay prompts.
- `op://vault/item/field` for direct 1Password references, if direct references remain desirable after typed secret params exist.

Resolved secrets must never enter history records, batch traces, stdout, logs, or exported `.axn` files as literals. That work should start only after the parameter model and trace-redaction rules are explicit.

## Open Questions

- **Strict mode.** Should Axon later offer `strictCredentialRedaction: true`, where missing or stale provider indexes block model-facing observation until refreshed?
- **Index scope.** Should refresh include all readable vaults by default, or only user-selected vaults?
- **Provider config.** How should Axon remember that a user wants 1Password protection enabled without making 1Password a dependency for everyone?
- **Strict screenshot policy.** The first implementation omits screenshots when AX/OCR text detects an active credential. Should `look(..., screenshot: true)` refuse whenever active-secret protection is configured until pixel masking exists, even if text detection finds nothing?
- **Sensitive flag.** Should `sensitive` be renamed/deprecated now that it is not the security boundary?

## Non-Goals For The First Milestone

- No late-bound `.axn` secret parameters yet.
- No local credential plaintext storage.
- No background `op` polling or timer-triggered auth prompts.
- No claim that screenshot pixels are active-secret safe before spatial masking exists.
- No bespoke credential store inside Axon.
- No automatic provider lockout for users who do not use 1Password.

## Next Steps

1. Done: Define the `ActiveSecretRedactor` / `ActiveCredentialFilter` interface in axon-core.
2. Done: Add the redactor to the external textual `look`/`find` serialization paths.
3. Done: Add a Keychain-backed HMAC key and exact index cache with metadata (`createdAt`, provider, version).
4. Done: Implement `axon refresh-secrets` for 1Password using `op`.
5. Pending: Add metadata freshness checks at status/pre-run checkpoints; stale indexes warn but still run.
6. Done: Add tests that prove a known active-secret fixture cannot appear in MCP `look` observation, MCP `look` debug JSON, child pages, `find` candidates, text-location candidates, or change summaries.
7. Done: Add the first screenshot guard: if AX/OCR text redaction detects an active credential and screenshot modality is requested for the same `look`, omit the image with an explicit warning.
8. Pending: Resolve [Screenshot Pixel Secret Redaction](2026-05-14-screenshot-pixel-secret-redaction.md) before claiming image-returning `look` calls are active-secret safe.
9. Pending: Defer write-side late-bound secret parameters until `.axn` parameterization is specified.
