"""What the daemon knows of Antigravity (`agy`): the payload its `hooks.json` hooks get on stdin,
which AiTerm's hook script posts unchanged, with the tab in X-AiTerm-iTerm-Session.

Its hooks speak first with the first prompt -- SessionStart and PreInvocation arrive together -- so a
tab started without one says nothing until then, and its folder-trust dialog, which comes before any
hook loads, is read from the screen as PI's is."""
from __future__ import annotations

from typing import TYPE_CHECKING, Any

from ..hook_events import HookEvent, StatusLine, TickState
from ..models import ITERM_SESSION_FIELD, SessionInfo, Transition
from ..text import nonempty_string
from ..usage import clamped_percent

if TYPE_CHECKING:
    from ..status import StatusEngine

# The events AiTerm's driver registers, and what each says of the turn. PreInvocation runs before
# every model call of a turn; the turn's first one starts it, and the rest repeat working. A Stop
# ends the turn however it ended (`terminationReason`): finished, cancelled or failed.
AGY_EVENTS: dict[str, Transition | None] = {
    "SessionStart": "sessionStart",
    "PreInvocation": "working",
    "PostInvocation": None,
    "Stop": "done",
}


def parse_agy_hook(p: dict[str, Any]) -> HookEvent | None:
    if not isinstance(p, dict):
        return None
    name = nonempty_string(p.get("hookEventName"))
    if name is None or name not in AGY_EVENTS:
        return None
    return HookEvent(
        "agy", AGY_EVENTS[name],
        nonempty_string(p.get("conversationId")),
        nonempty_string(p.get("cwd")),
        iterm_session_id=nonempty_string(p.get(ITERM_SESSION_FIELD)),
        event_name=name,
        transcript=nonempty_string(p.get("transcriptPath")),
    )


# What the status line's `agent_state` says of the turn. Starting up, signing in or failing says
# nothing: a failed turn ends with its Stop hook.
_TICK_STATES: dict[str, TickState] = {"working": "working", "tool_use": "working", "reviewing": "working", "idle": "done"}


def parse_agy_statusline(p: dict[str, Any], now: int) -> StatusLine:
    """A post of AiTerm's status-line shim: the payload Antigravity gives its status line on every change
    of state. It names the conversation, the context used and what the turn is doing: a tool waiting for
    the person's approval (`tool_confirmation_pending`) is the one sign of needs-input agy gives. Its
    `transcript_path` names the desktop app's folder, not the CLI's, so the hooks' is the one kept. It
    reports no account usage AiTerm reads."""
    agent_state = p.get("agent_state")
    state = _TICK_STATES.get(agent_state) if isinstance(agent_state, str) else None
    if state is not None and p.get("tool_confirmation_pending") is True:
        state = "needsInput"
    window = p.get("context_window")
    return StatusLine(
        None,
        nonempty_string(p.get("conversation_id")) or nonempty_string(p.get("session_id")),
        nonempty_string(p.get("cwd")),
        nonempty_string(p.get(ITERM_SESSION_FIELD)),
        clamped_percent(window.get("used_percentage")) if isinstance(window, dict) else None,
        state=state,
    )


def trust_screens(status: StatusEngine, sessions: list[SessionInfo]) -> list[str]:
    """The Antigravity tabs whose screen may show its folder-trust dialog: a process that has not
    named its conversation yet, while its row is idle, and any tab the dialog holds now, to see it close."""
    return [s.session_id for s in sessions if s.agent == "agy" and s.job_pid and (
        (s.conversation_id is None and s.state == "idle") or status.showing_trust_prompt(s.session_id))]
