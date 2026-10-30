"""What became of a slash command AiTerm typed into a Claude session (message_task), as the session's own transcript
records it. Checked against Claude Code 2.1.283 to 2.1.310, and driven live on 2.1.310:

- A command Claude Code ran is a user record whose text is its `<command-name>/name</command-name>`, with its
  `<command-args>`; a local command's output follows under the same promptId, as `<local-command-stdout>`. 2.1.306
  wrote both as `system` records of subtype `local_command`.
- A command typed while the session works, and not run at once, is a `queue-operation` record `enqueue` holding the
  text as typed. It leaves the queue by any other operation: a `dequeue`, which names nothing; a `remove`, which names
  what it took unless a hook dropped it; a `popAll` or `popOne`, which take it back into the input to be edited.
- /model and /effort run at once even mid-turn, and then write no record at all; one that asks the person to confirm
  first writes its record only once answered. A command with no record has not been seen, which is not that it did
  not run."""
from __future__ import annotations

import json
import math
import os
import re
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Literal

from .delivery import MESSAGE_FILE_THRESHOLD, pasteable
from .jsonl import JsonlCursor
from .models import SlashCommand
from .sessions import SessionRegistry
from .text import iso_seconds, nonempty_string

# How long a typed command may go with nothing of it in its transcript before it is unknown: one run at once has its
# record within a second, and one that waits its turn its enqueue.
UNSEEN_SECONDS = 60.0
# How long after it was typed a command not seen to run is looked for, and what its transcript records in that time
# its own: one waiting on a dialog runs once the person answers it, which once took half an hour. Past it, a command
# not seen to run is unknown, and no run is its own.
WATCH_SECONDS = 60 * 60.0
# How many of a session's slash commands are kept: the last typed.
KEPT = 3
# The most of a transcript one read takes in: one read from its start catches up over a few ticks.
READ_BYTES = 8 * 1024 * 1024
# A local command's output is kept as its first line with text, cut to this many characters.
OUTPUT_CHARS = 200

_COMMAND = re.compile(r"\s*(?:<command-message>[^<]*</command-message>\s*)?<command-name>(/[^<]+)</command-name>")
_ARGS = re.compile(r"<command-args>(.*?)</command-args>", re.DOTALL)
_OUTPUT = re.compile(r"<local-command-stdout>(.*?)</local-command-stdout>", re.DOTALL)
# What a line must hold to be worth parsing: most of a transcript says nothing of a slash command.
_MARKERS = (b'"queue-operation"', b"<command-name>", b"<local-command-stdout>")


@dataclass(frozen=True, slots=True)
class TranscriptRecord:
    """A transcript record that says something of a typed slash command: the queue's `enqueue` of one, something that
    `left` the queue, a `command` Claude Code ran, or a local command's `output`. `at` is its own timestamp, on the wall
    clock."""
    kind: Literal["enqueue", "left", "command", "output"]
    at: float
    # The command it queued, or took from the queue (None when it names nothing); the one it ran as typed
    # (`/effort high`); or the output.
    text: str | None = None
    # Its promptId: a local command's output carries its command's.
    prompt: str | None = None


def _spaced(text: str) -> str:
    """`text` with its runs of whitespace as single spaces, as the prompt line keeps a typed command."""
    return " ".join(text.split())


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
    if not isinstance(r, dict) or r.get("isSidechain") is True or (at := iso_seconds(r.get("timestamp"))) is None:
        return None
    prompt = nonempty_string(r.get("promptId"))
    if r.get("type") == "queue-operation":
        content = nonempty_string(r.get("content"))
        queued = _spaced(content) if content is not None and content.lstrip().startswith("/") else None
        if r.get("operation") == "enqueue":
            return TranscriptRecord("enqueue", at, queued) if queued is not None else None
        # Every other operation takes from the queue, one this daemon doesn't know as well: what it names, or maybe
        # anything when it names nothing. One that names another message took that.
        return TranscriptRecord("left", at, queued) if queued is not None or content is None else None
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
    """One transcript as read so far: its cursor, the byte it was asked to be read from, and what it kept."""
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
        the last call left it, from the offset afresh once that is past where it left it, and from its start once
        rewritten. One not written yet has none; one that cannot be read is None. Every other transcript is
        forgotten."""
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
        rewritten = kept is not None and kept.cursor.rewritten(st.st_ino, st.st_size)
        if kept is None or rewritten or not kept.start <= start <= max(kept.start, kept.cursor.offset):
            # Read from `start`: what comes before it is no followed command's, even where a read had not got that far.
            # A transcript replaced, or shorter than where its command was typed, is another file: read all of it.
            begin = 0 if rewritten or start > st.st_size else start
            kept = self._read[path] = _Transcript(JsonlCursor(st.st_ino, begin), start)
        try:
            lines = kept.cursor.read_lines(Path(path), min(st.st_size, kept.cursor.offset + READ_BYTES))
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


def _own(records: Sequence[TranscriptRecord], taken: set[int], kind: str, text: str, since: float, until: float,
         after: int = -1) -> int | None:
    """Where in `records` the first record of `kind` for `text` is: past index `after`, written from `since` and before
    `until`, and not an older command's (`taken`)."""
    return next((index for index, record in enumerate(records) if index > after and index not in taken
                 and record.kind == kind and record.text == text and since <= record.at < until), None)


def _settle(command: SlashCommand, until: float, records: Sequence[TranscriptRecord] | None, now: float,
            taken: set[int]) -> SlashCommand:
    """What one command became, the next of its text typed at `until`; it takes the records it reads as its own into
    `taken`. See `settle`."""
    text = _spaced(command.text)
    if command.state == "ran":
        # The run it was seen by, if it is still among what was read: no newer command's, and its output may follow it.
        if records is None or (run := next((index for index, record in enumerate(records) if index not in taken
                                            and record.kind == "command" and record.text == text
                                            and record.at == command.seen_at), None)) is None:
            return command
        taken.add(run)
        return command if command.output is not None else replace(command, output=_output(records[run + 1:], records[run].prompt))
    if records is None:
        return replace(command, state="unknown", seen_at=None)
    watched = command.delivered_at + WATCH_SECONDS
    queued = _own(records, taken, "enqueue", text, command.delivered_at, min(until, watched))
    # Run at once, it ran before the next of its text was typed, and before any enqueue of its text, which is then a
    # later command's: the person may type the same.
    if (run := _own(records[:queued], taken, "command", text, command.delivered_at, min(until, watched))) is not None:
        queued = None
    elif queued is not None:
        taken.add(queued)
        # Queued, it runs in its turn, the same text queued twice first in first out, unless something took it from the
        # queue by its text first: a remove, a popAll or popOne.
        named = next((index for index in range(queued + 1, len(records))
                      if records[index].kind == "left" and records[index].text == text), len(records))
        run = _own(records[:named], taken, "command", text, command.delivered_at, watched, after=queued)
    if run is not None:
        taken.add(run)
        return replace(command, state="ran", seen_at=records[run].at, output=_output(records[run + 1:], records[run].prompt))
    if now - command.delivered_at >= WATCH_SECONDS:
        # No longer looked for, and not seen to run: what it is now is no longer known.
        return replace(command, state="unknown", seen_at=None)
    if queued is not None:
        left = any(record.kind == "left" and record.text in (None, text) for record in records[queued + 1:])
        return replace(command, state="unknown", seen_at=None) if left else replace(command, state="queued", seen_at=records[queued].at)
    unseen = now - command.delivered_at >= UNSEEN_SECONDS
    return replace(command, state="unknown" if unseen else "delivered", seen_at=None)


def _next_typed(commands: Sequence[SlashCommand], index: int) -> float:
    """When the next command with the text of `commands[index]` was typed; infinity when none was."""
    text = _spaced(commands[index].text)
    return next((later.delivered_at for later in commands[index + 1:] if _spaced(later.text) == text), math.inf)


def settle(commands: Sequence[SlashCommand], records: Sequence[TranscriptRecord] | None, now: float) -> tuple[SlashCommand, ...]:
    """What each of a session's commands, oldest first, became as `records` show it at `now`: its transcript's, in file
    order, None when the transcript cannot be read. A command's own records are written within WATCH_SECONDS of its
    typing, and each is one command's, the oldest's that can take it. One run at once ran before the next of its text
    was typed, and before any enqueue of its text, which is then a later command's, such as the person's. One queued
    (its enqueue written before the next of its text was typed) runs in its turn, the same text queued twice first in
    first out, unless a remove, a popAll or popOne named it first. A command ran once its command record is there, its
    output attached once it follows. It is queued while its enqueue is there and nothing has left the queue since that
    names it or names nothing, as a dequeue does; it is unknown once something did and it has not run, once
    UNSEEN_SECONDS pass with nothing of it there at all, and once WATCH_SECONDS pass without its run. One that ran
    stays as it ran."""
    taken: set[int] = set()
    return tuple(_settle(command, _next_typed(commands, index), records, now, taken) for index, command in enumerate(commands))


def _followed(command: SlashCommand, now: float) -> bool:
    """Whether its transcript is still read for `command`: not seen to run, within WATCH_SECONDS of being typed; or seen
    to run with no output yet, for UNSEEN_SECONDS, in case one follows."""
    if command.state == "ran":
        return command.output is None and now - (command.seen_at or command.delivered_at) < UNSEEN_SECONDS
    return now - command.delivered_at < WATCH_SECONDS


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
        if s is None or s.agent != "claude" or not (typed := pasteable(text).strip()).startswith("/"):
            return None
        if len(pasteable(text)) > MESSAGE_FILE_THRESHOLD:
            return None
        return SlashCommand(typed, self._clock(), start=_size(s.transcript), transcript=s.transcript)

    def delivered(self, session_id: str, command: SlashCommand) -> list[str]:
        """Records `command`, typed and entered into the session, keeping the last KEPT."""
        s = self.reg.get(session_id)
        if s is None:
            return []
        return [session_id] if self.reg.set_slash_commands(session_id, (s.slash_commands + (command,))[-KEPT:]) else []

    def starts(self, now: float) -> dict[str, int]:
        """Each transcript its commands are still looked for in, by where to read it from: where the earliest of them
        was typed, or its start for one typed while the session wrote another."""
        starts: dict[str, int] = {}
        for s in self.reg.all():
            for c in s.slash_commands:
                if s.transcript and _followed(c, now):
                    start = c.start if c.transcript == s.transcript else 0
                    starts[s.transcript] = min(start, starts.get(s.transcript, start))
        return starts

    def apply(self, records: Mapping[str, tuple[TranscriptRecord, ...] | None], now: float) -> list[str]:
        """The sessions whose commands changed by `records`, each transcript's as `reader` read it, or by the time. A
        session whose hooks have named no transcript has none that can be read; one named anew while the others were
        read waits for the next tick."""
        changed: list[str] = []
        for s in self.reg.all():
            followed = any(_followed(c, now) for c in s.slash_commands)
            if followed and s.transcript and s.transcript not in records:
                continue
            settled = settle(s.slash_commands, records[s.transcript] if followed and s.transcript else None, now)
            if self.reg.set_slash_commands(s.session_id, settled):
                changed.append(s.session_id)
        return changed
