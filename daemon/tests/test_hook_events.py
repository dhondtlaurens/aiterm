import pytest
from aitermd.models import BackgroundJob, UsageWindow
from aitermd.agents.claude import parse_claude_hook, parse_claude_statusline
from aitermd.agents.codex import parse_codex_hook
from aitermd.agents.pi import parse_pi_hook

BASE = {"session_id": "abc", "cwd": "/repo/.worktrees/x", "transcript_path": "/t.jsonl", "permission_mode": "default"}
PI_BASE = {"session_id": "pi-session", "cwd": "/repo/.worktrees/x",
           "model": "openai-codex/gpt-5.6-sol", "reasoning": "high", "context_percent": 42.6,
           "_aiterm_iterm_session_id": "w0t0p0:pi-tab"}


@pytest.mark.parametrize("payload,kind", [
    ({**BASE, "hook_event_name": "SessionStart", "source": "startup", "model": "claude-opus-5"}, "sessionStart"),
    ({**BASE, "hook_event_name": "SessionStart", "source": "clear"}, "sessionStart"),
    # A compaction reports SessionStart mid-turn: metadata only, not a new conversation.
    ({**BASE, "hook_event_name": "SessionStart", "source": "compact", "model": "claude-opus-5"}, None),
    ({**BASE, "hook_event_name": "UserPromptSubmit", "user_prompt": "hi"}, "working"),
    ({**BASE, "hook_event_name": "Stop", "stop_reason": "end_turn"}, "done"),
    ({**BASE, "hook_event_name": "PermissionRequest", "tool_name": "Bash"}, "needsInput"),
    ({**BASE, "hook_event_name": "Notification", "notification_type": "permission_prompt"}, "needsInput"),
    ({**BASE, "hook_event_name": "Notification", "notification_type": "agent_needs_input"}, "needsInput"),
    ({**BASE, "hook_event_name": "Notification", "notification_type": "agent_completed"}, "done"),
])
def test_claude_hook_mapping(payload, kind):
    ev = parse_claude_hook(payload)
    assert ev.agent == "claude" and ev.kind == kind
    assert ev.session_id == "abc" and ev.cwd == "/repo/.worktrees/x"


def test_a_claude_post_from_inside_a_subagent_names_no_session_transcript():
    event = parse_claude_hook({**BASE, "hook_event_name": "PermissionRequest", "agent_id": "child-1"})
    assert event.transcript is None
    assert parse_claude_hook({**BASE, "hook_event_name": "SessionStart"}).transcript == BASE["transcript_path"]


def test_claude_idle_prompt_and_unknown_events_are_ignored():
    assert parse_claude_hook({**BASE, "hook_event_name": "Notification", "notification_type": "idle_prompt"}) is None
    assert parse_claude_hook({**BASE, "hook_event_name": "PreToolUse"}) is None
    assert parse_claude_hook({}) is None


def test_codex_hook_mapping():
    p = {"cwd": "/w", "hook_event_name": "SessionStart", "model": "gpt-5.6", "permission_mode": "default", "session_id": "th1",
         "source": "startup", "transcript_path": None}
    ev = parse_codex_hook(p)
    assert (ev.agent, ev.kind, ev.session_id, ev.cwd) == ("codex", "sessionStart", "th1", "/w")
    assert parse_codex_hook({**p, "hook_event_name": "Stop"}).kind == "done"
    assert parse_codex_hook({**p, "hook_event_name": "PermissionRequest"}).kind == "needsInput"
    assert parse_codex_hook({**p, "hook_event_name": "UserPromptSubmit"}).kind == "working"
    assert parse_codex_hook({**p, "hook_event_name": "PreToolUse"}) is None


@pytest.mark.parametrize("name,kind", [
    ("session_start", None),
    ("agent_start", "working"),
    ("ui_prompt_start", "promptStart"),
    ("ui_prompt_end", "promptEnd"),
    ("agent_settled", "done"),
    ("thinking_level_select", None),
    ("turn_end", None),
])
def test_pi_hook_mapping(name, kind):
    event = parse_pi_hook({**PI_BASE, "hook_event_name": name})
    assert event.agent == "pi" and event.kind == kind
    assert event.context_percent == 43
    assert event.iterm_session_id == "w0t0p0:pi-tab"


@pytest.mark.parametrize("reason,kind", [
    ("startup", "sessionStart"), ("new", "sessionStart"), ("resume", "sessionStart"), ("fork", "sessionStart"),
    # A reload re-runs the extensions inside the running conversation, like Claude's compaction.
    ("reload", None),
    # An extension from before `reason` was forwarded, or a reason PI adds later: metadata only.
    (None, None), ("teleport", None), (["startup"], None),
])
def test_pi_session_start_begins_a_conversation_unless_it_is_a_reload(reason, kind):
    event = parse_pi_hook({**PI_BASE, "hook_event_name": "session_start", "reason": reason})
    assert event.kind == kind


@pytest.mark.parametrize("raw,expected", [
    (True, None), ("43", None), (None, None), (-2, 0), (101, 100), (42.5, 42),
    (float("inf"), None), (float("-inf"), None), (float("nan"), None),
])
def test_pi_context_percent_rejects_non_numbers_and_clamps_numbers(raw, expected):
    assert parse_pi_hook({**PI_BASE, "hook_event_name": "session_start", "context_percent": raw}).context_percent == expected


def test_pi_hook_rejects_unknown_events_and_sanitizes_string_metadata():
    assert parse_pi_hook({**PI_BASE, "hook_event_name": "unknown"}) is None
    event = parse_pi_hook({**PI_BASE, "hook_event_name": "session_start",
                           "session_id": 7, "cwd": False, "model": ["bad"], "reasoning": 3})
    assert event.session_id is None and event.cwd is None


@pytest.mark.parametrize("parser,vendor", [(parse_claude_hook, "claude"), (parse_codex_hook, "codex")])
def test_subagent_lifecycle_hooks_identify_the_parent_session_and_child(parser, vendor):
    start = parser({**BASE, "hook_event_name": "SubagentStart", "agent_id": "child-1", "agent_type": "explorer"})
    stop = parser({**BASE, "hook_event_name": "SubagentStop", "agent_id": "child-1", "agent_type": "explorer"})
    assert (start.agent, start.kind, start.session_id, start.subagent_id) == (vendor, "subagentStart", "abc", "child-1")
    assert (stop.agent, stop.kind, stop.session_id, stop.subagent_id) == (vendor, "subagentStop", "abc", "child-1")


@pytest.mark.parametrize("payload,expected", [
    # SubagentStart carries only the session's transcript: the child's sits beside it, in <session>/subagents/.
    ({"transcript_path": "/p/sess.jsonl"}, "/p/sess/subagents/agent-child-1.jsonl"),
    # A path the hook gives for the child itself wins.
    ({"transcript_path": "/p/sess.jsonl", "agent_transcript_path": "/p/sess/subagents/wf/agent-child-1.jsonl"},
     "/p/sess/subagents/wf/agent-child-1.jsonl"),
    ({}, None),
    ({"transcript_path": "/p/sess.txt"}, None),
    ({"transcript_path": ["/p/sess.jsonl"]}, None),
])
def test_a_claude_subagent_start_names_the_childs_transcript(payload, expected):
    start = parse_claude_hook({"session_id": "abc", "cwd": "/x", "hook_event_name": "SubagentStart", "agent_id": "child-1", **payload})
    assert start.subagent_transcript == expected


def test_only_a_claude_subagent_start_names_a_transcript():
    assert parse_codex_hook({**BASE, "hook_event_name": "SubagentStart", "agent_id": "child-1"}).subagent_transcript is None
    assert parse_claude_hook({**BASE, "hook_event_name": "SubagentStop", "agent_id": "child-1"}).subagent_transcript is None


def _task(id_, type_, status="running"):
    return {"id": id_, "type": type_, "status": status, "description": "…"}


@pytest.mark.parametrize("tasks,expected", [
    # Claude Code lists in-flight background work only; a subagent's task id is its agent_id.
    ([], frozenset()),
    ([_task("a1", "subagent"), _task("b1", "shell"), _task("m1", "monitor"), _task("t1", "MCP task")], frozenset({"a1"})),
    ([_task("a1", "subagent", "pending")], frozenset({"a1"})),
    ([_task("a1", "subagent", "completed")], frozenset()),
    # A teammate's task id is not the agent_id its hooks carry, and a workflow's agents sit behind the
    # workflow's own id: with either in flight, no child can be proven gone.
    ([_task("a1", "subagent"), _task("t-9", "teammate")], None),
    ([_task("w1", "workflow")], None),
    ([_task("x1", "something new")], None),
    ([_task(7, "subagent")], None),
    (["a1"], None),
    # An older Claude Code, or a registry it could not reach, sends no list: nothing is known.
    (None, None),
    ("a1", None),
])
def test_a_claude_stop_lists_the_subagents_still_running(tasks, expected):
    payload = {**BASE, "hook_event_name": "Stop"} if tasks is None else {**BASE, "hook_event_name": "Stop", "background_tasks": tasks}
    assert parse_claude_hook(payload).running_subagents == expected


def test_a_claude_stop_lists_the_background_work_still_running():
    """What will wake the session again once it ends, each by its kind: a shell by its command, a subagent, a monitor
    and any other task by its description, a subagent with its agent_id. Work that has ended wakes nothing, and a
    subagent with no id is no child the daemon could count."""
    tasks = [{"id": "a1", "type": "subagent", "status": "running", "description": "Fix it"},
             {"type": "subagent", "status": "running", "description": "Nobody's"},
             {"id": "b1", "type": "shell", "status": "running", "description": "the gate", "command": "npm run test:run"},
             {"id": "b2", "type": "shell", "status": "completed", "description": "lint", "command": "npm run lint"},
             {"id": "m1", "type": "monitor", "status": "pending", "description": "CI on !46"},
             {"id": "t1", "type": "MCP task", "status": "running", "description": "Indexing the docs"}]
    event = parse_claude_hook({**BASE, "hook_event_name": "Stop", "background_tasks": tasks})
    assert event.background_work == (BackgroundJob("subagent", "Fix it", agent_id="a1"),
                                     BackgroundJob("shell", "npm run test:run", task_id="b1"),
                                     BackgroundJob("monitor", "CI on !46", task_id="m1"),
                                     BackgroundJob("task", "Indexing the docs", task_id="t1"))
    assert [job.to_json() for job in event.background_work][0] == {"kind": "subagent", "text": "Fix it"}
    assert parse_claude_hook({**BASE, "hook_event_name": "Stop", "background_tasks": []}).background_work == ()
    # An older Claude Code sends no list: nothing is known.
    assert parse_claude_hook({**BASE, "hook_event_name": "Stop"}).background_work is None
    assert parse_claude_hook({**BASE, "hook_event_name": "UserPromptSubmit", "background_tasks": tasks}).background_work is None


def test_a_claude_stop_leaves_out_its_artifact_watches():
    """Claude Code watches every artifact it publishes or is asked to watch for comments, for the rest of the session:
    a monitor that never ends and that Claude Code itself counts as no activity. A monitor you armed still counts."""
    tasks = [{"id": "w1", "type": "monitor", "status": "running",
              "description": "live updates for artifact https://claude.ai/artifact/6xDD (auto-armed on publish)"},
             {"id": "w2", "type": "monitor", "status": "running",
              "description": "live updates for artifact https://claude.ai/artifact/MnYZ (watch requested)"},
             {"id": "m1", "type": "monitor", "status": "running", "description": "CI on !46"},
             {"id": "m2", "type": "monitor", "status": "running", "description": "live updates for artifact deploys",
              "server": "ci", "tool": "watch"}]
    event = parse_claude_hook({**BASE, "hook_event_name": "Stop", "background_tasks": tasks})
    assert event.background_work == (BackgroundJob("monitor", "CI on !46", task_id="m1"),
                                     BackgroundJob("monitor", "live updates for artifact deploys", task_id="m2"))
    assert event.running_subagents == frozenset()


def test_a_prompt_submitted_carries_its_text():
    assert parse_claude_hook({**BASE, "hook_event_name": "UserPromptSubmit", "prompt": "Fix it"}).prompt == "Fix it"
    assert parse_codex_hook({**BASE, "hook_event_name": "UserPromptSubmit", "prompt": "Fix it"}).prompt == "Fix it"
    assert parse_claude_hook({**BASE, "hook_event_name": "Stop", "prompt": "Fix it"}).prompt is None


def test_only_a_claude_stop_lists_running_subagents():
    tasks = {"background_tasks": []}
    assert parse_claude_hook({**BASE, "hook_event_name": "SubagentStop", "agent_id": "a1", **tasks}).running_subagents is None
    assert parse_claude_hook({**BASE, "hook_event_name": "UserPromptSubmit", **tasks}).running_subagents is None
    assert parse_codex_hook({**BASE, "hook_event_name": "Stop", **tasks}).running_subagents is None


def test_pi_subagent_lifecycle_identifies_the_parent_session_and_child():
    start = parse_pi_hook({**PI_BASE, "hook_event_name": "subagent_start", "agent_id": "child-1"})
    stop = parse_pi_hook({**PI_BASE, "hook_event_name": "subagent_stop", "agent_id": "child-1"})
    assert (start.agent, start.kind, start.session_id, start.subagent_id) == ("pi", "subagentStart", "pi-session", "child-1")
    assert (stop.agent, stop.kind, stop.session_id, stop.subagent_id) == ("pi", "subagentStop", "pi-session", "child-1")
    assert start.iterm_session_id == "w0t0p0:pi-tab"


@pytest.mark.parametrize("name", ["subagent_start", "subagent_stop"])
def test_pi_subagent_event_without_a_child_id_is_ignored(name):
    assert parse_pi_hook({**PI_BASE, "hook_event_name": name}) is None
    assert parse_pi_hook({**PI_BASE, "hook_event_name": name, "agent_id": 7}) is None


def test_statusline_usage():
    usage = parse_claude_statusline({"rate_limits": {
        "five_hour": {"used_percentage": 23.4, "resets_at": 1738425600},
        "seven_day": {"used_percentage": 61, "resets_at": 1738900000}}}, now=1700000000).usage
    assert usage.five_hour == UsageWindow(23, 1738425600)
    assert usage.seven_day == UsageWindow(61, 1738900000)
    assert usage.spend is None and usage.updated_at == 1700000000


@pytest.mark.parametrize("rate_limits", [None, "invalid", {}, {"five_hour": {"used_percentage": "bad"}},
                                        {"five_hour": {"used_percentage": True}}])
def test_statusline_without_usable_rate_limits_gives_empty_usage(rate_limits):
    usage = parse_claude_statusline({"rate_limits": rate_limits}, now=1).usage
    assert usage.five_hour is None and usage.seven_day is None


def test_statusline_rejects_a_boolean_reset_time():
    usage = parse_claude_statusline({"rate_limits": {"seven_day": {"used_percentage": 50, "resets_at": True}}}, now=1).usage
    assert usage.seven_day == UsageWindow(50, None)


def test_statusline_carries_the_session_it_describes():
    tick = parse_claude_statusline({"session_id": "abc", "cwd": "/wt", "_aiterm_iterm_session_id": "w0t0p0:t"}, now=1)
    assert (tick.session_id, tick.cwd, tick.iterm_session_id) == ("abc", "/wt", "w0t0p0:t")


@pytest.mark.parametrize("bad", [{"not": "a string"}, ["m"], 7, ""])
def test_statusline_fields_that_are_not_strings_are_none(bad):
    # A dict session id cannot key a pin.
    tick = parse_claude_statusline({"session_id": bad, "cwd": bad, "model": {"id": bad}}, now=1)
    assert (tick.session_id, tick.cwd) == (None, None)


def test_hooks_ignore_non_dict_payloads():
    # parse_claude_hook with list payload
    assert parse_claude_hook([]) is None
    assert parse_claude_hook("string") is None
    assert parse_claude_hook(None) is None

    # parse_codex_hook with non-dict payloads
    assert parse_codex_hook([]) is None
    assert parse_codex_hook("x") is None
    assert parse_codex_hook(None) is None


def test_statusline_carries_the_context_window_fill():
    payload = {"session_id": "abc", "model": {"id": "claude-opus-5"},
               "context_window": {"used_percentage": 42.6}}
    assert parse_claude_statusline(payload, now=1).context_percent == 43


@pytest.mark.parametrize("cw", [
    None,                                   # absent entirely
    "invalid",                              # not a dict
    {},                                     # no used_percentage
    {"used_percentage": "78"},              # a string, not a number
    {"used_percentage": True},              # bool is an int subclass; must not read as 1
    {"used_percentage": float("inf")},      # json.loads accepts Infinity; int() would raise
    {"used_percentage": float("nan")},      # json.loads accepts NaN; round() would raise
])
def test_statusline_context_is_none_when_unusable(cw):
    payload = {"model": {"id": "m"}}
    if cw is not None:
        payload["context_window"] = cw
    assert parse_claude_statusline(payload, now=1).context_percent is None


@pytest.mark.parametrize("raw,expected", [(-5, 0), (0, 0), (100, 100), (140, 100)])
def test_statusline_context_is_clamped_to_a_percentage(raw, expected):
    payload = {"context_window": {"used_percentage": raw}}
    assert parse_claude_statusline(payload, now=1).context_percent == expected


@pytest.mark.parametrize("bad", [float("inf"), float("nan"), 10 ** 400], ids=["inf", "nan", "huge"])
def test_statusline_windows_reject_non_finite_numbers(bad):
    payload = {"rate_limits": {"five_hour": {"used_percentage": bad},
                               "seven_day": {"used_percentage": 5, "resets_at": bad}}}
    usage = parse_claude_statusline(payload, now=1).usage
    assert usage.five_hour is None
    assert usage.seven_day == UsageWindow(5, None)


@pytest.mark.parametrize("parser", [parse_claude_hook, parse_codex_hook])
def test_claude_and_codex_hooks_sanitize_string_fields(parser):
    event = parser({"hook_event_name": "SessionStart", "session_id": 7, "cwd": False, "model": ["bad"],
                    "_aiterm_iterm_session_id": {"x": 1}})
    assert event.session_id is None and event.cwd is None
    assert event.iterm_session_id is None
    assert parser({"hook_event_name": "SubagentStart", "agent_id": ""}) is None


@pytest.mark.parametrize("parser", [parse_claude_hook, parse_codex_hook, parse_pi_hook])
@pytest.mark.parametrize("bad", [["Stop"], {"name": "Stop"}, 7, None])
def test_a_type_confused_event_name_is_ignored_not_raised(parser, bad):
    assert parser({**BASE, "hook_event_name": bad}) is None


@pytest.mark.parametrize("bad", [["permission_prompt"], {"type": "permission_prompt"}])
def test_a_type_confused_notification_type_is_ignored(bad):
    assert parse_claude_hook({**BASE, "hook_event_name": "Notification", "notification_type": bad}) is None


@pytest.mark.parametrize("parse,payload", [
    (parse_claude_hook, {**BASE, "hook_event_name": "Stop"}),
    (parse_claude_hook, {**BASE, "hook_event_name": "SubagentStart", "agent_id": "c1"}),
    (parse_codex_hook, {**BASE, "hook_event_name": "SessionStart"}),
    (parse_codex_hook, {**BASE, "hook_event_name": "Stop"}),
    (parse_pi_hook, {**PI_BASE, "hook_event_name": "agent_start"}),
])
def test_an_event_carries_the_name_its_harness_gave_it(parse, payload):
    # The resolver binds a Codex thread by which event bound it, from the event rather than the raw body.
    ev = parse(payload)
    assert ev is not None and ev.event_name == payload["hook_event_name"]


def test_a_hook_names_its_sessions_conversation():
    assert parse_claude_hook({**BASE, "hook_event_name": "UserPromptSubmit"}).conversation_id == "abc"
    assert parse_codex_hook({"hook_event_name": "Stop", "session_id": "thread-1", "cwd": "/wt"}).conversation_id == "thread-1"
    assert parse_pi_hook({**PI_BASE, "hook_event_name": "agent_start"}).conversation_id == "pi-session"


def test_a_subagents_start_and_stop_name_no_conversation():
    for name in ("SubagentStart", "SubagentStop"):
        ev = parse_codex_hook({"hook_event_name": name, "session_id": "thread-2", "cwd": "/wt", "agent_id": "child-1"})
        assert ev is not None and ev.conversation_id is None, name
        ev = parse_claude_hook({**BASE, "hook_event_name": name, "agent_id": "child-1"})
        assert ev is not None and ev.conversation_id is None, name


def test_claude_stop_with_unhashable_task_type_cannot_prove_subagents_finished():
    event = parse_claude_hook({"hook_event_name": "Stop", "background_tasks": [{"type": []}]})
    assert event.running_subagents is None


def test_claude_route_drops_payloads_from_another_cli_running_claudes_hooks():
    # Another CLI that loads ~/.claude/settings.json hooks sends `hookEventName`, a key Claude
    # never sends; were it to reach the Claude route, it must not count as Claude.
    assert parse_claude_hook({**BASE, "hook_event_name": "Stop", "hookEventName": "stop"}) is None
