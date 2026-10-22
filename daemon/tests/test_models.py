import pytest
from aitermd.models import (
    AGENT_BINARIES, HARNESS_BY_AGENT, USAGE_VENDORS, Frame, SessionInfo, Usage,
    UsageWindow, classify_agent,
)


def test_the_harness_table_derives_what_each_agent_is():
    assert AGENT_BINARIES == {"claude", "codex", "pi"}
    # Claude's posts are placed by the agent's pid, everyone else's by the tab the header names.
    assert {a: h.placement for a, h in HARNESS_BY_AGENT.items()} == {
        "claude": "pid_file", "codex": "header", "pi": "header"}
    # PI has no tick signal: what its hooks say stands.
    assert {a: h.corroboration for a, h in HARNESS_BY_AGENT.items()} == {
        "claude": "claude_file", "codex": "codex_title", "pi": None}
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
    s = SessionInfo("s1", "w1", 0, "t1", None, "claude", "claude-opus-5", "working", "✳ Claude Code", "/repo", 4242,
                    agent_cwd="/repo/.worktrees/x")
    assert s.to_json() == {
        "sessionId": "s1", "windowId": "w1", "tabIndex": 0, "taskId": "t1", "projectId": None,
        "agent": "claude", "model": "claude-opus-5", "reasoning": None,
        "state": "working", "title": "✳ Claude Code", "cwd": "/repo",
        "agentCwd": "/repo/.worktrees/x", "active": False, "contextPercent": None,
        "conversationId": None, "terminalId": None, "tabKey": None, "background": [], "yourPrompt": None,
    }


def test_usage_json():
    u = Usage(UsageWindow(23, 1790172996), None, None, "max", 1789568196)
    assert u.to_json() == {"fiveHour": {"usedPercent": 23, "resetsAt": 1790172996}, "sevenDay": None, "spend": None, "plan": "max",
                           "updatedAt": 1789568196}
