import pytest
from aitermd.models import (
    AGENT_BINARIES, HARNESS_BY_AGENT, USAGE_VENDORS, Frame, SessionInfo, StoppedOn, Usage,
    UsageWindow, classify_agent,
)


def test_the_harness_table_derives_what_each_agent_is():
    assert AGENT_BINARIES == {"claude", "codex", "pi"}
    # Claude's posts are placed by the agent's pid, everyone else's by the tab the header names.
    assert {a: h.placement for a, h in HARNESS_BY_AGENT.items()} == {
        "claude": "pid_file", "codex": "header", "pi": "header"}
    assert USAGE_VENDORS == ("claude", "codex")


def test_frame_from_json():
    f = Frame.from_json({"x": 324, "y": 36.5, "w": 1104, "h": 852})
    assert (f.x, f.y, f.w, f.h) == (324, 36.5, 1104, 852)


@pytest.mark.parametrize("field,bad", [
    # Stricter than float(), deliberately: the app always encodes a frame's coordinates as numbers.
    ("x", "324"),
    ("w", float("inf")), ("w", float("-inf")), ("w", float("nan")), ("w", True), ("w", False), ("w", None),
    ("x", 10**1000),
], ids=["numeric-string", "inf", "-inf", "nan", "True", "False", "None", "too-large-an-integer"])
def test_frame_rejects_what_is_not_a_finite_number(field, bad):
    with pytest.raises(ValueError):
        Frame.from_json({"x": 324, "y": 36, "w": 1104, "h": 852} | {field: bad})


def test_classify_agent_uses_basename_of_first_token():
    assert classify_agent("claude") == "claude"
    assert classify_agent("/Users/x/.local/bin/claude --model opus") == "claude"
    assert classify_agent("codex -m gpt-5.6") == "codex"
    assert classify_agent("-zsh") == "shell"
    assert classify_agent("node /opt/homebrew/bin/pi") == "pi"
    assert classify_agent("node /opt/homebrew/bin/not-pi") == "shell"
    assert classify_agent(None) == "shell"
    assert classify_agent("") == "shell"


def test_classify_agent_ignores_case_of_the_process_name():
    # Claude Code sets its own process title and, depending on how the session was
    # started, argv[0] is "Claude" rather than "claude" (verified live with `ps`:
    # two concurrent sessions, one of each). A case-sensitive match left those
    # sessions classified as a plain shell, so the sidebar kept the terminal avatar.
    assert classify_agent("Claude") == "claude"
    assert classify_agent("/Users/x/.local/bin/Claude --model opus") == "claude"
    assert classify_agent("Codex") == "codex"


def test_classify_pi_including_its_node_shebang_process():
    assert classify_agent("pi --model openai/gpt") == "pi"
    assert classify_agent("/opt/homebrew/bin/PI") == "pi"
    assert classify_agent("/opt/homebrew/bin/node /opt/homebrew/bin/pi --model openai/gpt") == "pi"
    assert classify_agent("node worker.js") == "shell"


def test_session_info_json_is_camel_case_and_drops_job_pid():
    # Neither the process id nor the transcript's path is sent.
    s = SessionInfo("s1", "w1", 0, "t1", None, "claude", "working", "✳ Claude Code", "/repo", 4242,
                    agent_cwd="/repo/.worktrees/x", transcript="/p/c.jsonl",
                    stopped_on=StoppedOn("rate_limit", 1793017200, at=1002.0))
    assert s.to_json() == {
        "sessionId": "s1", "windowId": "w1", "tabIndex": 0, "taskId": "t1", "projectId": None,
        "agent": "claude",
        "state": "working", "cwd": "/repo",
        "agentCwd": "/repo/.worktrees/x", "active": False, "contextPercent": None, "contextTokens": None,
        "conversationId": None, "terminalId": None, "tabKey": None, "work": [], "yourPrompt": None,
        "stoppedOn": {"error": "rate_limit", "resetsAt": 1793017200},
        "testActivity": None,
    }


def test_session_json_omits_unused_metadata():
    session = SessionInfo("s1", "w1", 0, None, None, "claude", "idle", "Claude", "/wt", 1)
    assert not {"model", "reasoning", "title", "subagentsWrittenAt", "slashCommands"} & session.to_json().keys()


def test_usage_json():
    u = Usage(UsageWindow(23, 1790172996), None, None, 1789568196)
    assert u.to_json() == {"fiveHour": {"usedPercent": 23, "resetsAt": 1790172996}, "sevenDay": None, "spend": None,
                           "updatedAt": 1789568196, "retrievalFailure": None}


def test_display_labels_do_not_replace_raw_work_or_its_readiness():
    from aitermd.models import BackgroundJob, work_items
    session = SessionInfo("s", "w", 0, None, None, "claude", "done", "", "/wt", 1)
    session.stop_work = (BackgroundJob("shell", "scripts/test.sh", task_id="gate", display_label="Run the gate"),)
    session.shown_shells = (BackgroundJob("shell", "scripts/test.sh", task_id="gate"),)
    session.shown_subagents = (BackgroundJob("subagent", "default", agent_id="child", display_label="Review checkout"),)
    assert [item.to_json() for item in work_items(session)] == [
        {"kind": "shell", "text": "scripts/test.sh", "holdsTurn": True, "idle": False, "displayLabel": "Run the gate"},
        {"kind": "subagent", "text": "default", "holdsTurn": False, "idle": False, "displayLabel": "Review checkout"},
    ]
    session.stop_work = ()
    assert work_items(session)[0].text == "default"
    assert not work_items(session)[0].holds_turn
