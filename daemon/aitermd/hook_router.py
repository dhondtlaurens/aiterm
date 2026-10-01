"""Agent hook posts, turned into status and usage changes."""
from __future__ import annotations
import logging
from collections.abc import Callable
from typing import Any

from .hook_events import HOOK_PARSERS, STATUSLINE_PARSERS
from .models import AgentKind
from .publisher import Publisher
from .resolver import SessionResolver
from .status import StatusEngine
from .usage import UsageStore

log = logging.getLogger(__name__)


class HookRouter:
    """Places each post on a tab through the resolver, applies it to the status engine or the
    usage store, and publishes what changed. Knows nothing of HTTP or of iTerm2."""

    def __init__(self, resolver: SessionResolver, status: StatusEngine, usage: UsageStore,
                 clock: Callable[[], float], publisher: Publisher):
        self.resolver, self.status, self.usage, self.clock, self.publisher = resolver, status, usage, clock, publisher

    async def handle_hook(self, path: str, body: dict[str, Any]) -> dict[str, Any] | None:
        if path in HOOK_PARSERS and isinstance(
                test_id := body.get("_aiterm_test_id"), str) and test_id:
            # The synthetic probe proves the extension reached this daemon. It is intentionally
            # acknowledged before parsing or session resolution and can never mutate real state.
            return {"ok": True, "testId": test_id}
        if (statusline := STATUSLINE_PARSERS.get(path)) is not None:
            agent, parse = statusline
            tick = parse(body, int(self.clock()))
            usage = tick.usage
            if usage and (usage.five_hour or usage.seven_day or usage.spend) and self.usage.set(agent, usage):
                await self.publisher.usage_changed()
            # The model, reasoning and context all arrive from one session, so one resolution serves
            # them. Status keeps the model on that session and promotes context to the task's latest
            # value. A tick can carry either without the other: `context_window` is present from
            # the first turn, while `model` only appears once Claude has settled on one.
            if (tick.model or tick.reasoning or tick.context_percent is not None) and (
                    sid := self._resolve_post(agent, tick.session_id, tick.cwd, tick.iterm_session_id)):
                await self.publisher.session_changed(self.status.apply_metadata(
                    sid, model=tick.model, reasoning=tick.reasoning, context=tick.context_percent))
            return None
        # Tool text and Stop hooks are telemetry, never checkout-removal authority.
        # Leave shell commands intact; explicit cleanup belongs to the app's Remove action.
        parser = HOOK_PARSERS.get(path)
        ev = parser(body) if parser else None
        if ev is None:
            return None
        sid = self._resolve_post(ev.agent, ev.session_id, ev.cwd, ev.iterm_session_id, body.get("hook_event_name"))
        if sid is None:
            log.debug("hook for unknown session: %s %s", ev.agent, ev.cwd)
            return None
        # The post came from the agent itself, so its cwd is the agent's — the only source
        # there is for a Codex or PI session, neither of which has a polled session file.
        changed = self.status.apply_metadata(sid, model=ev.model, reasoning=ev.reasoning,
                                             context=ev.context_percent, cwd=ev.cwd)
        # A new session forgets the tab's subagents and deferred completion — only for a tab the post
        # provably came from. A stale pin or a shared directory could otherwise wipe another tab's turn.
        starts_elsewhere = ev.kind == "sessionStart" and sid != self.resolver.resolve_directly(
            ev.agent, ev.session_id, ev.iterm_session_id)
        if ev.kind is not None and not starts_elsewhere:
            changed += self.status.apply_state(sid, ev.kind, ev.subagent_id, ev.turn_id, ev.starts_turn,
                                               ev.subagent_transcript, ev.running_subagents)
        await self.publisher.session_changed(changed)
        return None

    def _resolve_post(self, agent: AgentKind, session_id: str | None, cwd: str | None,
                      iterm_session_id: str | None = None, hook_event: str | None = None) -> str | None:
        if (sid := self.resolver.resolve(agent, session_id, cwd, iterm_session_id)) is not None:
            self.resolver.bind(sid, agent, session_id, hook_event)
        return sid
