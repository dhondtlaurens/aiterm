"""Agent hook posts, turned into status and usage changes."""
from __future__ import annotations
import asyncio
import logging
from collections.abc import Awaitable, Callable
from typing import Any

from .hook_events import HOOK_PARSERS, STATUSLINE_PARSERS, HookEvent
from .models import AgentKind
from .publisher import Publisher
from .resolver import SessionResolver
from .status import StatusEngine
from .usage import UsageStore

log = logging.getLogger(__name__)
# The least time between two ticks that unplaced hooks ask for. A hook from an agent outside iTerm2
# (another terminal, an editor) never places however often it is retried, so without a floor each
# of its posts would cost a tick.
RETICK_SECONDS = 1.0


def _first_line(prompt: str | None) -> str:
    """A prompt as run_status names it: its first line with text, cut to 200 characters."""
    line = next((line.strip() for line in (prompt or "").splitlines() if line.strip()), "")
    return line[:200] or "a prompt you typed"


class HookRouter:
    """Places each post on a tab through the resolver, applies it to the status engine or the
    usage store, and publishes what changed. Knows nothing of HTTP or of iTerm2."""

    def __init__(self, resolver: SessionResolver, status: StatusEngine, usage: UsageStore,
                 clock: Callable[[], float], publisher: Publisher,
                 tick: Callable[[], Awaitable[None]] | None = None, retick_seconds: float = RETICK_SECONDS):
        self.resolver, self.status, self.usage, self.clock, self.publisher = resolver, status, usage, clock, publisher
        # `tick` re-reads iTerm2 into the registry: the service's own, which already shares one pass
        # between callers that ask together.
        self._tick, self._retick_seconds = tick, retick_seconds
        # The tick the next unplaced hook will wait for, until it starts reading; and when the last began.
        self._pending_tick: asyncio.Task[bool] | None = None
        self._last_tick_start = float("-inf")
        self._ticks: set[asyncio.Task[bool]] = set()
        self._stopped = False
        # Whether the prompt a tab submits now is one you typed there: you just pressed Return in it and AiTerm
        # pasted nothing into it meanwhile. The service sets it once its keystroke and delivery records exist.
        self.typed_by_you: Callable[[str], bool] = lambda _sid: False
        # The tabs whose conversation has submitted a prompt since it started: its first is AiTerm's launch prompt.
        self._prompted: set[str] = set()
        # Posts are placed and applied in the order they arrive: a launch's SessionStart before its first
        # prompt. Placing one can wait on a scan of Claude's session files, so each holds this, FIFO,
        # from placing to applying. Uncontended, taking it does not yield.
        self._in_order = asyncio.Lock()

    async def stop(self) -> None:
        """End shared retry ticks, including those shielded from a cancelled HTTP caller."""
        self._stopped = True
        pending = tuple(self._ticks)
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        self._pending_tick = None

    async def handle_hook(self, path: str, body: dict[str, Any]) -> None:
        if (statusline := STATUSLINE_PARSERS.get(path)) is not None:
            agent, parse = statusline
            tick = parse(body, int(self.clock()))
            usage = tick.usage
            if usage and (usage.five_hour or usage.seven_day or usage.spend) and self.usage.set(agent, usage):
                await self.publisher.usage_changed()
            if tick.model or tick.reasoning or tick.context_percent is not None:
                async with self._in_order:
                    sid = (await self._resolve_post(agent, tick.session_id, tick.cwd, tick.iterm_session_id))[0]
                    ticked = self.status.apply_metadata(sid, model=tick.model, reasoning=tick.reasoning,
                                                        context=tick.context_percent) if sid else []
                if ticked:
                    await self.publisher.session_changed(ticked)
            return None
        # Hooks report the agent's state; checkout removal belongs to the app.
        parser = HOOK_PARSERS.get(path)
        ev = parser(body) if parser else None
        if ev is None:
            return None
        async with self._in_order:
            changed = await self._place_and_apply(ev, body)
        # An unplaced post waits for a tick without holding up the posts behind it, then tries once more.
        if changed is None and await self._tick_for_unplaced():
            async with self._in_order:
                changed = await self._place_and_apply(ev, body)
        if changed is None:
            log.debug("hook for unknown session: %s %s", ev.agent, ev.cwd)
            return None
        await self.publisher.session_changed(changed)
        return None

    async def _place_and_apply(self, ev: HookEvent, body: dict[str, Any]) -> list[str] | None:
        """The sessions `ev` changed, once placed on its tab; None when it places on none."""
        sid, direct = await self._resolve_post(ev.agent, ev.session_id, ev.cwd, ev.iterm_session_id, ev.event_name)
        if sid is None:
            return None
        # Placed by evidence -- the agent's pid, or the tab id its hook carries -- rather than by a pin or
        # the directory, either of which can name a sibling tab.
        # The post came from the agent itself, so its cwd is the agent's — the only source
        # there is for a Codex or PI session, neither of which has a polled session file. Its
        # conversation, and where it is written, are the tab's only when the post was placed by evidence.
        changed = self.status.apply_metadata(sid, model=ev.model, reasoning=ev.reasoning,
                                             context=ev.context_percent, cwd=ev.cwd,
                                             conversation=ev.conversation_id if sid == direct else None,
                                             transcript=ev.transcript if sid == direct else None)
        # A new session forgets the tab's subagents and deferred completion — only for a tab the post
        # provably came from. A stale pin or a shared directory could otherwise wipe another tab's turn.
        starts_elsewhere = ev.kind == "sessionStart" and sid != direct
        if not starts_elsewhere:
            changed += self.status.apply_event(sid, ev)
            if ev.kind == "sessionStart" and body.get("source") != "clear":
                self._prompted.discard(sid)
        if ev.event_name == "UserPromptSubmit":
            changed += self._note_prompt(sid, ev.prompt)
        return changed

    def forget_session(self, sid: str) -> None:
        self._prompted.discard(sid)

    def _note_prompt(self, sid: str, prompt: str | None) -> list[str]:
        """Records whether the prompt that started the tab's turn is yours (SessionInfo.your_prompt): never the first
        of its conversation, which AiTerm launched it with, even right after a Return (a folder-trust dialog's)."""
        first = sid not in self._prompted
        self._prompted.add(sid)
        yours = None if first or not self.typed_by_you(sid) else _first_line(prompt)
        return [sid] if self.status.reg.set_your_prompt(sid, yours) else []

    async def _tick_for_unplaced(self) -> bool:
        """Waits for a tick that began after the caller's post arrived, so that a tab the registry
        still classifies as `shell` (an agent's first hooks come before the poll that sees it start)
        is read again. Every post that arrives before that tick starts shares it, and one that
        arrives while it runs shares the next, which waits out `retick_seconds` since this one began:
        at most one running and one waiting, however many posts come. False if there is no tick to
        wait for or it failed, and the post is then dropped as before."""
        if self._stopped or self._tick is None:
            return False
        if (task := self._pending_tick) is None:
            task = self._pending_tick = asyncio.get_running_loop().create_task(self._paced_tick(self._tick))
            self._ticks.add(task)
            task.add_done_callback(self._ticks.discard)
        return await asyncio.shield(task)

    async def _paced_tick(self, tick: Callable[[], Awaitable[None]]) -> bool:
        loop = asyncio.get_running_loop()
        try:
            if (wait := self._last_tick_start + self._retick_seconds - loop.time()) > 0:
                await asyncio.sleep(wait)
        finally:
            # From here a post that arrives is not covered by this tick, which has begun to read.
            self._pending_tick, self._last_tick_start = None, loop.time()
        try:
            await tick()
        except Exception:  # noqa: BLE001 - a failed tick must not break the hook; the poll retries itself
            log.warning("tick for an unplaced hook failed", exc_info=True)
            return False
        return True

    async def _resolve_post(self, agent: AgentKind, session_id: str | None, cwd: str | None,
                      iterm_session_id: str | None = None, hook_event: str | None = None) -> tuple[str | None, str | None]:
        sid, direct = await self.resolver.resolve_with_evidence(agent, session_id, cwd, iterm_session_id)
        if sid is not None:
            self.resolver.bind(sid, agent, session_id, hook_event)
        return sid, direct
