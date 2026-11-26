"""What the daemon knows of Antigravity (`agy`): the payload its `hooks.json` hooks get on stdin,
which AiTerm's hook script posts unchanged, with the tab in X-AiTerm-iTerm-Session.

Its hooks speak first with the first prompt -- SessionStart and PreInvocation arrive together -- so a
tab started without one says nothing until then, and its folder-trust dialog, which comes before any
hook loads, is read from the screen as PI's is."""
from __future__ import annotations

import json
import os
import re
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

from .. import corroboration
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
    said = p.get("lastUserInput")
    return HookEvent(
        "agy", AGY_EVENTS[name],
        nonempty_string(p.get("conversationId")),
        nonempty_string(p.get("cwd")),
        iterm_session_id=nonempty_string(p.get(ITERM_SESSION_FIELD)),
        event_name=name,
        transcript=nonempty_string(p.get("transcriptPath")),
        fully_idle=fully if isinstance(fully := p.get("fullyIdle"), bool) else None,
        user_input=said if isinstance(said, str) else None,
    )


def is_subagent_post(ev: HookEvent, tab_conversation: str | None) -> bool:
    """Whether an agy post placed on a tab is one of that tab's subagents speaking, not the tab's own conversation.
    agy runs a subagent (`invoke_subagent`) as a conversation of its own in the same process, whose hooks fire from
    the parent's tab: they name the child's conversation. The tab's own new conversation (its first, or one after
    `/clear`) always starts with the prompt that started it, since agy's hooks speak with the first prompt; a
    subagent's starts from its parent's message, with an empty `lastUserInput`. So any post naming a conversation
    other than the tab's is a subagent's, except a SessionStart that carries a prompt."""
    if ev.agent != "agy" or ev.session_id is None or ev.session_id == tab_conversation:
        return False
    # Every post of the tab's own conversation carries the prompt it last took, model calls and the turns a
    # finished command or subagent starts included: one without is a subagent's, even in a tab whose conversation a
    # restarted daemon does not know yet.
    if ev.user_input == "":
        return True
    return tab_conversation is not None and not (ev.kind == "sessionStart" and ev.user_input)


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
    tasks = p.get("task_count")
    return StatusLine(
        None,
        nonempty_string(p.get("conversation_id")) or nonempty_string(p.get("session_id")),
        nonempty_string(p.get("cwd")),
        nonempty_string(p.get(ITERM_SESSION_FIELD)),
        clamped_percent(window.get("used_percentage")) if isinstance(window, dict) else None,
        state=state,
        version=nonempty_string(p.get("version")),
        # agy leaves the count out when it is zero.
        task_count=tasks if isinstance(tasks, int) and not isinstance(tasks, bool) and tasks > 0 else 0,
    )


@dataclass(frozen=True, slots=True)
class AgyTask:
    """A command agy moved to the background: its task id (`<conversation>/task-N`), its command, and when this
    daemon first read its record. agy writes that record the moment the command goes to the background, which can be
    long after it started (`WaitMsBeforeAsync`): what the status line's count is held against (StatusEngine)."""
    task_id: str
    command: str
    seen_at: float


@dataclass(frozen=True, slots=True)
class AgySubagent:
    """A subagent the conversation created: its own conversation id, the prompt it was given, and its role."""
    conversation: str
    prompt: str
    role: str | None


@dataclass(frozen=True, slots=True)
class AgyReading:
    """What a conversation's transcript says runs beside it: the background commands it started and has not seen
    end, and every subagent it created. Whether a subagent still runs is its own hooks' to say."""
    tasks: tuple[AgyTask, ...] = ()
    subagents: tuple[AgySubagent, ...] = ()


# How agy 1.5.18 writes a command that went to the background, the message that ends one, and a subagent's creation.
_TASK_STARTED = re.compile(r"running as a background task with task id: (\S+)")
_TASK_COMMAND = re.compile(r"^Task Description: (.*)$", re.M)
_MESSAGE_SENDER = re.compile(r"\[Message\][^\n]*?\bsender=(\S+)[^\n]*?\bcontent=([^\n]*)")
_SUBAGENT_CREATED = "Created the following subagent:"


@dataclass(slots=True)
class _Cursor:
    inode: int
    offset: int = 0
    rest: bytes = b""
    tasks: dict[str, AgyTask] = field(default_factory=dict)
    subagents: dict[str, AgySubagent] = field(default_factory=dict)
    # The `invoke_subagent` calls not yet matched to their "Created the following subagent" records, in order.
    asked: list[tuple[str, str | None]] = field(default_factory=list)


class AgyTranscripts:
    """Reads agy conversation transcripts (the hooks' `transcriptPath`) as they grow, from where the last read
    stopped. Called off the event loop, by the tick and by a Stop, so it locks. A file that cannot be read gives
    None, never an empty reading."""

    def __init__(self, clock: Callable[[], float] = time.time) -> None:
        self._lock = threading.Lock()
        self._cursors: dict[str, _Cursor] = {}
        # The wall clock the status engine shares, which a task's `seen_at` is read on.
        self._clock = clock

    def read(self, path: str) -> AgyReading | None:
        with self._lock:
            try:
                with open(path, "rb") as f:
                    stat = os.fstat(f.fileno())
                    cursor = self._cursors.get(path)
                    if cursor is None or cursor.inode != stat.st_ino or stat.st_size < cursor.offset:
                        cursor = self._cursors[path] = _Cursor(stat.st_ino)
                    f.seek(cursor.offset)
                    data = f.read()
            except OSError:
                self._cursors.pop(path, None)
                return None
            cursor.offset += len(data)
            *lines, cursor.rest = (cursor.rest + data).split(b"\n")
            now = self._clock()
            for line in lines:
                _take(cursor, line, now)
            return AgyReading(tuple(cursor.tasks.values()), tuple(cursor.subagents.values()))

    def read_all(self, paths: set[str]) -> dict[str, AgyReading | None]:
        self._cursors = {path: cursor for path, cursor in self._cursors.items() if path in paths}
        return {path: self.read(path) for path in paths}


def _take(cursor: _Cursor, line: bytes, now: float) -> None:
    try:
        record = json.loads(line)
    except ValueError:
        return
    if not isinstance(record, dict):
        return
    # A model response's calls are answered before the next response: what an earlier one asked and never created (a
    # launch that failed) is never a later subagent's.
    if record.get("type") == "PLANNER_RESPONSE":
        cursor.asked = []
    for call in record.get("tool_calls") or ():
        if isinstance(call, dict) and call.get("name") == "invoke_subagent" and isinstance(args := call.get("args"), dict):
            entries = args.get("Subagents")
            for entry in entries if isinstance(entries, list) else [args]:
                if isinstance(entry, dict):
                    prompt = nonempty_string(entry.get("Prompt")) or "Subagent"
                    cursor.asked.append((" ".join(prompt.split()), nonempty_string(entry.get("Role"))))
    content = record.get("content")
    if not isinstance(content, str):
        return
    kind = record.get("type")
    if kind == "GENERIC" and (started := _TASK_STARTED.search(content)):
        command = _TASK_COMMAND.search(content)
        cursor.tasks[started[1]] = AgyTask(started[1], command[1].strip() if command else started[1], now)
    elif kind == "GENERIC" and _SUBAGENT_CREATED in content:
        try:
            created = json.loads(content[content.index("{", content.index(_SUBAGENT_CREATED)):content.rindex("}") + 1])
        except ValueError:
            return
        conversation = nonempty_string(created.get("conversationId")) if isinstance(created, dict) else None
        if conversation is not None:
            prompt, role = cursor.asked.pop(0) if cursor.asked else ("Subagent", None)
            cursor.subagents[conversation] = AgySubagent(conversation, prompt, role)
    elif kind == "SYSTEM_MESSAGE":
        for sender, said in _MESSAGE_SENDER.findall(content):
            if sender in cursor.tasks and "finished" in said:
                del cursor.tasks[sender]


def trust_screens(status: StatusEngine, sessions: list[SessionInfo]) -> list[str]:
    """The Antigravity tabs whose screen may show its folder-trust dialog: a process that has not
    named its conversation yet, while its row is idle, and any tab the dialog holds now, to see it close."""
    return [s.session_id for s in sessions if s.agent == "agy" and s.job_pid and (
        (s.conversation_id is None and s.state == "idle") or status.showing_trust_prompt(s.session_id))]


def background_plan(status: StatusEngine, reader: AgyTranscripts,
                    sessions: list[SessionInfo]) -> corroboration.ReadPlan[dict[str, AgyReading | None]]:
    """Each Antigravity tab's background commands and subagents, from its own conversation's transcript, on every
    tick, its turn working or ended: a command shows while it runs, and leaves once its end is written there."""
    paths = {s.session_id: s.transcript for s in sessions
             if s.agent == "agy" and s.transcript and status.turn(s.session_id) is not None}
    keys = {sid: corroboration.SessionKey.capture(s, s.transcript) for s in sessions if (sid := s.session_id) in paths}

    def read() -> dict[str, AgyReading | None]:
        readings = reader.read_all(set(paths.values()))
        return {sid: readings.get(path) for sid, path in paths.items()}

    def apply(readings: dict[str, AgyReading | None]) -> list[str]:
        return [changed for sid, reading in readings.items() for changed in status.apply_agy_reading(sid, reading)]

    return corroboration.ReadPlan("the Antigravity background read", read, dict.fromkeys(paths), apply, keys,
                                  lambda s: corroboration.SessionKey.capture(s, s.transcript))
