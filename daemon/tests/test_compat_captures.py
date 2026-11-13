"""The daemon's half of the compatibility check: each agent CLI's newest capture
(`fixtures/compat/<agent>/`, written live by tools/compat_capture.py), read by the daemon's own
parsers, gives what AiTerm needs. A failure here after a new capture means the CLI changed something
AiTerm reads; the capture's diff shows what. Never regenerate a capture to make this pass: fix the
reader, or decide the change on purpose (docs/testing.md, "Agent compatibility")."""
from __future__ import annotations

import json
import re
from functools import cache
from pathlib import Path
from typing import Any

import pytest

from aitermd.claude_background import BackgroundTranscripts
from aitermd.claude_sessions import ClaudeSessionFiles
from aitermd.claude_subagents import SubagentTranscripts
from aitermd.codex_sessions import CodexSessionFiles
from aitermd.hook_events import parse_claude_hook, parse_claude_statusline, parse_codex_hook, parse_pi_hook
from aitermd.slash_commands import TranscriptReader
from aitermd.status import CLAUDE_FILE_STATUS, _has_spinner
from aitermd.usage import parse_codex_rate_limits

CAPTURES = Path(__file__).parent / "fixtures" / "compat"
# Where each CLI's scratch config sat in the capture's own paths (tools/compat_capture.py), and so
# where a path a CLI named is found in its capture.
CONFIG_ROOTS = {"claude": "/SCRATCH/claude-config/", "codex": "/SCRATCH/codex-home/"}


@cache
def note(agent: str) -> dict[str, Any]:
    path = CAPTURES / agent / "capture.json"
    if not path.is_file():
        pytest.fail(f"no {agent} capture in {path.parent}: run scripts/compat-check.sh --agents {agent}")
    found: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
    return found


@cache
def posts(agent: str) -> tuple[tuple[str, dict[str, Any]], ...]:
    note(agent)
    lines = (CAPTURES / agent / "posts.jsonl").read_text(encoding="utf-8").splitlines()
    return tuple((post["route"], post["body"]) for post in map(json.loads, lines))


def hooks(agent: str) -> list[dict[str, Any]]:
    return [body for route, body in posts(agent) if route == f"/hook/{agent}"]


def named(agent: str, event: str) -> list[dict[str, Any]]:
    return [body for body in hooks(agent) if body.get("hook_event_name") == event]


def local(agent: str, path: str) -> Path:
    """The capture's copy of a file the CLI named by its scratch path."""
    root = CONFIG_ROOTS[agent]
    assert path.startswith(root), f"{path!r} is not under the scratch config {root!r}"
    return CAPTURES / agent / path.removeprefix(root)


def first_prompt() -> str:
    return "Reply with only the word ALPHA followed by the result of 6 times 7."


@pytest.mark.parametrize("agent", ["claude", "codex", "pi"])
def test_each_capture_names_the_version_it_was_taken_from(agent):
    assert (CAPTURES / agent / "version.txt").read_text().strip() == note(agent)["version"]


# -- Claude Code -------------------------------------------------------------------------------------
def test_claude_posts_every_event_the_capture_raised():
    raised = {body.get("hook_event_name") for body in hooks("claude")}
    missing = {"SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification", "SubagentStart", "SubagentStop", "Stop"} - raised
    assert not missing, f"Claude Code no longer posts {sorted(missing)} to AiTerm's hooks"


def test_claude_hook_posts_read_as_the_events_aiterm_tracks():
    for body in hooks("claude"):
        event = parse_claude_hook(body)
        name = body["hook_event_name"]
        if name == "Notification":
            # One AiTerm does not act on (an idle reminder) reads as nothing; each still says its type.
            assert isinstance(body.get("notification_type"), str), body
            continue
        assert event is not None, f"{name} no longer reads: {body}"
        assert event.session_id and event.cwd, f"{name} lost its session or folder: {body}"
    assert all(parse_claude_hook(body).kind == "needsInput" for body in named("claude", "PermissionRequest"))
    prompts = [parse_claude_hook(body).prompt for body in named("claude", "UserPromptSubmit")]
    assert first_prompt() in prompts
    assert all(parse_claude_hook(body).kind == "done" for body in named("claude", "Stop"))


def test_claude_session_start_reads_as_a_new_conversation():
    starts = named("claude", "SessionStart")
    assert starts, "Claude Code posted no SessionStart to AiTerm's hook"
    assert parse_claude_hook(starts[0]).kind == "sessionStart"


def test_claude_names_each_subagent_and_where_it_writes_and_that_transcript_ends():
    start = parse_claude_hook(named("claude", "SubagentStart")[0])
    assert start.kind == "subagentStart" and start.subagent_id and start.subagent_transcript
    stop = parse_claude_hook(next(body for body in named("claude", "SubagentStop") if body.get("agent_id") == start.subagent_id))
    assert stop.kind == "subagentStop"
    tail = SubagentTranscripts().read(str(local("claude", start.subagent_transcript)))
    assert tail is not None and tail.ended_at is not None, "the subagent's transcript no longer shows its end"


def test_claude_stop_names_the_shell_it_left_running():
    work = [job for body in named("claude", "Stop") for job in (parse_claude_hook(body).background_work or ())]
    assert any(job.kind == "shell" and "DELTA-DONE" in job.text for job in work), named("claude", "Stop")


def test_claude_status_line_gives_usage_context_model_and_transcript():
    ticks = [parse_claude_statusline(body, 0) for route, body in posts("claude") if route == "/statusline"]
    assert ticks, "the status line never reached AiTerm"
    sessions = {body["session_id"] for body in hooks("claude")}
    last = ticks[-1]
    assert last.session_id in sessions
    assert last.usage is not None and last.usage.five_hour is not None, "the status line lost its rate limits"
    assert any(tick.context_percent is not None for tick in ticks), "the status line lost its context fill"
    assert last.model and last.transcript


def test_claude_session_file_names_its_process_version_and_a_known_status():
    files = sorted((CAPTURES / "claude" / "sessions").glob("*.json"))
    assert files, "no session file was seen"
    for path in files:
        parsed = ClaudeSessionFiles._parse(path, 0.0)
        assert parsed is not None, f"{path.name} no longer reads"
        assert parsed.version == note("claude")["version"]
        assert parsed.status in CLAUDE_FILE_STATUS, f"unknown status {parsed.status!r}"


def first_session(agent: str) -> str:
    """The conversation the capture's first prompt went to: its main session, which the scripted
    turns ran in (an approval runs in a session of its own)."""
    submitted = [body for body in named(agent, "UserPromptSubmit") if body.get("prompt") == first_prompt()]
    assert submitted, "the first prompt never reached AiTerm's hook"
    session: str = submitted[0]["session_id"]
    return session


def _main_transcript() -> Path:
    main = first_session("claude")
    paths = {event.transcript for body in named("claude", "Stop")
             if body.get("session_id") == main and (event := parse_claude_hook(body)) is not None}
    assert len(paths) == 1, paths
    path = paths.pop()
    assert path is not None, "the Stop no longer names its transcript"
    return local("claude", path)


def test_claude_transcript_shows_the_background_shell_start_and_end(tmp_path):
    transcript = _main_transcript()
    # The shell the Stop named, by its task id.
    named_shells = {job.task_id for body in named("claude", "Stop") for job in (parse_claude_hook(body).background_work or ())
                    if job.kind == "shell" and "DELTA-DONE" in job.text}
    assert len(named_shells) == 1, named_shells
    shell = named_shells.pop()
    # Up to the notice queued for that shell, it runs; with the notice, it has ended. The system
    # prompt quotes the tag too, and a subagent's end is a notice of its own.
    lines = transcript.read_text(encoding="utf-8").splitlines(keepends=True)
    cut = next(index for index, line in enumerate(lines)
               if re.search(r'"(content|prompt)":"<task-notification>', line) and f"<task-id>{shell}</task-id>" in line)
    before = tmp_path / "before.jsonl"
    before.write_text("".join(lines[:cut]), encoding="utf-8")
    running = BackgroundTranscripts().read_all({"tab": (str(before), 0.0)})["tab"]
    assert running is not None, "the transcript no longer reads for background shells"
    assert shell in {task.job.task_id for task in running.tasks}, "the background shell's start is not seen"
    ended = BackgroundTranscripts().read_all({"tab": (str(transcript), 0.0)})["tab"]
    assert ended is not None and shell in ended.ended, "the background shell's end is not seen"


def test_claude_transcript_shows_the_slash_command_and_its_output():
    path = str(_main_transcript())
    records = TranscriptReader().read_all({path: 0})[path] or ()
    commands = [record for record in records if record.kind == "command"]
    assert any(record.text == "/model sonnet" for record in commands), records
    ran = next(record for record in commands if record.text == "/model sonnet")
    assert any(record.kind == "output" and record.prompt == ran.prompt for record in records), "its output is not seen"


# -- Codex ---------------------------------------------------------------------------------------------
def test_codex_posts_every_event_the_capture_raised():
    raised = {body.get("hook_event_name") for body in hooks("codex")}
    missing = {"SessionStart", "UserPromptSubmit", "PermissionRequest", "SubagentStart", "SubagentStop", "Stop"} - raised
    assert not missing, f"Codex no longer posts {sorted(missing)} to AiTerm's hooks"


def test_codex_hook_posts_read_as_the_events_aiterm_tracks():
    for body in hooks("codex"):
        event = parse_codex_hook(body)
        assert event is not None, f"{body.get('hook_event_name')} no longer reads: {body}"
        assert event.session_id and event.cwd
    start = parse_codex_hook(named("codex", "SessionStart")[0])
    assert start.kind == "sessionStart" and start.model == note("codex")["model"]
    assert first_prompt() in [parse_codex_hook(body).prompt for body in named("codex", "UserPromptSubmit")]
    assert parse_codex_hook(named("codex", "PermissionRequest")[0]).kind == "needsInput"
    assert all(parse_codex_hook(body).kind == "done" for body in named("codex", "Stop"))
    children = [parse_codex_hook(body) for body in named("codex", "SubagentStart")]
    assert all(child.subagent_id for child in children)


def test_codex_rollout_gives_version_context_turn_and_rate_limits():
    sessions = CodexSessionFiles(CAPTURES / "codex" / "sessions")
    thread = parse_codex_hook(named("codex", "SessionStart")[0]).session_id
    reading = sessions.reading(thread)
    assert reading.version == note("codex")["version"], "the rollout no longer names its CLI version"
    assert reading.context is not None, "the rollout no longer gives the context fill"
    assert reading.turn is not None and reading.turn[0] == "done", reading.turn
    limits = sessions.rate_limits()
    assert limits is not None, "no rollout carries rate limits"
    usage = parse_codex_rate_limits(limits[0], 0)
    assert usage.five_hour is not None or usage.seven_day is not None


def test_codex_tab_title_spins_while_it_works():
    titles = json.loads((CAPTURES / "codex" / "titles.json").read_text())
    assert any(_has_spinner(title) for title in titles), titles


# -- PI ------------------------------------------------------------------------------------------------
def test_pi_extension_posts_every_event_the_capture_raised():
    raised = {body.get("hook_event_name") for body in hooks("pi")}
    missing = {"session_start", "agent_start", "turn_end", "agent_settled"} - raised
    assert not missing, f"PI no longer posts {sorted(missing)} to AiTerm's extension"


def test_pi_extension_posts_read_with_session_model_reasoning_and_context():
    events = [parse_pi_hook(body) for body in hooks("pi")]
    assert all(event is not None and event.session_id and event.cwd for event in events), hooks("pi")
    assert events[0].kind == "sessionStart"
    assert {event.model for event in events} == {note("pi")["model"]}
    assert {event.reasoning for event in events} == {note("pi")["reasoning"]}
    assert any(event.context_percent is not None for event in events), "PI no longer reports its context"
