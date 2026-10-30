from __future__ import annotations
import os
from collections.abc import Collection, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .jsonl import records_newest_first
from .text import iso_seconds

# How much of a transcript's end is read. The records that end a child -- an interruption, a
# SubagentStop hook's attachment -- are a few hundred bytes; a transcript grows to megabytes.
TAIL_BYTES = 64 * 1024
# The text Claude Code writes as a user message when it aborts an agent's run: Esc, or its stream
# watchdog ("Agent stalled: no progress for 600s"). Mid-tool it reads "... for tool use]".
INTERRUPTED = "[Request interrupted by user"


@dataclass(frozen=True, slots=True)
class TranscriptTail:
    """What the end of a subagent's transcript says. `stamp` is (st_mtime_ns, st_size), which
    changes whenever Claude appends; `written_at` is the st_mtime, in the wall clock's seconds."""
    stamp: tuple[int, int]
    written_at: float
    # When the last record ends the child's run -- an interruption, or a SubagentStop hook that ran with no prompt before
    # it for the child to answer -- the time that record gives, or `written_at` when it gives none. Claude writes in
    # batches, so a record can reach the file well after its time. None while the last record is no such end.
    ended_at: float | None


def _user_content(record: dict[str, Any]) -> str | list[Any] | None:
    """A user message's content: its text, or its blocks. None for any other record."""
    if record.get("type") != "user" or not isinstance(message := record.get("message"), dict):
        return None
    content = message.get("content")
    return content if isinstance(content, (str, list)) else None


def _is_interruption(record: dict[str, Any]) -> bool:
    if isinstance(content := _user_content(record), str):
        return content.startswith(INTERRUPTED)
    return content is not None and any(
        isinstance(block, dict) and block.get("type") == "text" and isinstance(text := block.get("text"), str)
        and text.startswith(INTERRUPTED) for block in content)


def _is_prompt(record: dict[str, Any]) -> bool:
    """A user message for the child to answer: not a tool's result, nor the interruption that ends it."""
    if (content := _user_content(record)) is None or _is_interruption(record):
        return False
    return isinstance(content, str) or not any(
        isinstance(block, dict) and block.get("type") == "tool_result" for block in content)


def _is_subagent_stop(record: dict[str, Any]) -> bool:
    """A SubagentStop hook's attachment, whatever came of the hook: Claude sent it, so the child
    stopped, even if the daemon never saw the post."""
    return record.get("type") == "attachment" and isinstance(a := record.get("attachment"), dict) \
        and a.get("hookEvent") == "SubagentStop"


def _ending(records: Iterator[Any]) -> dict[str, Any] | None:
    """The last complete record in the tail if it ends the child, else None. A record still being
    written, or one longer than the tail, is neither of the small records that do. A SubagentStop
    does not when the last message before it is a prompt the child has yet to answer: Claude Code
    (2.1.283 to 2.1.308 at least) reminds a background child that ends its turn without handing
    back its report, fires SubagentStop, then runs the child on to answer the reminder."""
    if not isinstance(last := next(records, None), dict):
        return None
    if _is_interruption(last):
        return last
    if not _is_subagent_stop(last):
        return None
    # Past the attachments of the other hooks that ran with it. A record the tail cannot show leaves the stop standing.
    message = next((r for r in records if not isinstance(r, dict) or r.get("type") in ("user", "assistant")), None)
    return None if isinstance(message, dict) and _is_prompt(message) else last


# A transcript as last read, keyed by its stamp: only a file Claude has appended to since is read again.
_Entry = tuple[tuple[int, int], TranscriptTail]


class SubagentTranscripts:
    """Reads the end of Claude subagents' transcripts, for the status engine: whether a child's run
    is over, at its SubagentStop or without one, and when it last wrote. Blocking file I/O: the
    service runs it on a worker thread."""

    def __init__(self) -> None:
        self._cache: dict[str, _Entry] = {}

    def read_all(self, paths: Collection[str]) -> dict[str, TranscriptTail | None]:
        """Each of `paths`, read: None for one that cannot be found or read. The cache keeps only those read."""
        tails = {path: self.read(path) for path in paths}
        self._cache = {path: entry for path, entry in self._cache.items() if tails.get(path) is not None}
        return tails

    def read(self, path: str) -> TranscriptTail | None:
        """The end of the transcript at `path`, or of the same file one or two directories below
        its own: Claude Code files some agents under `subagents/<subdir>/`, and a workflow's under
        `subagents/workflows/<run>/`. None while none exists."""
        if (st := self._stat(path)) is None:
            return None
        real, stat = st
        stamp = (stat.st_mtime_ns, stat.st_size)
        if (cached := self._cache.get(path)) is not None and cached[0] == stamp:
            return cached[1]
        try:
            ending = _ending(records_newest_first(Path(real), TAIL_BYTES, discard_boundary=True))
        except OSError:
            return None
        tail = TranscriptTail(stamp, stat.st_mtime, None if ending is None else iso_seconds(ending.get("timestamp")) or stat.st_mtime)
        self._cache[path] = (stamp, tail)
        return tail

    @staticmethod
    def _stat(path: str) -> tuple[str, os.stat_result] | None:
        try:
            return path, os.stat(path)
        except (OSError, ValueError):
            pass
        try:
            p = Path(path)
            for pattern in (f"*/{p.name}", f"*/*/{p.name}"):
                for candidate in p.parent.glob(pattern):
                    return str(candidate), candidate.stat()
        except (OSError, ValueError):
            pass
        return None
