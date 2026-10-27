from __future__ import annotations

import os
from collections.abc import Callable
from dataclasses import dataclass, replace
from typing import Any, NamedTuple

from .text import nonempty_string
from .models import HARNESSES, ITERM_SESSION_FIELD, AgentKind, BackgroundJob, Transition, Usage
from .usage import finite_number, parse_claude_rate_limits

NEEDS_INPUT_NOTIFICATIONS = {"permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog"}
SIMPLE_EVENTS: dict[str, Transition] = {"UserPromptSubmit": "working", "Stop": "done", "PermissionRequest": "needsInput"}



@dataclass(frozen=True, slots=True)
class HookEvent:
    agent: AgentKind
    kind: Transition | None
    model: str | None
    session_id: str | None
    cwd: str | None
    subagent_id: str | None = None
    iterm_session_id: str | None = None
    reasoning: str | None = None
    context_percent: int | None = None
    # Where a Claude SubagentStart's child writes its transcript, or a directory or two below (SubagentTranscripts.read):
    # what the status engine reads on every tick, for whether the child's run is over and when it last wrote.
    subagent_transcript: str | None = None
    # The subagents a Claude Stop's `background_tasks` says are still running; None when it cannot say.
    running_subagents: frozenset[str] | None = None
    # The work a Claude Stop's `background_tasks` says is still in flight, which wakes the session again once it ends:
    # a shell by its command, anything else by its description, a subagent with its agent_id. None when it cannot say.
    background_work: tuple[BackgroundJob, ...] | None = None
    # What a UserPromptSubmit submitted, as the agent got it; None for every other event.
    prompt: str | None = None
    # The harness's own name for the event (`hook_event_name`): a Codex thread's binding to its tab
    # depends on which event bound it (SessionResolver.bind).
    event_name: str | None = None
    # Where a Claude session writes its conversation (`transcript_path`), from a post of its own: what shows what
    # became of a slash command AiTerm typed there (slash_commands).
    transcript: str | None = None
    # The API error that ended a Claude turn in place of its Stop (StopFailure's `error`: `rate_limit`, `billing_error`,
    # `authentication_failed`...); None for every other event.
    stop_error: str | None = None

    @property
    def conversation_id(self) -> str | None:
        """The conversation the post's tab runs, which a reopened window resumed: its session id,
        unless the post is a subagent's start or stop in any harness (a Codex child's carries its own
        thread id)."""
        return None if self.kind in ("subagentStart", "subagentStop") else self.session_id


def _subagent(name: str, p: dict[str, Any]) -> tuple[Transition, str] | None:
    child = nonempty_string(p.get("agent_id"))
    return ("subagentStart" if name == "SubagentStart" else "subagentStop", child) if child else None


def _claude_subagent_transcript(p: dict[str, Any], child: str) -> str | None:
    """The child's transcript. SubagentStart carries only the session's, `<dir>/<session>.jsonl`;
    Claude Code writes the child's beside it, at `<dir>/<session>/subagents/agent-<id>.jsonl`, or
    files it a directory or two further down, where the reader looks too. A path the hook gives for
    the child itself (`agent_transcript_path`, which so far only SubagentStop has carried) wins."""
    if (own := nonempty_string(p.get("agent_transcript_path"))) is not None:
        return own
    session = nonempty_string(p.get("transcript_path"))
    if session is None or not session.endswith(".jsonl"):
        return None
    return os.path.join(session.removesuffix(".jsonl"), "subagents", f"agent-{child}.jsonl")


# The `background_tasks` types whose children the daemon can match by id: a subagent's task id is its
# agent_id, and shells, monitors and MCP tasks run no agent. A teammate's task id is not the agent_id
# its hooks carry, and a workflow's agents sit behind the workflow's own id.
CLAUDE_MATCHABLE_TASK_TYPES = frozenset({"subagent", "shell", "monitor", "MCP task"})
# The statuses Claude Code lists a task under while it is in flight.
CLAUDE_IN_FLIGHT_TASK_STATUSES = frozenset({"running", "pending"})
# How Claude Code describes the watch it keeps on an artifact it published or was asked to watch: a monitor with no
# MCP server that runs for the rest of the session, which Claude Code counts as no activity (`ambient`, a flag its
# hooks do not carry). Its description is all a Stop says of it (Claude Code 2.1.308).
CLAUDE_ARTIFACT_WATCH_PREFIX = "live updates for artifact "


def _claude_background_work(tasks: Any) -> tuple[BackgroundJob, ...] | None:
    """What a Stop's `background_tasks` lists as in flight: the shells, subagents, monitors and other work Claude Code
    resumes the session for once each ends (a dev server left running among them), each by its kind, a subagent with
    its agent_id. None when there is no list to read."""
    if not isinstance(tasks, list):
        return None
    work: list[BackgroundJob] = []
    for task in tasks:
        if not isinstance(task, dict) or (kind := nonempty_string(task.get("type"))) is None:
            continue
        if nonempty_string(task.get("status")) not in CLAUDE_IN_FLIGHT_TASK_STATUSES or _claude_artifact_watch(task):
            continue
        said = nonempty_string(task.get("command")) if kind == "shell" else None
        if (said := said or nonempty_string(task.get("description"))) is None:
            continue
        if kind != "subagent":
            work.append(BackgroundJob("shell" if kind == "shell" else "monitor" if kind == "monitor" else "task", said))
        # Only a subagent named by its agent_id is a child the status engine can count.
        elif (child := nonempty_string(task.get("id"))) is not None:
            work.append(BackgroundJob("subagent", said, child))
    return tuple(work)


def _claude_artifact_watch(task: dict[str, Any]) -> bool:
    """Whether a `background_tasks` entry is Claude Code watching an artifact for comments, which never ends and
    wakes the session only when someone comments: no work in flight."""
    said = nonempty_string(task.get("description"))
    return (task.get("type") == "monitor" and task.get("server") is None
            and said is not None and said.startswith(CLAUDE_ARTIFACT_WATCH_PREFIX))


def _claude_running_subagents(tasks: Any) -> frozenset[str] | None:
    """The agent ids of the subagents a Stop's `background_tasks` lists as in flight. None when the
    list cannot prove a counted child gone: it is absent (an older Claude Code, or a registry it could
    not reach), malformed, or holds work whose agents it does not name by their agent_id."""
    if not isinstance(tasks, list):
        return None
    running: set[str] = set()
    for task in tasks:
        if not isinstance(task, dict) or nonempty_string(task.get("type")) not in CLAUDE_MATCHABLE_TASK_TYPES:
            return None
        if task["type"] != "subagent" or nonempty_string(task.get("status")) not in CLAUDE_IN_FLIGHT_TASK_STATUSES:
            continue
        if (child := nonempty_string(task.get("id"))) is None:
            return None
        running.add(child)
    return frozenset(running)


def _session_start(p: dict[str, Any]) -> Transition | None:
    """A Claude or Codex SessionStart begins a new conversation — except after a compaction,
    which each reports as `source: "compact"` in the middle of a turn whose background subagents may
    still be running. That one carries only metadata: resetting the turn there would end it early."""
    return None if p.get("source") == "compact" else "sessionStart"


def _submitted(name: str, p: dict[str, Any]) -> str | None:
    """The prompt a UserPromptSubmit submitted; None for any other event."""
    return nonempty_string(p.get("prompt")) if name == "UserPromptSubmit" else None


def _session_field(p: dict[str, Any], key: str) -> str | None:
    """What a Claude post says of its session under `key`. Claude Code adds `agent_id` to a hook that fires within a
    subagent, whose model is the child's: such a post says nothing of the session."""
    return None if nonempty_string(p.get("agent_id")) else nonempty_string(p.get(key))


def parse_claude_hook(p: dict[str, Any]) -> HookEvent | None:
    # Another CLI that runs ~/.claude/settings.json hooks (Grok Build does) sends `hookEventName`,
    # which Claude never does: such a post is not Claude's.
    if not isinstance(p, dict) or "hookEventName" in p:
        return None
    ev = _claude_event(p)
    return replace(ev, transcript=_session_field(p, "transcript_path")) if ev is not None else None


def _claude_event(p: dict[str, Any]) -> HookEvent | None:
    name = nonempty_string(p.get("hook_event_name"))
    sid, cwd = nonempty_string(p.get("session_id")), nonempty_string(p.get("cwd"))
    # A hook's `effort` is not the session's: a Stop's is its turn's, which an /effort run mid-turn leaves behind. The
    # status line says the session's (parse_claude_statusline).
    if name == "SessionStart":
        return HookEvent("claude", _session_start(p), _session_field(p, "model"), sid, cwd, event_name=name)
    if name == "PostModelSwitch":
        return HookEvent("claude", None, _session_field(p, "to_model"), sid, cwd, event_name=name)
    if name in {"SubagentStart", "SubagentStop"}:
        if (child := _subagent(name, p)) is None:
            return None
        transcript = _claude_subagent_transcript(p, child[1]) if name == "SubagentStart" else None
        return HookEvent("claude", child[0], None, sid, cwd, child[1], subagent_transcript=transcript, event_name=name)
    if name == "Stop":
        tasks = p.get("background_tasks")
        return HookEvent("claude", "done", None, sid, cwd, running_subagents=_claude_running_subagents(tasks),
                         background_work=_claude_background_work(tasks), event_name=name)
    if name == "StopFailure":
        # Fired in place of Stop when an API error ended the turn; Claude Code names one it cannot tell `unknown`.
        return HookEvent("claude", "done", None, sid, cwd, event_name=name, stop_error=nonempty_string(p.get("error")) or "unknown")
    if name in SIMPLE_EVENTS:
        return HookEvent("claude", SIMPLE_EVENTS[name], None, sid, cwd, event_name=name, prompt=_submitted(name, p))
    if name == "Notification":
        nt = nonempty_string(p.get("notification_type"))
        if nt in NEEDS_INPUT_NOTIFICATIONS:
            return HookEvent("claude", "needsInput", None, sid, cwd, event_name=name)
        if nt == "agent_completed":
            return HookEvent("claude", "done", None, sid, cwd, event_name=name)
    return None


def parse_codex_hook(p: dict[str, Any]) -> HookEvent | None:
    if not isinstance(p, dict):
        return None
    name = nonempty_string(p.get("hook_event_name"))
    model, sid, cwd = (nonempty_string(p.get(key)) for key in ("model", "session_id", "cwd"))
    iterm_session_id = nonempty_string(p.get(ITERM_SESSION_FIELD))
    if name == "SessionStart":
        return HookEvent("codex", _session_start(p), model, sid, cwd, iterm_session_id=iterm_session_id, event_name=name)
    if name in {"SubagentStart", "SubagentStop"}:
        child = _subagent(name, p)
        return HookEvent("codex", child[0], None, sid, cwd, child[1], iterm_session_id, event_name=name) if child else None
    if name in SIMPLE_EVENTS:
        return HookEvent("codex", SIMPLE_EVENTS[name], model, sid, cwd, iterm_session_id=iterm_session_id, event_name=name,
                         prompt=_submitted(name, p))
    return None


PI_EVENTS: dict[str, Transition | None] = {
    "session_start": None,  # "sessionStart" for a reason in PI_NEW_CONVERSATION_REASONS
    "agent_start": "working",
    "agent_settled": "done",
    "ui_prompt_start": "promptStart",
    "ui_prompt_end": "promptEnd",
    "model_select": None,
    "thinking_level_select": None,
    # Refresh context after each tool turn while the agent keeps running.
    "turn_end": None,
    # PI has no subagents of its own; the extension relays pi-subagents' `subagents:*` bus events.
    "subagent_start": "subagentStart",
    "subagent_stop": "subagentStop",
}


# Why PI started a session, when that begins a new conversation. `reload` re-runs the extensions
# inside the running one -- PI's counterpart of Claude's compaction -- so, like a reason this
# daemon does not know or an extension too old to send one, it carries metadata only.
PI_NEW_CONVERSATION_REASONS = frozenset({"startup", "new", "resume", "fork"})


def _clamped_percent(value: Any) -> int | None:
    number = finite_number(value)
    return max(0, min(100, round(number))) if number is not None else None


def parse_pi_hook(p: dict[str, Any]) -> HookEvent | None:
    if not isinstance(p, dict):
        return None
    name = nonempty_string(p.get("hook_event_name"))
    if name is None or name not in PI_EVENTS:
        return None
    kind = PI_EVENTS[name]
    if name == "session_start" and nonempty_string(p.get("reason")) in PI_NEW_CONVERSATION_REASONS:
        kind = "sessionStart"
    child = None
    if kind in {"subagentStart", "subagentStop"} and (child := nonempty_string(p.get("agent_id"))) is None:
        return None
    return HookEvent(
        agent="pi",
        kind=kind,
        model=nonempty_string(p.get("model")),
        session_id=nonempty_string(p.get("session_id")),
        cwd=nonempty_string(p.get("cwd")),
        subagent_id=child,
        iterm_session_id=nonempty_string(p.get(ITERM_SESSION_FIELD)),
        reasoning=nonempty_string(p.get("reasoning")),
        context_percent=_clamped_percent(p.get("context_percent")),
        event_name=name,
    )


def _context_percent(p: dict[str, Any]) -> int | None:
    """`context_window.used_percentage`: how full *this conversation* is. Unlike the rate-limit
    windows it arrives from one session, so the service resolves that session and the status engine
    promotes it to the task's latest value rather than putting it in the vendor's `Usage`. Clamped,
    because the payload is another process's arithmetic and the ring cannot render 140%."""
    cw = p.get("context_window")
    if not isinstance(cw, dict):
        return None
    return _clamped_percent(cw.get("used_percentage"))


class StatusLine(NamedTuple):
    """What one status-line tick tells the daemon: the session it describes, and facts that land in
    different places -- account usage in the `UsageStore`, the model, effort and context fill on the
    resolved session's task. `usage` is None when the payload carries no rate-limit summary. The model
    and effort are the session's own, as Claude Code holds them now: changed only once an /model or
    /effort has run, and never a subagent's."""
    usage: Usage | None
    session_id: str | None
    cwd: str | None
    iterm_session_id: str | None
    model: str | None
    context_percent: int | None
    # `effort.level`, absent for a model that takes no effort.
    reasoning: str | None = None
    # Where the session writes its conversation (`transcript_path`), as its hooks name it too.
    transcript: str | None = None


def _object_field(p: dict[str, Any], key: str, field: str) -> str | None:
    """`p[key][field]` as a string, as in `model.id`."""
    value = p.get(key)
    return nonempty_string(value.get(field)) if isinstance(value, dict) else None


def parse_claude_statusline(p: dict[str, Any], now: int) -> StatusLine:
    return StatusLine(
        parse_claude_rate_limits(p.get("rate_limits"), now),
        nonempty_string(p.get("session_id")), nonempty_string(p.get("cwd")),
        nonempty_string(p.get(ITERM_SESSION_FIELD)),
        _object_field(p, "model", "id"), _context_percent(p), _object_field(p, "effort", "level"),
        nonempty_string(p.get("transcript_path")),
    )


HookParser = Callable[[dict[str, Any]], HookEvent | None]
# A status-line parser also takes the time a rate-limit summary is stamped with.
StatusLineParser = Callable[[dict[str, Any], int], StatusLine]
# Each harness's parsers. A route in models.HARNESSES without its parser here fails at import.
_HOOK_PARSER: dict[AgentKind, HookParser] = {
    "claude": parse_claude_hook, "codex": parse_codex_hook, "pi": parse_pi_hook,
}
_STATUSLINE_PARSER: dict[AgentKind, StatusLineParser] = {"claude": parse_claude_statusline}

# The agent hook routes, each with the parser for its agent's payload.
HOOK_PARSERS: dict[str, HookParser] = {h.hook_route: _HOOK_PARSER[h.agent] for h in HARNESSES}
# Each status-line shim's route, with the agent it reports on and the parser for its payload.
STATUSLINE_PARSERS: dict[str, tuple[AgentKind, StatusLineParser]] = {
    h.statusline_route: (h.agent, _STATUSLINE_PARSER[h.agent]) for h in HARNESSES if h.statusline_route}
