from __future__ import annotations
import contextlib
import json
import math
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

from .jsonl import JsonlCursor
from .models import TokenTally
from .usage import finite_number, whole_count

# How often the whole sessions tree is listed again. In between, only the rollouts last seen to be
# the newest, the tracked threads' own and today's directory are looked at: a new session writes
# under today's date, and a resumed one appends to a rollout already known.
LIST_SECONDS = 30.0
RECENT_KEPT = 8
# How many day directories after a thread's own are searched for its children: one long-running
# thread may outlive a few midnights, and a listing that grew without bound would cost every tick.
CHILD_DAYS = 31

# What every `token_count` record contains, so a line without it can be skipped unparsed.
_TOKEN_COUNT = b'"token_count"'
# The same for a `session_meta` record, the one that names the Codex version.
_SESSION_META = b'"session_meta"'


@dataclass(slots=True)
class _MetaCursor(JsonlCursor):
    """How far one rollout has been read for its `session_meta` records: the byte offset, the inode it
    was read from, the start of a line Codex was still writing, and the version found so far."""
    version: str | None = None

Stamp = tuple[Path, int, int]  # path, st_mtime_ns, st_size


class CodexSessionFiles:
    def __init__(self, root: Path | None = None, clock: Callable[[], float] = time.monotonic):
        self.root = root or Path.home() / ".codex" / "sessions"
        self._clock = clock
        self._paths: dict[str, Path] = {}
        # Thread id -> when a full listing last failed to find its rollout.
        self._missed: dict[str, float] = {}
        self._listed_at: float | None = None
        self._recent: list[Path] = []
        # Thread id -> the rollout as last parsed, and the fill it gave.
        self._context: dict[str, tuple[Stamp, int | None]] = {}
        # Each rollout's (thread id, session id, parent thread id), from its first record, which
        # never changes. Pruned to day directories still relevant to tracked threads.
        self._lineage: dict[Path, tuple[str | None, str | None, str | None]] = {}
        # Rollout -> its stamp as last read, and the total it gave.
        self._totals: dict[Path, tuple[Stamp, TokenTally | None]] = {}
        # Directory contents change only when rollouts are added/removed, so overlapping
        # parent searches can reuse one listing without delaying discovery of new children.
        self._days: dict[Path, tuple[tuple[int, int], tuple[Path, ...]]] = {}
        # Thread id -> the rollouts of its subagents as last found, for `retain`.
        self._children: dict[str, list[Path]] = {}
        # Rollout -> how far it has been read for the Codex version (cli_version).
        self._versions: dict[Path, _MetaCursor] = {}
        # The rollouts `rate_limits()` last consulted, by (path, mtime), and what they said: the
        # tick asks every two seconds, and a file nobody has written to has nothing new to say.
        self._limits_seen: tuple[tuple[Path, int], ...] | None = None
        self._limits_answer: tuple[dict[str, Any], int | None] | None = None

    def retain(self, session_ids: set[str]) -> None:
        """Drops what is cached for threads no tab is running any more."""
        for cache in (self._paths, self._missed, self._context, self._children):
            for session_id in cache.keys() - session_ids:
                del cache[session_id]
        kept = {*self._paths.values(), *(p for paths in self._children.values() for p in paths)}
        for path in self._totals.keys() - kept:
            del self._totals[path]
        for path in self._versions.keys() - set(self._paths.values()):
            del self._versions[path]
        days = {day for path in self._paths.values() for day in self._day_directories_since(path)}
        for day in self._days.keys() - days:
            del self._days[day]
        for path in tuple(self._lineage):
            if path.parent not in days:
                del self._lineage[path]

    def context_percent(self, session_id: str) -> int | None:
        path = self._path_for(session_id)
        if path is None:
            return None
        try:
            st = path.stat()
        except OSError:
            return None
        stamp = (path, st.st_mtime_ns, st.st_size)
        cached = self._context.get(session_id)
        if cached is not None and cached[0] == stamp:
            return cached[1]
        try:
            percent = self._read_context(path)
        except OSError:
            return None
        self._context[session_id] = (stamp, percent)
        return percent

    def cli_version(self, thread_id: str) -> str | None:
        """The Codex version that runs the thread: `cli_version` in the newest `session_meta` record
        its rollout holds for it -- the record a session starts with; another one later in the file,
        from a resume, wins. None before the rollout names one. A rollout only grows, so it is read on
        from where the last read stopped, and one rewritten is read again from its start."""
        path = self._path_for(thread_id)
        if path is None:
            return None
        try:
            st = path.stat()
        except OSError:
            return None
        cursor = self._versions.get(path)
        if cursor is None or cursor.rewritten(st.st_ino, st.st_size):
            cursor = self._versions[path] = _MetaCursor(st.st_ino)
        try:
            lines = cursor.read_lines(path, st.st_size)
        except OSError:
            return cursor.version
        for line in lines:
            if _SESSION_META in line and (version := _meta_version(line, thread_id)) is not None:
                cursor.version = version
        return cursor.version

    def _read_context(self, path: Path) -> int | None:
        for _, payload in self._token_counts(path):
            info = payload.get("info")
            last = info.get("last_token_usage") if isinstance(info, dict) else None
            total = finite_number(last.get("total_tokens")) if isinstance(last, dict) else None
            window = finite_number(info.get("model_context_window")) if isinstance(info, dict) else None
            if total is None or window is None or window <= 0:
                continue
            percent = total / window * 100
            if not math.isfinite(percent):
                continue
            return max(0, min(100, round(percent)))
        return None

    def tally(self, thread_id: str) -> TokenTally | None:
        """What the thread has spent with its subagents'. Codex keeps each child's tokens in the
        child's own rollout and none in the parent's (a review child's 798,760 against its parent's
        whole 24,212), so the parent's total alone would leave them out."""
        path = self._path_for(thread_id)
        if path is None:
            return None
        children = self._children[thread_id] = self._descendants(thread_id, path)
        return TokenTally.combined(total for p in (path, *children) if (total := self._total(p)) is not None)

    def _descendants(self, thread_id: str, path: Path) -> list[Path]:
        """The rollouts started under `thread_id` at any depth: a child names its parent thread
        (`parent_thread_id`, or its spawn's) and its conversation's root (`session_id`). A child starts
        after its parent, so only the parent's day directory and the ones since are looked in."""
        by_parent: dict[str, list[tuple[Path, str | None]]] = {}
        for candidate in self._list_days_since(path):
            if candidate == path:
                continue
            own, root, parent = self._lineage_of(candidate)
            if own == thread_id:
                continue
            for ancestor in {root, parent} - {None}:
                if ancestor is not None:
                    by_parent.setdefault(ancestor, []).append((candidate, own))
        family, found, pending = {thread_id}, set(), [thread_id]
        while pending:
            for candidate, own in by_parent.get(pending.pop(), []):
                found.add(candidate)
                if own is not None and own not in family:
                    family.add(own)
                    pending.append(own)
        return sorted(found)

    def _day_directories_since(self, path: Path) -> list[Path]:
        """Day directories in the existing bounded child-search window."""
        try:
            first = date(*map(int, path.relative_to(self.root).parts[:3]))
        except (ValueError, TypeError):
            return []
        last = max(date.today(), datetime.now(UTC).date())
        return [self.root / f"{first + timedelta(days=offset):%Y/%m/%d}"
                for offset in range(min((last - first).days, CHILD_DAYS) + 1)]

    def _list_days_since(self, path: Path) -> list[Path]:
        """Rollouts in the parent's day and subsequent days, sharing unchanged listings."""
        found: list[Path] = []
        for day in self._day_directories_since(path):
            try:
                st = day.stat()
                stamp = (st.st_ino, st.st_mtime_ns)
                cached = self._days.get(day)
                if cached is None or cached[0] != stamp:
                    cached = (stamp, tuple(day.glob("rollout-*.jsonl")))
                    self._days[day] = cached
                found.extend(cached[1])
            except OSError:
                self._days.pop(day, None)
        return found

    def _lineage_of(self, path: Path) -> tuple[str | None, str | None, str | None]:
        if (known := self._lineage.get(path)) is not None:
            return known
        lineage = _read_lineage(path)
        if lineage is not None:  # a file without its first line yet is asked again next time
            self._lineage[path] = lineage
        return lineage or (None, None, None)

    def _total(self, path: Path) -> TokenTally | None:
        """The rollout's own spend, cached until the file changes."""
        try:
            st = path.stat()
        except OSError:
            return None
        stamp = (path, st.st_mtime_ns, st.st_size)
        if (cached := self._totals.get(path)) is not None and cached[0] == stamp:
            return cached[1]
        try:
            total = self._read_total(path)
        except OSError:
            return None
        self._totals[path] = (stamp, total)
        return total

    def _read_total(self, path: Path) -> TokenTally | None:
        """The newest `total_token_usage`. Its `input_tokens` already counts the cache
        (`total_tokens` = input + output in every rollout measured)."""
        for _, payload in self._token_counts(path):
            info = payload.get("info")
            usage = info.get("total_token_usage") if isinstance(info, dict) else None
            if not isinstance(usage, dict):
                continue
            spent_in, spent_out = whole_count(usage.get("input_tokens")), whole_count(usage.get("output_tokens"))
            if spent_in is None or spent_out is None:
                continue
            read, written = whole_count(usage.get("cached_input_tokens")), whole_count(usage.get("cache_write_input_tokens")) or 0
            return TokenTally(spent_in, None if read is None else read + written, spent_out)
        return None

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
        except OSError:
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
        matches = [path for path in (self._list_all() if full else self._list_today()) if path.name.endswith(suffix)]
        path = max(matches, key=lambda item: _mtime(item) or -1, default=None)
        if path is None:
            if full:
                self._missed[session_id] = self._clock()
            return None
        self._missed.pop(session_id, None)
        self._paths[session_id] = path
        return path

    def _list_all(self) -> list[Path]:
        if not self.root.is_dir():
            return []
        try:
            return list(self.root.rglob("rollout-*.jsonl"))
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
        for line in cls._lines_reverse(path, _TOKEN_COUNT):
            try:
                record = json.loads(line)
            except (UnicodeDecodeError, ValueError):
                continue
            if not isinstance(record, dict) or record.get("type") != "event_msg":
                continue
            payload = record.get("payload")
            if isinstance(payload, dict) and payload.get("type") == "token_count":
                yield record, payload

    @staticmethod
    def _lines_reverse(path: Path, containing: bytes = b"", block_size: int = 64 * 1024) -> Iterator[bytes]:
        """The lines of `path` that contain `containing`, last first. A block holding none is not
        even split into lines."""
        with path.open("rb") as stream:
            stream.seek(0, 2)
            position = stream.tell()
            remainder = b""
            while position > 0:
                size = min(block_size, position)
                position -= size
                stream.seek(position)
                block = stream.read(size) + remainder
                start = block.find(b"\n") + 1  # the first line may continue into the block before
                if start == 0:
                    remainder = block
                    continue
                remainder = block[:start - 1]
                if containing not in block[start:]:
                    continue
                for line in reversed(block[start:].split(b"\n")):
                    if line and containing in line:
                        yield line
            if remainder and containing in remainder:
                yield remainder


def _mtime(path: Path) -> int | None:
    try:
        return path.stat().st_mtime_ns
    except OSError:
        return None


def _epoch(timestamp: Any) -> int | None:
    """Codex stamps records in RFC 3339 UTC (`2026-09-22T14:31:09.229Z`)."""
    if not isinstance(timestamp, str):
        return None
    try:
        parsed = datetime.fromisoformat(timestamp)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return int(parsed.timestamp())


def _read_lineage(path: Path) -> tuple[str | None, str | None, str | None] | None:
    """A rollout's (thread id, session id, parent thread id) from its first record, the session's
    meta; three Nones for a file that starts with anything else, and None while its first line is
    still being written."""
    try:
        with path.open("rb") as stream:
            line = stream.readline()
    except OSError:
        return None
    if not line.endswith(b"\n"):
        return None
    try:
        record = json.loads(line)
    except (UnicodeDecodeError, ValueError):
        return (None, None, None)
    payload = record.get("payload") if isinstance(record, dict) and record.get("type") == "session_meta" else None
    if not isinstance(payload, dict):
        return (None, None, None)
    return (_string(payload.get("id")), _string(payload.get("session_id")),
            _string(payload.get("parent_thread_id")) or _spawned_by(payload.get("source")))


def _spawned_by(source: Any) -> str | None:
    """The parent a spawned subagent names in `source.subagent.thread_spawn`."""
    for key in ("subagent", "thread_spawn"):
        source = source.get(key) if isinstance(source, dict) else None
    return _string(source.get("parent_thread_id")) if isinstance(source, dict) else None


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _meta_version(line: bytes, thread_id: str) -> str | None:
    """The `cli_version` of a `session_meta` record for `thread_id`; None for any other line."""
    try:
        record = json.loads(line)
    except (UnicodeDecodeError, ValueError):
        return None
    payload = record.get("payload") if isinstance(record, dict) and record.get("type") == "session_meta" else None
    if not isinstance(payload, dict) or payload.get("id") != thread_id:
        return None
    return _string(payload.get("cli_version"))
