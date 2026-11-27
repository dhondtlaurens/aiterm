# Show background shells on adopted Claude tabs

## Goal

After a daemon relaunch, a Claude tab that was already open can report a background Bash result while its card stays empty. The daemon should list that shell during the working turn and across a subsequent prompt for as long as it runs. The active shell is display work with `holdsTurn: false`. A Stop can still report work that holds the ended turn.

## Approach

The Claude background reader requires a parent transcript path and a turn with a wall-clock `work_since`. Currently only a genuine SessionStart supplies the latter. An ordinary parent hook, or the PID session file together with a directly placed status-line transcript path, must also allow the daemon to adopt the initial conversation. A path may arrive before the conversation ID or before any state-changing hook. Use the existing placement and reader ownership checks. Reading a PID file alone supplies no transcript path.

1. Record when the daemon started and when it first observed each Claude process. Use the daemon start as the fallback for Claude processes in the first successful iTerm snapshot, even if earlier ticks failed or found iTerm disconnected. For processes first appearing in later snapshots, use their own first observation. Capture this timing before yielding to hooks. Forget it on closure or replacement. This covers the period between restart and the first prompt without admitting the history of an earlier occupant of a subsequently replaced tab.
2. Prefer the matching Claude PID file’s `startedAt` when adopting. The recorded Claude compatibility fixture expresses it in Unix milliseconds. Validate the optional value independently of the rest of the file, convert to wall-clock seconds and require the PID and conversation to match. Absent, malformed or implausibly future values leave the fallback usable. A matching process start can recover a shell that is still running from before the daemon restarted. A hook-only adoption uses the fallback as soon as it has the tab’s own transcript. If matching file evidence arrives later, allow one refinement to the verified process start for that initial conversation. A changed boundary invalidates in-flight reads and restarts the existing bounded cursor. Ordinary hooks and ticks never move the boundary forward with the current prompt.
3. Distinguish first binding an unknown conversation ID from replacing a known ID. Keep adoption scoped to the initial conversation of that process. A known-ID change retires the old reader, displayed work and adoption eligibility even if a SessionStart was missed. A genuine startup, clear or resume hook takes precedence and supplies its normal boundary. A compact hook for the same conversation preserves it. Keep late reads scoped to the captured agent, PID, conversation, transcript path and boundary. The reader also supplies teammate state and child labels, so these identity checks apply to the entire result.
4. Use the existing incremental parent transcript reader from the chosen boundary. It joins the Bash call to its confirmed native result, processes terminal notifications and publishes only after catching up. Keep the existing Stop snapshot reconciliation. A valid Stop supplies the expected shell IDs and its timestamp can clear earlier uncertainty. It cannot reconstruct a launch excluded by the time filter. Reading both records from the earlier boundary lets a shell listed by a Stop survive the next prompt with the correct command and a single display entry.

When the PID file supplies no usable start time, a Stop may list a shell launched before the fallback boundary. If the reader has seen neither that launch nor its end, the existing completeness check withholds the entire live shell inventory across the next prompt. A matching native start can recover the launch. A terminal record identifying the shell, or a subsequent valid Stop omitting it, can also resolve the missing ID. Preserve that rule for adopted sessions.

## Other agents

| Agent | How an existing session behaves |
| --- | --- |
| Antigravity | A parent PreInvocation hook can create a turn and supply the CLI transcript path. Its reader requires that turn and path and has no start-time filter. A synthetic working-turn probe without SessionStart showed a shell. The status line alone omits the CLI path. |
| Codex | The daemon restores its thread binding and reads rollout boundaries and child descriptions. Its card can show counted children. AiTerm has no active-turn background-shell inventory for a fresh or adopted Codex tab. |
| Pi | The extension reports root turn and prompt lifecycle. AiTerm has no background-shell inventory for a fresh or adopted Pi tab. |

## Files

| Action | File | Purpose |
| --- | --- | --- |
| Modify | `daemon/aitermd/agents/claude.py` | Parse the optional native start time and pass verified PID-file evidence through the existing tick. |
| Modify | `daemon/aitermd/service.py` | Supply daemon startup and process observation times during snapshot reconciliation. |
| Modify | `daemon/aitermd/status.py` | Own the initial adoption boundary, metadata ordering and conversation resets alongside the existing turn state. |
| Modify | `daemon/tests/test_service.py` | Exercise adoption through placed posts, real transcript reads, ticks and the sessions.list RPC. |
| Modify | `daemon/tests/test_claude_sessions.py` and `daemon/tests/test_status.py` | Cover native timestamp validation, boundary precedence and reset behavior with deterministic clocks. |
| Modify | `docs/status-model.md` | Update the documented SessionStart requirement with the verified process start, fallback and Stop reconciliation rules. |

## Proof and to-dos

- [ ] Reproduce the reported case in a daemon service test on the current code. Start with an existing Claude tab, omit SessionStart, deliver a parent prompt hook and write the matched Bash call and background result. Tick and assert the exact shell entry in `sessions.list` while working. Append completion and assert the shell disappears while the turn remains working. Implement the adoption fallback and cover a directly supplied transcript preceding the first state-changing hook.
- [ ] Add the cross-turn regression with distinct clock values for daemon start, launch, Stop and next prompt. Omit SessionStart throughout. Let the first Stop list the shell, submit the next prompt and do the first background read after that prompt. Assert that the Stop obligation clears and the same single shell appears as display work. Include an unlisted older shell as a control for Stop reconciliation.
- [ ] Honor a matching native process start and test a live launch before daemon restart, an unresolved launch before process start, invalid or absent start time, and a delayed matching file after hook-only adoption. Retain the turn state and reject superseded reads after refinement.
- [ ] Cover first conversation ID arriving after the path, same-ID compaction, a known-ID change followed by a later prompt, genuine clear/resume, and process replacement, including a read already in flight. Check that repeated metadata cannot re-enable a retired boundary or bring back previous work. Reuse the existing replacement and unavailable-reader tests where they cover these cases.
- [ ] Exercise a Stop listing a pre-fallback shell while the PID file lacks a start time. Assert that an unresolved expected ID keeps the working inventory unavailable even with a newer confirmed launch. Resolve the older ID with a terminal record and assert that the newer shell appears. Document adoption and this completeness rule in `docs/status-model.md`.
- [ ] Run focused daemon tests for the changed paths and existing Claude reader, teammate, Codex, Antigravity and Pi suites, then run `scripts/test.sh`. The daemon RPC payload is the input used by the existing card. No app relaunch is required for this proof.

## Plan review

Claude Opus 5.5 (high) reviewed two rounds. Round one found the existing status-model documentation needed an update and requested coverage for a Stop listing an unverifiable launch from before the fallback boundary. Both changes are in the files and proof above. Round two confirmed both fixes and reported no further findings.

The Antigravity check used a synthetic working turn and a captured command record. The Claude timestamp evidence comes from captured PID files. Live wrapper PID mapping and PID-file updates across clear/resume were outside that evidence. The plan uses native timing only for verified matches during initial adoption.
