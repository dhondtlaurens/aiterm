from __future__ import annotations
import contextlib
import json
import logging
import os
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


class _LocatedRollout(NamedTuple):
    path: Path | None
    after_cached_miss: bool = False


class CodexReading(NamedTuple):
    context: int | None
    version: str | None
    turn: tuple[State, float] | None


@dataclass(slots=True)
class _RolloutCursor(JsonlCursor):
    version: str | None = None
    latest: tuple[State, float] | None = None
    boundary_seen: bool = False
    stamp: tuple[int, int, int, int, int] | None = None
    version_error: Exception | None = None
    turn_error: Exception | None = None

    def consume(self, lines: list[bytes], thread_id: str, *, version: bool = True, turn: bool = True) -> None:
        for line in lines:
            if not any(marker in line for marker in (_SESSION_META, b'"task_started"', b'"task_complete"', b'"turn_aborted"')):
                continue
            meta = version and self.version_error is None and _SESSION_META in line
            boundary = (turn and self.turn_error is None
                        and any(marker in line for marker in (b'"task_started"', b'"task_complete"', b'"turn_aborted"')))
            if not meta and not boundary:
                continue
            try:
                record = json.loads(line)
            except (UnicodeDecodeError, ValueError):
                continue
            except Exception as error:  # noqa: BLE001 - each field reports its own parser failure
                if meta:
                    self.version_error = error
                if boundary:
                    self.turn_error = error
                continue
            if not isinstance(record, dict) or not isinstance(payload := record.get("payload"), dict):
                continue
            if meta and record.get("type") == "session_meta" and payload.get("id") == thread_id:
                if (found_version := nonempty_string(payload.get("cli_version"))) is not None:
                    self.version = found_version
            if not boundary or record.get("type") != "event_msg":
                continue
            kind = payload.get("type")
            if kind in ("turn_aborted", "task_started", "task_complete"):
                self.boundary_seen = True
                at = iso_seconds(record.get("timestamp"))
                self.latest = (("working" if kind == "task_started" else "done", at)
                               if kind != "turn_aborted" and at is not None else None)


Stamp = tuple[Path, int, int, int, int]  # path, target inode, ctime, mtime, size


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
        # Thread id -> the rollout as last parsed, and the fill it gave.
        self._context: dict[str, tuple[Stamp, int | None]] = {}
        # Rollout -> the shared version/boundary cursor and the target stamp it consumed.
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
        for cache in (self._paths, self._missed, self._context):
            for session_id in cache.keys() - session_ids:
                del cache[session_id]
        for path in self._rollouts.keys() - set(self._paths.values()):
            del self._rollouts[path]

    def context_percent(self, session_id: str) -> int | None:
        located = self._path_for(session_id)
        if located.path is None or located.after_cached_miss:
            return None
        return self._context_at(session_id, located.path)

    def _context_at(self, session_id: str, path: Path) -> int | None:
        try:
            st = path.stat()
        except OSError:
            return None
        stamp = (path, st.st_ino, st.st_ctime_ns, st.st_mtime_ns, st.st_size)
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
        if (path := self._path_for(thread_id).path) is None:
            return None
        try:
            stat = path.stat()
        except OSError:
            return None
        try:
            cursor = self._rollout(path, thread_id, stat)
        except OSError:
            return self._previous_version(path, stat)
        error, cursor.version_error = cursor.version_error, None
        if error is not None:
            raise error
        return cursor.version

    def _previous_version(self, path: Path, stat: os.stat_result) -> str | None:
        previous = self._rollouts.get(path)
        return previous.version if previous is not None and not previous.rewritten(stat.st_ino, stat.st_size) else None

    def turn_state(self, thread_id: str) -> tuple[State, float] | None:
        if (path := self._path_for(thread_id).path) is None:
            return None
        return self._turn_at(path, thread_id)

    def _turn_at(self, path: Path, thread_id: str) -> tuple[State, float] | None:
        try:
            cursor = self._rollout(path, thread_id, path.stat())
        except OSError:
            return None
        error, cursor.turn_error = cursor.turn_error, None
        if error is not None:
            raise error
        return cursor.latest

    def reading(self, thread_id: str) -> CodexReading:
        """One discovery with version/boundary sharing a pass; failures remain field-specific."""
        located = self._path_for(thread_id)
        path = located.path
        if path is None:
            return CodexReading(None, None, None)
        log = logging.getLogger("aitermd.service")
        try:
            context = None if located.after_cached_miss else self._context_at(thread_id, path)
        except Exception:  # context failure must not discard version or boundary evidence
            log.exception("reading the Codex context of thread %s failed", thread_id)
            context = None
        version = None
        try:
            stat = path.stat()
        except OSError:
            cursor = None
        else:
            try:
                cursor = self._rollout(path, thread_id, stat)
            except OSError:
                version, cursor = self._previous_version(path, stat), None
            except Exception:  # a failed shared read must not discard context
                log.exception("reading the Codex rollout of thread %s failed", thread_id)
                cursor = None
        if cursor is None:
            # Main attempted the boundary independently after a failed version read. Keep that
            # recovery opportunity, using the already-discovered path rather than rediscovering it.
            try:
                turn = self._turn_at(path, thread_id)
            except Exception:  # each field has the same isolation boundary as before consolidation
                log.exception("reading the Codex turn boundary of thread %s failed", thread_id)
                turn = None
            return CodexReading(context, version, turn)
        version_error, turn_error = cursor.version_error, cursor.turn_error
        cursor.version_error = cursor.turn_error = None
        if version_error is not None:
            log.error("reading the Codex version of thread %s failed", thread_id, exc_info=version_error)
        if turn_error is not None:
            log.error("reading the Codex turn boundary of thread %s failed", thread_id, exc_info=turn_error)
        return CodexReading(context, cursor.version if version_error is None else None,
                            cursor.latest if turn_error is None else None)

    def _rollout(self, path: Path, thread_id: str, st: os.stat_result) -> _RolloutCursor:
        stamp = (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_ctime_ns, st.st_size)
        old = self._rollouts.get(path)
        if old is not None and old.stamp == stamp:
            return old
        fresh = (old is None or old.rewritten(st.st_ino, st.st_size)
                 or (old.offset == st.st_size and old.stamp != stamp))
        cursor = _RolloutCursor(st.st_ino) if fresh or old is None else replace(old)
        with path.open("rb") as stream:
            actual = os.fstat(stream.fileno())
            if (actual.st_dev, actual.st_ino) != (st.st_dev, st.st_ino):
                raise OSError("rollout replaced before its read")
            start = max(0, st.st_size - READ_BYTES) if fresh else cursor.offset
            stream.seek(start)
            chunk = stream.read(st.st_size - start)
            short = len(chunk) != st.st_size - start
            if short and fresh and start:
                # An incomplete tail cannot establish the missing head's facts. Main read from
                # the beginning on first sight; recover that same complete-record prefix.
                cursor = _RolloutCursor(st.st_ino)
                start = 0
                stream.seek(0)
                chunk = stream.read(st.st_size)
                short = len(chunk) != st.st_size
            offset = start + len(chunk)
            clipped = b""
            if fresh and start:
                end = chunk.find(b"\n")
                clipped, chunk = (chunk, b"") if end < 0 else (chunk[:end + 1], chunk[end + 1:])
            *lines, cursor.partial = (cursor.partial + chunk).split(b"\n")
            cursor.consume(lines, thread_id)
            if fresh and start and (cursor.version is None or not cursor.boundary_seen):
                # The tail cannot erase an older answer. Read the head once for both missing
                # facts, including the complete line that straddles the window's edge.
                stream.seek(0)
                prefix = stream.read(start)
                if len(prefix) != start:
                    # The read is incomplete: use only the contiguous complete records from
                    # the start, with no complete-stamp cache hit until a later read catches up.
                    short, offset = True, len(prefix)
                    cursor = _RolloutCursor(st.st_ino)
                    clipped, chunk = b"", b""

                *head_lines, partial = (prefix + clipped).split(b"\n")
                need_version, need_turn = cursor.version is None, not cursor.boundary_seen
                head = _RolloutCursor(st.st_ino)
                head.consume(head_lines, thread_id, version=need_version, turn=need_turn)
                if need_version:
                    cursor.version = head.version
                    cursor.version_error = cursor.version_error or head.version_error
                if need_turn:
                    cursor.latest, cursor.boundary_seen = head.latest, head.boundary_seen
                    cursor.turn_error = cursor.turn_error or head.turn_error
                if not chunk:
                    cursor.partial = partial
        cursor.offset, cursor.stamp = offset, None if short else stamp
        # Main advances through the complete batch before parsing it. A decoder failure
        # reports once, then exposes only the facts parsed before it until more bytes arrive.
        self._rollouts[path] = cursor
        return cursor

    def _read_context(self, path: Path) -> int | None:
        for _, payload in self._token_counts(path):
            info = payload.get("info")
            last = info.get("last_token_usage") if isinstance(info, dict) else None
            total = finite_number(last.get("total_tokens")) if isinstance(last, dict) else None
            window = finite_number(info.get("model_context_window")) if isinstance(info, dict) else None
            if total is None or window is None or window <= 0:
                continue
            if (percent := clamped_percent(total / window * 100)) is not None:
                return percent
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

    def _path_for(self, session_id: str) -> _LocatedRollout:
        cached = self._paths.get(session_id)
        if cached is not None and cached.is_file():
            return _LocatedRollout(cached)
        # A thread whose rollout is nowhere is looked for across the whole tree once per
        # LIST_SECONDS; in between only under today's date, where a new thread's rollout appears.
        missed = self._missed.get(session_id)
        full = missed is None or self._clock() - missed >= LIST_SECONDS
        suffix = f"-{session_id}.jsonl"
        shared_tree = full and self._tree is not None
        matches = [path for path in (self._list_all() if full else self._list_today()) if path.name.endswith(suffix)]
        path = max(matches, key=lambda item: _mtime(item) or -1, default=None)
        recovered = False
        if path is None and shared_tree:
            # The shared tree is a snapshot. A new rollout may already exist under today's
            # date, where main's second lookup discovered it in the same tick.
            today = [candidate for candidate in self._list_today() if candidate.name.endswith(suffix)]
            path = max(today, key=lambda item: _mtime(item) or -1, default=None)
            recovered = path is not None
        if path is None:
            if full:
                self._missed[session_id] = self._clock()
            return _LocatedRollout(None)
        self._missed.pop(session_id, None)
        self._paths[session_id] = path
        return _LocatedRollout(path, recovered)

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
