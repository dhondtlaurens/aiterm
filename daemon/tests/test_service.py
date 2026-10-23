# daemon/tests/test_service.py
import asyncio
import gc
import json
import os
import subprocess
import sys
import textwrap
import threading
import time
from pathlib import Path

import pytest

from aitermd import service
from aitermd.codex_sessions import CodexSessionFiles
from aitermd.hooks_server import HookServer
from aitermd.iterm_bridge import ItermUnavailable
from aitermd.models import BackgroundJob, Frame
from tests.conftest import wait_until
from tests.fake_iterm import FakeIterm

FRAME = {"x": 324, "y": 36, "w": 1104, "h": 852}


@pytest.fixture
async def stack(make_service):
    """A started service with an app attached: the service, its FakeIterm, its Claude session
    files, and the app's end of the RPC socket."""
    svc = make_service()
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    yield svc, svc.iterm, svc.claude_files, r, w
    w.close()


async def call(r, w, method, params=None, id_=1):
    w.write((json.dumps({"id": id_, "method": method, "params": params}) + "\n").encode())
    await w.drain()
    while True:
        msg = json.loads(await asyncio.wait_for(r.readline(), 2))
        if msg.get("id") == id_:
            return msg


async def next_event(r, name):
    while True:
        msg = json.loads(await asyncio.wait_for(r.readline(), 2))
        if msg.get("event") == name:
            return msg["payload"]


async def drain_events(r) -> list[dict]:
    """Every message already on its way to the app."""
    messages: list[dict] = []
    while True:
        try:
            line = await asyncio.wait_for(r.readline(), 0.2)
        except TimeoutError:
            return messages
        messages.append(json.loads(line))


async def post_hook(port, path, body):
    """Real HTTP POST against the daemon's HookServer port, the way the
    installed Claude/Codex hooks and the statusline shim actually talk to it
    (unlike svc.hook_router.handle_hook(...), which every other test calls in-process)."""
    r, w = await asyncio.open_connection("127.0.0.1", port)
    data = json.dumps(body).encode()
    w.write(f"POST {path} HTTP/1.1\r\nHost: x\r\nX-AiTerm-Hook: 1\r\n"
            f"Content-Type: application/json\r\nContent-Length: {len(data)}\r\n\r\n".encode() + data)
    await w.drain()
    status_line = await asyncio.wait_for(r.readline(), 2)
    w.close()
    return int(status_line.split()[1])


async def test_status_and_create_task_window(stack):
    svc, it, files, r, w = stack
    assert (await call(r, w, "iterm.status"))["result"] == {"connected": True, "version": "3.7.2", "authError": None}
    res = await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/repo/.worktrees/x", "title": "x",
                                                 "agentCommand": "claude --model opus", "frame": FRAME})
    wid = res["result"]["windowId"]
    assert it.windows[wid]["frame"].w == 1104 and it.windows[wid]["active"]
    assert it.sent == [(it.windows[wid]["sessions"][0], " claude --model opus\n")]
    await svc.tick()
    sessions = (await call(r, w, "sessions.list", id_=2))["result"]
    assert sessions[0]["taskId"] == "t1" and sessions[0]["state"] == "idle"


async def test_an_operators_command_is_typed_as_the_app_quoted_it(stack):
    """The Operator's command, quoted by the app, is typed as it is: nothing stripped or escaped
    again. Its first message stays in the run folder's file, read by the shell, never typed."""
    svc, it, files, r, w = stack
    folder = "/Users/me/Library/Application Support/AiTerm/operators/runs/R"
    cmd = ("claude --model 'claude-fable-5-1[1m]' --effort high --append-system-prompt-file"
           f" '{folder}/brief.md' --tools Read,Grep,Glob --add-dir '/code/it'\\''s a \"shop\" → é · 🚀'"
           f" --mcp-config '{folder}/mcp.json' --allowedTools 'mcp__aiterm__*' --strict-mcp-config"
           ' "$(command cat first-message.md)"')
    res = await call(r, w, "window.createTask", {"taskId": "R", "cwd": folder, "title": "Sprint", "agentCommand": cmd,
                                                 "frame": FRAME})
    wid = res["result"]["windowId"]
    assert it.sent == [(it.windows[wid]["sessions"][0], " " + cmd + "\n")]


async def test_user_tab_is_tagged_and_redirected(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = await it.user_opens_tab(wid, cwd="/Users/me")
    assert (sid, " cd /wt && clear\n") in it.sent
    assert it.sessions[sid].user_vars == {"aiterm_task": "t1"}
    await svc.tick()
    assert [s["taskId"] for s in (await call(r, w, "sessions.list", id_=3))["result"]] == ["t1", "t1"]


def gated_snapshots(it, fail_on: int | None = None):
    """Holds the first snapshot until `gate` is set, raises on call number `fail_on`, counts all."""
    gate, count, snapshot = asyncio.Event(), [0], it.snapshot

    async def gated():
        count[0] += 1
        if count[0] == 1:
            await gate.wait()
        if count[0] == fail_on:
            raise ItermUnavailable("iTerm2 did not answer within 10s")
        return await snapshot()

    it.snapshot = gated
    return gate, count


async def test_ticks_queued_behind_one_are_served_by_a_single_next_tick(stack):
    svc, it, files, r, w = stack
    gate, snapshots = gated_snapshots(it)
    first = asyncio.create_task(svc.tick())
    await wait_until(lambda: snapshots[0] == 1)
    # A change the running tick has already missed, so the queued ones still need a tick of their own.
    wid, sid = await it.create_window("/wt", "x", {"aiterm_task": "t1"}, Frame(0, 0, 10, 10))
    queued = [asyncio.create_task(svc.tick()) for _ in range(3)]
    await asyncio.sleep(0)
    gate.set()
    await asyncio.gather(first, *queued)
    assert snapshots[0] == 2, "one tick, started after all three asked, serves them all"
    assert svc.registry.get(sid) is not None


async def test_a_failed_tick_serves_nobody_queued_behind_it(stack):
    svc, it, files, r, w = stack
    gate, snapshots = gated_snapshots(it, fail_on=2)
    first = asyncio.create_task(svc.tick())
    await wait_until(lambda: snapshots[0] == 1)
    queued = [asyncio.create_task(svc.tick()) for _ in range(2)]
    await asyncio.sleep(0)
    gate.set()
    results = await asyncio.gather(first, *queued, return_exceptions=True)
    assert isinstance(results[1], ItermUnavailable) and results[2] is None
    assert snapshots[0] == 3, "the second waiter ran its own tick"


async def test_a_new_tab_reads_iterm2_once_for_itself_and_once_for_its_tick(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    snapshots = 0
    snapshot = it.snapshot

    async def counted():
        nonlocal snapshots
        snapshots += 1
        return await snapshot()

    it.snapshot = counted
    sid = await it.user_opens_tab(wid)
    assert it.sessions[sid].user_vars == {"aiterm_task": "t1"}
    assert snapshots == 1, "the new session is looked up on its own, not through a second snapshot"


async def test_a_new_session_missing_from_the_snapshot_still_refreshes_the_registry(stack):
    """The bridge's hierarchy can lag a new-session notification. Its session is then not tagged,
    but the tick must still run, so the registry does not miss what did change."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    other = await it._add_session(wid, "/wt", {}, command_line="-zsh", title="zsh")  # no notification
    await svc.windows.on_new_session("not-yet-listed")
    assert svc.registry.get(other) is not None


async def test_a_task_window_can_open_in_the_background(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME,
                                                  "background": True}))["result"]["windowId"]
    assert it.windows[wid]["background"] and not it.windows[wid]["active"]
    assert it.windows[wid]["frame"].w == 1104, "snapped beside the sidebar all the same"


async def test_a_task_window_comes_forward_unless_asked_not_to(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    assert not it.windows[wid]["background"] and it.windows[wid]["active"]


async def test_background_must_be_a_bool(stack):
    svc, it, files, r, w = stack
    reply = await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "frame": FRAME, "background": "yes"})
    assert reply["error"]["code"] == "bad_params" and it.windows == {}


async def test_a_window_created_before_its_tick_fails_is_still_returned(stack, caplog):
    """The window exists whatever the tick after it finds. An error would make the app retry, and
    a retried window.createTerminal, which has no dedupe, opens a second window."""
    svc, it, files, r, w = stack
    create_window = it.create_window

    async def created_then_unreadable(*args, **kwargs):
        created = await create_window(*args, **kwargs)
        it.snapshot_error = ItermUnavailable("iTerm2 did not answer within 10s")
        return created

    it.create_window = created_then_unreadable
    with caplog.at_level("ERROR", logger="aitermd.windows"):
        res = await call(r, w, "window.createTerminal", {"projectId": "p1", "cwd": "/repo", "frame": FRAME})
    assert res["result"]["windowId"] in it.windows
    assert len(it.windows) == 1
    assert "tick after creating a window or tab failed" in caplog.text


async def test_create_terminal_tags_the_window_with_its_terminal_id(stack):
    # The id a terminal row is adopted by, as a task's is: iTerm2 renumbers a window it restores.
    svc, it, files, r, w = stack
    terminal = {"projectId": "p1", "terminalId": "T1", "cwd": "/repo", "frame": FRAME}
    wid = (await call(r, w, "window.createTerminal", terminal))["result"]["windowId"]
    assert it.sessions[it.windows[wid]["sessions"][0]].user_vars == {"aiterm_project": "p1", "aiterm_terminal": "T1"}
    sid = (await call(r, w, "tab.create", {"windowId": wid}, id_=2))["result"]["sessionId"]
    assert it.sessions[sid].user_vars == {"aiterm_project": "p1", "aiterm_terminal": "T1"}
    listed = (await call(r, w, "sessions.list", id_=3))["result"]
    assert {s["terminalId"] for s in listed} == {"T1"}


async def test_a_tab_created_before_its_tick_fails_is_still_returned(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTerminal", {"projectId": "p1", "cwd": "/repo", "frame": FRAME}))["result"]["windowId"]
    it.snapshot_error = ItermUnavailable("iTerm2 did not answer within 10s")
    res = await call(r, w, "tab.create", {"windowId": wid}, id_=2)
    assert res["result"]["sessionId"] in it.sessions


async def test_a_closed_window_is_answered_ok_when_the_tick_after_fails(stack, caplog):
    """The window is gone whatever the tick after finds; the app removing a task must not read a
    failure into it."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTerminal", {"projectId": "p1", "cwd": "/repo", "frame": FRAME}))["result"]["windowId"]
    it.snapshot_error = ItermUnavailable("iTerm2 did not answer within 10s")
    with caplog.at_level("ERROR", logger="aitermd.service"):
        res = await call(r, w, "window.close", {"windowId": wid}, id_=2)
    assert res["result"] == {} and wid not in it.windows
    assert "tick after closing a window failed" in caplog.text


@pytest.mark.parametrize("method,params", [
    ("window.createTask", {"taskId": "t1", "cwd": "/wt", "frame": FRAME}),
    ("interface.setMatchItermBackground", {"matchItermBackground": True}),
])
async def test_a_tick_that_fails_before_a_change_is_answered_iterm_unavailable(stack, method, params):
    """Not `internal`: nothing was changed, and the app handles an unavailable iTerm2 already."""
    svc, it, files, r, w = stack
    it.snapshot_error = ItermUnavailable("iTerm2 did not answer within 10s")
    assert (await call(r, w, method, params))["error"]["code"] == "iterm_unavailable"
    assert not it.windows and not it.background_requests


async def test_an_agent_command_iterm_would_not_take_still_returns_the_window(stack, caplog):
    """The window exists: an error would make the app retry, and a retry opens a second one."""
    svc, it, files, r, w = stack
    it.send_error = ItermUnavailable("iTerm2 did not answer within 10s")
    with caplog.at_level("ERROR", logger="aitermd.windows"):
        res = await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "agentCommand": "claude", "frame": FRAME})
        wid = res["result"]["windowId"]
        res = await call(r, w, "tab.create", {"windowId": wid, "agentCommand": "claude"}, id_=2)
    assert res["result"]["sessionId"] in it.sessions
    assert list(it.windows) == [wid]
    assert "sending the agent command after creating a window or tab failed" in caplog.text


async def test_interface_background_only_changes_aiterm_sessions_and_future_tabs(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    result = await call(r, w, "interface.setMatchItermBackground", {"matchItermBackground": True}, id_=2)
    assert result["result"] == {}
    assert it.background_requests[-1] == ([sid], True)
    new_sid = await it.user_opens_tab(wid)
    assert it.background_requests[-1] == ([new_sid], True)
    await call(r, w, "interface.setMatchItermBackground", {"matchItermBackground": False}, id_=3)
    assert it.background_requests[-1] == ([sid, new_sid], False)


async def test_claude_hook_updates_status_via_pid_mapping(stack, tmp_path):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=555, title="✳ Claude Code")
    files.root.mkdir(parents=True)
    (files.root / "555.json").write_text(json.dumps({"pid": 555, "sessionId": "abc", "cwd": "/wt", "status": "idle", "updatedAt": 1}))
    await svc.tick()
    # This tick's snapshot diff legitimately emits its own session.changed (the
    # title now reads "✳ Claude Code" per user_runs) before the hook-driven one
    # below; drain it so the assertions match the event the hook itself causes.
    await next_event(r, "session.changed")
    await svc.hook_router.handle_hook("/hook/claude", {"hook_event_name": "PermissionRequest", "session_id": "abc", "cwd": "/wt",
                                                       "tool_name": "Bash"})
    payload = await next_event(r, "session.changed")
    assert payload["sessionId"] == sid and payload["state"] == "needsInput"
    await svc.hook_router.handle_hook("/hook/claude", {"hook_event_name": "PostModelSwitch", "session_id": "abc", "cwd": "/wt",
                                                       "from_model": "a", "to_model": "claude-opus-5"})
    assert (await next_event(r, "session.changed"))["model"] == "claude-opus-5"
    assert (await call(r, w, "sessions.markSeen", {"taskId": "t1"}, id_=4))["result"] == {"changed": 0}


async def test_hook_over_http_updates_session(stack, tmp_path):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=888, title="✳ Claude Code")
    files.root.mkdir(parents=True)
    (files.root / "888.json").write_text(json.dumps({"pid": 888, "sessionId": "http-abc", "cwd": "/wt", "status": "idle", "updatedAt": 1}))
    await svc.tick()
    await next_event(r, "session.changed")  # the tick's own title-change event, per test_claude_hook_updates_status_via_pid_mapping

    status = await post_hook(svc.hooks.port, "/hook/claude",
                              {"hook_event_name": "PermissionRequest", "session_id": "http-abc", "cwd": "/wt", "tool_name": "Bash"})
    assert status == 200
    payload = await next_event(r, "session.changed")
    assert payload["sessionId"] == sid and payload["state"] == "needsInput"


@pytest.mark.parametrize("agent", ["claude", "codex"])
async def test_stop_and_cleanup_commands_never_schedule_task_deletion(stack, tmp_path, agent):
    svc, it, files, r, w = stack
    worktree = tmp_path / "keep-alive"
    worktree.mkdir()
    wid = (await call(r, w, "window.createTask", {
        "taskId": "task-alive", "cwd": str(worktree), "title": "x", "frame": FRAME,
    }))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, agent, job_pid=891, title=agent)
    await svc.tick()
    events = []
    async def record(name, payload):
        events.append(name)
    svc.publisher.broadcast = record
    base = {"session_id": "agent-session", "cwd": str(worktree),
            "_aiterm_iterm_session_id": sid}
    for command in ['git ' + 'worktree remove "$WORKTREE_PATH"',
                    'echo git ' + 'worktree remove; git status',
                    'git ' + 'branch -d feat/done']:
        response = await svc.hook_router.handle_hook(f"/hook/{agent}", {**base,
            "hook_event_name": "PreToolUse", "tool_name": "Bash",
            "tool_input": {"command": command}})
        assert response is None, "ambiguous shell text must never be replaced"
    await svc.hook_router.handle_hook(f"/hook/{agent}", {**base, "hook_event_name": "Stop"})
    worktree.rmdir()
    await svc.hook_router.handle_hook(f"/hook/{agent}", {**base, "hook_event_name": "Stop"})
    assert not any(name.startswith("task.") for name in events)
    assert wid in it.windows, "even an externally removed checkout retains its window"


async def test_tick_reads_codex_context_after_a_hook_identifies_the_thread(stack):
    svc, it, files, r, w = stack
    svc.codex_files = CodexSessionFiles(files.root.parent / "codex-sessions")
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "codex", job_pid=104, title="Codex")
    await svc.tick()
    await svc.hook_router.handle_hook("/hook/codex", {
        "hook_event_name": "SessionStart", "session_id": "thread-context", "cwd": "/wt",
        "model": "gpt-5.6", "_aiterm_iterm_session_id": sid,
    })

    rollout = svc.codex_files.root / "2026" / "09" / "22" / "rollout-2026-09-22T09-26-25-thread-context.jsonl"
    rollout.parent.mkdir(parents=True)
    rollout.write_text("\n".join(json.dumps(record) for record in [
        {"type": "session_meta", "payload": {"id": "thread-context", "session_id": "thread-context"}},
        {"type": "event_msg", "payload": {"type": "token_count", "info": {
            "last_token_usage": {"total_tokens": 66_020}, "model_context_window": 258_400,
        }}},
    ]) + "\n")
    await svc.tick()

    assert svc.registry.get(sid).context_percent == 26


async def test_new_codex_process_cannot_reuse_the_previous_threads_context(stack):
    svc, it, files, r, w = stack
    svc.codex_files = CodexSessionFiles(files.root.parent / "codex-sessions")
    wid = (await call(r, w, "window.createTask", {
        "taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME,
    }))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "codex", job_pid=106, title="Codex")
    await svc.tick()
    await svc.hook_router.handle_hook("/hook/codex", {
        "hook_event_name": "SessionStart", "session_id": "old-thread", "cwd": "/wt",
        "model": "gpt-5.6", "_aiterm_iterm_session_id": sid,
    })
    rollout = svc.codex_files.root / "2026" / "09" / "22" / "rollout-old-thread.jsonl"
    rollout.parent.mkdir(parents=True)
    rollout.write_text(json.dumps({
        "type": "event_msg", "payload": {"type": "token_count", "info": {
            "last_token_usage": {"total_tokens": 50}, "model_context_window": 100,
        }},
    }) + "\n")
    await svc.tick()
    assert svc.registry.get(sid).context_percent == 50
    await svc.hook_router.handle_hook("/hook/codex", {
        "hook_event_name": "Stop", "session_id": "old-thread", "cwd": "/wt",
        "_aiterm_iterm_session_id": sid,
    })

    # The shell transition can happen entirely between daemon polls. The new process id is
    # what distinguishes this as a different Codex conversation before its first hook arrives.
    await it.user_runs(sid, "-zsh", job_pid=107, title="zsh")
    await it.user_runs(sid, "codex", job_pid=108, title="Codex")
    await svc.tick()

    assert svc.resolver.codex_thread(sid) is None
    assert svc.registry.get(sid).context_percent is None


async def test_new_codex_hook_before_snapshot_binds_to_the_replacement_process(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {
        "taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME,
    }))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "codex", job_pid=109, title="Codex")
    await svc.tick()
    await svc.hook_router.handle_hook("/hook/codex", {
        "hook_event_name": "UserPromptSubmit", "session_id": "old-thread", "cwd": "/wt",
        "_aiterm_iterm_session_id": sid,
    })
    await svc.tick()

    # The replacement process and its first hook both arrive before the next iTerm snapshot.
    await it.user_runs(sid, "-zsh", job_pid=110, title="zsh")
    await it.user_runs(sid, "codex", job_pid=111, title="Codex")
    await svc.hook_router.handle_hook("/hook/codex", {
        "hook_event_name": "UserPromptSubmit", "session_id": "new-thread", "cwd": "/wt",
        "_aiterm_iterm_session_id": sid,
    })
    await svc.tick()

    assert svc.resolver.codex_thread(sid) == "new-thread"


async def test_tick_uses_claude_file_status_and_agent_exit(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=777)
    files.root.mkdir(parents=True)
    (files.root / "777.json").write_text(json.dumps({"pid": 777, "sessionId": "z", "cwd": "/wt", "status": "busy", "updatedAt": 1}))
    await svc.tick()
    assert svc.registry.get(sid).state == "working"
    (files.root / "777.json").write_text(json.dumps({"pid": 777, "sessionId": "z", "cwd": "/wt", "status": "idle", "updatedAt": 2}))
    await svc.tick()
    assert svc.registry.get(sid).state == "done"
    assert (await call(r, w, "sessions.markSeen", {"taskId": "t1"}, id_=5))["result"] == {"changed": 1}
    await it.user_runs(sid, "-zsh", job_pid=1)
    svc.registry.set_state(sid, "working")
    await svc.tick()
    assert svc.registry.get(sid).state == "idle"


async def test_a_claude_trust_prompt_needs_input_until_it_is_answered(stack):
    """Claude asks whether to trust a new folder before it writes its session file or loads its
    hooks, so the screen is all that shows it."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=779)
    it.screens[sid] = " ❯ 1. No, exit\n   2. Yes, I trust this folder\n Enter to confirm · Esc to cancel"
    await svc.tick()
    assert svc.registry.get(sid).state == "needsInput"
    # Trusted: Claude writes its file, and the row was never in a turn.
    it.screens[sid] = " > "
    files.root.mkdir(parents=True)
    write_claude_file(files, 779, "idle", 1001)
    await svc.tick()
    assert svc.registry.get(sid).state == "idle"
    assert it.screen_reads == [sid], "a tab with a session file is past the dialog: its screen is not read"


async def test_a_claude_trust_prompt_dismissed_without_a_file_goes_back_to_idle(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=780)
    it.screens[sid] = "Do you trust the files in this folder?"
    await svc.tick()
    assert svc.registry.get(sid).state == "needsInput"
    it.screens[sid] = ""
    await svc.tick()
    assert svc.registry.get(sid).state == "idle"


async def test_a_screen_that_cannot_be_read_leaves_the_row_alone(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=781)
    it.screens[sid] = "Yes, I trust this folder"
    await svc.tick()
    it.screen_error = RuntimeError("iTerm2 refused")
    await svc.tick()
    assert svc.registry.get(sid).state == "needsInput"


def write_claude_file(files, pid, status, written_at):
    path = files.root / f"{pid}.json"
    path.write_text(json.dumps({"pid": pid, "sessionId": f"c{pid}", "cwd": "/wt", "status": status, "updatedAt": 1}))
    os.utime(path, (written_at, written_at))


async def test_a_session_file_older_than_the_last_hook_does_not_override_it(stack):
    """The stack's clock stamps every hook at 1000."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=778)
    files.root.mkdir(parents=True)
    write_claude_file(files, 778, "idle", 900)
    await svc.tick()
    base = {"session_id": "c778", "cwd": "/wt"}

    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "UserPromptSubmit"})
    await svc.tick()
    assert svc.registry.get(sid).state == "working", "the previous turn's idle file must not end this one"

    write_claude_file(files, 778, "busy", 999)
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "PermissionRequest"})
    await svc.tick()
    assert svc.registry.get(sid).state == "needsInput"

    # Answered: Claude rewrites its file, and no hook reports the resume.
    write_claude_file(files, 778, "busy", 1001)
    await svc.tick()
    assert svc.registry.get(sid).state == "working"


async def test_statusline_updates_usage_and_broadcasts(stack):
    svc, it, files, r, w = stack
    await svc.hook_router.handle_hook("/statusline", {"session_id": "abc", "model": {"id": "claude-opus-5"},
                                                      "rate_limits": {"five_hour": {"used_percentage": 23, "resets_at": 99}}})
    payload = await next_event(r, "usage.changed")
    assert payload["claude"]["fiveHour"] == {"usedPercent": 23, "resetsAt": 99}
    assert (await call(r, w, "usage.get", id_=6))["result"]["claude"]["fiveHour"]["usedPercent"] == 23


async def test_statusline_hangs_the_context_fill_on_the_session(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=666, title="✳ Claude Code")
    files.root.mkdir(parents=True)
    (files.root / "666.json").write_text(json.dumps({"pid": 666, "sessionId": "ctx-abc", "cwd": "/wt", "status": "idle", "updatedAt": 1}))
    await svc.tick()
    await next_event(r, "session.changed")  # the tick's own title change, per the tests above

    # No rate limits at all: the context fill alone must still reach the session, because
    # `context_window` and `rate_limits` arrive independently on the same payload.
    await svc.hook_router.handle_hook("/statusline", {"session_id": "ctx-abc", "cwd": "/wt",
                                          "context_window": {"used_percentage": 42}})
    payload = await next_event(r, "session.changed")
    assert payload["sessionId"] == sid and payload["contextPercent"] == 42


async def test_statusline_hangs_the_context_fill_on_a_terminal_session(stack):
    # A terminal's tab carries no task tag. Claude started in it still resolves by pid, and the
    # fill stays on that session alone for the app to match to the terminal by window.
    svc, it, files, r, w = stack
    terminal = {"projectId": "p1", "cwd": "/repo", "title": "Terminal", "frame": FRAME}
    wid = (await call(r, w, "window.createTerminal", terminal))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=777, title="✳ Claude Code")
    files.root.mkdir(parents=True)
    (files.root / "777.json").write_text(json.dumps({"pid": 777, "sessionId": "ctx-term", "cwd": "/repo", "status": "idle",
                                                     "updatedAt": 1}))
    await svc.tick()
    await next_event(r, "session.changed")

    await svc.hook_router.handle_hook("/statusline", {"session_id": "ctx-term", "cwd": "/repo",
                                          "context_window": {"used_percentage": 23}})
    payload = await next_event(r, "session.changed")
    assert payload["sessionId"] == sid and payload["windowId"] == wid
    assert payload["taskId"] is None and payload["contextPercent"] == 23


async def test_errors(stack):
    svc, it, files, r, w = stack
    assert (await call(r, w, "window.activate", {"windowId": "nope"}))["error"]["code"] == "not_found"
    # Retry quickly, so the loop makes several attempts while iTerm2 is away.
    svc.supervisor.reconnect_seconds = 0.001
    await it.disconnect()
    created = await call(r, w, "window.createTask", {"taskId": "t", "cwd": "/", "title": "t", "frame": FRAME}, id_=2)
    assert created["error"]["code"] == "iterm_unavailable"
    # The reconnect loop never opens iTerm2 after a disconnect: it connects once the person starts it.
    await asyncio.sleep(0.05)
    await it.reconnect()
    await wait_until(lambda: svc.supervisor.version is not None)
    assert svc.supervisor.launch_iterm.calls == 0


async def test_window_closed_event_when_last_session_goes(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    await it.close_window(wid)
    await svc.tick()
    payload = await next_event(r, "window.closed")
    assert payload["windowId"] == wid


async def test_activating_a_session_selects_its_tab_and_raises_its_window(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    terminal = {"projectId": "p1", "cwd": "/", "title": "y", "frame": FRAME}
    other = (await call(r, w, "window.createTerminal", terminal, id_=2))["result"]["windowId"]
    first = it.windows[wid]["sessions"][0]
    docs = (await call(r, w, "tab.create", {"windowId": wid, "tabKey": "docs"}, id_=3))["result"]["sessionId"]
    assert it.windows[wid]["current"] == docs and it.windows[other]["active"]

    assert (await call(r, w, "session.activate", {"sessionId": first}, id_=4)) == {"id": 4, "result": {}}
    assert it.windows[wid]["current"] == first and it.windows[wid]["active"] and not it.windows[other]["active"]
    assert (await call(r, w, "session.activate", {"sessionId": "nope"}, id_=5))["error"]["code"] == "not_found"
    assert (await call(r, w, "session.activate", {}, id_=6))["error"]["code"] == "bad_params"


async def test_externally_activated_window_is_broadcast_to_the_app(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    await it.user_activates_window(wid)
    assert await next_event(r, "window.activated") == {"windowId": wid}


async def test_concurrent_ticks_emit_window_closed_once(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    await it.close_window(wid)
    await asyncio.gather(svc.tick(), svc.tick())
    closed = []
    while True:
        try:
            msg = json.loads(await asyncio.wait_for(r.readline(), 0.2))
        except TimeoutError:
            break
        if msg.get("event") == "window.closed":
            closed.append(msg["payload"])
    assert closed == [{"windowId": wid}]


async def test_user_tab_in_a_terminal_window_is_tagged_and_redirected(stack):
    # Spec 2.4's redirect was gated on a task tag alone, so Cmd+T in a window
    # opened by window.createTerminal landed in $HOME instead of the project.
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTerminal", {"projectId": "p1", "cwd": "/repo", "frame": FRAME}))["result"]["windowId"]
    sid = await it.user_opens_tab(wid, cwd="/Users/me")
    assert (sid, " cd /repo && clear\n") in it.sent
    assert it.sessions[sid].user_vars == {"aiterm_project": "p1"}
    await svc.tick()
    assert [s["projectId"] for s in (await call(r, w, "sessions.list", id_=3))["result"]] == ["p1", "p1"]


async def test_daemon_created_tab_in_a_terminal_window_carries_the_project_tag(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTerminal", {"projectId": "p1", "cwd": "/repo", "frame": FRAME}))["result"]["windowId"]
    sid = (await call(r, w, "tab.create", {"windowId": wid}, id_=2))["result"]["sessionId"]
    assert it.sessions[sid].user_vars == {"aiterm_project": "p1"}


async def test_create_terminal_titles_the_window_with_the_given_name(stack):
    svc, it, files, r, w = stack
    terminal = {"projectId": "p1", "cwd": "/repo", "title": "Logs", "frame": FRAME}
    wid = (await call(r, w, "window.createTerminal", terminal))["result"]["windowId"]
    assert it.sessions[it.windows[wid]["sessions"][0]].title == "Logs"


async def test_branch_titles_only_change_aiterm_managed_tabs(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "old", "frame": FRAME}))["result"]["windowId"]
    managed = it.windows[wid]["sessions"][0]
    _, unmanaged = await it.create_window("/other", "Other", {}, it.windows[wid]["frame"])
    await svc.tick()

    result = await call(r, w, "sessions.setTitles", {"titles": [
        {"sessionId": managed, "title": "feat/live-branch"},
        {"sessionId": unmanaged, "title": "must-not-change"},
        {"sessionId": "already-closed", "title": "stale"},
    ]}, id_=2)

    assert result["result"] == {"changed": 1}
    assert it.titles == {managed: "feat/live-branch"}


async def test_unchanged_branch_titles_are_not_reapplied(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "old", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    titles = {"titles": [{"sessionId": sid, "title": "main"}]}

    assert (await call(r, w, "sessions.setTitles", titles, id_=2))["result"] == {"changed": 1}
    # The app re-sends every title every couple of seconds; iTerm2 already shows this one.
    assert (await call(r, w, "sessions.setTitles", titles, id_=3))["result"] == {"changed": 0}
    assert it.title_calls == 1
    assert (await call(r, w, "sessions.setTitles", {"titles": [{"sessionId": sid, "title": "feat/x"}]}, id_=4))["result"] == {"changed": 1}

    # A reconnect may be a restarted iTerm2, which has forgotten every title.
    await it.disconnect()
    await it.reconnect()
    await wait_until(lambda: svc.supervisor.version is not None)
    assert (await call(r, w, "sessions.setTitles", {"titles": [{"sessionId": sid, "title": "feat/x"}]}, id_=5))["result"] == {"changed": 1}


async def test_a_closed_sessions_applied_title_is_forgotten(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "old", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await call(r, w, "sessions.setTitles", {"titles": [{"sessionId": sid, "title": "main"}]}, id_=2)
    await it.close_window(wid)
    await svc.tick()
    assert sid not in svc.windows._applied_titles


async def test_daemon_created_tab_is_not_redirected(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    res = await call(r, w, "tab.create", {"windowId": wid, "agentCommand": "claude"}, id_=2)
    sid = res["result"]["sessionId"]
    await svc.windows.on_new_session(sid)
    sent_for_sid = [text for (s, text) in it.sent if s == sid]
    assert " claude\n" in sent_for_sid
    assert not any(text.startswith(" cd ") for text in sent_for_sid)


async def test_tab_create_opens_in_the_directory_it_is_given(stack):
    # A review opened in its task's window must start in the task's worktree: its command may read
    # its prompt from `.aiterm/first-prompt.md` there. The active tab can be anywhere by then.
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    first = it.windows[wid]["sessions"][0]
    it.sessions[first].cwd = "/elsewhere"
    await svc.tick()
    sid = (await call(r, w, "tab.create", {"windowId": wid, "cwd": "/wt", "agentCommand": "claude"}, id_=2))["result"]["sessionId"]
    assert it.sessions[sid].cwd == "/wt"
    assert it.sessions[sid].user_vars == {"aiterm_task": "t1"}
    assert (sid, " claude\n") in it.sent


async def test_an_extra_worker_tab_carries_its_task_and_its_own_key(stack):
    # An Operator's extra worker tab (open_tab) is its task's, and told apart from the task's first
    # worker and from its other extra tabs by its key; a tab you open beside it inherits no key.
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    first = it.windows[wid]["sessions"][0]
    review = (await call(r, w, "tab.create", {"windowId": wid, "cwd": "/wt", "tabKey": "review"}, id_=2))["result"]["sessionId"]
    docs = (await call(r, w, "tab.create", {"windowId": wid, "cwd": "/wt", "tabKey": "docs"}, id_=3))["result"]["sessionId"]
    assert it.sessions[review].user_vars == {"aiterm_task": "t1", "aiterm_tab": "review"}
    yours = await it.user_opens_tab(wid)
    await it.settle()
    listed = {s["sessionId"]: s for s in (await call(r, w, "sessions.list", id_=4))["result"]}
    assert {sid: (s["taskId"], s["tabKey"]) for sid, s in listed.items()} == {
        first: ("t1", None), review: ("t1", "review"), docs: ("t1", "docs"), yours: ("t1", None)}


async def test_an_extra_worker_tab_asked_for_again_is_the_one_already_open(stack):
    # A request whose answer was lost is asked again: the tab tagged with its task and key is the
    # answer, never a second tab beside it.
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    params = {"windowId": wid, "cwd": "/wt", "tabKey": "review", "agentCommand": "claude"}
    sid = (await call(r, w, "tab.create", params, id_=2))["result"]["sessionId"]
    assert (await call(r, w, "tab.create", params, id_=3))["result"]["sessionId"] == sid
    assert len(it.windows[wid]["sessions"]) == 2
    assert [text for (s, text) in it.sent if s == sid] == [" claude\n"]
    other = (await call(r, w, "tab.create", params | {"tabKey": "docs"}, id_=4))["result"]["sessionId"]
    assert other != sid and len(it.windows[wid]["sessions"]) == 3


async def test_a_background_tab_leaves_its_window_on_the_tab_you_were_on(stack):
    # An Operator's worker opens behind your work: its window keeps the tab it had current, and
    # iTerm2 is not brought forward (the bridge asks iTerm2 not to select the new tab).
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    first = it.windows[wid]["sessions"][0]
    background = {"windowId": wid, "cwd": "/wt", "tabKey": "review", "background": True}
    sid = (await call(r, w, "tab.create", background, id_=2))["result"]["sessionId"]
    assert sid in it.sessions and it.windows[wid]["current"] == first
    front = (await call(r, w, "tab.create", {"windowId": wid, "cwd": "/wt"}, id_=3))["result"]["sessionId"]
    assert it.windows[wid]["current"] == front


async def test_tab_create_race_with_notification_during_create_is_not_redirected(stack):
    # I1: the real ItermBridge.create_tab() creates the tab (which fires the
    # new-session notification) and only *then* tags the session - so the
    # notification for a daemon-created tab's own session can arrive
    # untagged, during create_tab()'s await, before _h_tab_create gets to
    # record the session in _self_created. Reproduce that exact ordering
    # (FakeIterm normally tags atomically at creation, which would hide this
    # race) and assert the redirect - which would otherwise race the
    # agentCommand send right below it - is still skipped.
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]

    async def racing_create_tab(window_id, tags, cwd=None, background=False):
        cwd = cwd or it.sessions[it.windows[window_id]["sessions"][0]].cwd
        sid = await it._add_session(window_id, cwd, {}, command_line="-zsh", title="zsh")  # untagged, like the real bridge
        for cb in it._new_cbs:
            await cb(sid)  # notification fires before the tag is applied
        it.sessions[sid].user_vars.update(tags)
        return sid

    it.create_tab = racing_create_tab

    res = await call(r, w, "tab.create", {"windowId": wid, "agentCommand": "claude"}, id_=2)
    sid = res["result"]["sessionId"]
    sent_for_sid = [text for (s, text) in it.sent if s == sid]
    assert " claude\n" in sent_for_sid
    assert not any(text.startswith(" cd ") for text in sent_for_sid)


async def test_daemon_created_tab_is_not_redirected_when_iterm_announces_it_by_default(stack):
    # The same race as above, with nothing hand-built: FakeIterm announces a tab the daemon creates
    # while the create is still awaiting, as the library does, so an agent command is never raced
    # by a `cd` redirect on the default path.
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = (await call(r, w, "tab.create", {"windowId": wid, "agentCommand": "claude"}, id_=2))["result"]["sessionId"]
    await it.settle()
    assert [text for (s, text) in it.sent if s == sid] == [" claude\n"]
    assert it.sessions[sid].user_vars == {"aiterm_task": "t1"}


async def test_a_window_the_daemon_created_is_in_the_registry_once_its_announcement_is_handled(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    await it.settle()
    assert {s.window_id for s in svc.registry.all()} == {wid}
    assert not it.sent


async def test_a_window_closed_in_iterm_is_announced_and_leaves_the_registry(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    await it.settle()
    await it.close_window(wid)
    await it.settle()
    assert not svc.registry.all()
    assert (await next_event(r, "window.closed"))["windowId"] == wid


async def test_a_tab_renumbered_by_a_close_gets_its_title_applied_again(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    first = it.windows[wid]["sessions"][0]
    second = (await call(r, w, "tab.create", {"windowId": wid}, id_=2))["result"]["sessionId"]
    await it.settle()
    titles = {"titles": [{"sessionId": first, "title": "a"}, {"sessionId": second, "title": "b"}]}
    assert (await call(r, w, "sessions.setTitles", titles, id_=3))["result"] == {"changed": 2}
    await it.user_closes_session(first)
    await svc.tick()
    only_second = {"titles": [{"sessionId": second, "title": "b"}]}
    assert (await call(r, w, "sessions.setTitles", only_second, id_=4))["result"] == {"changed": 1}


async def test_closing_a_pane_leaves_the_other_tabs_titles_alone(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    first = it.windows[wid]["sessions"][0]
    second = (await call(r, w, "tab.create", {"windowId": wid}, id_=2))["result"]["sessionId"]
    pane = await it.add_pane(wid, tab_index=0)
    await it.settle()
    titles = {"titles": [{"sessionId": first, "title": "a"}, {"sessionId": second, "title": "b"}]}
    assert (await call(r, w, "sessions.setTitles", titles, id_=3))["result"] == {"changed": 2}
    await it.user_closes_session(pane)
    await svc.tick()
    assert (await call(r, w, "sessions.setTitles", titles, id_=4))["result"] == {"changed": 0}


async def test_user_tab_in_other_window_is_redirected_during_unrelated_create(stack):
    # The global _PENDING_WINDOW gate this replaced blocked the tag+redirect
    # for *every* window while any window.createTask/createTerminal call was
    # in flight, not just the one being created. Reproduce a user opening a
    # tab in an already-tagged window while a second, unrelated window is
    # still being created, and assert the first window's tab is still
    # tagged+redirected (the per-window `_creating_in` gate that remains only
    # covers the window actually being created).
    svc, it, files, r, w = stack
    wid1 = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt1", "title": "x", "frame": FRAME}))["result"]["windowId"]

    real_create_window = it.create_window
    captured: dict[str, str] = {}

    async def create_window_with_race(cwd, title, tags, frame, background=False):
        # Fire the race before the second window exists at all, i.e. well
        # before its (still-unknown) window id could ever be recorded.
        captured["sid"] = await it.user_opens_tab(wid1, cwd="/Users/me")
        return await real_create_window(cwd, title, tags, frame, background=background)

    it.create_window = create_window_with_race

    await call(r, w, "window.createTask", {"taskId": "t2", "cwd": "/wt2", "title": "y", "frame": FRAME}, id_=2)

    other_sid = captured["sid"]
    assert (other_sid, " cd /wt1 && clear\n") in it.sent
    assert it.sessions[other_sid].user_vars == {"aiterm_task": "t1"}


async def test_codex_usage_is_read_from_the_rollout_file_on_tick(tmp_path, make_service):
    # Codex writes its account rate limits into every `token_count` record of its rollout
    # file. That is the whole feed: no subprocess, and the number's age is the record's own
    # timestamp rather than the moment the daemon looked.
    from tests.test_codex_sessions import rate_limited, write_rollout
    root = tmp_path / "codex-sessions"
    path = write_rollout(root, "thread-1", [rate_limited({"used_percent": 52.0, "window_minutes": 10080, "resets_at": 1790582049},
                                                         plan="self_serve_business_prolite")])
    svc = make_service(codex_files=CodexSessionFiles(root))
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    await svc.tick()
    assert (await call(r, w, "usage.get"))["result"]["codex"] == {
        "fiveHour": None, "sevenDay": {"usedPercent": 52, "resetsAt": 1790582049},
        "spend": None, "plan": "self_serve_business_prolite", "updatedAt": 1790087469}
    # Codex's next turn appends a record; the next tick announces it.
    with path.open("a") as stream:
        stream.write(json.dumps(rate_limited({"used_percent": 53.0, "window_minutes": 10080, "resets_at": 1790582049},
                                             timestamp="2026-09-22T14:31:59.215Z")) + "\n")
    await svc.tick()
    payload = await asyncio.wait_for(next_event(r, "usage.changed"), 3)
    assert payload["codex"]["sevenDay"] == {"usedPercent": 53, "resetsAt": 1790582049}
    assert payload["codex"]["updatedAt"] == 1790087519
    w.close()


async def test_tick_publishes_the_claude_session_files_cwd(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTerminal", {"projectId": "p1", "cwd": "/repo", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=4242)
    files.root.mkdir(parents=True)
    (files.root / "4242.json").write_text(json.dumps(
        {"pid": 4242, "sessionId": "abc", "cwd": "/repo/.worktrees/feat", "status": "idle", "updatedAt": 1}))
    await svc.tick()
    # iTerm2 still reports the shell's directory; the agent's own is what moved.
    assert svc.registry.get(sid).cwd == "/repo"
    assert svc.registry.get(sid).agent_cwd == "/repo/.worktrees/feat"
    assert svc.registry.get(sid).to_json()["agentCwd"] == "/repo/.worktrees/feat"


async def test_cmd_t_inherits_the_active_tabs_agent_directory(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTerminal", {"projectId": "p1", "cwd": "/repo", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=4242)
    files.root.mkdir(parents=True)
    (files.root / "4242.json").write_text(json.dumps(
        {"pid": 4242, "sessionId": "abc", "cwd": "/repo/.worktrees/feat", "status": "idle", "updatedAt": 1}))
    await svc.tick()  # learns the agent's directory, and that this tab is the current one
    new_sid = await it.user_opens_tab(wid)  # Cmd+T, which lands in $HOME
    sent = [text for target, text in it.sent if target == new_sid]
    assert sent and "/repo/.worktrees/feat" in sent[0]


async def test_cmd_t_follows_the_tab_the_user_switched_to(stack):
    svc, it, files, r, w = stack
    task = {"taskId": "t1", "cwd": "/repo/.worktrees/feat", "title": "x", "frame": FRAME}
    wid = (await call(r, w, "window.createTask", task))["result"]["windowId"]
    first = it.windows[wid]["sessions"][0]
    second = await it.user_opens_tab(wid)
    it.sessions[second].cwd = "/repo"  # the user cd'd this tab back to the repo root
    await svc.tick()
    it.user_selects_tab(second)
    await svc.tick()
    third = await it.user_opens_tab(wid)
    sent = [text for target, text in it.sent if target == third]
    # Not the first tab's worktree, which is what the old "window's first session" rule gave.
    assert sent == [" cd /repo && clear\n"]
    assert it.sessions[first].cwd == "/repo/.worktrees/feat"


async def test_task_window_retry_and_reconnect_never_replay_prompt(stack, make_service):
    svc, it, files, r, w = stack
    params = {"taskId": "stable-task", "cwd": "/wt", "title": "x", "frame": FRAME,
              "agentCommand": "agent original-prompt"}
    first = await svc.windows.create_task(params)
    replies = await asyncio.gather(*(svc.windows.create_task(params) for _ in range(6)))
    assert all(reply == first for reply in replies)
    assert len(it.windows) == 1
    assert sum(text == " agent original-prompt\n" for _, text in it.sent) == 1
    # A second daemon over the same iTerm2 is a restart: it starts with an empty registry, and the
    # window's tagged session is all it needs to find the window again.
    restarted = make_service(iterm=it)
    assert restarted.registry.all() == []
    assert await restarted.windows.create_task(params) == first
    assert len(it.windows) == 1
    assert sum(text == " agent original-prompt\n" for _, text in it.sent) == 1


async def test_bootstrap_snapshot_contains_live_tags_and_protocol(stack):
    svc, it, files, r, w = stack
    await svc.windows.create_task({"taskId": "stable-task", "cwd": "/wt", "title": "x", "frame": FRAME})
    result = (await call(r, w, "workspace.snapshot"))["result"]
    assert result["protocolVersion"] == 1 and result["connected"]
    # Settings names the iTerm2 it is connected to, and every snapshot event would otherwise drop it.
    assert result["itermVersion"] == "3.7.2"
    assert result["sessions"][0]["taskId"] == "stable-task"
    assert "usage" in result


async def test_a_failing_codex_usage_read_does_not_stop_session_polling(stack):
    svc, it, files, r, w = stack

    class Broken(CodexSessionFiles):
        def rate_limits(self):
            raise OverflowError("cannot convert float infinity to integer")

    svc.codex_files = Broken(files.root.parent / "codex-sessions")
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    await it.close_window(wid)
    await svc.tick()
    assert svc.registry.all() == []


async def test_snapshot_survives_a_failing_tick(stack, caplog):
    svc, it, files, r, w = stack
    await svc.windows.create_task({"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME})

    async def broken_snapshot():
        raise RuntimeError("iterm2 library bug")

    it.snapshot = broken_snapshot
    with caplog.at_level("ERROR", logger="aitermd.service"):
        result = (await call(r, w, "workspace.snapshot"))["result"]
    assert result["sessions"][0]["taskId"] == "t1"
    assert any("tick failed" in rec.getMessage() for rec in caplog.records)


async def test_a_new_claude_process_in_the_tab_is_not_held_working_by_the_old_ones_subagent(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=901)
    files.root.mkdir(parents=True)
    (files.root / "901.json").write_text(json.dumps({"pid": 901, "sessionId": "old", "cwd": "/wt", "status": "busy", "updatedAt": 1}))
    await svc.tick()
    await svc.hook_router.handle_hook("/hook/claude", {"hook_event_name": "SubagentStart", "session_id": "old", "cwd": "/wt",
                                                       "agent_id": "lost"})

    # The process is killed with its child: no SubagentStop ever arrives.
    await it.user_runs(sid, "claude", job_pid=902)
    (files.root / "902.json").write_text(json.dumps({"pid": 902, "sessionId": "new", "cwd": "/wt", "status": "busy", "updatedAt": 2}))
    await svc.tick()
    (files.root / "902.json").write_text(json.dumps({"pid": 902, "sessionId": "new", "cwd": "/wt", "status": "idle", "updatedAt": 3}))
    await svc.tick()
    assert svc.registry.get(sid).state == "done"


@pytest.mark.parametrize("method,params", [
    ("window.activate", None),
    ("window.activate", {}),
    ("window.activate", {"windowId": 7}),
    ("window.setFrame", {"windowId": "w1", "frame": {"x": 1}}),
    ("window.setFrame", {"windowId": "w1", "frame": "wide"}),
    ("window.setFrame", {"windowId": "w1", "frame": {**FRAME, "w": float("nan")}}),
    ("window.setFrame", {"windowId": "w1", "frame": {**FRAME, "h": True}}),
    ("window.createTask", {"taskId": "t", "cwd": "/", "frame": {"x": "a", "y": 0, "w": 0, "h": 0}}),
    ("window.createTerminal", {"cwd": "/", "frame": FRAME}),
    ("tab.create", {"windowId": "w1", "agentCommand": 5}),
    ("tab.create", {"windowId": "w1", "cwd": 5}),
    ("sessions.markSeen", {"taskId": None}),
    ("sessions.setTitles", {"titles": "main"}),
])
async def test_malformed_params_are_bad_params_not_internal_errors(stack, method, params):
    svc, it, files, r, w = stack
    assert (await call(r, w, method, params))["error"]["code"] == "bad_params"


async def test_set_titles_skips_malformed_items(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    result = await call(r, w, "sessions.setTitles", {"titles": ["junk", None, {"sessionId": sid, "title": "main"}]}, id_=2)
    assert result["result"] == {"changed": 1}


async def test_a_failing_window_activated_broadcast_is_contained(stack, caplog):
    svc, it, files, r, w = stack

    async def broken(*_):
        raise RuntimeError("broadcast failed")

    svc.rpc.broadcast = broken
    with caplog.at_level("ERROR", logger="aitermd.service"):
        await svc._on_window_activated("w1")  # must not raise into the iTerm2 library's dispatch
    assert any("w1" in rec.getMessage() for rec in caplog.records)


async def test_closed_sessions_leave_nothing_behind(stack):
    svc, it, files, r, w = stack
    svc.codex_files = CodexSessionFiles(files.root.parent / "codex-sessions")
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "codex", job_pid=301, title="Codex")
    await svc.tick()
    for event in ("SessionStart", "SubagentStart"):
        await svc.hook_router.handle_hook("/hook/codex", {"hook_event_name": event, "session_id": "thread-z", "cwd": "/wt",
                                              "agent_id": "child", "_aiterm_iterm_session_id": sid})
    await call(r, w, "sessions.setTitles", {"titles": [{"sessionId": sid, "title": "main"}]}, id_=2)
    await svc.tick()

    await it.close_window(wid)
    await svc.tick()
    assert sid not in svc.windows._self_created and sid not in svc.windows._applied_titles
    assert svc.status.turn(sid) is None
    assert not svc.resolver._pins and not svc.resolver._codex
    assert not svc.codex_files._paths and not svc.codex_files._context


async def test_a_hook_port_in_use_leaves_no_rpc_socket_behind(make_service):
    import socket as socket_module
    blocker = socket_module.socket()
    blocker.bind(("127.0.0.1", 0))
    blocker.listen(1)
    try:
        svc = make_service(hooks=HookServer(on_post=None, port=blocker.getsockname()[1]))
        with pytest.raises(OSError):
            await svc.start()
        assert not os.path.exists(svc.rpc.path)
    finally:
        blocker.close()


async def test_a_compaction_mid_turn_keeps_the_turn_open_for_its_subagents(stack):
    """Claude reports SessionStart with `source: compact` in the middle of a turn. Its background
    children are still running, so the foreground Stop must stay deferred until the last one ends."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=911)
    files.root.mkdir(parents=True)
    (files.root / "911.json").write_text(json.dumps({"pid": 911, "sessionId": "c1", "cwd": "/wt", "status": "busy", "updatedAt": 1}))
    await svc.tick()
    base = {"session_id": "c1", "cwd": "/wt"}
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "UserPromptSubmit"})
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "SubagentStart", "agent_id": "child"})
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "SessionStart", "source": "compact"})
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "Stop"})
    assert svc.registry.get(sid).state == "working"
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "SubagentStop", "agent_id": "child"})
    assert svc.registry.get(sid).state == "done"


async def test_a_subagent_killed_without_subagent_stop_no_longer_holds_its_row(stack, tmp_path):
    """Claude's stream watchdog kills a stalled background child: its transcript ends in an
    interruption and no SubagentStop is ever sent. The tick finds that and lands the deferred done."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=931)
    files.root.mkdir(parents=True)
    (files.root / "931.json").write_text(json.dumps({"pid": 931, "sessionId": "c1", "cwd": "/wt", "status": "busy", "updatedAt": 1}))
    await svc.tick()
    base = {"session_id": "c1", "cwd": "/wt", "transcript_path": str(tmp_path / "c1.jsonl")}
    child = tmp_path / "c1" / "subagents" / "agent-a1.jsonl"
    child.parent.mkdir(parents=True)
    child.write_text(json.dumps({"type": "user", "message": {"content": "Fix it"}}) + "\n")
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "UserPromptSubmit"})
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "SubagentStart", "agent_id": "a1"})
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "Stop"})
    await svc.tick()
    assert svc.registry.get(sid).state == "working", "the child is alive: its transcript is still open"
    with child.open("a") as f:
        f.write(json.dumps({"type": "user", "message": {"content": [{"type": "text", "text": "[Request interrupted by user]"}]}}) + "\n")
    # The file's mtime must be later than the daemon's clock at SubagentStart (1000 in these tests).
    os.utime(child, (2000, 2000))
    await svc.tick()
    assert svc.registry.get(sid).state == "done"


async def test_a_stop_listing_no_running_subagent_ends_the_turn(stack, tmp_path):
    """A Stop's `background_tasks` lists what is still in flight. A counted child it leaves out is gone,
    whatever its transcript says -- here there is none to read."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=934)
    files.root.mkdir(parents=True)
    (files.root / "934.json").write_text(json.dumps({"pid": 934, "sessionId": "c4", "cwd": "/wt", "status": "busy", "updatedAt": 1}))
    await svc.tick()
    base = {"session_id": "c4", "cwd": "/wt", "transcript_path": str(tmp_path / "c4.jsonl")}
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "UserPromptSubmit"})
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "SubagentStart", "agent_id": "a1"})
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "Stop", "background_tasks": [
        {"id": "a1", "type": "subagent", "status": "running", "description": "Fix it"}]})
    assert svc.registry.get(sid).state == "working"
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "Stop", "background_tasks": [
        {"id": "b7", "type": "shell", "status": "running", "description": "dev server", "command": "npm run dev"}]})
    assert svc.registry.get(sid).state == "done"


async def test_a_turn_that_ends_with_background_work_says_what_still_runs(stack, tmp_path):
    """A Claude turn that ends while a background shell runs is paused, not done: the session says what still runs,
    until its next turn starts, and the next Stop says what runs then."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=935)
    files.root.mkdir(parents=True)
    (files.root / "935.json").write_text(json.dumps({"pid": 935, "sessionId": "c5", "cwd": "/wt", "status": "busy", "updatedAt": 1}))
    await svc.tick()
    base = {"session_id": "c5", "cwd": "/wt", "transcript_path": str(tmp_path / "c5.jsonl")}
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "UserPromptSubmit"})
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "Stop", "background_tasks": [
        {"id": "b1", "type": "shell", "status": "running", "description": "the gate", "command": "npm run test:run"}]})
    session = svc.registry.get(sid)
    assert (session.state, session.background) == ("done", (BackgroundJob("shell", "npm run test:run"),))
    assert session.to_json()["background"] == [{"kind": "shell", "text": "npm run test:run"}]
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "UserPromptSubmit"})
    assert svc.registry.get(sid).background == ()
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "Stop", "background_tasks": []})
    assert (svc.registry.get(sid).state, svc.registry.get(sid).background) == ("done", ())


async def test_a_prompt_you_type_into_a_worker_is_yours_until_its_turn_ends(make_service, tmp_path):
    """A prompt submitted right after you pressed Return in that tab is yours, by its first line, until the turn it
    started ends. The conversation's first prompt is AiTerm's launch prompt, even right after a Return (the folder-trust
    dialog's), and so is one AiTerm just delivered."""
    now = [500.0]
    svc = make_service(monotonic=lambda: now[0])
    await svc.start()
    it, files = svc.iterm, svc.claude_files
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    try:
        wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
        sid = it.windows[wid]["sessions"][0]
        await it.user_runs(sid, "claude", job_pid=936)
        files.root.mkdir(parents=True)
        (files.root / "936.json").write_text(json.dumps({"pid": 936, "sessionId": "c6", "cwd": "/wt", "status": "busy", "updatedAt": 1}))
        await svc.tick()
        base = {"session_id": "c6", "cwd": "/wt", "transcript_path": str(tmp_path / "c6.jsonl")}

        async def prompt(text):
            await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "UserPromptSubmit", "prompt": text})
            return svc.registry.get(sid).your_prompt

        async def stop():
            await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "Stop", "background_tasks": []})

        await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "SessionStart", "source": "startup"})
        await it.user_types(sid, "\r")
        assert await prompt("Ticket FE-1784: Dependency updates, minor group.") is None, "the launch prompt"
        await stop()

        now[0] += 60
        await it.user_types(sid, "\r")
        assert await prompt("Fix the language switch inline here\n(keep it minimal)") == "Fix the language switch inline here"
        assert svc.registry.get(sid).to_json()["yourPrompt"] == "Fix the language switch inline here"
        await stop()
        assert svc.registry.get(sid).your_prompt is None, "the turn it started ended"

        now[0] += 60
        await it.user_types(sid, "\r")
        now[0] += 30
        assert await prompt("Commit, then stop.") is None, "a Return long before is not this prompt"
        await stop()
    finally:
        w.close()


async def test_a_turn_with_nothing_deferred_reads_no_transcript(stack, tmp_path, monkeypatch):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=932)
    files.root.mkdir(parents=True)
    (files.root / "932.json").write_text(json.dumps({"pid": 932, "sessionId": "c2", "cwd": "/wt", "status": "busy", "updatedAt": 1}))
    await svc.tick()
    base = {"session_id": "c2", "cwd": "/wt", "transcript_path": str(tmp_path / "c2.jsonl")}
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "UserPromptSubmit"})
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "SubagentStart", "agent_id": "a1"})
    monkeypatch.setattr(svc.subagent_transcripts, "read_all", lambda paths: pytest.fail("read a transcript mid-turn"))
    await svc.tick()
    assert svc.registry.get(sid).state == "working"


async def test_a_transcript_read_that_hangs_releases_nothing(stack, tmp_path, monkeypatch):
    monkeypatch.setattr(service, "OFF_LOOP_CHECK_SECONDS", 0.05)
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=933)
    files.root.mkdir(parents=True)
    (files.root / "933.json").write_text(json.dumps({"pid": 933, "sessionId": "c3", "cwd": "/wt", "status": "busy", "updatedAt": 1}))
    await svc.tick()
    base = {"session_id": "c3", "cwd": "/wt", "transcript_path": str(tmp_path / "c3.jsonl")}
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "UserPromptSubmit"})
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "SubagentStart", "agent_id": "a1"})
    await svc.hook_router.handle_hook("/hook/claude", {**base, "hook_event_name": "Stop"})
    release, calls = threading.Event(), []

    def hung(paths):
        calls.append(paths)
        release.wait(5)
        return {}

    monkeypatch.setattr(svc.subagent_transcripts, "read_all", hung)
    try:
        for _ in range(3):
            await asyncio.wait_for(svc.tick(), 1)
        assert svc.registry.get(sid).state == "working"
        assert len(calls) == 1, "no second read is started beside one still stuck"
    finally:
        release.set()


async def test_a_session_start_matched_only_by_directory_resets_no_tab(stack):
    """A SessionStart the daemon can only place by its directory, or by a pin that may be stale,
    must not wipe the subagents of whichever tab it lands on."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "claude", job_pid=921)
    files.root.mkdir(parents=True)
    (files.root / "921.json").write_text(json.dumps({"pid": 921, "sessionId": "live", "cwd": "/wt", "status": "busy", "updatedAt": 1}))
    await svc.tick()
    await svc.hook_router.handle_hook("/hook/claude", {"hook_event_name": "SubagentStart", "session_id": "live", "cwd": "/wt",
                                                       "agent_id": "child"})
    # Another conversation starting in the same directory, before its own session file exists.
    await svc.hook_router.handle_hook("/hook/claude", {"hook_event_name": "SessionStart", "source": "resume", "session_id": "other",
                                                       "cwd": "/wt"})
    assert (turn := svc.status.turn(sid)) is not None and turn.children


async def test_a_moved_session_gets_its_title_applied_again(stack):
    """A tab dragged to another position keeps its session id but not its tab's title override."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "old", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    titles = {"titles": [{"sessionId": sid, "title": "main"}]}
    assert (await call(r, w, "sessions.setTitles", titles, id_=2))["result"] == {"changed": 1}
    it.sessions[sid].tab_index += 1
    await svc.tick()
    assert (await call(r, w, "sessions.setTitles", titles, id_=3))["result"] == {"changed": 1}


async def test_a_session_moved_while_its_title_is_applied_gets_it_applied_again(stack):
    """The move is seen while iTerm2 applies the title, to the tab the session is leaving: what
    was applied must not be recorded against the tab it lands in."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "old", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    set_session_titles = it.set_session_titles

    async def moved_meanwhile(titles):
        applied = await set_session_titles(titles)
        it.sessions[sid].tab_index += 1
        await svc.tick()
        return applied

    it.set_session_titles = moved_meanwhile
    titles = {"titles": [{"sessionId": sid, "title": "main"}]}
    assert (await call(r, w, "sessions.setTitles", titles, id_=2))["result"] == {"changed": 1}
    it.set_session_titles = set_session_titles
    assert (await call(r, w, "sessions.setTitles", titles, id_=3))["result"] == {"changed": 1}


REFUSED = "execution error: Not authorized to send Apple events to iTerm2. (-1743)"


async def test_the_snapshot_carries_why_iterm2_refused_the_daemon(make_service):
    it = FakeIterm(connected=False)
    it.auth_error = REFUSED

    async def no_wait(_seconds):
        await asyncio.sleep(0.001)

    svc = make_service(iterm=it, supervisor={"reconnect_sleep": no_wait})
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    assert (await call(r, w, "iterm.status"))["result"] == {"connected": False, "version": None, "authError": REFUSED}
    refusing = (await call(r, w, "workspace.snapshot", id_=2))["result"]
    assert refusing["connected"] is False and refusing["itermAuthError"] == REFUSED and refusing["itermVersion"] is None
    w.close()


async def test_a_cookie_request_made_before_the_app_attached_is_in_the_snapshot_and_its_answer_connects(make_service):
    used = []
    svc = make_service(supervisor={"cookies_from_app": True, "apply_cookie": lambda cookie, key: used.append((cookie, key))})
    await svc.start()
    await wait_until(lambda: svc.supervisor._cookie_request is not None)
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    snapshot = (await call(r, w, "workspace.snapshot"))["result"]
    assert snapshot["itermCookieRequest"] == 1
    answer = await call(r, w, "iterm.provideCookie", {"requestId": 1, "cookie": "c00kie", "key": "k3y"}, id_=2)
    assert answer["result"] == {"accepted": True}
    assert await asyncio.wait_for(next_event(r, "iterm.connected"), 2) == {"version": "3.7.2"}
    assert used == [("c00kie", "k3y")]
    snapshot = (await call(r, w, "workspace.snapshot", id_=3))["result"]
    assert snapshot["itermCookieRequest"] is None and snapshot["itermVersion"] == "3.7.2"
    w.close()


async def test_a_malformed_cookie_answer_is_bad_params(stack):
    svc, it, files, r, w = stack
    assert (await call(r, w, "iterm.provideCookie", {"requestId": 1, "cookie": "c"}))["error"]["code"] == "bad_params"


def gate_first_call(it, name):
    """Holds the first call to FakeIterm's `name` until the returned event is set; counts all."""
    gate, calls, real = asyncio.Event(), [0], getattr(it, name)

    async def gated(*args):
        calls[0] += 1
        if calls[0] == 1:
            await gate.wait()
        return await real(*args)

    setattr(it, name, gated)
    return gate, calls


async def send(w, id_, method, params):
    w.write((json.dumps({"id": id_, "method": method, "params": params}) + "\n").encode())
    await w.drain()


async def replies(r, ids):
    got = {}
    while set(got) != set(ids):
        msg = json.loads(await asyncio.wait_for(r.readline(), 2))
        if msg.get("id") in ids:
            got[msg["id"]] = msg
    return got


async def test_background_changes_take_effect_in_the_order_they_were_sent(stack):
    """Requests are answered concurrently, but a later toggle must not be overtaken by an earlier one."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    gate, calls = gate_first_call(it, "set_aiterm_background")
    await send(w, 2, "interface.setMatchItermBackground", {"matchItermBackground": True})
    await wait_until(lambda: calls[0] == 1)
    await send(w, 3, "interface.setMatchItermBackground", {"matchItermBackground": False})
    await asyncio.sleep(0.05)  # time for the second to overtake the first, were it allowed to
    gate.set()
    await replies(r, {2, 3})
    assert it.background_requests == [([sid], True), ([sid], False)]
    assert svc.windows.match_iterm_background is False


async def test_titles_take_effect_in_the_order_they_were_sent(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    gate, calls = gate_first_call(it, "set_session_titles")
    await send(w, 2, "sessions.setTitles", {"titles": [{"sessionId": sid, "title": "main"}]})
    await wait_until(lambda: calls[0] == 1)
    await send(w, 3, "sessions.setTitles", {"titles": [{"sessionId": sid, "title": "feat/next"}]})
    await asyncio.sleep(0.05)
    gate.set()
    await replies(r, {2, 3})
    assert it.titles == {sid: "feat/next"} and svc.windows._applied_titles == {sid: "feat/next"}


async def test_a_window_created_while_the_background_is_being_turned_on_gets_it(stack):
    """The toggle has already listed the sessions to paint when the window appears; the window
    must then read the setting the toggle is about to store, not the one it is replacing."""
    svc, it, files, r, w = stack
    gate, calls = gate_first_call(it, "set_aiterm_background")
    await send(w, 2, "interface.setMatchItermBackground", {"matchItermBackground": True})
    await wait_until(lambda: calls[0] == 1)
    await send(w, 3, "window.createTerminal", {"projectId": "p1", "cwd": "/repo", "frame": FRAME})
    await wait_until(lambda: len(it.windows) == 1)
    await asyncio.sleep(0.05)  # time for the new window to read the setting, were it allowed to
    gate.set()
    got = await replies(r, {2, 3})
    sid = it.windows[got[3]["result"]["windowId"]]["sessions"][0]
    assert ([sid], True) in it.background_requests


async def test_a_tab_the_user_opens_while_the_background_is_being_turned_on_gets_it(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    gate, calls = gate_first_call(it, "set_aiterm_background")
    await send(w, 2, "interface.setMatchItermBackground", {"matchItermBackground": True})
    await wait_until(lambda: calls[0] == 1)
    opened = asyncio.create_task(it.user_opens_tab(wid))  # its notification waits on the toggle
    await asyncio.sleep(0.05)
    gate.set()
    await replies(r, {2})
    sid = await asyncio.wait_for(opened, 2)
    assert ([sid], True) in it.background_requests


async def test_two_tabs_created_in_one_window_at_once_are_both_left_alone(stack):
    """The first tab.create to finish must not un-gate the window while the second is still
    opening its tab: that tab's own notification would then be taken for a user's Cmd+T."""
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    first_may_finish, first_done = asyncio.Event(), asyncio.Event()
    created: list[str] = []

    async def create_tab(window_id, tags, cwd=None, background=False):
        if not created:
            created.append("first")
            await first_may_finish.wait()
            sid = await it._add_session(window_id, "/wt", dict(tags), command_line="-zsh", title="zsh")
            first_done.set()
            return sid
        created.append("second")
        await first_done.wait()
        await asyncio.sleep(0.05)  # the first tab.create has returned and cleaned up by now
        # As the real bridge does: the notification comes before the tag is set.
        sid = await it._add_session(window_id, "/wt", {}, command_line="-zsh", title="zsh")
        for cb in it._new_cbs:
            await cb(sid)
        it.sessions[sid].user_vars.update(tags)
        return sid

    it.create_tab = create_tab
    await send(w, 2, "tab.create", {"windowId": wid, "agentCommand": "claude"})
    await wait_until(lambda: created == ["first"])
    await send(w, 3, "tab.create", {"windowId": wid, "agentCommand": "claude"})
    await wait_until(lambda: created == ["first", "second"])  # both in flight
    first_may_finish.set()
    got = await replies(r, {2, 3})
    second = got[3]["result"]["sessionId"]
    assert not any(text.startswith(" cd ") for target, text in it.sent if target == second)


async def test_the_frame_set_last_is_the_one_that_stays(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    gate, calls = gate_first_call(it, "set_frame")
    await send(w, 2, "window.setFrame", {"windowId": wid, "frame": {"x": 1, "y": 1, "w": 10, "h": 10}})
    await wait_until(lambda: calls[0] == 1)
    await send(w, 3, "window.setFrame", {"windowId": wid, "frame": {"x": 2, "y": 2, "w": 20, "h": 20}})
    await asyncio.sleep(0.05)  # time for the second to overtake the first, were it allowed to
    gate.set()
    await replies(r, {2, 3})
    assert it.windows[wid]["frame"] == Frame(2, 2, 20, 20)


async def test_the_window_activated_last_is_the_one_left_active(stack):
    svc, it, files, r, w = stack
    first = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    task = {"taskId": "t2", "cwd": "/wt2", "title": "y", "frame": FRAME}
    second = (await call(r, w, "window.createTask", task, id_=2))["result"]["windowId"]
    gate, calls = gate_first_call(it, "activate_window")
    await send(w, 3, "window.activate", {"windowId": first})
    await wait_until(lambda: calls[0] == 1)
    await send(w, 4, "window.activate", {"windowId": second})
    await asyncio.sleep(0.05)
    gate.set()
    await replies(r, {3, 4})
    assert it.windows[second]["active"] and not it.windows[first]["active"]


async def _pi_tab_working_in(svc, r, w, cwd):
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": cwd, "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = svc.iterm.windows[wid]["sessions"][0]
    await svc.iterm.user_runs(sid, "pi", job_pid=41)
    await svc.tick()
    await svc.hook_router.handle_hook("/hook/pi", {"hook_event_name": "agent_start", "session_id": "p-1",
                                                   "cwd": cwd, "_aiterm_iterm_session_id": sid})
    assert svc.registry.get(sid).state == "working"
    return sid


async def test_an_agent_that_exits_leaves_the_row_idle_even_with_an_unseen_done(make_service):
    # docs/status-model.md: the tick that finds the tab back at its shell ends whatever its turn was.
    svc = make_service()
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    try:
        sid = await _pi_tab_working_in(svc, r, w, "/wt")
        await svc.hook_router.handle_hook("/hook/pi", {"hook_event_name": "agent_settled", "session_id": "p-1", "cwd": "/wt",
                                                       "_aiterm_iterm_session_id": sid})
        assert svc.registry.get(sid).state == "done"
        await svc.iterm.user_runs(sid, "-zsh", job_pid=42)
        await svc.tick()
        assert svc.registry.get(sid).state == "idle"
    finally:
        w.close()


async def test_the_first_hooks_of_an_agent_launched_after_the_last_poll_are_not_lost(stack):
    # window.createTask ticks right after sending the command, while the tab still reads as a shell;
    # the agent's first prompt then arrives before the next poll has seen it start.
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await svc.tick()
    assert svc.registry.get(sid).agent == "shell"
    await it.user_runs(sid, "codex", job_pid=77)
    assert svc.registry.get(sid).agent == "shell", "the registry has not yet seen the agent start"
    assert await post_hook(svc.hooks.port, "/hook/codex", {"hook_event_name": "UserPromptSubmit", "session_id": "c1",
                                                           "cwd": "/wt", "model": "gpt-5.6",
                                                           "_aiterm_iterm_session_id": f"w0t0p0:{sid}"}) == 200
    await wait_until(lambda: svc.registry.get(sid).state == "working")
    assert svc.registry.get(sid).agent == "codex" and svc.registry.get(sid).model == "gpt-5.6"


async def _claude_tab_busy(svc, r, w, pid, session, user_tab_of=None):
    """A Claude tab whose session file says `busy`, found by a tick: its row is working."""
    if user_tab_of is None:
        wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
        sid = svc.iterm.windows[wid]["sessions"][0]
    else:
        sid = await svc.iterm.user_opens_tab(user_tab_of)
    await svc.iterm.user_runs(sid, "claude", job_pid=pid)
    svc.claude_files.root.mkdir(parents=True, exist_ok=True)
    (svc.claude_files.root / f"{pid}.json").write_text(json.dumps(
        {"pid": pid, "sessionId": session, "cwd": "/wt", "status": "busy", "updatedAt": 1}))
    return sid


async def _published_until(r, matches):
    while True:
        payload = await next_event(r, "session.changed")
        if matches(payload):
            return payload


async def test_a_tick_that_raises_after_the_snapshot_still_publishes_what_the_snapshot_changed(stack, monkeypatch):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await svc.tick()
    await it.user_runs(sid, "claude", job_pid=5)

    class Abort(BaseException):
        """Not an Exception, so no step's guard swallows it, as with a cancelled tick."""

    def broken():
        raise Abort

    monkeypatch.setattr(svc.resolver, "snapshot_applied", broken)
    with pytest.raises(Abort):
        await svc.tick()
    # The registry already holds the new agent, so the next tick would diff nothing: the app must hear of it now.
    payload = await asyncio.wait_for(_published_until(r, lambda p: p["sessionId"] == sid and p["agent"] == "claude"), 2)
    assert payload["state"] == "idle"


async def test_one_announcement_failing_does_not_cost_the_rest(stack, monkeypatch, caplog):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    other = (await call(r, w, "window.createTask", {"taskId": "t2", "cwd": "/wt2", "title": "y", "frame": FRAME}))["result"]["windowId"]
    await it.create_tab(other, {"aiterm_task": "t2"})
    await it.settle()
    await svc.tick()
    # Two sessions open in one window while two close and a whole window goes, all seen by one tick.
    it.notify_on_create = False
    first = await it._add_session(wid, "/x", {}, "-zsh", "zsh")
    second = await it._add_session(wid, "/x", {}, "-zsh", "zsh")
    gone = list(it.windows[other]["sessions"])
    await it.close_window(other)
    delivered: list[tuple[str, str]] = []
    failed: set[str] = set()
    real = svc.rpc.broadcast

    async def broadcast(event, payload):
        if event in ("session.opened", "session.closed") and event not in failed:
            failed.add(event)
            raise ConnectionError("a client that went away mid-write")
        delivered.append((event, payload.get("sessionId") or payload.get("windowId")))
        await real(event, payload)

    monkeypatch.setattr(svc.rpc, "broadcast", broadcast)
    with caplog.at_level("ERROR", logger="aitermd.service"):
        await svc.tick()
    assert failed == {"session.opened", "session.closed"}
    assert len([e for e in delivered if e[0] == "session.opened"]) == 1
    assert len([e for e in delivered if e[0] == "session.closed"]) == len(gone) - 1
    assert ("window.closed", other) in delivered
    assert {first, second} <= {s.session_id for s in svc.registry.all()}
    # Each failure is logged as its own step's, and only the two that failed are.
    logged = [rec.getMessage() for rec in caplog.records if rec.name == "aitermd.service"]
    assert len(logged) == 2
    assert any(m.startswith("announcing opened session") for m in logged)
    assert any(m.startswith("announcing closed session") for m in logged)


async def test_a_step_before_the_announcements_failing_does_not_cost_them(stack, monkeypatch, caplog):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    first = it.windows[wid]["sessions"][0]
    moved = await it.create_tab(wid, {"aiterm_task": "t1"})
    await it.settle()
    await svc.tick()
    it.notify_on_create = False
    opened = await it._add_session(wid, "/x", {}, "-zsh", "zsh")
    # The second tab dragged in front of the first: both keep their ids, but not their tabs' titles.
    it.sessions[first].tab_index, it.sessions[moved].tab_index = 1, 0
    forgotten: list[str] = []

    def broken(*args):
        forgotten.extend(args)
        raise RuntimeError("a store that could not keep up")

    monkeypatch.setattr(svc.resolver, "snapshot_applied", broken)
    monkeypatch.setattr(svc.windows, "forget_title", broken)
    with caplog.at_level("ERROR", logger="aitermd.service"):
        await svc.tick()
    while (await next_event(r, "session.opened"))["sessionId"] != opened:
        pass
    assert sorted(forgotten) == sorted([first, moved]), "the second moved session is forgotten though the first raised"
    logged = [rec.getMessage() for rec in caplog.records if rec.name == "aitermd.service"]
    assert any("bindings after the snapshot" in m for m in logged)
    assert all(any(f"moved session {sid}" in m for m in logged) for sid in (first, moved))


async def test_a_session_that_cannot_be_forgotten_is_still_announced_closed(stack, monkeypatch, caplog):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    second = (await call(r, w, "tab.create", {"windowId": wid}, id_=2))["result"]["sessionId"]
    await it.settle()

    def broken(session_id):
        raise RuntimeError("a store that could not forget")

    monkeypatch.setattr(svc.status, "reset_turn", broken)
    with caplog.at_level("ERROR", logger="aitermd.service"):
        await it.user_closes_session(second)  # the tick its notification starts
    assert (await next_event(r, "session.closed"))["sessionId"] == second


@pytest.mark.parametrize("part,method", [("windows", "forget_session"), ("status", "reset_turn"), ("resolver", "forget")])
async def test_a_part_that_cannot_forget_a_closed_session_does_not_keep_the_others_from_it(stack, monkeypatch, caplog, part, method):
    svc, it, files, r, w = stack
    what = {"windows": "window state", "status": "turn", "resolver": "bindings"}[part]
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "codex", job_pid=301, title="Codex")
    await svc.tick()
    for event in ("SessionStart", "SubagentStart"):
        await svc.hook_router.handle_hook("/hook/codex", {"hook_event_name": event, "session_id": "thread-z", "cwd": "/wt",
                                                          "agent_id": "child", "_aiterm_iterm_session_id": sid})
    await call(r, w, "sessions.setTitles", {"titles": [{"sessionId": sid, "title": "main"}]}, id_=2)
    assert svc.status.turn(sid) and svc.resolver._pins and sid in svc.windows._applied_titles

    def broken(session_id):
        raise RuntimeError("a store that could not forget")

    monkeypatch.setattr(getattr(svc, part), method, broken)
    with caplog.at_level("ERROR", logger="aitermd.service"):
        await it.close_window(wid)
        await svc.tick()
    assert part == "windows" or sid not in svc.windows._applied_titles
    assert part == "status" or svc.status.turn(sid) is None
    assert part == "resolver" or not svc.resolver._pins
    assert f"forgetting the {what} of closed session {sid} failed" in [rec.getMessage() for rec in caplog.records]


async def test_a_failing_step_of_the_status_pass_does_not_cost_the_others(stack, monkeypatch, caplog):
    svc, it, files, r, w = stack
    sid = await _claude_tab_busy(svc, r, w, 951, "c1")

    def broken(paths):
        raise RuntimeError("transcript layout nobody expected")

    monkeypatch.setattr(svc.status, "release_dead_subagents", lambda tails: broken(tails))
    with caplog.at_level("ERROR", logger="aitermd.service"):
        await svc.tick()
    assert svc.registry.get(sid).state == "working"
    await asyncio.wait_for(_published_until(r, lambda p: p["sessionId"] == sid and p["state"] == "working"), 2)
    assert any("subagent" in rec.getMessage() for rec in caplog.records)


async def test_one_sessions_failing_corroboration_does_not_stop_the_others(stack, monkeypatch, caplog):
    svc, it, files, r, w = stack
    first = await _claude_tab_busy(svc, r, w, 952, "c1")
    wid = svc.registry.get(first).window_id
    second = await _claude_tab_busy(svc, r, w, 953, "c2", user_tab_of=wid)
    real = svc.status.apply_claude_file_status

    def apply(session_id, *args):
        if session_id == first:
            raise OverflowError("cannot convert float infinity to integer")
        return real(session_id, *args)

    monkeypatch.setattr(svc.status, "apply_claude_file_status", apply)
    with caplog.at_level("ERROR", logger="aitermd.service"):
        await svc.tick()
    assert svc.registry.get(second).state == "working"
    assert any(first in rec.getMessage() for rec in caplog.records)


async def test_an_off_loop_check_that_raises_answers_what_it_was_given_for_nothing(make_service, caplog):
    svc = make_service()

    def broken():
        raise ValueError("boom")

    with caplog.at_level("ERROR", logger="aitermd.service"):
        assert await svc._off_loop("a check", broken, "nothing") == "nothing"
    assert any("a check" in rec.getMessage() for rec in caplog.records)


async def test_an_off_loop_check_that_fails_after_the_tick_gave_up_on_it_is_not_left_unretrieved(make_service, monkeypatch, caplog):
    monkeypatch.setattr(service, "OFF_LOOP_CHECK_SECONDS", 0.05)
    svc = make_service()
    release, handled = threading.Event(), []
    asyncio.get_running_loop().set_exception_handler(lambda loop, context: handled.append(context))

    def late_failure():
        release.wait(5)
        raise ValueError("too late for anyone")

    with caplog.at_level("WARNING", logger="aitermd.service"):
        assert await svc._off_loop("a check", late_failure, "nothing") == "nothing"
        release.set()
        await wait_until(lambda: svc._checks["a check"].done())
        await asyncio.sleep(0.01)
    svc._checks.clear()
    gc.collect()
    await asyncio.sleep(0.01)
    assert handled == [], "Future exception was never retrieved"
    assert any("too late for anyone" in str(rec.exc_info[1]) for rec in caplog.records if rec.exc_info)


async def test_an_off_loop_check_that_hangs_does_not_hold_the_process_open(make_service, monkeypatch):
    # asyncio.run joins the default executor on exit, and a stat stuck on a dead mount never returns.
    monkeypatch.setattr(service, "OFF_LOOP_CHECK_SECONDS", 0.05)
    svc = make_service()
    release, threads = threading.Event(), []

    def hung():
        threads.append(threading.current_thread())
        release.wait(5)

    try:
        await svc._off_loop("a check", hung, None)
        assert threads[0].daemon, "a non-daemon worker is joined when the interpreter exits"
    finally:
        release.set()


def test_a_daemon_with_a_stuck_worker_thread_still_exits():
    # The package this checkout is testing, not whichever one the interpreter finds first: the
    # venv's install can point at an app bundle, and a bare `-c` imports from the current directory.
    daemon_dir = Path(__file__).resolve().parents[1]
    script = textwrap.dedent("""
        import asyncio, threading
        import aitermd
        from aitermd.offload import run_detached

        async def main():
            stuck = threading.Event()
            run_detached(lambda: stuck.wait())
            await asyncio.sleep(0.1)

        asyncio.run(main())
        print(aitermd.__file__)
    """)
    done = subprocess.run([sys.executable, "-c", script], timeout=20, capture_output=True, text=True, cwd=daemon_dir,
                          env={**os.environ, "PYTHONPATH": str(daemon_dir)})
    assert done.returncode == 0, done.stderr
    assert Path(done.stdout.strip()).is_relative_to(daemon_dir)


async def test_a_title_only_change_is_not_broadcast_yet_still_drives_a_codex_turn(stack):
    svc, it, files, r, w = stack
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "codex", job_pid=401, title="Codex")
    await svc.tick()
    assert svc.registry.get(sid).state == "idle"
    await drain_events(r)

    await it.user_runs(sid, "codex", job_pid=401, title="⠋ Codex")
    await svc.tick()
    await it.user_runs(sid, "codex", job_pid=401, title="⠙ Codex")
    await svc.tick()

    assert svc.registry.get(sid).title == "⠙ Codex"
    assert svc.registry.get(sid).state == "working", "the spinner is read from the registry"
    changes = [e["payload"] for e in await drain_events(r) if e.get("event") == "session.changed"]
    assert [c["state"] for c in changes] == ["working"], "the state change is announced once; the later glyph is not"


async def test_codex_rollouts_are_read_off_the_event_loop(stack):
    svc, it, files, r, w = stack
    reader: dict[str, set[int]] = {}

    class Recording(CodexSessionFiles):
        def _note(self, what):
            reader.setdefault(what, set()).add(threading.get_ident())

        def context_percent(self, session_id):
            self._note("context")
            return super().context_percent(session_id)

        def rate_limits(self):
            self._note("limits")
            return super().rate_limits()

        def retain(self, session_ids):
            self._note("retain")
            super().retain(session_ids)

    svc.codex_files = Recording(files.root.parent / "codex-sessions")
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "codex", job_pid=402, title="Codex")
    await svc.tick()
    await svc.hook_router.handle_hook("/hook/codex", {"hook_event_name": "SessionStart", "session_id": "thread-off",
                                                      "cwd": "/wt", "_aiterm_iterm_session_id": sid})
    rollout = svc.codex_files.root / "2026" / "09" / "22" / "rollout-2026-09-22T09-26-25-thread-off.jsonl"
    rollout.parent.mkdir(parents=True)
    rollout.write_text(json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": {
        "last_token_usage": {"total_tokens": 50}, "model_context_window": 100}}}) + "\n")

    await svc.tick()

    assert svc.registry.get(sid).context_percent == 50
    assert set(reader) == {"context", "limits", "retain"}
    assert threading.get_ident() not in set().union(*reader.values())


async def test_a_codex_context_read_that_timed_out_holds_back_both_reads_until_it_returns(stack, monkeypatch):
    svc, it, files, r, w = stack
    monkeypatch.setattr(service, "OFF_LOOP_CHECK_SECONDS", 0.05)
    release = threading.Event()
    calls = {"context": 0, "limits": 0}

    class FirstReadHangs(CodexSessionFiles):
        def context_percent(self, session_id):
            calls["context"] += 1
            if calls["context"] == 1:
                release.wait(5)
            return super().context_percent(session_id)

        def rate_limits(self):
            calls["limits"] += 1
            return super().rate_limits()

    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "codex", job_pid=403, title="Codex")
    await svc.tick()
    await svc.hook_router.handle_hook("/hook/codex", {"hook_event_name": "SessionStart", "session_id": "thread-slow",
                                                      "cwd": "/wt", "_aiterm_iterm_session_id": sid})
    svc.codex_files = FirstReadHangs(files.root.parent / "codex-sessions")
    rollout = svc.codex_files.root / "2026" / "09" / "22" / "rollout-2026-09-22T09-26-25-thread-slow.jsonl"
    rollout.parent.mkdir(parents=True)
    rollout.write_text(json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": {
        "last_token_usage": {"total_tokens": 50}, "model_context_window": 100}}}) + "\n")
    try:
        await svc.tick()                   # the context read gives up at its deadline
        assert svc.registry.get(sid).context_percent is None
        await svc.tick()                   # still stuck: neither read starts beside it
        assert calls == {"context": 1, "limits": 1}
    finally:
        release.set()
    await asyncio.wait_for(asyncio.shield(svc._checks[service.CODEX_READ]), 2)

    await svc.tick()

    assert svc.registry.get(sid).context_percent == 50
    assert calls == {"context": 2, "limits": 2}


async def test_a_codex_rollout_read_that_hangs_costs_the_tick_its_deadline_not_the_loop(stack, monkeypatch):
    svc, it, files, r, w = stack
    monkeypatch.setattr(service, "OFF_LOOP_CHECK_SECONDS", 0.05)
    release = threading.Event()

    class Hung(CodexSessionFiles):
        def rate_limits(self):
            release.wait(5)
            return None

    svc.codex_files = Hung(files.root.parent / "codex-sessions")
    started = time.monotonic()
    try:
        await svc.tick()
        elapsed = time.monotonic() - started
    finally:
        release.set()
    assert elapsed < 1, "the tick gave up on the read at its deadline instead of waiting for it"


async def test_windows_iterm2_lost_while_away_are_announced_after_it_reconnects_and_before_the_snapshot(make_service):
    """What the app tells a person's close from iTerm2 going away by (ClosedWindowTriage): a quit or a
    crash drops the connection -- `iterm.disconnected` -- and no tick can see a window go while iTerm2
    is away. Those windows are announced closed by the first tick once it is back, which runs before
    the reply to the snapshot the app asks for on `iterm.connected`."""
    async def no_wait(_seconds):
        await asyncio.sleep(0.001)

    svc = make_service(supervisor={"reconnect_sleep": no_wait})
    await svc.start()
    it = svc.iterm
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    await drain_events(r)

    await it.disconnect()
    await it.close_window(wid)
    events = [m.get("event") for m in await drain_events(r)]
    assert "iterm.disconnected" in events and "window.closed" not in events

    await it.reconnect()
    assert await next_event(r, "iterm.connected") == {"version": "3.7.2"}
    w.write((json.dumps({"id": 9, "method": "workspace.snapshot", "params": None}) + "\n").encode())
    await w.drain()
    before_reply: list[dict] = []
    while (msg := json.loads(await asyncio.wait_for(r.readline(), 2))).get("id") != 9:
        before_reply.append(msg)
    assert {"event": "window.closed", "payload": {"windowId": wid}} in before_reply
    assert msg["result"]["connected"] is True and msg["result"]["sessions"] == []
    w.close()


async def test_the_tick_reads_each_clis_version_from_its_own_files(stack):
    svc, it, files, r, w = stack
    svc.codex_files = CodexSessionFiles(files.root.parent / "codex-sessions")
    first = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    second = (await call(r, w, "window.createTask", {"taskId": "t2", "cwd": "/wt2", "title": "y", "frame": FRAME},
                         id_=2))["result"]["windowId"]
    claude, codex = it.windows[first]["sessions"][0], it.windows[second]["sessions"][0]
    files.root.mkdir(parents=True)
    (files.root / "4242.json").write_text(json.dumps({"pid": 4242, "sessionId": "c1", "cwd": "/wt", "status": "idle",
                                                      "version": "2.1.301"}))
    await it.user_runs(claude, "claude", job_pid=4242)
    await it.user_runs(codex, "codex", job_pid=4343, title="Codex")
    await svc.tick()
    await svc.hook_router.handle_hook("/hook/codex", {"hook_event_name": "SessionStart", "session_id": "thread-v",
                                                      "cwd": "/wt2", "_aiterm_iterm_session_id": codex})
    rollout = svc.codex_files.root / "2026" / "09" / "22" / "rollout-2026-09-22T09-26-25-thread-v.jsonl"
    rollout.parent.mkdir(parents=True)
    rollout.write_text(json.dumps({"type": "session_meta", "payload": {"id": "thread-v", "session_id": "thread-v",
                                                                       "cli_version": "0.160.0"}}) + "\n")

    await svc.tick()

    assert svc.registry.get(claude).cli_version == "2.1.301"
    assert svc.registry.get(codex).cli_version == "0.160.0"
    await it.user_runs(claude, "claude", job_pid=4244)  # another Claude in the tab, its file not written yet
    await svc.tick()
    assert svc.registry.get(claude).cli_version is None


async def test_codex_rollout_cannot_change_a_replacement_thread(stack, monkeypatch):
    svc, it, files, r, w = stack
    svc.codex_files = CodexSessionFiles(files.root.parent / "codex-sessions")
    wid = (await call(r, w, "window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = it.windows[wid]["sessions"][0]
    await it.user_runs(sid, "codex", job_pid=500, title="Codex")
    await svc.tick()
    svc.resolver.bind(sid, "codex", "old-thread", "SessionStart")

    async def replaced_during_read(name, work, nothing):
        svc.resolver.bind(sid, "codex", "new-thread", "SessionStart")
        return {"old-thread": (90, "old-version")}

    monkeypatch.setattr(svc, "_off_loop", replaced_during_read)
    assert await svc._apply_codex_rollouts({sid: "old-thread"}) == []
    session = svc.registry.get(sid)
    assert (session.context_percent, session.cli_version) == (None, None)


async def test_service_stop_drains_the_shared_tick_started_by_an_unplaced_hook(make_service):
    svc = make_service()
    await svc.start()
    entered, finished, release = asyncio.Event(), asyncio.Event(), asyncio.Event()

    async def gated_tick():
        entered.set()
        try:
            await release.wait()
        finally:
            finished.set()

    svc.hook_router._tick = gated_tick
    try:
        assert await post_hook(svc.hooks.port, "/hook/codex", {
            "hook_event_name": "UserPromptSubmit", "session_id": "unplaced", "cwd": "/missing"}) == 200
        await asyncio.wait_for(entered.wait(), 1)
        await asyncio.wait_for(svc.stop(), 1)
        assert finished.is_set(), "the shielded tick must end before the service finishes stopping"
    finally:
        release.set()
        await asyncio.wait_for(finished.wait(), 1)


async def test_snapshot_uses_app_supplied_claude_directory(stack, tmp_path, monkeypatch):
    svc, _, _, r, w = stack
    profile = tmp_path / "Claude Profile"
    sessions = profile / "sessions"
    sessions.mkdir(parents=True)
    (sessions / "123.json").write_text(json.dumps({"pid": 123, "sessionId": "moved", "status": "idle"}))
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "wrong"))
    response = await call(r, w, "workspace.snapshot", {"claudeConfigDirectory": str(profile)})
    assert response["result"]["claudeConfigDirectory"] == str(profile)
    assert svc.claude_files.root == sessions
    assert svc.resolver.claude_files.pid_for_session("moved") == 123
    other = tmp_path / "other"
    await call(r, w, "workspace.snapshot", {"claudeConfigDirectory": str(other)})
    assert svc.claude_files.pid_for_session("moved") is None


async def test_snapshot_echoes_the_claude_directory_as_the_app_spelled_it(stack, tmp_path):
    svc, _, _, r, w = stack
    spelled = f"{tmp_path}/./Claude Profile"  # pathlib would spell it without the "./"
    response = await call(r, w, "workspace.snapshot", {"claudeConfigDirectory": spelled})
    assert response["result"]["claudeConfigDirectory"] == spelled
    assert svc.claude_files.root == tmp_path / "Claude Profile" / "sessions"



@pytest.mark.parametrize("directory", ["", "relative/path", "~/claude"])
async def test_snapshot_rejects_nonabsolute_claude_directory(stack, directory):
    svc, _, _, r, w = stack
    root = svc.claude_files.root
    response = await call(r, w, "workspace.snapshot", {"claudeConfigDirectory": directory})
    assert response["error"]["code"] == "bad_params"
    assert svc.claude_files.root == root


async def test_closed_session_forgets_prompt_attribution(stack):
    svc, *_ = stack
    svc.hook_router.typed_by_you = lambda _: True
    svc.hook_router._note_prompt("reused", "first")
    svc._forget_session("reused")
    assert "reused" not in svc.hook_router._prompted
