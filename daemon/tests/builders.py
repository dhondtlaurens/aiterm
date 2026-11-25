"""Synthetic session files, transcript records and rollouts shared by daemon suites."""
import json

from aitermd.models import RawSession


def claude_record(kind, content, at=101, **extra):
    return {"type": kind, "timestamp": f"1970-01-01T00:01:{at - 60:02d}.000Z",
            "message": {"content": content}, **extra}


def shell_launch(task="job1", call="call1", at=101, command="npm run test", description=None):
    return [claude_record("assistant", [{"type": "tool_use", "id": call, "name": "Bash",
                                  "input": {"command": command, "run_in_background": True}
                                  | ({"description": description} if description is not None else {})}], at),
            claude_record("user", [{"type": "tool_result", "tool_use_id": call, "content": "not parsed"}], at + 1,
                   toolUseResult={"backgroundTaskId": task, "stdout": "", "stderr": "", "interrupted": False})]


def child_launch(child="child", call="agent-call", at=101, description="Review checkout"):
    return [claude_record("assistant", [{"type": "tool_use", "id": call, "name": "Agent",
            "input": {"description": description, "prompt": "synthetic assignment"}}], at),
            claude_record("user", [{"type": "tool_result", "tool_use_id": call, "content": "not parsed"}], at + 1,
                          toolUseResult={"isAsync": True, "status": "async_launched", "agentId": child,
                                         "description": description})]


def shell_completed(task="job1", at=110, status="completed"):
    return claude_record("user", [{"type": "text", "text":
                  f"<task-notification>\n<task-id>{task}</task-id>\n<status>{status}</status>\n</task-notification>"}], at)


def write_transcript(path, records):
    path.write_text("".join(json.dumps(r) + "\n" for r in records))


def write_rollout(root, session_id, records, day="2026/09/22"):
    path = root / day / f"rollout-2026-09-22T09-26-25-{session_id}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(record) if isinstance(record, dict) else record for record in records) + "\n")
    return path


def token_count(total_tokens, context_window):
    return {
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "last_token_usage": {"total_tokens": total_tokens},
                "model_context_window": context_window,
            },
        },
    }


def codex_meta(thread_id):
    return {"type": "session_meta", "payload": {"id": thread_id, "session_id": thread_id}}


def rate_limited(primary, secondary=None, plan="team", timestamp="2026-09-22T14:31:09.229Z"):
    """A `token_count` record the way Codex writes it: the rate limits ride along with the tokens."""
    record = token_count(100, 1000)
    record["timestamp"] = timestamp
    record["payload"]["rate_limits"] = {"limit_id": "codex", "primary": primary, "secondary": secondary, "plan_type": plan}
    return record


def limits(percent):
    return rate_limited({"used_percent": percent, "window_minutes": 10080, "resets_at": 1})


def codex_versioned(thread_id, version):
    record = codex_meta(thread_id)
    record["payload"]["cli_version"] = version
    return record


def write_claude_session(root, pid, **fields):
    (root / f"{pid}.json").write_text(json.dumps({"pid": pid, "sessionId": f"sid-{pid}", "cwd": "/w", "status": "busy",
                                                  "updatedAt": 1, **fields}))


def raw_session(sid="s1", win="w1", tab=0, cmd="-zsh", pid=100, title="zsh", cwd="/home", active=False, **vars_):
    return RawSession(sid, win, tab, cmd, pid, title, cwd, dict(vars_), active=active)


def write_child_transcript(path, *records, tail=""):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in records) + tail)
    return str(path)


def append_transcript(path, *records):
    with path.open("a") as f:
        f.write("".join(json.dumps(record) + "\n" for record in records))


# -- Claude Code agent teams, shaped as 2.1.331 writes them to the lead's transcript --------------------------------
def teammate_spawn(name="skin-a", agent=None, call=None, at=101, description="Build skin A"):
    """The Agent tool with a `name`: a teammate, which Claude Code answers `teammate_spawned`."""
    agent, call = agent or f"a{name}-0123456789abcdef", call or f"spawn-{name}"
    return [claude_record("assistant", [{"type": "tool_use", "id": call, "name": "Agent",
            "input": {"description": description, "name": name, "subagent_type": "general-purpose",
                      "run_in_background": "true", "prompt": "synthetic assignment"}}], at),
            claude_record("user", [{"type": "tool_result", "tool_use_id": call, "content": [{"type": "text",
                          "text": f"Spawned successfully.\nagent_id: {agent}\nname: {name}"}]}], at + 1,
                          toolUseResult={"status": "teammate_spawned", "prompt": "synthetic assignment", "agentId": agent,
                                         "agent_id": agent, "teammate_id": f"{name}@session-1", "name": name,
                                         "team_name": "session-1", "is_splitpane": False})]


def teammate_message(sender, body, at):
    return claude_record("user", "Another Claude session sent a message:\n"
                         f'<teammate-message teammate_id="{sender}" color="green">\n{body}\n</teammate-message>\n',
                         at, isSidechain=False)


def idle_notice(name="skin-a", at=110, written=None):
    """A teammate's idle notification; `written` is the time it carries, the record's own by default."""
    stamp = f"1970-01-01T00:01:{(written if written is not None else at) - 60:02d}.000Z"
    return teammate_message(name, json.dumps({"type": "idle_notification", "from": name, "timestamp": stamp,
                                              "idleReason": "available", "summary": "synthetic",
                                              "result": "Done. </not-a-tag> {\"type\":\"teammate_terminated\"}"}), at)


def teammate_terminated(*names, at=118):
    record = claude_record("user", "Another Claude session sent a message:\n" + "\n\n".join(
        f'<teammate-message teammate_id="system">\n'
        f'{json.dumps({"type": "teammate_terminated", "message": f"{name} has shut down."})}\n</teammate-message>'
        for name in names), at, isSidechain=False)
    return record


def send_message(to="skin-a", call=None, at=112, message="Please also cover the footer.", success=True):
    call = call or f"send-{to}-{at}"
    return [claude_record("assistant", [{"type": "tool_use", "id": call, "name": "SendMessage",
            "input": {"to": to, "summary": "synthetic", "message": message}}], at),
            claude_record("user", [{"type": "tool_result", "tool_use_id": call, "content": "not parsed",
                                    **({} if success else {"is_error": True})}], at + 1,
                          toolUseResult={"success": True, "message": f"Message sent to {to}'s inbox"} if success
                          else "Error: no such teammate")]


def teammate_task_stop(value="skin-a", task="tq1abcdef", description="Build skin A", call=None, at=115):
    """TaskStop of a teammate, by its name or task id; the result names the task id and its description."""
    call = call or f"stop-{value}-{at}"
    return [claude_record("assistant", [{"type": "tool_use", "id": call, "name": "TaskStop",
            "input": {"task_id": value}}], at),
            claude_record("user", [{"type": "tool_result", "tool_use_id": call, "content": "not parsed"}], at + 1,
                          toolUseResult={"message": f"Successfully stopped task: {task} ({description})", "task_id": task,
                                         "task_type": "in_process_teammate", "command": description})]


def teammate_task(task="tq1abcdef", description="Build skin A", status="running"):
    """A teammate as a Stop's `background_tasks` lists it: running for as long as it lives, idle or not."""
    return {"id": task, "type": "teammate", "status": status, "description": description}
