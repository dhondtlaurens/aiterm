from __future__ import annotations
import contextlib
import json
import logging
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, NamedTuple

from .models import State
from .text import iso_seconds, nonempty_string
from .jsonl import JsonlCursor, records_newest_first
from .usage import clamped_percent, finite_number

# How often the whole sessions tree is listed again. In between, only the rollouts last seen to be
# the newest, the tracked threads' own and today's directory are looked at: a new session writes
# under today's date, and a resumed one appends to a rollout already known.
LIST_SECONDS = 30.0
RECENT_KEPT = 8
# What every `token_count` record contains, so a line without it can be skipped unparsed.
_TOKEN_COUNT = b'"token_count"'
# The same for a `session_meta` record, the one that names the Codex version.
_SESSION_META = b'"session_meta"'


# Account usage and thread corroboration share this off-loop name: their reader caches
# are not locked, so an outstanding read must hold back both kinds of work.
CODEX_READ = "the Codex rollout read"
READ_BYTES = 8 * 1024 * 1024


class CodexReading(NamedTuple):
    context: int | None
    version: str | None
    turn: tuple[State, float] | None


@dataclass(slots=True)
class _RolloutCursor(JsonlCursor):
    version: str | None = None
    turn: tuple[State, float] | None = None
    context: int | None = None
    # Whether the first clipped tail line still needs dropping once it is complete.
    clipped: bool = False

    def consume(self, lines: list[bytes], thread_id: str) -> None:
        for line in lines:
            if not any(marker in line for marker in (_SESSION_META, b'"task_started"', b'"task_complete"',
                                                     b'"turn_aborted"', _TOKEN_COUNT)):
                continue
            try:
                record = json.loads(line)
            except ValueError:
                logging.getLogger(__name__).warning("skipping an unparsable Codex rollout line for thread %s", thread_id)
                continue
            if not isinstance(record, dict) or not isinstance(payload := record.get("payload"), dict):
                continue
            if record.get("type") == "session_meta" and payload.get("id") == thread_id:
                if (version := nonempty_string(payload.get("cli_version"))) is not None:
                    self.version = version
            if record.get("type") != "event_msg":
                continue
            kind = payload.get("type")
            if kind in ("turn_aborted", "task_started", "task_complete"):
                at = iso_seconds(record.get("timestamp"))
                self.turn = (("working" if kind == "task_started" else "done", at)
                             if kind != "turn_aborted" and at is not None else None)
            elif kind == "token_count":
                info = payload.get("info")
                last = info.get("last_token_usage") if isinstance(info, dict) else None
                total = finite_number(last.get("total_tokens")) if isinstance(last, dict) else None
                window = finite_number(info.get("model_context_window")) if isinstance(info, dict) else None
                if total is not None and window is not None and window > 0:
                    if (percent := clamped_percent(total / window * 100)) is not None:
                        self.context = percent


class CodexSessionFiles:
    def __init__(self, root: Path | None = None, clock: Callable[[], float] = time.monotonic):
        self.root = root or Path.home() / ".codex" / "sessions"
        self._clock = clock
        self._paths: dict[str, Path] = {}
        # Thread id -> when a full listing last failed to find its rollout.
        self._missed: dict[str, float] = {}
        self._listed_at: float | None = None
        self._batch_listing = False
        self._tree: list[Path] | None = None
        self._recent: list[Path] = []
        # Rollout -> the version, turn and context followed from its last read.
        self._rollouts: dict[Path, _RolloutCursor] = {}
        # The rollouts `rate_limits()` last consulted, by (path, mtime), and what they said: the
        # tick asks every two seconds, and a file nobody has written to has nothing new to say.
        self._limits_seen: tuple[tuple[Path, int], ...] | None = None
        self._limits_answer: tuple[dict[str, Any], int | None] | None = None

    def begin_tick(self) -> None:
        """Share any full tree discovery across usage and thread reads in this tick."""
        self._batch_listing, self._tree = True, None

    def retain(self, session_ids: set[str]) -> None:
        """Drops what is cached for threads no tab is running any more."""
        for cache in (self._paths, self._missed):
            for session_id in cache.keys() - session_ids:
                del cache[session_id]
        for path in self._rollouts.keys() - set(self._paths.values()):
            del self._rollouts[path]

    def reading(self, thread_id: str) -> CodexReading:
        """Follow one rollout for the thread's version, last turn boundary and context fill."""
        try:
            if (path := self._path_for(thread_id)) is None:
                return CodexReading(None, None, None)
            stat = path.stat()
            old = self._rollouts.get(path)
            first = b""
            if old is None or old.rewritten(stat.st_ino, stat.st_size):
                cursor = _RolloutCursor(stat.st_ino)
                if stat.st_size > READ_BYTES:
                    with path.open("rb") as stream:
                        first = stream.readline(READ_BYTES)
                    cursor.offset = stat.st_size - READ_BYTES
                    cursor.clipped = True
            else:
                if old.offset == stat.st_size:
                    return CodexReading(old.context, old.version, old.turn)
                cursor = replace(old)
            lines = cursor.read_lines(path, stat.st_size)
        except OSError:
            return CodexReading(None, None, None)
        if first.endswith(b"\n"):
            cursor.consume([first], thread_id)
        if cursor.clipped and lines:
            lines = lines[1:]
            cursor.clipped = False
        cursor.consume(lines, thread_id)
        self._rollouts[path] = cursor
        return CodexReading(cursor.context, cursor.version, cursor.turn)

    def rate_limits(self) -> tuple[dict[str, Any], int | None] | None:
        """The newest `rate_limits` block any Codex session has written, with the record's own
        timestamp (epoch seconds, None if unreadable) as the number's age. Rate limits are
        account-wide, so the most recently written rollout is the truth whichever session AiTerm
        happens to track -- and a Codex run outside AiTerm counts just the same. Only the few
        newest rollouts are consulted: a file without a single such record is read in full, and
        a hundred of them on every tick would not be."""
        newest = self._newest_rollouts(3)
        if newest == self._limits_seen:
            return self._limits_answer
        try:
            answer = self._read_rate_limits([path for path, _ in newest])
        except FileNotFoundError:
            return None
        self._limits_seen, self._limits_answer = newest, answer
        return self._limits_answer

    def _read_rate_limits(self, paths: list[Path]) -> tuple[dict[str, Any], int | None] | None:
        for path in paths:
            for record, payload in self._token_counts(path):
                limits = payload.get("rate_limits")
                if isinstance(limits, dict):
                    return limits, _epoch(record.get("timestamp"))
        return None

    def _newest_rollouts(self, count: int) -> tuple[tuple[Path, int], ...]:
        """The `count` most recently written rollouts with their mtimes, newest first."""
        if self._listed_at is None or self._clock() - self._listed_at >= LIST_SECONDS:
            self._listed_at = self._clock()
            candidates = set(self._list_all())
        else:
            candidates = {*self._recent, *self._paths.values(), *self._list_today()}
        stamped = [(path, mtime) for path in candidates if (mtime := _mtime(path)) is not None]
        stamped.sort(key=lambda item: item[1], reverse=True)
        self._recent = [path for path, _ in stamped[:RECENT_KEPT]]
        return tuple(stamped[:count])

    def _path_for(self, session_id: str) -> Path | None:
        cached = self._paths.get(session_id)
        if cached is not None and cached.is_file():
            return cached
        # A thread whose rollout is nowhere is looked for across the whole tree once per
        # LIST_SECONDS; in between only under today's date, where a new thread's rollout appears.
        missed = self._missed.get(session_id)
        full = missed is None or self._clock() - missed >= LIST_SECONDS
        suffix = f"-{session_id}.jsonl"
        shared_tree = full and self._tree is not None
        matches = [path for path in (self._list_all() if full else self._list_today()) if path.name.endswith(suffix)]
        path = max(matches, key=lambda item: _mtime(item) or -1, default=None)
        if path is None and shared_tree:
            # The shared tree is a snapshot. A new rollout may already exist under today's
            # date, even when the tree was listed earlier in this tick.
            today = [candidate for candidate in self._list_today() if candidate.name.endswith(suffix)]
            path = max(today, key=lambda item: _mtime(item) or -1, default=None)
        if path is None:
            if full:
                self._missed[session_id] = self._clock()
            return None
        self._missed.pop(session_id, None)
        self._paths[session_id] = path
        return path

    def _list_all(self) -> list[Path]:
        if self._tree is not None:
            return self._tree
        try:
            paths = list(self.root.rglob("rollout-*.jsonl"))
            if self._batch_listing:
                self._tree = paths
            return paths
        except OSError:
            return []

    def _list_today(self) -> list[Path]:
        days = {datetime.now().strftime("%Y/%m/%d"), datetime.now(UTC).strftime("%Y/%m/%d")}
        found: list[Path] = []
        for day in days:
            with contextlib.suppress(OSError):
                found += (self.root / day).glob("rollout-*.jsonl")
        return found

    @classmethod
    def _token_counts(cls, path: Path) -> Iterator[tuple[dict[str, Any], dict[str, Any]]]:
        """Every `token_count` event of a rollout, newest first, with the record that carries it."""
        # Most of a rollout is messages and tool output: parsing them to find that they are not
        # token counts made a rollout with none cost tens of milliseconds a megabyte.
        for record in records_newest_first(path, None, containing=_TOKEN_COUNT):
            if not isinstance(record, dict) or record.get("type") != "event_msg":
                continue
            payload = record.get("payload")
            if isinstance(payload, dict) and payload.get("type") == "token_count":
                yield record, payload


def _mtime(path: Path) -> int | None:
    try:
        return path.stat().st_mtime_ns
    except OSError:
        return None


def _epoch(timestamp: Any) -> int | None:
    """Codex stamps records in RFC 3339 UTC (`2026-09-22T14:31:09.229Z`)."""
    seconds = iso_seconds(timestamp)
    return int(seconds) if seconds is not None else None
