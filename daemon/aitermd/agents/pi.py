"""What the daemon knows of PI: its extension's hook payloads. PI has no tick signal: what its hooks
say stands, so each turn of a run says working again, and a run whose `agent_start` was lost still
shows."""
from __future__ import annotations

from typing import TYPE_CHECKING, Any

from ..hook_events import HookEvent
from ..models import ITERM_SESSION_FIELD, SessionInfo, Transition, Usage
from ..text import nonempty_string
from ..usage import clamped_percent
from .codex import parse_codex_rate_limits

if TYPE_CHECKING:
    from ..status import StatusEngine

PI_EVENTS: dict[str, Transition | None] = {
    "session_start": None,  # "sessionStart" for a reason in PI_NEW_CONVERSATION_REASONS
    "agent_start": "working",
    "agent_settled": "done",
    "ui_prompt_start": "promptStart",
    "ui_prompt_end": "promptEnd",
    "thinking_level_select": None,
    # Each model call of a run. PI runs its launch prompt at once, before iTerm2 names the tab's job:
    # an `agent_start` the daemon could not place is mended by the run's next turn. No blocking prompt
    # can be open then (it holds the tool that opened it), and the extension posts in order, so one
    # never lands after the run's `agent_settled`.
    "turn_start": "working",
    # Refresh context after each tool turn while the agent keeps running.
    "turn_end": None,
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
    return HookEvent(
        agent="pi",
        kind=kind,
        session_id=nonempty_string(p.get("session_id")),
        cwd=nonempty_string(p.get("cwd")),
        iterm_session_id=nonempty_string(p.get(ITERM_SESSION_FIELD)),
        context_percent=clamped_percent(p.get("context_percent")),
        event_name=name,
    )


# The vendors whose account a PI provider spends, by the PI provider that reports its rate limits.
# `openai-codex` is the ChatGPT sign-in Codex uses: one account, one footer.
PI_USAGE_PROVIDERS = {"codex": "codex"}


def parse_pi_usage(p: dict[str, Any], updated_at: int) -> tuple[str, Usage] | None:
    """A `rate_limits` post: the `codex.rate_limits` block PI's Codex provider receives with each
    response, in the shape Codex itself writes to its rollout, save that a window's reset is
    `reset_at`. The vendor whose footer it fills, and its windows; None for any other post."""
    if not isinstance(p, dict) or p.get("hook_event_name") != "rate_limits":
        return None
    vendor, limits = PI_USAGE_PROVIDERS.get(nonempty_string(p.get("vendor")) or ""), p.get("rate_limits")
    if vendor is None or not isinstance(limits, dict):
        return None
    windows = {key: ({"resets_at": w.get("reset_at")} | w if isinstance(w, dict) else w) for key, w in limits.items()}
    usage = parse_codex_rate_limits(windows, updated_at)
    return (vendor, usage) if usage.five_hour or usage.seven_day else None


def trust_screens(status: StatusEngine, sessions: list[SessionInfo]) -> list[str]:
    """The PI tabs whose screen may show its folder-trust dialog: a PI process that has not posted its
    session yet, while its row is idle, and any tab the dialog holds now, to see it close."""
    return [s.session_id for s in sessions if s.agent == "pi" and s.job_pid and (
        (s.conversation_id is None and s.state == "idle") or status.showing_trust_prompt(s.session_id))]
