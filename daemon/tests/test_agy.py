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
    # The CLI's own version: what a delivery-check pass is written for.
    assert tick.version == "1.5.18"
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


async def test_a_session_found_idle_mid_turn_recovers_its_state_from_the_status_line(agy_hooks):
    # A restarted daemon finds every tab idle: an agy turn under way, or waiting on an approval, shows
    # again from its next status line, as Claude's file and Codex's spinner show theirs.
    [busy, asking] = agy_hooks.tabs(("s1", "agy", 132), ("s2", "agy", 137))
    await agy_hooks.post("/statusline/agy", _tick(busy, agent_state="working"))
    await agy_hooks.post("/statusline/agy", _tick(asking, agent_state="tool_use", tool_confirmation_pending=True))
    assert (agy_hooks.state(busy), agy_hooks.state(asking)) == ("working", "needsInput")
    # Idle and done readings of an idle tab change nothing.
    [quiet] = agy_hooks.tabs(("s3", "agy", 138))
    await agy_hooks.post("/statusline/agy", _tick(quiet, agent_state="idle"))
    assert agy_hooks.state(quiet) == "idle"


async def test_the_status_line_never_overrides_a_fresh_hook(agy_hooks):
    [sid] = agy_hooks.tabs(("s1", "agy", 132))
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


async def test_the_status_line_records_the_tabs_cli_version(agy_hooks):
    [sid] = agy_hooks.tabs(("s1", "agy", 134))
    await agy_hooks.post("/statusline/agy", _tick(sid))
    assert agy_hooks.registry.get(sid).cli_version == "1.5.18"


# Screens as agy 1.5.18 draws them (docs/research/2026-11-26-antigravity-cli.md), trimmed.
RULE = "─" * 60
IDLE = f"probe-status\n{RULE}\n> Auto mode: edits & safe commands auto-approved (shift+tab to cycle)\n{RULE}\nprobe-status\n"
PERMISSION = (f"● Ran (touch asked.txt) (ctrl+o to expand)\n{RULE}\nRequesting permission for:\n touch asked.txt\n"
              "Run this command?\n> 1. Yes, run command\n 2. Yes, and always allow in this conversation for commands "
              "that start with 'touch'\n 4. No, cancel\n ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command\n")
TRUST = ("Accessing workspace:\n/repo/wt\nDo you trust the contents of this project?\n"
         "Antigravity CLI requires permission to read, edit, and execute files here.\n> Yes, I trust this folder\n"
         "  No, exit\n ↑/↓ Navigate · enter Confirm\n")


def test_its_screens_are_read_for_delivery():
    from aitermd.screens import open_prompt, shows_input_box
    assert shows_input_box("agy", IDLE) and open_prompt("agy", IDLE) is None
    assert open_prompt("agy", PERMISSION) == "permission"
    assert open_prompt("agy", TRUST) == "startup"


async def test_a_turn_that_ends_within_the_settle_window_without_its_stop_is_ended_by_the_tick(agy_hooks):
    # The idle reading is held, not dropped: with no hook or newer reading after it, the tick applies it
    # once the window has passed, so a lost Stop cannot leave the row working.
    [sid] = agy_hooks.tabs(("s1", "agy", 135))
    await agy_hooks.post("/hook/agy", _hook(sid, "PreInvocation"))
    agy_hooks.clock.now += 0.4
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="idle"))
    assert agy_hooks.state(sid) == "working"
    assert agy_hooks.status.settle_held_ticks() == []
    agy_hooks.clock.now += 1.0
    assert agy_hooks.status.settle_held_ticks() == [sid]
    assert agy_hooks.state(sid) == "done"


async def test_a_held_reading_a_newer_reading_or_hook_replaced_is_never_applied(agy_hooks):
    # A stale idle reading lands after the hook that started the turn; the turn's own working reading
    # follows it, and the held idle is forgotten.
    [sid] = agy_hooks.tabs(("s1", "agy", 136))
    await agy_hooks.post("/hook/agy", _hook(sid, "PreInvocation"))
    agy_hooks.clock.now += 0.3
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="idle"))
    agy_hooks.clock.now += 0.3
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="working"))
    agy_hooks.clock.now += 2
    assert agy_hooks.status.settle_held_ticks() == []
    assert agy_hooks.state(sid) == "working"
    # The same with a hook in place of the newer reading.
    await agy_hooks.post("/hook/agy", _hook(sid, "PreInvocation"))
    agy_hooks.clock.now += 0.3
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="idle"))
    await agy_hooks.post("/hook/agy", _hook(sid, "PreInvocation"))
    agy_hooks.clock.now += 2
    assert agy_hooks.status.settle_held_ticks() == []
    assert agy_hooks.state(sid) == "working"


async def test_a_held_reading_never_revives_a_turn_the_person_has_since_seen(agy_hooks):
    # Stop, then the moment-before working reading lands and is held; the person opens the finished
    # row (done to idle) before the window passes. The held reading is of a row that has moved on.
    [sid] = agy_hooks.tabs(("s1", "agy", 139))
    await agy_hooks.post("/hook/agy", _hook(sid, "PreInvocation"))
    agy_hooks.clock.now += 5
    await agy_hooks.post("/hook/agy", _hook(sid, "Stop"))
    agy_hooks.clock.now += 0.2
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="working"))
    agy_hooks.registry.set_state(sid, "idle")      # what seeing the done row does
    agy_hooks.clock.now += 2
    assert agy_hooks.status.settle_held_ticks() == []
    assert agy_hooks.state(sid) == "idle"


# -- background work: commands and subagents --------------------------------------------------------
import json  # noqa: E402

from aitermd.agents.agy import AgyTranscripts, background_plan, is_subagent_post  # noqa: E402
from aitermd.hook_events import HookEvent  # noqa: E402
from aitermd.models import work_items  # noqa: E402

PARENT, CHILD = "dbc4da62-8b3e-4062-b9fb-043c40e7a74f", "2e0afd67-5d5a-45f0-a777-e6f3547e9e25"
TASK = f"{PARENT}/task-2"
LOGS = f"file:///Users/me/.gemini/antigravity-cli/brain/{PARENT}/.system_generated"

# The records agy 1.5.18 wrote for a backgrounded command, its end, a subagent's creation and its answer
# (docs/research/2026-11-26-antigravity-background-work.md), trimmed.
COMMAND_CALL = {"step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
                "created_at": "2026-11-26T13:51:30Z",
                "tool_calls": [{"name": "run_command", "args": {"CommandLine": "sleep 40; echo CHARLIE", "WaitMsBeforeAsync": 2000}}]}
COMMAND_RUNNING = {"step_index": 2, "source": "MODEL", "type": "GENERIC", "status": "RUNNING", "created_at": "2026-11-26T13:51:33Z",
                   "content": f"Created At: 2026-11-26T14:51:33+01:00\nTool is running as a background task with task id: {TASK}\n"
                              f"Task Description: sleep 40; echo CHARLIE\nTask logs are available at: {LOGS}/tasks/task-2.log"}
COMMAND_ENDED = {"step_index": 4, "source": "SYSTEM", "type": "SYSTEM_MESSAGE", "status": "DONE", "created_at": "2026-11-26T13:52:14Z",
                 "content": "The following is a <SYSTEM_MESSAGE> not actually sent by the user.\n\n<SYSTEM_MESSAGE>\n"
                            f"[Message] timestamp=2026-11-26T13:52:14Z sender={TASK} priority=MESSAGE_PRIORITY_HIGH "
                            f"content=Task id \"{TASK}\" finished with result:\nCommand exited with code 0.\n\nCommand output:\n"
                            f"CHARLIE\r\n\nLog: {LOGS}/tasks/task-2.log\n</SYSTEM_MESSAGE>"}
SUBAGENT_CALL = {"step_index": 7, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "created_at": "2026-11-26T13:52:21Z",
                 "tool_calls": [{"name": "invoke_subagent", "args": {
                     "Prompt": "Run `sleep 30` using run_command, wait for it to finish, and then reply with the single word DELTA.",
                     "Role": "Sleep Worker", "TypeName": "self"}}]}
SUBAGENT_CREATED = {"step_index": 8, "source": "MODEL", "type": "GENERIC", "status": "DONE", "created_at": "2026-11-26T13:52:25Z",
                    "content": "Created At: 2026-11-26T14:52:25+01:00\nCompleted At: 2026-11-26T14:52:27+01:00\n"
                               "Created the following subagent:\n" + json.dumps({
                                   "conversationId": CHILD,
                                   "logAbsoluteUri": f"file:///Users/me/.gemini/antigravity-cli/brain/{CHILD}/.system_generated/logs/transcript.jsonl",
                                   "workspaceUris": ["file:///repo/wt"]}, indent=2)
                               + "\nThe subagent will send you a message when it has completed its task or requires guidance."}
SUBAGENT_ANSWERED = {"step_index": 4, "source": "SYSTEM", "type": "SYSTEM_MESSAGE", "status": "DONE", "created_at": "2026-11-26T13:55:05Z",
                     "content": "<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-26T13:55:05Z "
                                f"sender={CHILD} priority=MESSAGE_PRIORITY_HIGH content=DELTA\n</SYSTEM_MESSAGE>"}


def _write(path, *records, mode="a"):
    with open(path, mode, encoding="utf-8") as f:
        f.writelines(json.dumps(record) + "\n" for record in records)


def test_a_stop_says_whether_work_still_runs_and_each_post_carries_its_prompt():
    running = parse_agy_hook({**BASE, "hookEventName": "Stop", "fullyIdle": False})
    finished = parse_agy_hook({**BASE, "hookEventName": "Stop", "fullyIdle": True})
    assert (running.fully_idle, finished.fully_idle) == (False, True)
    assert parse_agy_hook({**BASE, "hookEventName": "PreInvocation"}).fully_idle is None
    assert parse_agy_hook({**BASE, "hookEventName": "SessionStart", "lastUserInput": ""}).user_input == ""


@pytest.mark.parametrize("event,tab,child", [
    # A subagent's conversation speaks from its parent's tab, its start carrying no prompt.
    (("sessionStart", CHILD, ""), PARENT, True),
    (("working", CHILD, ""), PARENT, True),
    (("done", CHILD, ""), PARENT, True),
    # The tab's own conversation, and a new one of its own (its first, or after /clear) that starts with a prompt.
    (("working", PARENT, "Invoke one subagent"), PARENT, False),
    (("sessionStart", CHILD, "Fix the build"), PARENT, False),
    (("sessionStart", PARENT, "Fix the build"), None, False),
    (("working", PARENT, "Fix the build"), None, False),
    # A daemon restarted while a subagent works knows no conversation for the tab yet: the child's posts carry no
    # prompt, the parent's always do.
    (("working", CHILD, ""), None, True),
])
def test_a_post_of_another_conversation_is_a_subagents_unless_it_starts_one_with_a_prompt(event, tab, child):
    kind, conversation, said = event
    assert is_subagent_post(HookEvent("agy", kind, conversation, "/repo/wt", user_input=said), tab) is child
    assert not is_subagent_post(HookEvent("claude", kind, conversation, "/repo/wt"), tab)


def test_the_status_line_counts_the_background_commands():
    # agy leaves the count out when it is zero.
    assert parse_agy_statusline(TICK, 1000).task_count == 0
    assert parse_agy_statusline({**TICK, "task_count": 2}, 1000).task_count == 2


def test_the_transcript_says_which_commands_run_and_which_subagents_were_created(tmp_path):
    path = tmp_path / "transcript_full.jsonl"
    _write(path, COMMAND_CALL, COMMAND_RUNNING)
    clock = _Clock()
    reader = AgyTranscripts(clock)
    reading = reader.read(str(path))
    # Each by when it was first read: agy writes the record as the command goes to the background.
    assert [(t.task_id, t.command, t.seen_at) for t in reading.tasks] == [(TASK, "sleep 40; echo CHARLIE", 1000.0)]
    clock.now += 30
    assert reader.read(str(path)).tasks[0].seen_at == 1000.0
    # Read on from where it stopped: the command's end, then a subagent.
    _write(path, COMMAND_ENDED, SUBAGENT_CALL, SUBAGENT_CREATED)
    reading = reader.read(str(path))
    assert reading.tasks == ()
    assert [(s.conversation, s.role) for s in reading.subagents] == [(CHILD, "Sleep Worker")]
    assert reading.subagents[0].prompt.startswith("Run `sleep 30` using run_command")
    # A line still being written waits for its end.
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(COMMAND_RUNNING)[:40])
    assert reader.read(str(path)).tasks == ()
    # A file written anew is read from its start.
    _write(path, COMMAND_RUNNING, mode="w")
    assert [t.task_id for t in reader.read(str(path)).tasks] == [TASK]
    assert reader.read(str(tmp_path / "missing.jsonl")) is None


def _post(sid, name, conversation=PARENT, transcript=None, said="Run it in the background", **fields):
    return {**BASE, "hookEventName": name, ITERM_SESSION_FIELD: sid, "conversationId": conversation,
            "lastUserInput": said, "transcriptPath": str(transcript or "/nowhere.jsonl"), **fields}


def _work(hooks, sid):
    return [(item.kind, item.text, item.holds_turn) for item in work_items(hooks.registry.get(sid))]


async def test_a_command_left_running_in_the_background_holds_the_turn_until_its_end_wakes_the_tab(agy_hooks, tmp_path):
    transcript = tmp_path / "transcript_full.jsonl"
    [sid] = agy_hooks.tabs(("s1", "agy --model gemini-4-neon-high", 140))
    await agy_hooks.post("/hook/agy", _post(sid, "SessionStart", transcript=transcript))
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", transcript=transcript))
    _write(transcript, COMMAND_CALL, COMMAND_RUNNING)
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", transcript=transcript, fullyIdle=False))
    assert agy_hooks.state(sid) == "done"
    assert _work(agy_hooks, sid) == [("shell", "sleep 40; echo CHARLIE", True)]
    # Its end is a message to the conversation, which starts a turn of its own.
    _write(transcript, COMMAND_ENDED)
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", transcript=transcript))
    assert (agy_hooks.state(sid), _work(agy_hooks, sid)) == ("working", [])
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", transcript=transcript, fullyIdle=True))
    assert (agy_hooks.state(sid), _work(agy_hooks, sid)) == ("done", [])


async def test_a_stop_with_nothing_left_running_reads_no_work(agy_hooks, tmp_path):
    transcript = tmp_path / "transcript_full.jsonl"
    _write(transcript, COMMAND_CALL, COMMAND_RUNNING)
    [sid] = agy_hooks.tabs(("s1", "agy", 141))
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", transcript=transcript))
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", transcript=transcript, fullyIdle=True))
    assert (agy_hooks.state(sid), _work(agy_hooks, sid)) == ("done", [])


async def test_a_subagent_is_a_child_of_its_parents_tab_and_never_takes_the_tab_over(agy_hooks, tmp_path):
    transcript = tmp_path / "transcript_full.jsonl"
    child_transcript = tmp_path / "child.jsonl"
    [sid] = agy_hooks.tabs(("s1", "agy", 142))
    await agy_hooks.post("/hook/agy", _post(sid, "SessionStart", transcript=transcript))
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", transcript=transcript))
    _write(transcript, SUBAGENT_CALL, SUBAGENT_CREATED)

    def child(name, **fields):
        return _post(sid, name, conversation=CHILD, transcript=child_transcript, said="", **fields)

    await agy_hooks.post("/hook/agy", child("SessionStart"))
    await agy_hooks.post("/hook/agy", child("PreInvocation"))
    tab = agy_hooks.registry.get(sid)
    assert (tab.conversation_id, tab.transcript) == (PARENT, str(transcript))
    assert agy_hooks.state(sid) == "working"
    # The parent's turn ends while its child works: it waits on the child, as Claude's does.
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", transcript=transcript, fullyIdle=False))
    assert agy_hooks.state(sid) == "working"
    assert [(i.kind, i.display_label) for i in work_items(agy_hooks.registry.get(sid))] == [("subagent", "Sleep Worker")]
    # The child's own command keeps it alive; its turns never move the tab's.
    await agy_hooks.post("/hook/agy", child("Stop", fullyIdle=False))
    await agy_hooks.post("/hook/agy", child("PreInvocation"))
    assert agy_hooks.state(sid) == "working"
    # Its answer wakes the parent, whose Stop comes before the child's last (agy 1.5.18 says fullyIdle false there).
    _write(transcript, SUBAGENT_ANSWERED)
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", transcript=transcript))
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", transcript=transcript, fullyIdle=False))
    assert agy_hooks.state(sid) == "working"
    await agy_hooks.post("/hook/agy", child("Stop", fullyIdle=True))
    assert (agy_hooks.state(sid), _work(agy_hooks, sid)) == ("done", [])
    assert agy_hooks.registry.get(sid).conversation_id == PARENT


async def test_a_new_conversation_of_the_tabs_own_still_takes_the_tab(agy_hooks):
    [sid] = agy_hooks.tabs(("s1", "agy", 143))
    await agy_hooks.post("/hook/agy", _post(sid, "SessionStart"))
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", fullyIdle=True))
    # /clear, then a prompt: agy's hooks speak with the prompt.
    await agy_hooks.post("/hook/agy", _post(sid, "SessionStart", conversation=CHILD, said="Start over"))
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", conversation=CHILD, said="Start over"))
    assert (agy_hooks.registry.get(sid).conversation_id, agy_hooks.state(sid)) == (CHILD, "working")


def _read(hooks, sid):
    """The tick's Antigravity read of the tab, applied."""
    plan = background_plan(hooks.status, hooks.router.agy_transcripts, [hooks.registry.get(sid)])
    return plan.apply(plan.read())


async def test_a_status_line_that_stops_counting_ends_the_commands_it_counted(agy_hooks, tmp_path):
    transcript = tmp_path / "transcript_full.jsonl"
    [sid] = agy_hooks.tabs(("s1", "agy", 144))
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", transcript=transcript))
    # It counts a command seconds after the command went to the background: none counted yet ends nothing.
    _write(transcript, COMMAND_CALL, COMMAND_RUNNING)
    _read(agy_hooks, sid)
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="working", conversation_id=PARENT))
    agy_hooks.clock.now += 6
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="working", conversation_id=PARENT, task_count=1))
    agy_hooks.clock.now += 5
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", transcript=transcript, fullyIdle=False))
    assert _work(agy_hooks, sid) == [("shell", "sleep 40; echo CHARLIE", True)]
    # Killed, say: no message ends it in the transcript, but the count does.
    agy_hooks.clock.now += 5
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="idle", conversation_id=PARENT))
    assert (agy_hooks.state(sid), _work(agy_hooks, sid)) == ("done", [])
    # And the transcript, read again, does not bring it back.
    _read(agy_hooks, sid)
    assert _work(agy_hooks, sid) == []


async def test_a_command_that_went_to_the_background_after_the_last_count_outlives_a_zero_count(agy_hooks, tmp_path):
    """Command B starts while A runs, and goes to the background only after A's last count and A's end: the reading
    that counts none ends A, never B."""
    transcript = tmp_path / "transcript_full.jsonl"
    [sid] = agy_hooks.tabs(("s1", "agy", 146))
    await agy_hooks.post("/hook/agy", _post(sid, "SessionStart", transcript=transcript))
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", transcript=transcript))
    first = {**COMMAND_RUNNING, "content": COMMAND_RUNNING["content"].replace(TASK, f"{PARENT}/task-1")}
    _write(transcript, first)
    _read(agy_hooks, sid)
    agy_hooks.clock.now += 10
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="working", conversation_id=PARENT, task_count=1))
    agy_hooks.clock.now += 1
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="working", conversation_id=PARENT))
    agy_hooks.clock.now += 3
    _write(transcript, COMMAND_RUNNING)
    _read(agy_hooks, sid)
    agy_hooks.clock.now += 1
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", transcript=transcript, fullyIdle=False))
    assert _work(agy_hooks, sid) == [("shell", "sleep 40; echo CHARLIE", True)]
    assert [job.task_id for job in agy_hooks.registry.get(sid).stop_work] == [TASK]


async def test_a_daemon_restarted_while_a_subagent_works_binds_the_tab_to_the_parent(agy_hooks, tmp_path):
    transcript = tmp_path / "transcript_full.jsonl"
    [sid] = agy_hooks.tabs(("s1", "agy", 147))
    assert agy_hooks.registry.get(sid).conversation_id is None
    child = {"conversation": CHILD, "transcript": tmp_path / "child.jsonl", "said": ""}
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", **child))
    assert agy_hooks.registry.get(sid).conversation_id is None
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", transcript=transcript))
    assert agy_hooks.registry.get(sid).conversation_id == PARENT
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", transcript=transcript, fullyIdle=False))
    assert agy_hooks.state(sid) == "working"
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", fullyIdle=True, **child))
    assert (agy_hooks.state(sid), agy_hooks.registry.get(sid).conversation_id) == ("done", PARENT)


async def test_a_command_shows_while_the_turn_works_and_leaves_once_it_ended(agy_hooks, tmp_path):
    transcript = tmp_path / "transcript_full.jsonl"
    [sid] = agy_hooks.tabs(("s1", "agy", 145))
    await agy_hooks.post("/hook/agy", _post(sid, "SessionStart", transcript=transcript))
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", transcript=transcript))
    _write(transcript, COMMAND_CALL, COMMAND_RUNNING)

    def tick():
        return _read(agy_hooks, sid)

    assert tick() == [sid]
    assert (agy_hooks.state(sid), _work(agy_hooks, sid)) == ("working", [("shell", "sleep 40; echo CHARLIE", False)])
    # The turn stops, the command ends, its message wakes the tab and the tab stops again, all between two ticks.
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", transcript=transcript, fullyIdle=False))
    _write(transcript, COMMAND_ENDED)
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", transcript=transcript))
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", transcript=transcript, fullyIdle=True))
    tick()
    assert (agy_hooks.state(sid), _work(agy_hooks, sid)) == ("done", [])


async def test_a_command_counted_soon_after_it_was_seen_still_ends_with_a_later_zero_count(agy_hooks, tmp_path):
    transcript = tmp_path / "transcript_full.jsonl"
    [sid] = agy_hooks.tabs(("s1", "agy", 148))
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", transcript=transcript))
    _write(transcript, COMMAND_RUNNING)
    _read(agy_hooks, sid)
    agy_hooks.clock.now += 3
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="working", conversation_id=PARENT, task_count=1))
    agy_hooks.clock.now += 1
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", transcript=transcript, fullyIdle=False))
    assert _work(agy_hooks, sid) == [("shell", "sleep 40; echo CHARLIE", True)]
    agy_hooks.clock.now += 60
    await agy_hooks.post("/statusline/agy", _tick(sid, agent_state="idle", conversation_id=PARENT))
    assert (agy_hooks.state(sid), _work(agy_hooks, sid)) == ("done", [])


async def test_a_listed_command_whose_end_is_in_the_transcript_leaves_the_stops_work_on_the_tick(agy_hooks, tmp_path):
    # Its end normally starts a turn; should that turn's hook be lost, the tick still ends it.
    transcript = tmp_path / "transcript_full.jsonl"
    [sid] = agy_hooks.tabs(("s1", "agy", 149))
    await agy_hooks.post("/hook/agy", _post(sid, "PreInvocation", transcript=transcript))
    _write(transcript, COMMAND_RUNNING)
    await agy_hooks.post("/hook/agy", _post(sid, "Stop", transcript=transcript, fullyIdle=False))
    assert _work(agy_hooks, sid) == [("shell", "sleep 40; echo CHARLIE", True)]
    _write(transcript, COMMAND_ENDED)
    _read(agy_hooks, sid)
    assert (agy_hooks.state(sid), _work(agy_hooks, sid)) == ("done", [])


def test_a_subagent_launch_that_failed_never_names_the_next_one(tmp_path):
    path = tmp_path / "transcript_full.jsonl"
    failed = {**SUBAGENT_CALL, "step_index": 5, "tool_calls": [{"name": "invoke_subagent", "args": {
        "Prompt": "Review the API changes.", "Role": "Reviewer", "TypeName": "self"}}]}
    _write(path, failed, {"step_index": 6, "source": "MODEL", "type": "GENERIC", "status": "ERROR",
                          "content": "invoke_subagent failed"}, SUBAGENT_CALL, SUBAGENT_CREATED)
    [child] = AgyTranscripts().read(str(path)).subagents
    assert (child.conversation, child.role) == (CHILD, "Sleep Worker")
