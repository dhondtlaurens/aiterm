from __future__ import annotations
import contextlib
import json
import math
import time
from collections.abc import Callable, Iterator
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .usage import finite_number

# How often the whole sessions tree is listed again. In between, only the rollouts last seen to be
# the newest, the tracked threads' own and today's directory are looked at: a new session writes
# under today's date, and a resumed one appends to a rollout already known.
LIST_SECONDS = 30.0
RECENT_KEPT = 8

# What every `token_count` record contains, so a line without it can be skipped unparsed.
_TOKEN_COUNT = b'"token_count"'

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
        # The rollouts `rate_limits()` last consulted, by (path, mtime), and what they said: the
        # tick asks every two seconds, and a file nobody has written to has nothing new to say.
        self._limits_seen: tuple[tuple[Path, int], ...] | None = None
        self._limits_answer: tuple[dict[str, Any], int | None] | None = None

    def retain(self, session_ids: set[str]) -> None:
        """Drops what is cached for threads no tab is running any more."""
        for cache in (self._paths, self._missed, self._context):
            for session_id in cache.keys() - session_ids:
                del cache[session_id]

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
        percent = self._read_context(path)
        self._context[session_id] = (stamp, percent)
        return percent

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
        self._limits_seen, self._limits_answer = newest, self._read_rate_limits([path for path, _ in newest])
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
        try:
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
        except OSError:
            return


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
