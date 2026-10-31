"""Display-only Claude shell evidence from native parent transcript records, never command stdout."""
from __future__ import annotations

import json
import re
import time
from collections.abc import Callable
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

from .jsonl import JsonlCursor
from .models import CLAUDE_TERMINAL_TASK_STATUSES, BackgroundJob
from .text import iso_seconds, nonempty_string

READ_BYTES = 8 * 1024 * 1024
MAX_TRACKED = 4096
_TASK_ID = re.compile(r"<task-id>([^<]+)</task-id>")
_STATUS = re.compile(r"<status>([^<]+)</status>")


@dataclass(frozen=True, slots=True)
class ShellTask:
    job: BackgroundJob
    started_at: float


@dataclass(frozen=True, slots=True)
class ShellReading:
    tasks: tuple[ShellTask, ...]
    ended: frozenset[str]


@dataclass(slots=True)
class _Transcript:
    path: str
    since: float
    cursor: JsonlCursor
    calls: dict[str, tuple[str, str]] = field(default_factory=dict)
    tasks: dict[str, ShellTask] = field(default_factory=dict)
    ended: set[str] = field(default_factory=set)
    uncertain: dict[str, float] = field(default_factory=dict)
    gap_at: float | None = None

    def consume(self, line: bytes, observed_at: float) -> None:
        try:
            record = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            self.gap_at = observed_at
            return
        if not isinstance(record, dict) or record.get("isSidechain") is True:
            return
        at = iso_seconds(record.get("timestamp"))
        if at is None or at < self.since:
            return
        attachment = record.get("attachment")
        if (record.get("type") == "attachment" and isinstance(attachment, dict)
                and attachment.get("type") == "queued_command" and attachment.get("commandMode") == "task-notification"):
            self.notice(attachment.get("prompt"), at)
        elif record.get("type") == "queue-operation" and record.get("operation") == "enqueue":
            self.notice(record.get("content"), at)
        message = record.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        blocks = content if isinstance(content, list) else [{"type": "text", "text": content}]
        if record.get("type") == "assistant":
            for block in blocks:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                name, call = block.get("name"), nonempty_string(block.get("id"))
                args = block.get("input")
                if call and isinstance(args, dict) and name in ("Bash", "TaskStop"):
                    value = nonempty_string(args.get("command" if name == "Bash" else "task_id"))
                    if value:
                        self.calls[call] = (name, value)
        elif record.get("type") == "user":
            results = [block for block in blocks if isinstance(block, dict) and block.get("type") == "tool_result"]
            native = record.get("toolUseResult")
            for block in results:
                pending = self.calls.pop(str(block.get("tool_use_id")), None)
                if pending is None:
                    continue
                name, value = pending
                if block.get("is_error") is True:
                    if name == "TaskStop" and value in self.tasks:
                        self.uncertain[value] = at
                    continue
                if not isinstance(native, dict) or len(results) != 1:
                    if name == "TaskStop" and value in self.tasks:
                        self.uncertain[value] = at
                    continue
                if name == "Bash" and "backgroundTaskId" in native:
                    task = nonempty_string(native.get("backgroundTaskId"))
                    if task is None or native.get("interrupted") is True:
                        self.gap_at = observed_at
                    elif task not in self.ended:
                        self.tasks.setdefault(task, ShellTask(BackgroundJob("shell", value, task_id=task), at))
                elif name == "TaskStop" and native.get("task_id") == value and native.get("task_type") == "local_bash":
                    self.finish(value)
                elif name == "TaskStop" and value in self.tasks:
                    self.uncertain[value] = at
            for block in blocks:
                if not isinstance(block, dict) or block.get("type") != "text":
                    continue
                self.notice(block.get("text"), at)
        if len(self.calls) > MAX_TRACKED or len(self.tasks) + len(self.ended) > MAX_TRACKED:
            self.gap_at = observed_at
            self.calls.clear()
            self.tasks.clear()
            self.ended.clear()
            self.uncertain.clear()

    def notice(self, value: object, at: float) -> None:
        if not isinstance(value, str) or not value.lstrip().startswith("<task-notification>"):
            return
        task_match, status_match = _TASK_ID.search(value), _STATUS.search(value)
        if task_match is None:
            return  # Artifact-watch notices carry no shell identity.
        if status_match is not None and status_match[1] in CLAUDE_TERMINAL_TASK_STATUSES:
            self.finish(task_match[1])
        elif task_match[1] in self.tasks:
            # Monitor events and other task notices say nothing about unrelated shells.
            self.uncertain[task_match[1]] = at

    def finish(self, task: str) -> None:
        self.tasks.pop(task, None)
        self.ended.add(task)
        self.uncertain.pop(task, None)


class BackgroundTranscripts:
    """Worker-thread-owned cursors. A failed, incomplete or unsupported read is unavailable, not empty."""

    def __init__(self, read_bytes: int = READ_BYTES, clock: Callable[[], float] = time.time):
        self.read_bytes = read_bytes
        self.clock = clock
        self._read: dict[str, _Transcript] = {}

    def read_all(self, requests: Mapping[str, tuple[str, float]],
                 recoveries: Mapping[str, float] | None = None) -> dict[str, ShellReading | None]:
        self._read = {sid: value for sid, value in self._read.items() if sid in requests}
        return {sid: self._one(sid, path, since, (recoveries or {}).get(sid)) for sid, (path, since) in requests.items()}

    def _one(self, sid: str, path: str, since: float, recovery_at: float | None) -> ShellReading | None:
        try:
            stat = Path(path).stat()
        except (OSError, ValueError):
            self._read.pop(sid, None)
            return None
        value = self._read.get(sid)
        if (value is None or value.path != path or value.since != since
                or value.cursor.rewritten(stat.st_ino, stat.st_size)):
            value = self._read[sid] = _Transcript(path, since, JsonlCursor(stat.st_ino))
        try:
            lines = value.cursor.read_lines(Path(path), min(stat.st_size, value.cursor.offset + self.read_bytes))
        except OSError:
            return None
        for line in lines:
            value.consume(line, self.clock())
        if len(value.cursor.partial) > READ_BYTES:
            value.cursor.partial = b""
            value.gap_at = self.clock()
        if recovery_at is not None:
            value.uncertain = {task: at for task, at in value.uncertain.items() if at > recovery_at}
            if value.gap_at is not None and recovery_at >= value.gap_at:
                value.gap_at = None
        if value.gap_at is not None or value.uncertain or value.cursor.offset < stat.st_size or value.cursor.partial:
            return None
        return ShellReading(tuple(value.tasks.values()), frozenset(value.ended))
