"""Which Codex thread each tab runs: learnt from hooks placed on the tab by evidence, valid only for the
process that posted them, and kept on the tab's iTerm2 variable so a helper restart recovers it."""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass

from .iterm_port import ItermPort
from .models import CODEX_THREAD_TAG, RawSession, SessionInfo
from .sessions import SessionRegistry

log = logging.getLogger(__name__)


@dataclass(slots=True)
class CodexBinding:
    """The Codex thread a tab runs, replaced by every Codex hook placed on the tab by evidence. A
    non-None `pending_generation` leaves the process open until a newer snapshot, because a
    replacement Codex can post before iTerm2 reports its new pid."""
    thread_id: str
    pid: int | None
    pending_generation: int | None


class CodexThreads:
    def __init__(self, registry: SessionRegistry, iterm: ItermPort):
        self.registry, self.iterm = registry, iterm
        self._bindings: dict[str, CodexBinding] = {}
        self._generation = 0
        # The (pid, thread) last written to each tab's tag.
        self._written: dict[str, tuple[int, str]] = {}

    def restore(self, raw: list[RawSession]) -> list[str]:
        """Called after every registry snapshot. Validates every binding, including those of tabs
        no longer running Codex, then binds each Codex tab that has none to the thread its tag saved
        for its current process. Returns the tabs whose conversation the tag supplied."""
        self._generation += 1
        for sid in tuple(self._bindings):
            self._validate(sid)
        restored: list[str] = []
        for r in raw:
            session = self.registry.get(r.session_id)
            if (session is None or session.agent != "codex" or not session.job_pid
                    or r.session_id in self._bindings or (thread := _saved_thread(r, session.job_pid)) is None):
                continue
            self._bindings[r.session_id] = CodexBinding(thread, session.job_pid, None)
            self._written[r.session_id] = (session.job_pid, thread)
            if session.conversation_id is None and self.registry.set_conversation(r.session_id, thread):
                restored.append(r.session_id)
        return restored

    def bind(self, session_id: str, thread: str, hook_event: str | None) -> None:
        """Records the thread a Codex hook placed on the tab by evidence names."""
        if hook_event in ("SubagentStart", "SubagentStop"):
            return
        session = self.registry.get(session_id)
        pid = session.job_pid if session else None
        current = self._bindings.get(session_id)
        if hook_event == "Stop":
            # A final hook cannot authorize this thread to follow a future process id. Binding it
            # to the currently observed process makes replacement invalidate it.
            self._bindings[session_id] = CodexBinding(thread, pid, None)
        elif current is None or current.thread_id != thread or hook_event == "SessionStart":
            # A different thread, or an explicit resume of the same thread, may belong to a
            # replacement process whose pid iTerm2 has not reported yet.
            self._bindings[session_id] = CodexBinding(thread, pid, self._generation)

    def thread(self, session_id: str) -> str | None:
        """The tab's thread as the last snapshot and the hooks since left it: pids change only at a
        snapshot, where `restore` validates every binding."""
        binding = self._bindings.get(session_id)
        return binding.thread_id if binding else None

    def forget(self, session_id: str) -> None:
        self._bindings.pop(session_id, None)
        self._written.pop(session_id, None)

    async def remember(self, sessions: list[SessionInfo]) -> None:
        """Keeps each tab's thread on its tag with the process it belongs to, writing only what changed."""
        for captured in sessions:
            if (session := self.registry.get(captured.session_id)) is None:
                continue
            sid, pid = session.session_id, session.job_pid
            if session.agent != "codex" or pid is None or (thread := self.thread(sid)) is None:
                continue
            identity = (pid, thread)
            if self._written.get(sid) == identity:
                continue
            try:
                await self.iterm.set_session_tags(sid, {CODEX_THREAD_TAG: json.dumps({"pid": pid, "thread": thread})})
            except Exception:  # one tab's write must not cost the others'
                log.exception("remembering the Codex thread of session %s failed", sid)
                continue
            self._written[sid] = identity

    def _validate(self, session_id: str) -> None:
        binding = self._bindings[session_id]
        session = self.registry.get(session_id)
        if session is None or session.agent != "codex":
            del self._bindings[session_id]
        elif binding.pending_generation is not None:
            if self._generation > binding.pending_generation:
                binding.pid, binding.pending_generation = session.job_pid, None
        elif session.job_pid != binding.pid:
            del self._bindings[session_id]


def _saved_thread(raw: RawSession, pid: int) -> str | None:
    """The thread the tab's tag saved for process `pid`, if it saved one for that process."""
    try:
        saved = json.loads(raw.user_vars.get(CODEX_THREAD_TAG, ""))
    except (ValueError, TypeError):
        return None
    if (isinstance(saved, dict) and type(saved.get("pid")) is int and saved["pid"] == pid
            and isinstance(thread := saved.get("thread"), str) and thread.strip()):
        return thread
    return None
