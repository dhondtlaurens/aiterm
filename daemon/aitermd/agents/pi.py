"""What the daemon knows of PI: its extension's hook payloads. PI has no tick signal: what its hooks
say stands."""
from __future__ import annotations

from typing import Any

from ..hook_events import HookEvent
from ..models import ITERM_SESSION_FIELD, Transition
from ..text import nonempty_string
from ..usage import clamped_percent

PI_EVENTS: dict[str, Transition | None] = {
    "session_start": None,  # "sessionStart" for a reason in PI_NEW_CONVERSATION_REASONS
    "agent_start": "working",
    "agent_settled": "done",
    "ui_prompt_start": "promptStart",
    "ui_prompt_end": "promptEnd",
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
        session_id=nonempty_string(p.get("session_id")),
        cwd=nonempty_string(p.get("cwd")),
        subagent_id=child,
        iterm_session_id=nonempty_string(p.get(ITERM_SESSION_FIELD)),
        context_percent=clamped_percent(p.get("context_percent")),
        event_name=name,
    )
