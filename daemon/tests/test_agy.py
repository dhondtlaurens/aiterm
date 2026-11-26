"""Antigravity's hook posts: the payload its hooks get on stdin, which AiTerm's hook script posts as it is."""
from types import SimpleNamespace

import pytest

from aitermd.agents.agy import parse_agy_hook, trust_screens
from aitermd.models import ITERM_SESSION_FIELD, classify_agent
from aitermd.screens import shows_trust_prompt

# Captured from agy 1.5.18 (docs/research/2026-11-26-antigravity-cli.md), paths shortened.
BASE = {
    "artifactDirectoryPath": "/Users/me/.gemini/antigravity-cli/brain/c62469da",
    "conversationId": "c62469da-98ce-4672-be18-99a728393ddb",
    "cwd": "/repo/wt",
    "lastUserInput": "Reply with exactly the word PONG and nothing else.",
    "modelName": "gemini-3.8-flash-low",
    "transcriptPath": "/Users/me/.gemini/antigravity-cli/brain/c62469da/.system_generated/logs/transcript_full.jsonl",
    "workspacePaths": ["/repo/wt"],
    ITERM_SESSION_FIELD: "w0t0p0:ABC",
}


@pytest.mark.parametrize("name,kind", [
    ("SessionStart", "sessionStart"),
    ("PreInvocation", "working"),
    ("Stop", "done"),
    # Each model call of a turn is bracketed by both; only the first says the turn started.
    ("PostInvocation", None),
])
def test_agy_hook_mapping(name, kind):
    event = parse_agy_hook({**BASE, "hookEventName": name})
    assert event is not None
    assert (event.agent, event.kind, event.event_name) == ("agy", kind, name)
    assert event.session_id == "c62469da-98ce-4672-be18-99a728393ddb"
    assert event.cwd == "/repo/wt"
    assert event.iterm_session_id == "w0t0p0:ABC"
    assert event.transcript == BASE["transcriptPath"]


def test_a_stop_that_ended_on_an_error_or_a_cancel_still_ends_the_turn():
    for reason in ("ERROR", "USER_CANCELED", "NO_TOOL_CALL"):
        event = parse_agy_hook({**BASE, "hookEventName": "Stop", "terminationReason": reason, "fullyIdle": True})
        assert event is not None and event.kind == "done"


@pytest.mark.parametrize("payload", [
    None, [], {}, {"hookEventName": "PreToolUse", "conversationId": "c"}, {"hookEventName": 3},
])
def test_what_is_not_an_agy_lifecycle_post_is_nothing(payload):
    assert parse_agy_hook(payload) is None


def test_the_cli_is_recognised_by_its_binary():
    assert classify_agent("/Users/me/.local/bin/agy --model gemini-4-neon-high") == "agy"


def test_its_trust_dialog_is_read_from_the_screen():
    screen = ("Accessing workspace:\n/repo/wt\nDo you trust the contents of this project?\n"
              "Antigravity CLI requires permission to read, edit, and execute files here.\n"
              "> Yes, I trust this folder\n  No, exit\n")
    assert shows_trust_prompt("agy", screen)
    assert not shows_trust_prompt("agy", "> Reply with exactly the word PONG\n")


def test_only_an_agy_tab_that_has_not_spoken_yet_or_shows_the_dialog_is_read_for_it():
    """Its hooks speak first with the first prompt: until then a quiet idle tab may be held by the dialog."""
    def tab(sid, agent="agy", pid=10, conversation=None, state="idle"):
        return SimpleNamespace(session_id=sid, agent=agent, job_pid=pid, conversation_id=conversation, state=state)
    status = SimpleNamespace(showing_trust_prompt=lambda sid: sid == "held")
    tabs = [tab("quiet"), tab("spoken", conversation="c"), tab("busy", state="working"), tab("no-process", pid=None),
            tab("codex", agent="codex"), tab("held", conversation="c", state="needsInput")]
    assert trust_screens(status, tabs) == ["quiet", "held"]


# -- the status line ------------------------------------------------------------------------------
from aitermd.agents.agy import parse_agy_statusline  # noqa: E402

# Captured from agy 1.5.18's statusLine stdin, trimmed.
TICK = {
    "cwd": "/repo/wt", "session_id": "c62469da", "conversation_id": "c62469da",
    # The status line names the desktop app's folder here, which the CLI does not write: never kept.
    "transcript_path": "/Users/me/.gemini/antigravity/brain/c62469da/.system_generated/logs/transcript.jsonl",
    "model": {"id": "Gemini 3.8 Flash (Low)", "display_name": "Gemini 3.8 Flash (Low)", "effort": "low"},
    "version": "1.5.18",
    "context_window": {"total_input_tokens": 14092, "context_window_size": 1048576,
                       "used_percentage": 1.3439178466796875, "remaining_percentage": 98.656},
    "agent_state": "idle",
    ITERM_SESSION_FIELD: "w0t0p0:ABC",
}


@pytest.mark.parametrize("fields,state", [
    ({"agent_state": "working"}, "working"),
    ({"agent_state": "tool_use"}, "working"),
    ({"agent_state": "reviewing"}, "working"),
    ({"agent_state": "tool_use", "tool_confirmation_pending": True}, "needsInput"),
    ({"agent_state": "idle"}, "done"),
    # Starting up, signing in or failing says nothing of a turn.
    ({"agent_state": "authenticating"}, None),
    ({"agent_state": "initializing"}, None),
    ({"agent_state": "error"}, None),
    ({"agent_state": 3}, None),
])
def test_the_status_line_says_what_the_turn_is_doing(fields, state):
    tick = parse_agy_statusline({**TICK, **fields}, 1000)
    assert tick.state == state


def test_the_status_line_names_the_conversation_its_context_and_its_tab():
    tick = parse_agy_statusline(TICK, 1000)
    assert (tick.session_id, tick.cwd, tick.iterm_session_id) == ("c62469da", "/repo/wt", "w0t0p0:ABC")
    assert tick.context_percent == 1
    assert tick.usage is None and tick.transcript is None
    # Before the first conversation starts it names none.
    assert parse_agy_statusline({**TICK, "conversation_id": "", "session_id": ""}, 1000).session_id is None


class _Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


@pytest.fixture
def agy_hooks(tmp_path):
    from tests.test_hook_router import Hooks
    hooks = Hooks(tmp_path)
    clock = _Clock()
    hooks.status._clock = clock
    hooks.router.clock = clock
    hooks.clock = clock
    return hooks


def _hook(sid, name):
    return {**BASE, "hookEventName": name, ITERM_SESSION_FIELD: sid}


def _tick(sid, **fields):
    return {**TICK, ITERM_SESSION_FIELD: sid, **fields}


async def test_a_permission_prompt_holds_the_row_at_needs_input_until_it_is_answered(agy_hooks):
    [sid] = agy_hooks.tabs(("s1", "agy --model gemini-4-neon-high", 130))
    await agy_hooks.post("/hook/agy", _hook(sid, "PreInvocation"))
    assert agy_hooks.state(sid) == "working"
    agy_hooks.clock.now += 5
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="tool_use", tool_confirmation_pending=True))
    assert agy_hooks.state(sid) == "needsInput"
    agy_hooks.clock.now += 5
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="tool_use"))
    assert agy_hooks.state(sid) == "working"


async def test_a_missed_stop_is_mended_by_the_idle_status_line(agy_hooks):
    [sid] = agy_hooks.tabs(("s1", "agy", 131))
    await agy_hooks.post("/hook/agy", _hook(sid, "PreInvocation"))
    agy_hooks.clock.now += 5
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="idle"))
    assert agy_hooks.state(sid) == "done"


async def test_the_status_line_never_starts_a_turn_or_overrides_a_fresh_hook(agy_hooks):
    [sid] = agy_hooks.tabs(("s1", "agy", 132))
    # Idle, a working status line is not a turn: only the hook starts one.
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="working"))
    assert agy_hooks.state(sid) == "idle"
    # A status line that raced its Stop hook still says working: it is the moment before, and ignored.
    await agy_hooks.post("/hook/agy", _hook(sid, "PreInvocation"))
    agy_hooks.clock.now += 5
    await agy_hooks.post("/hook/agy", _hook(sid, "Stop"))
    agy_hooks.clock.now += 0.3
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="tool_use", tool_confirmation_pending=True))
    assert agy_hooks.state(sid) == "done"


async def test_a_permission_prompt_right_after_a_model_call_still_says_needs_input(agy_hooks):
    # Its status line may report the waiting tool once and not again: within the settle window, a
    # needs-input reading is not the moment before a hook, since answering it takes the person longer.
    [sid] = agy_hooks.tabs(("s1", "agy", 133))
    await agy_hooks.post("/hook/agy", _hook(sid, "PreInvocation"))
    agy_hooks.clock.now += 0.3
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="tool_use", tool_confirmation_pending=True))
    assert agy_hooks.state(sid) == "needsInput"
