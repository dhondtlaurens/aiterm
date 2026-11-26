"""What a hook or status-line post says, whichever agent sent it, and the parts of reading one that
Claude and Codex share. Each agent's parser lives in its module under `agents/`."""
from __future__ import annotations

from collections.abc import Callable
from dataclasses import KW_ONLY, dataclass
from typing import Any, Literal, NamedTuple

from .text import nonempty_string
from .models import AgentKind, BackgroundJob, Transition, Usage

SIMPLE_EVENTS: dict[str, Transition] = {"UserPromptSubmit": "working", "Stop": "done", "PermissionRequest": "needsInput"}


@dataclass(frozen=True, slots=True)
class HookEvent:
    agent: AgentKind
    kind: Transition | None
    session_id: str | None
    cwd: str | None
    _: KW_ONLY
    subagent_id: str | None = None
    iterm_session_id: str | None = None
    context_percent: int | None = None
    context_tokens: int | None = None
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
    # Where a Claude session writes its conversation (`transcript_path`), from a post of its own.
    transcript: str | None = None
    # The API error that ended a Claude turn in place of its Stop (StopFailure's `error`: `rate_limit`, `billing_error`,
    # `authentication_failed`...); None for every other event.
    stop_error: str | None = None
    subagent_label: str | None = None
    display_shells: tuple[BackgroundJob, ...] | None = None

    @property
    def conversation_id(self) -> str | None:
        """The conversation the post's tab runs, which a reopened window resumed: its session id,
        unless the post is a subagent's start or stop in any harness (a Codex child's carries its own
        thread id)."""
        return None if self.kind in ("subagentStart", "subagentStop") else self.session_id


def subagent_event(name: str, p: dict[str, Any]) -> tuple[Transition, str] | None:
    """A Claude or Codex SubagentStart or SubagentStop, with the child's agent id; None without one."""
    child = nonempty_string(p.get("agent_id"))
    return ("subagentStart" if name == "SubagentStart" else "subagentStop", child) if child else None


def session_start(p: dict[str, Any]) -> Transition | None:
    """A Claude or Codex SessionStart begins a new conversation — except after a compaction,
    which each reports as `source: "compact"` in the middle of a turn whose background subagents may
    still be running. That one carries only metadata: resetting the turn there would end it early."""
    return None if p.get("source") == "compact" else "sessionStart"


def submitted_prompt(name: str, p: dict[str, Any]) -> str | None:
    """The prompt a UserPromptSubmit submitted; None for any other event."""
    return nonempty_string(p.get("prompt")) if name == "UserPromptSubmit" else None


# What a status line can say a turn is doing (StatusLine.state), as tick evidence states it.
TickState = Literal["working", "needsInput", "done"]


class StatusLine(NamedTuple):
    """Account usage and context metadata reported by one session's status line."""
    usage: Usage | None
    session_id: str | None
    cwd: str | None
    iterm_session_id: str | None
    context_percent: int | None
    # Where the session writes its conversation (`transcript_path`), as its hooks name it too.
    transcript: str | None = None
    context_tokens: int | None = None
    # What the status line says the turn is doing, for a harness whose status line knows (Antigravity's
    # `agent_state`): tick evidence (status.Evidence), which may only move a turn already under way.
    state: TickState | None = None
    # The CLI's own version, where its status line says it (Antigravity's): the tab's `cli_version`.
    version: str | None = None


HookParser = Callable[[dict[str, Any]], HookEvent | None]
# A status-line parser also takes the time a rate-limit summary is stamped with.
StatusLineParser = Callable[[dict[str, Any], int], StatusLine]
