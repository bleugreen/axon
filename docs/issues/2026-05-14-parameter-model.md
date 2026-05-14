# Parameter Model For .axn Files

## Context

`.axn` files are recordings of tool-call sequences. To be reusable beyond their exact original context they need *holes* — named slots filled at replay time instead of hard-coded literals. The same mechanism handles two adjacent problems:

1. **Reusability.** "Open the report folder, drag yesterday's CSV into the upload field, click Submit" is reusable; the literal filename is not.
2. **Write-side secrets.** Passwords, tokens, MFA seeds, and signing keys can't be recorded as literals — they need a reference that resolves to the real value at replay.

The [Active-Secret Redaction](2026-05-13-late-bound-values-and-credentials.md) reframe correctly split the read-side guard (shipped as `ActiveSecretRedactor`) from the write-side parameterization, on the grounds that *adding `secret` as a parameter type before a parameter surface exists would force the credential work into the wrong shape.* This issue defines that parameter surface, so secret-typed parameters slot into a model that already exists rather than the model being shaped by credentials.

## Desired Shape

Three concepts, kept separate:

1. **Declaration** — what holes exist in this file, with what type, optional default, optional source. Lives in an `args:` header at the top of the `.axn`. The file's *interface*.
2. **Reference** — where holes appear in action bodies. `{{name}}` substitution inside string-shaped `value` fields.
3. **Resolution** — how each parameter's value is filled at replay time. Either the declared `source:` or a caller-supplied arg or a default; if nothing resolves and the parameter is required, the file errors at load time.

**The load-bearing insight**: `secret` is a *type*, not a *source*. The type governs handling (no logging, no traces, redacted in errors, never persisted as plaintext). The source can be `op://`, `env://`, or a caller-supplied arg — the same secret-handling rules apply regardless. This separates "what kind of value is this" from "where does it come from."

## Declaration

The `args:` header sits at the top of an `.axn` file, parallel to `actions:`:

```yaml
version: 1
args:
  - name: recipient
    type: email
    description: "Recipient address"
  - name: report_date
    type: date
    description: "Date of the report (YYYY-MM-DD or 'today')"
    default: today
  - name: password
    type: secret
    description: "Account password"
    source: op://Personal/Gmail/password

actions:
  - tool: type
    target: { app: Gmail, locator: { role: AXTextField, label: "To" } }
    value: "{{recipient}}"
  - tool: type
    target: { app: Gmail, locator: { role: AXSecureTextField } }
    value: "{{password}}"
```

Per-parameter fields:

- `name` (required) — snake_case identifier, unique within the file.
- `type` (required) — one of the closed v1 type set (see below).
- `description` (recommended) — plain-text, surfaces in editor UI and CLI usage strings.
- `default` (optional) — literal value used when no source resolves and no caller-supplied arg is provided. Forbidden on `type: secret` — a defaulted secret would be a literal in the file, which defeats the point.
- `source` (optional) — a URL with a registered scheme (`op://`, `env://`, etc.). When present, this is the binding; the parameter resolves from this source at replay.

The args list is order-preserving (list, not map) so the recorder can append without inventing keys, CLI usage strings have a stable ordering, and the editor UI's step-view stays predictable. This supersedes the map-shaped sketch in the active-secret-redaction doc.

A parameter either has a `source:` (bound to a resolver, file makes the decision) or doesn't (open to caller). The two cases don't overlap; there is no "caller arg overrides declared source" precedence. If you want to override a bound parameter, edit the file.

## Reference

References use double-brace substitution inside string-shaped `value` fields:

```yaml
value: "Hello {{recipient}}, the report is at {{report_path}}/{{report_date}}.csv"
```

A single string can contain multiple references. References inside non-string YAML fields (locators, keys, etc.) are out of scope for v1 — the parameter model touches values, not structure.

YAML treats unquoted `{{...}}` as ambiguous in some contexts. References must always sit inside quoted strings; a linter rule flags bare references at load time.

Only declared parameters can be referenced. Inline schemes like `value: "{{env://HOME}}"` are not supported — declare an `env://HOME`-sourced parameter and reference it by name. This keeps the file's interface auditable: every external dependency appears in the `args:` header.

## Resolution

At load time, each parameter resolves in order:

1. **Caller-supplied arg.** A value passed to `run` (CLI `--arg name=value` or programmatic `run(path: ..., args: {...})`). Valid only for parameters without a declared `source:`.
2. **Declared `source:`.** Resolved via the source's scheme handler.
3. **`default:`.** The literal in the declaration.
4. **Error.** A required parameter (no caller arg, no source, no default) is a hard load-time error.

Resolution happens once, before any action fires. A `.axn` either has every value it needs and runs cleanly, or it fails before touching the system. No partial replay, no mid-sequence failures over missing args.

Source resolvers register by scheme:

- `op://vault/item/field` — 1Password CLI. Already integrated for the read-side index; same plumbing.
- `env://NAME` — process environment.
- New schemes register later (`keychain://`, `aws-secrets://`, etc.) without changing the parameter surface.

## Types

The v1 type set is closed and axon-defined:

- `string` — any text. Default when `type` is omitted.
- `secret` — string-shaped with secret-handling rules (next section).
- `number` — integer or float. Caller args are parsed from string; non-numeric input is a load-time error.
- `date` — ISO 8601 or the special tokens `today`, `yesterday`. Parsed at load.
- `email` — string with basic shape validation.
- `path` — filesystem path. Existence-check policy is an open question.

No user-registered types in v1. Validation stays small and auditable; extension can come later if real cases appear.

## Secret Handling

A parameter declared `type: secret` carries handling rules through the entire write-side pipeline:

- **Never logged.** Resolution, substitution, and action execution do not log the value at any layer.
- **Never persisted as plaintext.** History records and batch traces show `<redacted: contains-secret>` instead.
- **Redacted in errors.** A failure substituting a secret reports the parameter name and the failure mode, not the value.
- **Taint propagates.** A secret substituted into a longer string (`"Hello {{password}}, welcome"`) taints the entire resulting string. The trace shows `<redacted: contains-secret>` rather than attempting partial-substitution masking. Errs toward leak-prevention.
- **No `default:`.** A defaulted secret would be a literal in the file.

These rules apply regardless of the source — a secret from `op://` and a secret from a CLI arg get identical handling. The shipped [ActiveSecretRedactor](2026-05-13-late-bound-values-and-credentials.md#active-credential-index) is the read-side equivalent (values matching the active-credential index are redacted on output even when they leak into AX snapshots); this section is the write-side mirror. Together the two layers give a symmetric guarantee: secrets cannot enter Axon as observable text, and secrets cannot leave Axon as observable text — at either boundary.

## Validation

Validation happens at two points:

1. **Load time** — declaration parse, source-URL parse, required-parameter check, `default:` compatibility with `type:`.
2. **Resolution time** — caller-supplied values are coerced to declared types (`"5"` → `5` for `type: number`); type-incompatible values are a hard error before any action fires.

Principle: *fail before side effects*. If anything about the parameter binding is wrong, no AX call fires.

## Recorder And Editor UX

The recorder writes parameter declarations when it can't safely record a literal. With the parameter model in place, the secure-field branch produces:

1. **Bind to op now.** The recorder writes a `type: secret`, `source: op://...` parameter and a reference at the action site. Live op picker (already a UI primitive for `axon refresh-secrets`).
2. **Bind later.** Writes a `type: secret` parameter with no source. At replay the value must be caller-supplied or the file errors. The post-record editor surfaces these as "needs binding" and offers the op picker.
3. **Skip.** No parameter, no action.

Option 2 replaces the old `prompt://` resolver — the value still gets supplied at replay, but it comes from the caller, not an interactive human prompt.

The document-based editor (`.axn` files register as the file type; double-click opens) shows:

- Steps in order
- Each step's parameter references
- A toggle per reference: literal / open-to-caller arg / declared-source-binding
- Op picker for `op://` bindings, environment picker for `env://`, etc.

Editor UI lives in its own issue when it's time to build; this issue defines the model the editor manipulates.

## Open Questions

- **Param naming convention.** snake_case, kebab-case, or camelCase? Lean: snake_case for YAML idiom consistency and to avoid quoting in `{{name}}` references.
- **`type: path` existence checks.** Validate at load or at action time? Existence is racy regardless; lean toward action-time with a clear error message.
- **`description` rendering.** Plain text v1. Markdown later if CLI usage strings or editor surfaces benefit.
- **Multi-source params.** Could a parameter declare a source list with fallback? Nice-to-have, defer.
- **Override-at-runtime escape hatch.** If a file declares `source: op://...` but a caller wants to override (for testing), is there an explicit unlock flag, or do you always edit the file? Lean: always edit. Runtime-override is a hole in the file's interface.

## Non-Goals

- **No interactive prompting at any layer.** No `prompt://` resolver, no `prompt:` field on declarations. An automation that pauses for keyboard input is a tutorial, not an automation. If a human is required, the caller supplies the value before invoking `run`.
- **No nested file composition.** A `.axn` cannot include another `.axn` in v1. Parameters don't flow across files yet.
- **No computed parameters.** No `{{full_name}} = {{first}} {{last}}` expression layer. Parameters stay flat.
- **No reference in non-string fields.** `{{name}}` only appears inside string-shaped value fields. Dynamic targeting (locator-as-template) is a separate problem.
- **No user-registered types.** Closed v1 type set; extension is a later choice when real cases exist.
- **No partial replay on failure.** Validation runs before any action fires; the file either has every value it needs or it errors at load.

## Next Steps

- Define the YAML schema for `args:` and the formal type list. Update the `.axn` JSON schema (`docs/`) accordingly.
- Implement the parameter loader and source-resolver registry in axon-core. `op://` resolver is the first concrete instance — reuse op CLI plumbing already present from the read-side work. `env://` is the second.
- Implement caller-arg surfaces: CLI `--arg name=value` and programmatic `run(args:)`.
- Wire secret-handling rules into the action executor, history store, and batch trace serializer. Audit every layer for "does this honor `type: secret`."
- Update the recorder's secure-field branch to write parameter declarations + references rather than bare `op://` references in action values.
- Open a separate issue for the document-based `.axn` editor app once this lands and there's something concrete to wire UI against.
- Update the example `.axn` files and `docs/tool-surface.md` to reflect the new `args:` header.
