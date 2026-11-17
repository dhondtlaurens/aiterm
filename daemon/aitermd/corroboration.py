"""Plans for the daemon's fixed corroborating readers. Capture on loop, read off loop, apply on loop."""
from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass, replace
from typing import Generic, TypeVar

from .claude_background import BackgroundTranscripts, ShellReading
from .claude_sessions import ClaudeSessionFile, ClaudeSessionFiles
from .claude_subagents import SubagentTranscripts, TranscriptTail
from .codex_sessions import CODEX_READ, CodexReading, CodexSessionFiles
from .iterm_port import ItermPort
from .models import HARNESS_BY_AGENT, AgentKind, SessionInfo
from .resolver import SessionResolver
from .sessions import SessionRegistry
from .status import StatusEngine
from .screens import shows_trust_prompt
from .stop_failures import LIMIT_ERRORS, RESET_READ_SECONDS, StopReading, StopTranscripts
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
    def __init__(self, registry: SessionRegistry, status: StatusEngine, resolver: SessionResolver,
                 iterm: ItermPort, clock: Callable[[], float]):
        self.registry, self.status, self.resolver = registry, status, resolver
        self.iterm, self.clock = iterm, clock

    def snapshot(self, sessions: list[SessionInfo], changed: list[str]) -> tuple[dict[str, str], list[str]]:
        threads: dict[str, str] = {}
        for session in sessions:
            with logged(f"corroborating session {session.session_id}"):
                if session.agent == "shell":
                    if session.state != "idle":
                        changed += self.status.agent_exited(session.session_id)
                elif HARNESS_BY_AGENT[session.agent].corroboration == "codex_title":
                    changed += self.status.apply_codex_title(session.session_id, session.title)
                    if thread := self.resolver.codex_thread(session.session_id):
                        threads[session.session_id] = thread
        return threads, []

    def claude(self, files: ClaudeSessionFiles, sessions: list[SessionInfo],
               screens: list[str]) -> ReadPlan[dict[str, ClaudeSessionFile | None]]:
        root = files.root
        captured = {s.session_id: s for s in sessions
                    if s.agent != "shell" and HARNESS_BY_AGENT[s.agent].corroboration == "claude_file"}

        def key(session: SessionInfo) -> SessionKey:
            return SessionKey.capture(session, session.agent_cwd)

        keys = {sid: key(session) for sid, session in captured.items()}

        def read() -> dict[str, ClaudeSessionFile | None]:
            readings: dict[str, ClaudeSessionFile | None] = {}
            for sid, captured_key in keys.items():
                with logged(f"reading the Claude file of session {sid}"):
                    pid = captured_key.job_pid
                    readings[sid] = files.read(pid) if pid else None
            return readings

        def apply(readings: dict[str, ClaudeSessionFile | None]) -> list[str]:
            changed: list[str] = []
            if files.root != root:
                return changed
            for sid, file in readings.items():
                session = captured[sid]
                with logged(f"corroborating session {sid}"):
                    if file:
                        changed += self.status.apply_trust_prompt(sid, False)
                        changed += self.status.apply_claude_file_status(sid, file.status, file.written_at)
                        changed += self.status.apply_metadata(sid, cwd=file.cwd)
                        if (current := self.registry.get(sid)) is not None and current.conversation_id is None:
                            changed += self.status.apply_metadata(sid, conversation=file.session_id)
                        self.registry.set_cli_version(sid, file.version)
                    elif session.job_pid and (session.state == "idle" or self.status.showing_trust_prompt(sid)):
                        screens.append(sid)
            return changed

        return ReadPlan("the Claude file read", read if captured else None, {}, apply, keys, key)

    async def trust_prompts(self, session_ids: list[str]) -> list[str]:
        screens = await asyncio.gather(*(self.iterm.screen_text(sid) for sid in session_ids), return_exceptions=True)
        changed: list[str] = []
        for sid, screen in zip(session_ids, screens, strict=True):
            if isinstance(screen, BaseException):
                log.warning("reading the screen of session %s failed: %s", sid, screen)
            elif screen is not None and (session := self.registry.get(sid)) is not None:
                changed += self.status.apply_trust_prompt(sid, shows_trust_prompt(session.agent, screen))
        return changed

    def codex(self, files: CodexSessionFiles, threads: dict[str, str]) -> ReadPlan[dict[str, CodexReading | None]]:
        captured = dict(threads)

        def key(session: SessionInfo) -> SessionKey:
            return SessionKey.capture(session, self.resolver.codex_thread(session.session_id))

        keys = {sid: SessionKey.capture(session, thread) for sid, thread in captured.items()
                if (session := self.registry.get(sid)) is not None}

        def read() -> dict[str, CodexReading | None]:
            readings: dict[str, CodexReading | None] = {}
            for thread in set(captured.values()):
                try:
                    readings[thread] = files.reading(thread)
                except Exception:  # a different thread's file must still be read
                    log.exception("reading the Codex rollout of thread %s failed", thread)
                    readings[thread] = None
            files.retain(set(captured.values()))
            return {sid: readings[thread] for sid, thread in captured.items()}

        def apply(readings: dict[str, CodexReading | None]) -> list[str]:
            changed: list[str] = []
            for sid, reading in readings.items():
                context, version, turn = reading or CodexReading(None, None, None)
                self.registry.set_cli_version(sid, version)
                changed += self.status.apply_metadata(sid, context=context)
                if turn is not None:
                    changed += self.status.apply_codex_rollout(sid, *turn)
            return changed

        return ReadPlan(CODEX_READ, read, dict.fromkeys(captured), apply, keys, key)

    def subagents(self, reader: SubagentTranscripts) -> ReadPlan[dict[str, TranscriptTail | None]]:
        paths = self.status.subagent_transcripts()
        read = reader.read_all
        return ReadPlan("the subagent transcript read", (lambda: read(paths)) if paths else None,
                        {}, self.status.release_dead_subagents)

    def background(self, reader: BackgroundTranscripts,
                   sessions: list[SessionInfo]) -> ReadPlan[dict[str, ShellReading | None]]:
        captured = {s.session_id: (s.transcript, self.status.turn(s.session_id)) for s in sessions if s.agent == "claude"}

        def key(session: SessionInfo) -> SessionKey:
            turn = self.status.turn(session.session_id)
            return SessionKey.capture(session, session.transcript, turn.work_since if turn is not None else None)

        keys = {s.session_id: key(s) for s in sessions if s.session_id in captured}
        requests = {sid: (path, owner.work_since)
                    for sid, (path, owner) in captured.items()
                    if path is not None and owner is not None and owner.work_since is not None}
        recoveries = {sid: owner.shell_snapshot_at
                      for sid, (_, owner) in captured.items()
                      if owner is not None and owner.shell_snapshot_valid and owner.shell_snapshot is not None}

        def read() -> dict[str, ShellReading | None]:
            readings = reader.read_all(requests, recoveries)
            return {sid: readings.get(sid) for sid in captured}

        def apply(readings: dict[str, ShellReading | None]) -> list[str]:
            changed: list[str] = []
            for sid, reading in readings.items():
                changed += self.status.apply_shell_reading(sid, reading)
            return changed

        return ReadPlan("the Claude background read", read, dict.fromkeys(captured), apply, keys, key)

    def stops(self, reader: StopTranscripts) -> ReadPlan[dict[str, StopReading]]:
        now = self.clock()
        stopped = {s.session_id: (s.stopped_on, s.transcript) for s in self.registry.all()
                   if s.stopped_on is not None and s.transcript}
        paths = {transcript for _, transcript in stopped.values() if transcript}

        def key(session: SessionInfo) -> SessionKey:
            return SessionKey.capture(session, session.transcript, session.stopped_on.at if session.stopped_on is not None else None)

        keys = {sid: key(session) for sid in stopped if (session := self.registry.get(sid)) is not None}

        def read() -> dict[str, StopReading]:
            readings = reader.read_all(paths)
            return {sid: readings[path] for sid, (_, path) in stopped.items() if path in readings}

        def apply(readings: dict[str, StopReading]) -> list[str]:
            changed: list[str] = []
            for sid, reading in readings.items():
                stopped_on, _ = stopped[sid]
                if reading.progress_at is not None:
                    changed += self.status.apply_claude_progress(sid, reading.progress_at)
                if (reading.resets_at is not None and stopped_on.error in LIMIT_ERRORS and stopped_on.resets_at is None
                        and now - stopped_on.at <= RESET_READ_SECONDS):
                    changed += [sid] if self.registry.set_stopped_on(sid, replace(stopped_on, resets_at=reading.resets_at)) else []
            return changed

        return ReadPlan("the stopped worker transcript read", read if stopped else None, {}, apply, keys, key)

    def tests(self, reader: TestActivityReader, sessions: list[SessionInfo]) -> ReadPlan[ActivityRead | None]:
        captured = [replace(session) for session in sessions]

        def key(session: SessionInfo) -> SessionKey:
            return SessionKey.capture(session, session.agent_cwd, session.cwd)

        keys = {s.session_id: key(s) for s in captured}

        def apply(reading: ActivityRead | None) -> list[str]:
            return [] if reading is None else reader.apply(self.registry, reading)

        return ReadPlan("the test activity read", lambda: reader.read(captured), None, apply, keys, key, whole=True)
