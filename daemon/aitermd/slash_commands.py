"""What became of a slash command AiTerm typed into a Claude session (message_task), as the session's own transcript
records it. Checked against Claude Code 2.1.283 to 2.1.310, and driven live on 2.1.310:

- A command Claude Code ran is a user record whose text is its `<command-name>/name</command-name>`, with its
  `<command-args>`; a local command's output follows under the same promptId, as `<local-command-stdout>`. 2.1.306
  wrote both as `system` records of subtype `local_command`.
- A command typed while the session works, and not run at once, is a `queue-operation` record `enqueue` holding the
  text as typed. It leaves the queue by a `dequeue`, which names nothing, or a `remove`, which names what it took.
- /model and /effort run at once even mid-turn, and then write no record at all; one that asks the person to confirm
  first writes its record only once answered. A command with no record has not been seen, which is not that it did
  not run."""
from __future__ import annotations

import json
import os
import re
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field, replace
from datetime import datetime
from pathlib import Path
from typing import Any, Literal

from .delivery import MESSAGE_FILE_THRESHOLD, pasteable
from .jsonl import JsonlCursor
from .models import SlashCommand
from .sessions import SessionRegistry
from .text import nonempty_string

# How long a typed command may go with nothing of it in its transcript before it is unknown: one run at once has its
# record within a second, and one that waits its turn its enqueue.
UNSEEN_SECONDS = 60.0
# How long after it was typed a command not seen to run is looked for: one waiting on a dialog runs once the person
# answers it, which once took half an hour. Past it, the command stays as it was last seen.
WATCH_SECONDS = 60 * 60.0
# How many of a session's slash commands are kept: the last typed.
KEPT = 3
# A local command's output is kept as its first line with text, cut to this many characters.
OUTPUT_CHARS = 200

_COMMAND = re.compile(r"\s*(?:<command-message>[^<]*</command-message>\s*)?<command-name>(/[^<]+)</command-name>")
_ARGS = re.compile(r"<command-args>(.*?)</command-args>", re.DOTALL)
_OUTPUT = re.compile(r"<local-command-stdout>(.*?)</local-command-stdout>", re.DOTALL)
# What a line must hold to be worth parsing: most of a transcript says nothing of a slash command.
_MARKERS = (b'"queue-operation"', b"<command-name>", b"<local-command-stdout>")


@dataclass(frozen=True, slots=True)
class TranscriptRecord:
    """A transcript record that says something of a typed slash command: the queue's `enqueue`, `dequeue` or `remove`,
    a `command` Claude Code ran, or a local command's `output`. `at` is its own timestamp, on the wall clock."""
    kind: Literal["enqueue", "dequeue", "remove", "command", "output"]
    at: float
    # The text it queued or removed, the command it ran as typed (`/effort high`), or the output.
    text: str | None = None
    # Its promptId: a local command's output carries its command's.
    prompt: str | None = None


def _spaced(text: str) -> str:
    """`text` with its runs of whitespace as single spaces, as the prompt line keeps a typed command."""
    return " ".join(text.split())


def _time(value: Any) -> float | None:
    """A record's `timestamp` (`2026-10-26T08:21:16.304Z`) on the wall clock."""
    try:
        return datetime.fromisoformat(value).timestamp() if isinstance(value, str) else None
    except ValueError:
        return None


def _text(record: dict[str, Any]) -> str | None:
    """A user record's own text, or a local command's system record's: never a tool's result, which is a list."""
    if record.get("type") == "user" and isinstance(message := record.get("message"), dict):
        return nonempty_string(message.get("content"))
    if record.get("type") == "system" and record.get("subtype") == "local_command":
        return nonempty_string(record.get("content"))
    return None


def _record(line: bytes) -> TranscriptRecord | None:
    """What `line` says of a typed slash command, if anything. A subagent's record is its own, not the session's."""
    if not any(marker in line for marker in _MARKERS):
        return None
    try:
        r = json.loads(line)
    except ValueError:
        return None
    if not isinstance(r, dict) or r.get("isSidechain") is True or (at := _time(r.get("timestamp"))) is None:
        return None
    prompt = nonempty_string(r.get("promptId"))
    if r.get("type") == "queue-operation":
        operation, content = r.get("operation"), nonempty_string(r.get("content"))
        if operation == "dequeue":
            return TranscriptRecord("dequeue", at)
        if operation in ("enqueue", "remove") and content is not None and content.lstrip().startswith("/"):
            return TranscriptRecord(operation, at, _spaced(content))
        return None
    if (text := _text(r)) is None:
        return None
    if command := _COMMAND.match(text):
        args = _ARGS.search(text)
        return TranscriptRecord("command", at, _spaced(f"{command[1]} {args[1] if args else ''}"), prompt)
    if output := _OUTPUT.search(text):
        return TranscriptRecord("output", at, output[1], prompt)
    return None


@dataclass(slots=True)
class _Transcript:
    """One transcript as read so far: its cursor, the byte it was first read from, and what it kept."""
    cursor: JsonlCursor
    start: int
    records: list[TranscriptRecord] = field(default_factory=list)


class TranscriptReader:
    """Reads Claude transcripts on from where a slash command was typed into them, and keeps what says something of
    one. Blocking file I/O: the service runs it on a worker thread, and everything that touches it runs there."""

    def __init__(self) -> None:
        self._read: dict[str, _Transcript] = {}

    def read_all(self, starts: Mapping[str, int]) -> dict[str, tuple[TranscriptRecord, ...] | None]:
        """The records of each transcript in `starts`, in file order, from its byte offset there: read on from where
        the last call left it, and from its start once rewritten. One not written yet has none; one that cannot be read
        is None. Every other transcript is forgotten."""
        self._read = {path: kept for path, kept in self._read.items() if path in starts}
        return {path: self._read_one(path, start) for path, start in starts.items()}

    def _read_one(self, path: str, start: int) -> tuple[TranscriptRecord, ...] | None:
        try:
            st = os.stat(path)
        except FileNotFoundError:
            self._read.pop(path, None)
            return ()
        except (OSError, ValueError):
            return None
        kept = self._read.get(path)
        if kept is None or start < kept.start or kept.cursor.rewritten(st.st_ino, st.st_size):
            # A transcript replaced, or shorter than where its command was typed, is another file: read all of it.
            rewritten = kept is not None and kept.cursor.rewritten(st.st_ino, st.st_size)
            begin = 0 if rewritten or start > st.st_size else start
            kept = self._read[path] = _Transcript(JsonlCursor(st.st_ino, begin), begin)
        try:
            lines = kept.cursor.read_lines(Path(path), st.st_size)
        except OSError:
            return None
        kept.records += [record for line in lines if (record := _record(line)) is not None]
        return tuple(kept.records)


def _one_line(text: str | None) -> str | None:
    """`text`'s first line with text, cut to OUTPUT_CHARS; None when it has none."""
    line = next((line.strip() for line in (text or "").splitlines() if line.strip()), "")
    return line[:OUTPUT_CHARS] or None


def _output(after: Sequence[TranscriptRecord], prompt: str | None) -> str | None:
    """The output of the command whose run `after` follows: the first one before another command ran, under its
    promptId when both name one."""
    for record in after:
        if record.kind == "command":
            return None
        if record.kind == "output" and (prompt is None or record.prompt is None or record.prompt == prompt):
            return _one_line(record.text)
    return None


def settle(command: SlashCommand, records: Sequence[TranscriptRecord] | None, now: float) -> SlashCommand:
    """What `command` became, as `records` show it at `now`: its transcript's, in file order, None when the transcript
    cannot be read. Only a record written since it was typed is its own. It ran once its command record is there;
    it is queued while its enqueue is there and nothing has been taken from the queue since, a dequeue naming nothing;
    it is unknown once taken and not run, and once UNSEEN_SECONDS pass with nothing there at all. One that ran stays as
    it ran."""
    if command.state == "ran":
        return command
    if records is None:
        return replace(command, state="unknown", seen_at=None)
    text = _spaced(command.text)
    since = [record for record in records if record.at >= command.delivered_at]
    for index, record in enumerate(since):
        if record.kind == "command" and record.text == text:
            return replace(command, state="ran", seen_at=record.at, output=_output(since[index + 1:], record.prompt))
    queued = next((index for index, record in enumerate(since) if record.kind == "enqueue" and record.text == text), None)
    if queued is not None:
        taken = any(r.kind == "dequeue" or (r.kind == "remove" and r.text == text) for r in since[queued + 1:])
        return replace(command, state="unknown", seen_at=None) if taken else replace(command, state="queued", seen_at=since[queued].at)
    unseen = now - command.delivered_at >= UNSEEN_SECONDS
    return replace(command, state="unknown" if unseen else "delivered", seen_at=None)


def _followed(command: SlashCommand, now: float) -> bool:
    """Whether `command` is still looked for in its transcript: not seen to run, and typed within WATCH_SECONDS."""
    return command.state != "ran" and now - command.delivered_at < WATCH_SECONDS


def _size(path: str | None) -> int:
    """How long the transcript at `path` is now, in bytes; 0 for one not named or not written yet."""
    try:
        return os.stat(path).st_size if path else 0
    except (OSError, ValueError):
        return 0


class SlashCommands:
    """The slash commands AiTerm typed into Claude sessions (SessionInfo.slash_commands), and what became of each:
    noted as each is typed, then settled on every tick from its session's transcript, which `reader` reads off the
    loop. Only Claude's transcript is read: another agent's records commands its own way."""

    def __init__(self, registry: SessionRegistry, clock: Callable[[], float]):
        self.reg, self._clock = registry, clock
        self.reader = TranscriptReader()

    def stamp(self, session_id: str, text: str) -> SlashCommand | None:
        """The slash command `text` is, about to be typed into the session: stamped with the time and with where its
        transcript ends, before anything of it can be written there. None for other text, for one too long to paste,
        which goes through a message file (delivery.MESSAGE_FILE_THRESHOLD), and in any but a Claude tab."""
        s = self.reg.get(session_id)
        if s is None or s.agent != "claude" or not (typed := text.strip()).startswith("/"):
            return None
        if len(pasteable(text)) > MESSAGE_FILE_THRESHOLD:
            return None
        return SlashCommand(typed, self._clock(), start=_size(s.transcript))

    def delivered(self, session_id: str, command: SlashCommand) -> list[str]:
        """Records `command`, typed and entered into the session: the last KEPT are kept, a command typed again in
        place of its earlier self."""
        s = self.reg.get(session_id)
        if s is None:
            return []
        kept = tuple(c for c in s.slash_commands if c.text != command.text) + (command,)
        return [session_id] if self.reg.set_slash_commands(session_id, kept[-KEPT:]) else []

    def starts(self, now: float) -> dict[str, int]:
        """Each transcript a command is looked for in, by where to read it from: where the earliest of them was typed."""
        starts: dict[str, int] = {}
        for s in self.reg.all():
            for c in s.slash_commands:
                if s.transcript and _followed(c, now):
                    starts[s.transcript] = min(c.start, starts.get(s.transcript, c.start))
        return starts

    def apply(self, records: Mapping[str, tuple[TranscriptRecord, ...] | None], now: float) -> list[str]:
        """The sessions whose commands changed by `records`, each transcript's as `reader` read it, or by the time. A
        session whose hooks have named no transcript has none that can be read; one named anew while the others were
        read waits for the next tick."""
        changed: list[str] = []
        for s in self.reg.all():
            if not any(_followed(c, now) for c in s.slash_commands) or (s.transcript and s.transcript not in records):
                continue
            read = records[s.transcript] if s.transcript else None
            settled = tuple(settle(c, read, now) if _followed(c, now) else c for c in s.slash_commands)
            if self.reg.set_slash_commands(s.session_id, settled):
                changed.append(s.session_id)
        return changed
