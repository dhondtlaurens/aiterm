"""Synthetic session files, transcript records and rollouts shared by daemon suites."""
import json

from aitermd.models import RawSession


def claude_record(kind, content, at=101, **extra):
    return {"type": kind, "timestamp": f"1970-01-01T00:01:{at - 60:02d}.000Z",
            "message": {"content": content}, **extra}


def shell_launch(task="job1", call="call1", at=101, command="npm run test"):
    return [claude_record("assistant", [{"type": "tool_use", "id": call, "name": "Bash",
                                  "input": {"command": command, "run_in_background": True}}], at),
            claude_record("user", [{"type": "tool_result", "tool_use_id": call, "content": "not parsed"}], at + 1,
                   toolUseResult={"backgroundTaskId": task, "stdout": "", "stderr": "", "interrupted": False})]


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
