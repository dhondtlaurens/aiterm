"""The tick's corroborating reads: each captured on the loop, read off the loop under a deadline and
applied on the loop while its keys stand. The steps no one agent owns live here; each agent's own reads
are plans in its module under `agents/`."""
from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass, replace
from typing import Generic, TypeVar

from .agents.codex import title_evidence
from .iterm_port import ItermPort
from .models import AgentKind, SessionInfo
from .sessions import SessionRegistry
from .status import StatusEngine
from .screens import shows_trust_prompt
from .test_activity import ActivityRead, TestActivityReader

log = logging.getLogger("aitermd.service")
T = TypeVar("T")


@contextmanager
def logged(step: str) -> Iterator[None]:
    try:
        yield
    except Exception:  # each observation is independent of the ones after it
        log.exception("%s failed", step)


@dataclass(frozen=True)
class SessionKey:
    agent: AgentKind
    job_pid: int | None
    conversation_id: str | None
    extras: tuple[object, ...]

    @classmethod
    def capture(cls, session: SessionInfo, *extras: object) -> SessionKey:
        return cls(session.agent, session.job_pid, session.conversation_id, extras)


@dataclass(frozen=True)
class ReadPlan(Generic[T]):
    """One captured request and its bounded read, applied by the service while its keys stand.

    Keyed plans return readings by session id, unless whole requires the entire snapshot to stand.
    Unkeyed plans apply their reading as it is.
    """
    name: str
    read: Callable[[], T] | None
    nothing: T
    apply: Callable[[T], list[str]]
    keys: dict[str, SessionKey] | None = None
    current_key: Callable[[SessionInfo], SessionKey] = SessionKey.capture
    whole: bool = False


class CorroboratingReaders:
    def __init__(self, registry: SessionRegistry, status: StatusEngine, iterm: ItermPort, clock: Callable[[], float]):
        self.registry, self.status, self.iterm, self.clock = registry, status, iterm, clock

    def snapshot(self, sessions: list[SessionInfo], changed: list[str]) -> None:
        """What the snapshot itself shows: a shell tab whose agent exited, and the title of a Codex tab."""
        now = self.clock()
        for session in sessions:
            with logged(f"corroborating session {session.session_id}"):
                if session.agent == "shell":
                    if session.state != "idle":
                        changed += self.status.agent_exited(session.session_id)
                elif session.agent == "codex":
                    changed += self.status.apply_evidence(session.session_id, title_evidence(session.title, now))

    async def trust_prompts(self, session_ids: list[str]) -> list[str]:
        screens = await asyncio.gather(*(self.iterm.screen_text(sid) for sid in session_ids), return_exceptions=True)
        changed: list[str] = []
        for sid, screen in zip(session_ids, screens, strict=True):
            if isinstance(screen, BaseException):
                log.warning("reading the screen of session %s failed: %s", sid, screen)
            elif screen is not None and (session := self.registry.get(sid)) is not None:
                changed += self.status.apply_trust_prompt(sid, shows_trust_prompt(session.agent, screen))
        return changed

    def tests(self, reader: TestActivityReader, sessions: list[SessionInfo]) -> ReadPlan[ActivityRead | None]:
        captured = [replace(session) for session in sessions]

        def key(session: SessionInfo) -> SessionKey:
            return SessionKey.capture(session, session.agent_cwd, session.cwd)

        keys = {s.session_id: key(s) for s in captured}

        def apply(reading: ActivityRead | None) -> list[str]:
            return [] if reading is None else reader.apply(self.registry, reading)

        return ReadPlan("the test activity read", lambda: reader.read(captured), None, apply, keys, key, whole=True)
