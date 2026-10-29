# aitermd

AiTerm's Python helper owns iTerm2 access, agent telemetry and local transport. The Swift app owns
the persisted workspace and scheduling decisions. `Service` composes small registry, status,
delivery, window, hook and RPC owners; blocking file reads run off the asyncio loop.

## Develop and verify

Python 3.11+; dependencies and exact runtime pins live in `pyproject.toml`. From the repository root:

```sh
scripts/test.sh daemon
```

The runner creates `daemon/.venv`, installs the `dev` extra, then runs pytest, strict mypy over
`aitermd tests tools`, and ruff. To iterate from this directory:

```sh
.venv/bin/pytest -k delivery
.venv/bin/mypy aitermd tests tools
.venv/bin/ruff check aitermd tests tools
```

The default suite uses `FakeIterm`, fake clocks and temporary homes. Live integration tests require
`AITERMD_LIVE=1`; delivery checks open isolated agent sessions and are separate from ordinary tests.
See [testing](../docs/testing.md). Do not start another helper on the installed app's socket/port.
For a deliberately separate development instance, `python -m aitermd run` accepts `--socket`,
`--hook-port`, `--idle-exit-seconds` and `--cookies-from-app`; `ctl METHOD [JSON] --socket PATH`
sends one RPC. The app normally starts and supervises the bundled helper.

## App connection

`workspace.snapshot` returns protocol version 1, availability, tagged sessions and usage. The app
supplies its resolved `claudeConfigDirectory`; the helper applies it and echoes it exactly, including
when adopted by a new app connection. Requests omitting it retain the current directory. This
acknowledgement is part of compatibility checking.

The snapshot is written before later events and acts as the client's bootstrap barrier. A
disconnected snapshot proves no window closure. Overflow or malformed framing closes the
connection for a fresh bootstrap. Frames are limited to 1 MiB; slow writes have a two-second drain
deadline. Swift requests time out after 15 seconds and support cancellation.

Window creation serializes with snapshots and adopts existing task/tab tags on retry. A window
already created remains a success even if a subsequent tagging/refresh step fails. Hook Stop is
telemetry; it does not delete a checkout, rewrite shell commands or close its window. See the
[protocol reference](../docs/daemon-protocol.md) and [window rules](../docs/windows.md).

## Hook HTTP

The loopback receiver defaults to `127.0.0.1:47821`:

| Route | Input |
| --- | --- |
| `/hook/claude` | Session/model/turn/subagent/permission/notification/StopFailure events. |
| `/hook/codex` | Session/turn/subagent/permission events. |
| `/hook/pi` | Session, activity, UI prompt and model/reasoning events. |
| `/mcp` | Stateless Codex Stop bridge, still reachable after checkout removal. |
| `/statusline` | Claude's context, model and usage telemetry. |

Requests require `X-AiTerm-Hook: 1`; missing headers and unknown routes receive a plain 404. Codex/PI
tab placement uses `X-AiTerm-iTerm-Session`, never a same-named body field. Telemetry is acknowledged
with `{}` before handling and carries no decision. Harness test IDs are echoed and never applied to
state. Strict decimal Content-Length, a 1 MiB body cap, 100-header/32 KiB head limits and
`100-continue` support bound the receiver.

Operator MCP has a separate token/ownership-controlled surface. Its 32 schemas are frozen in
`tests/fixtures/operator-current-tools.json`; Python schema and forwarded-reply tests plus Swift's
current journey protect it. Update transcript/vendor parsers for actual supported CLI versions,
without adding a historical broadcast execution path.

## Polling

A tick owns one coherent registry snapshot, reused across consumers. `TestActivityReader` takes one
view per apply. Tests enforce six registry sorts for 0/18/150-session tick fixtures (eleven before
the refactor). Identity checks and fresh reads after asynchronous effects remain necessary; the
snapshot is not a global mutable cache.
