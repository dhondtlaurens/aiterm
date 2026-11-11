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
from .codex_sessions import CodexReading, CodexSessionFiles
from .iterm_port import ItermPort
from .models import HARNESS_BY_AGENT, SessionInfo
from .resolver import SessionResolver
from .sessions import SessionRegistry
from .slash_commands import SlashCommands, TranscriptRecord
from .status import StatusEngine
from .screens import shows_trust_prompt
from .stop_failures import LIMIT_ERRORS, RESET_READ_SECONDS, limit_resets_at
from .test_activity import ActivityRead, TestActivityReader

log = logging.getLogger("aitermd.service")
T = TypeVar("T")


@contextmanager
def logged(step: str) -> Iterator[None]:
    try:
        yield
    except Exception:  # noqa: BLE001 - each observation is independent of the ones after it
        log.exception("%s failed", step)


@dataclass(frozen=True)
class ReadPlan(Generic[T]):
    """One captured request, its bounded read and the apply that validates that request's identity."""
    name: str
    read: Callable[[], T] | None
    nothing: T
    apply: Callable[[T], list[str]]


class CorroboratingReaders:
    def __init__(self, registry: SessionRegistry, status: StatusEngine, resolver: SessionResolver,
                 iterm: ItermPort, clock: Callable[[], float], slash_commands: SlashCommands):
        self.registry, self.status, self.resolver = registry, status, resolver
        self.iterm, self.clock, self.slash_commands = iterm, clock, slash_commands

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
        identities = {sid: (s.agent, s.job_pid, s.conversation_id, s.agent_cwd) for sid, s in captured.items()}

        def read() -> dict[str, ClaudeSessionFile | None]:
            readings: dict[str, ClaudeSessionFile | None] = {}
            for sid, (_, pid, _, _) in identities.items():
                with logged(f"reading the Claude file of session {sid}"):
                    readings[sid] = files.read(pid) if pid else None
            return readings

        def apply(readings: dict[str, ClaudeSessionFile | None]) -> list[str]:
            changed: list[str] = []
            if files.root != root:
                return changed
            for sid, file in readings.items():
                current = self.registry.get(sid)
                if current is None or (current.agent, current.job_pid, current.conversation_id, current.agent_cwd) != identities[sid]:
                    continue
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

        return ReadPlan("the Claude file read", read if identities else None, {}, apply)

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

        def read() -> dict[str, CodexReading | None]:
            readings: dict[str, CodexReading | None] = {}
            for thread in set(captured.values()):
                try:
                    readings[thread] = files.reading(thread)
                except Exception:  # noqa: BLE001 - a different thread's file must still be read
                    log.exception("reading the Codex rollout of thread %s failed", thread)
                    readings[thread] = None
            files.retain(set(captured.values()))
            return readings

        def apply(readings: dict[str, CodexReading | None]) -> list[str]:
            changed: list[str] = []
            for sid, thread in captured.items():
                if self.resolver.codex_thread(sid) != thread:
                    continue
                context, version, turn = readings.get(thread) or CodexReading(None, None, None)
                self.registry.set_cli_version(sid, version)
                changed += self.status.apply_metadata(sid, context=context)
                if turn is not None:
                    changed += self.status.apply_codex_rollout(sid, *turn)
            return changed

        return ReadPlan("the Codex rollout read", read, {}, apply)

    def subagents(self, reader: SubagentTranscripts) -> ReadPlan[dict[str, TranscriptTail | None]]:
        paths = self.status.subagent_transcripts()
        read = reader.read_all
        return ReadPlan("the subagent transcript read", (lambda: read(paths)) if paths else None,
                        {}, self.status.release_dead_subagents)

    def background(self, reader: BackgroundTranscripts,
                   sessions: list[SessionInfo]) -> ReadPlan[dict[str, ShellReading | None]]:
        captured = {s.session_id: (s.agent, s.job_pid, s.conversation_id, s.transcript, self.status.turn(s.session_id))
                    for s in sessions if s.agent == "claude"}
        requests = {f"{sid}:{owner.generation}": (path, owner.work_since)
                    for sid, (_, _, _, path, owner) in captured.items()
                    if path is not None and owner is not None and owner.work_since is not None}
        recoveries = {f"{sid}:{owner.generation}": owner.shell_snapshot_at
                      for sid, (_, _, _, _, owner) in captured.items()
                      if owner is not None and owner.shell_snapshot_valid and owner.shell_snapshot is not None}
        read = reader.read_all

        def apply(readings: dict[str, ShellReading | None]) -> list[str]:
            changed: list[str] = []
            for sid, (agent, pid, conversation, path, owner) in captured.items():
                session = self.registry.get(sid)
                if (session is None or (session.agent, session.job_pid, session.conversation_id, session.transcript)
                        != (agent, pid, conversation, path) or self.status.turn(sid) is not owner):
                    continue
                key = f"{sid}:{owner.generation}" if owner is not None else ""
                if key in requests and owner is not None and owner.work_since != requests[key][1]:
                    continue
                changed += self.status.apply_shell_reading(sid, readings.get(key))
            return changed

        return ReadPlan("the Claude background read", lambda: read(requests, recoveries), {}, apply)

    def slash(self) -> ReadPlan[dict[str, tuple[TranscriptRecord, ...] | None] | None]:
        now, read = self.clock(), self.slash_commands.reader.read_all
        starts = self.slash_commands.starts(now)

        def apply(records: dict[str, tuple[TranscriptRecord, ...] | None] | None) -> list[str]:
            return [] if records is None else self.slash_commands.apply(records, now)

        if not starts:
            return ReadPlan("the slash command read", None, {}, apply)
        return ReadPlan("the slash command read", lambda: read(starts), None, apply)

    def limits(self) -> ReadPlan[dict[str, int | None]]:
        now = self.clock()
        stopped = {s.session_id: (s.stopped_on, s.transcript) for s in self.registry.all()
                   if s.stopped_on is not None and s.stopped_on.error in LIMIT_ERRORS and s.stopped_on.resets_at is None
                   and s.transcript and now - s.stopped_on.at <= RESET_READ_SECONDS}
        paths = {transcript for _, transcript in stopped.values() if transcript}

        def apply(resets: dict[str, int | None]) -> list[str]:
            changed: list[str] = []
            for sid, (stopped_on, transcript) in stopped.items():
                if (session := self.registry.get(sid)) is None or session.stopped_on is not stopped_on or not transcript:
                    continue
                if (resets_at := resets.get(transcript)) is not None:
                    changed += [sid] if self.registry.set_stopped_on(sid, replace(stopped_on, resets_at=resets_at)) else []
            return changed

        return ReadPlan("the usage limit read", (lambda: {path: limit_resets_at(path) for path in paths}) if stopped else None,
                        {}, apply)

    def tests(self, reader: TestActivityReader, sessions: list[SessionInfo]) -> ReadPlan[ActivityRead | None]:
        captured = [replace(session) for session in sessions]

        def apply(reading: ActivityRead | None) -> list[str]:
            return [] if reading is None else reader.apply(self.registry, reading)

        return ReadPlan("the test activity read", lambda: reader.read(captured), None, apply)
