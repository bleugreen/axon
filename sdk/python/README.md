# axon-cmd

A dependency-free Python client for the Axon daemon. It speaks the daemon's JSON-RPC socket
directly, and its per-tool parameter types are generated from `schema/tool-surface-v1.json` by the
same generator that produces the TypeScript client, so both SDKs describe the same tool surface the
daemon implements or CI fails.

The distribution is `axon-cmd` and the import is `axon_cmd`. The TypeScript client is published
under the same name on npm.

## Install

```sh
uv add axon-cmd
```

```sh
pip install axon-cmd
```

For a script that should carry its own dependency rather than live in a project:

```sh
uv run --with axon-cmd script.py
```

**This package is not the daemon.** It is a client for one, so Axon has to be installed separately
and running before any call succeeds — see [Install Axon](../../docs/install.md). `Axon.connect()`
is where that is checked, and it fails there with a reason rather than at the first action.

Versions track the daemon: `axon-cmd 0.3.6` is generated from the 0.3.6 tool surface and warns when
it connects to a daemon reporting something else. Pin the pair when reproducibility matters.

The package has zero runtime dependencies and needs Python 3.11 or newer, which is where
`typing.Required` and `typing.NotRequired` arrive. Bun is needed only to regenerate the client.

The import name matters. `axon` on PyPI is an unrelated project that also installs a top-level
`axon` package, so this distribution deliberately owns neither that distribution name nor that
import name, and ships no compatibility alias for either.

## Use

```python
from axon_cmd import Axon

axon = Axon.connect()                       # health handshake; raises if the daemon is not ready
session = axon.session("checkout")          # every call below is recorded under this session
app = session.app("Safari")

app.look()                                  # remembers the snapshot id and the process it named
app.click("checkout/submit")                # semantic names come from look
app.type("form/email", "ada@example.com")
app.wait_for_value("status", contains="Done")
print(app.changed_since())                  # no argument: the handle knows its own snapshot

session.save(path="checkout.axn")
```

Every call is one blocking round trip. An asyncio program wraps one in `asyncio.to_thread`; this
package does not ship a second async implementation, because two clients are two things to keep
true instead of one.

`Axon.connect` calls `health` first, so a script fails at connect with a clear reason rather than at
its first action. It warns when the daemon's version differs from the one this client was generated
for, and when the daemon is serving but has not been granted a permission, since that otherwise
surfaces much later as an unexplained refusal. Warnings go through `AxonWarning`, so a program can
silence or raise Axon's warnings alone; pass `warn=` to `Axon.connect` to receive them directly.

`axon.health` is the daemon's own report — flat `ready`, `platform`, `version`, `processId`,
`endpoint`, plus `session`, `permissions`, and `capabilities`. It is not the `health-v1` document
that `axon status --json` prints; that one nests a `daemon` object because it also has to describe
an install whose daemon never answered.

## What the client holds, and what it does not

An `App` handle holds exactly two pieces of state: the newest snapshot id that app produced, and the
process id that snapshot named. The snapshot id is what makes `app.changed_since()` need no
argument. The process id is what keeps a script bound to the app instance it observed, rather than
re-resolving a name that may now match a different window or a relaunched process.

Everything else belongs to the daemon:

- **Waiting is never client-side.** `wait_for_value` and `wait_for_stability` are single socket
  calls that the daemon polls behind. There is no retry loop in this package.
- **Results are the daemon's.** `look` returns the raw structured snapshot; this client does not
  render the observation DSL that MCP and the CLI produce. `changed_since` likewise returns the
  daemon's verdict unaltered, and that verdict currently compares app identity and top-level window
  signatures only — a change confined to an element's value reports `changed: false`. Use
  `wait_for_value` when you are waiting on a specific element's value, or
  `wait_for_stability(condition="changed")` for any observable change.
- **A refusal is not an error.** A JSON-RPC error raises `AxonRpcError`, because the request never
  reached its tool. An action that was refused returns normally with a `refusal` object on the
  result; deciding what to do about a policy refusal is the caller's job.
- **`.axn` files are written by `save`.** This package has no serializer.

`axon.supports("navigate")` answers from the generated availability map, without a round trip, so a
script can tell that a tool is absent on the connected platform before calling it. The daemon
remains the authority on whether an advertised tool is usable right now.

## Two layers, and which one is typed

`axon.raw` is the generated surface: one method per tool, each taking that tool's own `TypedDict`,
so a type checker rejects a call the daemon would reject.

```python
axon.raw.keyboard({"app": "Safari", "key": "cmd+s"})
```

`App` is the ergonomic layer over it. Its methods are snake_case, but keyword arguments are passed
to the tool unchanged and therefore keep the schema's own names — `deliveryPolicy`, `timeoutMs`,
`includeReads`. That keeps one spelling of every parameter across the daemon, the CLI, the MCP
surface, and both SDKs; the cost is that these keywords are typed as `Any`. Reach for `axon.raw`
when you want the checker to read along.

## Transport

`Axon.connect()` uses `SocketTransport`, which implements the daemon protocol: connect, write one
newline-terminated JSON-RPC request, read one newline-terminated response, close. One connection
carries one call. It defaults to a 30-second timeout, 300 seconds for `run`, `wait_for_value`, and
`wait_for_stability`, and refuses a response larger than 64 MiB.

The endpoint defaults to `AXON_SOCKET_PATH`, then to the platform's own: `/tmp/axon.sock` on macOS,
`$XDG_RUNTIME_DIR/axon-v1.sock` on Linux, and the `axon-v1` named pipe on Windows. The Windows path
opens the pipe as a file, which carries no timeout, so that endpoint is bounded by the daemon
answering rather than by `DEFAULT_TIMEOUT_S`.

**There is no network transport, and there will not be one.** Axon's trust boundary is local: it
speaks only to the same user on the same machine. A consumer that needs to reach a daemon across a
machine boundary supplies its own transport and its own authorization, by implementing the
`Transport` protocol and passing it to `Axon.connect(transport=...)`. See
[`docs/embedding.md`](../../docs/embedding.md).

## Generated code

`axon_cmd/_generated.py` is generated by `sdk/generate.ts` and must not be edited. After changing the
tool surface, run `scripts/check-tool-surface --write` from the repository root, which regenerates
the schema artifact and both clients together. `scripts/check-sdk-python` fails when the artifact
and this client disagree.

```sh
pyright             # types, including the tests
pytest              # against a fake daemon on a Unix socket; no daemon required
```

From the repository root, `scripts/check-sdk-python-package` builds the wheel and sdist, asserts
what they contain and what their metadata claims, and installs the wheel into an empty environment
to prove `from axon_cmd import Axon`. It reaches no index, and it is what a release runs before
publishing.
