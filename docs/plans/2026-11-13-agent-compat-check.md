# Agent compatibility check

## Goal

When Claude Code, Codex or PI updates, know quickly whether AiTerm still works with it. Today only
messaging (typing into Claude Code and Codex) is checked against the real CLI. Its pass is tied to
major.minor, so a new line already turns delivery off until Run check passes. Everything else AiTerm
relies on (hook payloads, Claude's status line, session and transcript files, model catalogues,
launch and headless flags, PI's extension API) is tested only against hand-written fixtures or
captures from old versions (Claude 2.1.251 to 2.1.318, Codex 0.160). A change there shows up as a
stuck status, a blank usage footer or a failed launch, and nobody is told why.

## Approach

**Agreed while grilling:**
- **Hybrid.** A maintainer script is the main deliverable. Users get a quiet "verified with"
  line in Settings that costs them nothing.
- **Messaging's Run check is unchanged.** It stays the per-user safety gate, because only the
  version on that user's Mac counts.
- **Granularity is major.minor, like Messaging.** "Verified with 2.1" covers every 2.1.x.
- **Capture, then test.** The script drives each CLI live and saves what it saw as the newest fixture
  set per CLI. Then pytest and Swift contract suites run against those captures. Only when they pass
  are the versions recorded as verified. Every later test run keeps guarding the real captures, and
  the fixture diff shows what the CLI changed.

**How a capture works** (`daemon/tools/compat_capture.py`, alongside `delivery_check.py`):
- **Setup.**
  - Each CLI gets a scratch config, built the way `delivery_check.py` already builds them:
    `scratch_claude_config` with the empty `CLAUDE_SECURESTORAGE_CONFIG_DIR` login rule, and
    `scratch_codex_home`. PI gets an equivalent scratch agent dir holding a copy of its sign-ins.
  - AiTerm's real driver goes into each scratch config: the Claude hooks and status-line shim, the
    Codex `config.toml` block, and the PI extension. Their endpoints point at a capture listener, not
    the live daemon, so the sidebar never sees test traffic. Nothing lands in `~/.claude`,
    `~/.codex` or `~/.pi`.
  - The capture never runs the app's driver install. That install writes the shared
    `~/Library/Application Support/AiTerm/hook-port`, which every live Claude session's shim reads.
    Instead, the capture writes the driver entries from checked-in templates
    (`compat/drivers/claude-settings.json`, `compat/drivers/codex-hooks.toml`), filling in the
    capture port. A Swift test keeps the templates byte-equal to what `ClaudeSettings` and
    `CodexHookConfig` produce for a given port, so the capture always installs what the app installs.
  - The shim stays unchanged. Its `statusLine.command` in the scratch settings runs it with `HOME`
    set to a scratch home, for that command alone. The scratch home's
    `Library/Application Support/AiTerm/hook-port` holds the capture port. Claude itself keeps the
    real `HOME`, so its login keeps working.
- **The session.**
  - Each CLI starts in a scratch folder in iTerm2, with AiTerm's own task launch words on the
    cheapest model at low effort.
  - Codex's task launch words include `--dangerously-bypass-approvals-and-sandbox`, so they never
    ask. Codex's approval turn therefore runs in a second session started the way
    `delivery_check.py` starts it (`-s workspace-write -a on-request`).
  - It runs a few short scripted turns that exercise every surface in the inventory:
    - a plain turn
    - one that needs an approval
    - one that spawns a subagent
    - one that starts a background shell (Claude)
    - one harmless slash command
  - The script never types `/model`, `/effort` or `/config` outside a scratch config.
- **What gets recorded.**
  - every hook, extension and status-line post
  - the session file, transcript and rollout files
  - the model catalogue files (Claude's `cache/model-catalog`, `~/.codex/models_cache.json`) and
    `pi --list-models` output
  - `--version`, and `--help` / `exec --help` text
  - the stdout or `-o` file of each headless command AiTerm runs (challenge, fixer, PI's `-p`),
    each with a one-word prompt
- **Scrubbing (the repo is public).** Before anything is written, the scratch root, the home folder,
  the user name and any account email or identifier are replaced with placeholders. The write fails
  if any of them is still present. Captures replace the previous set per CLI; git history keeps the
  old ones.

**Judging:**
- **Python** (`test_compat_captures.py`): the daemon's real parsers read each CLI's captures, and
  the suite asserts what AiTerm needs from them:
  - every expected event kind arrives
  - Stop's background tasks are read
  - Notification types are known
  - the status line gives rate limits, context and model
  - the session file gives pid, version and status
  - the Codex rollout gives version, token count, rate limits and turn start and end
  - the subagent end and the background shell's start and end are seen
  - the slash command is read
  - PI's posts carry session, model and context
- **Swift**: the parts Python can't reach, in two suites, because `WorkerTranscript` is internal to
  the `AiTerm` target.
  - `CompatContractTests` (`AiTermCoreTests`):
    - `ModelFiles` and `PiModelCatalog` must return exactly the model ids and effort values that the
      test reads from the captured files on its own. A non-empty list is not enough, because
      `ModelFiles` falls back to aliases and default models when decoding fails. A result equal to
      the fallback fails.
    - The challenge and fixer readers decode the captured headless output.
    - Every launch flag AiTerm builds appears in the captured `--help` text.
  - `CompatTranscriptTests` (`AiTermTests`): `WorkerTranscript` reads assistant text from the
    Claude and Codex transcripts.
  - The flags themselves come from one checked-in list. A test keeps that list in step with
    `Harness`, `AgentCommand`, `HeadlessRun`, `OperatorCommand` and `FixerLaunch`, so a new flag
    can't be left out.

**One command** (`scripts/compat-check.sh [claude,codex,pi]`):
1. Capture.
2. Run the delivery check `--write` for Claude Code and Codex, which updates Messaging. Its exit
   code says nothing about the verdict, because it returns 0 even when scenarios fail or iTerm2 is
   unreachable. Instead, the script reads the policy file afterwards. It requires, for each agent,
   an entry written during this run for the captured version, with `pasteSafe` and `submitSafe`
   both true. An entry that is missing or old counts as a failure.
3. Run the two contract suites.
4. Only if everything is green, write each CLI's major.minor into `compat/verified.json`.
5. Print a summary and the fixture diff stat.

You review and commit. It is never run by the test suite: it opens windows and spends tokens.

**In the app:** `compat/verified.json` is bundled the way `hooks/` is (`scripts/make-app.sh`). Each
agent card in Settings › Agents gets one muted line, drawn from the installed version and that list:
"2.1 verified with this AiTerm" or "2.2 not yet verified with this AiTerm". It is not a check row, never amber,
and doesn't change the card's health, because nothing is gated on it. Codex ships a minor every week,
so an amber state would be on most of the time.

## Added while building: Claude's SessionStart

The first live capture found a real break, as the check is meant to: Claude Code 2.1.323 runs a
`SessionStart` command hook but never posts a `SessionStart` http hook (probed directly in a scratch
config), and AiTerm installs it as http, so the daemon never hears a conversation start, a `/clear`
or a compaction from it. Agreed with the maintainer: fix it in this branch. `ClaudeSettings` installs
`SessionStart` alone as an async command hook that posts its stdin with curl to the same endpoint, as
Codex's command hooks do (probed: it arrives with `session_id`, `cwd`, `source` and
`transcript_path`, and holds nothing up); every other event stays http, which the capture shows
arriving. An install with the old http entry reads as outdated and Repair replaces it. Proof:
`HookConfigTests` for the new entry and the repair, the templates recorded again, a new capture whose
`SessionStart` contract tests pass.

## Files

| File | Change | Why |
|---|---|---|
| `daemon/tools/compat_capture.py` | create | Live capture: scratch configs, driver install, capture listener, scripted turns, scrubber, fixture writer |
| `daemon/tools/delivery_check.py` | reuse | The capture imports its scratch-config and iTerm2 session helpers (`Live`, `answer_trust`, `scratch_*_config`); no change was needed |
| `daemon/tests/fixtures/compat/{claude,codex,pi}/` | create | The newest scrubbed capture per CLI, with a `capture.json` naming version and date |
| `daemon/tests/test_compat_captures.py` | create | Python contract suite over the captures |
| `daemon/tests/test_compat_capture.py` | create | Unit tests for the tool's pure parts: scrubber and its guard, turn-script selection, verified-list merge |
| `app/Tests/AiTermCoreTests/CompatContractTests.swift` | create | Swift contract suite over the same captures: catalogues against the raw files, headless output, flags (reads across targets, like `WireContractTests`) |
| `app/Tests/AiTermTests/CompatTranscriptTests.swift` | create | `WorkerTranscript` over the captured transcripts; it lives where that internal type is reachable |
| `compat/drivers/` | create | The Claude settings entries and Codex hook block the app installs, with a port placeholder, kept byte-equal by a Swift test; the capture installs from them |
| `compat/launch.json` | create | Every command line AiTerm runs each CLI with, as templates (`{model}`, `{prompt}`…), kept in step by a Swift test; the capture launches from them and the flag check reads them. A flag `--help` leaves out (`--append-system-prompt-file`) is proved by a headless probe whose answer carries a marker |
| `compat/verified.json` | create | The major.minor per CLI the last green run verified; bundled into the app |
| `scripts/compat-check.sh` | create | The one maintainer command |
| `scripts/make-app.sh` | modify | Bundle `compat/verified.json` |
| `scripts/test-routes.tsv` | modify | Route `daemon/tests/fixtures/compat/*` and `compat/*` to both suites; register the cross-target reader |
| `app/Sources/AiTermCore/Harnesses/ClaudeSettings.swift` | modify | `SessionStart` as a curl command hook (above) |
| `app/Tests/AiTermCoreTests/HookConfigTests.swift` | modify | The command entry, and the repair of an http one |
| `app/Sources/AiTermCore/Harnesses/` (new `CompatVerified.swift`) | create | Read the bundled list; pure "verified / not yet verified" from the installed version |
| `app/Sources/AiTerm/Views/HarnessSettingsPane.swift` | modify | The muted line on each agent card, PI included |
| `app/Sources/AiTerm/Snapshots/SettingsSnapshots.swift` | modify | Snapshot both line states |
| `docs/testing.md`, `docs/configuration.md`, `scripts/README.md` | modify | Fixture provenance, what the card's line means, how and when to run the check |

## Proof

- **New pure-logic tests, written first:**
  - the scrubber leaves no home, user, email or scratch path, and refuses to write when one remains
  - the verified-list merge keeps other CLIs' entries
  - `CompatVerified` uses major.minor coverage, and treats an unknown version as not verified
  - the launch-flag list matches what the builders produce
  - the driver templates match what `ClaudeSettings` and `CodexHookConfig` write
  - the delivery-policy gate in `compat-check.sh` turns down a missing, old or failed entry (a
    pure function, `compat_capture.delivery_problems`, pinned by `test_compat_capture.py`)
- **Contract suites** run green against the first real captures (Claude 2.1.323, Codex 0.167.0,
  PI 1.4.0) and are routed so ordinary `scripts/test.sh` runs them whenever captures or parsers
  change.
- **Proof the check catches drift.** Edit a capture by hand (rename a status-line field, drop an
  event, rename a flag in the `--help` text), show the matching contract test fails with a message
  naming the surface, then restore it.
- **Live run.** `scripts/compat-check.sh` end to end, on this Mac, for all three CLIs. Confirm that
  nothing changed in `~/.claude`, `~/.codex`, `~/.pi` or AiTerm's real `hook-port` (checksums before
  and after) and that the
  sidebar showed no test sessions.
- **The app.** Settings snapshot shows the line for a covered and a newer version. `scripts/test.sh`
  before each commit; `scripts/test.sh all` before merging.

## To-dos

- [x] **Claude core capture.** Driver templates with their Swift in-step test, capture listener,
  scratch config with those hooks and the unchanged shim on a scratch `HOME`, one plain turn, scrubber with its guard, fixture writer. Python contract tests for hook posts, the
  status line and the session file. Runnable by hand for Claude.
- [x] **Claude extended turns.** Approval, subagent, background shell, slash command, and the headless
  runs. Contract tests for each.
- [x] **Codex capture.** Scratch `CODEX_HOME` with AiTerm's hook block, rollout and `models_cache.json`.
  Contract tests.
- [x] **PI capture.** Scratch agent dir with sign-ins and the extension, `--list-models`, headless `-p`.
  Contract tests. (PI honours a scratch agent dir through `PI_CODING_AGENT_DIR`, checked in its bundle.)
- [x] **Swift contract suites.** In Core: model catalogues compared with the raw files, with the
  fallback refused, headless output decoding, and `launch.json` with its in-step test and its
  `--help` check. In `AiTermTests`: worker transcripts. Routing rows for both.
- [x] **One command.** `scripts/compat-check.sh`, delivery check included and judged from the
  policy file it writes, `compat/verified.json` written only on green, summary and diff stat. First real run, fixtures committed.
- [x] **Settings line.** Bundle the list, `CompatVerified`, the muted line on every agent card,
  snapshots.
- [x] **Claude's SessionStart.** Command hook in `ClaudeSettings`, its tests, templates recorded again, Claude captured again with its SessionStart tests green.
- [x] **Docs.** `testing.md` provenance rows, `configuration.md`, `scripts/README.md`.
