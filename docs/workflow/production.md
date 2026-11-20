# Production signals

Production is the installed AiTerm (`/Applications/AiTerm.app`) on the maintainer's Mac, plus what
others attach to a GitHub bug report. Everything here is read, never edited, and an agent never
quits, restarts or replaces the running app. Where AiTerm writes what is mapped in
`docs/architecture.md` (What AiTerm writes, and where).

## Where to look

| Symptom | Where | How |
|---|---|---|
| "AiTerm's helper keeps stopping", an action that failed | `~/Library/Application Support/AiTerm/aitermd.log` | Read it. It is cleared at every launch, so read it before anyone relaunches. |
| The helper runs old code | `pgrep -fl aitermd` | Only a crash or force quit leaves it running; the maintainer ends that pid before reopening. A normal quit stops it. |
| Wrong or missing sidebar data | `state.json` beside the log, `state.json.backup` | `jq` for the keys in question, never the whole file. |
| "Couldn't open your workspace … missing", Restore Backup greyed out | `state.json` written by a newer dev build | Install the matching release (from its DMG); never edit the state. |
| Claude usage stale or missing | `statusLine.command` in `~/.claude/settings.json` | It points at the bundle that launched last; a deleted worktree build stops the feed. |
| Agent status or hooks not arriving | hook port `127.0.0.1:47821`; integration entries in `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.pi/agent/extensions/` | `lsof -nP -iTCP:47821 -sTCP:LISTEN`; read the entries. Other tools (Emdash) own slots there too. |
| Operator or signal behaviour | `operators/operator/` beside the log: `activity.jsonl`, `journals/`, `gate.json` | Read the lines around the time in question. |

## Access

Local files under the maintainer's account; no credentials are needed. Service tokens live in the
Keychain (`com.laurensdhondt.aiterm`, account `secrets`) and are never read.

## Data rules

`state.json`, the log and the Operator's journals hold the maintainer's project paths, branch names,
ticket keys and prompts from other, non-public work. The repository is public: quote the narrowest
key or line, replace names and keys with made-up ones, and keep raw records out of commits, issues,
fixtures and docs.
