"""Whether a stopped Claude parent carried on, and when its usage limit resets, from its own transcript.
Blocking file I/O: the service runs it on a worker thread."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .claude_subagents import TAIL_BYTES
from .jsonl import records_newest_first
from .text import iso_seconds

# The StopFailure errors that are a usage or rate limit, which resets: Claude Code may carry on by itself then.
LIMIT_ERRORS = frozenset({"rate_limit"})
# How long after its StopFailure a limit's reset is looked for in the transcript. Claude Code writes in batches, so its
# record of the limit can reach the file a moment after the hook; one not there by then is not coming.
RESET_READ_SECONDS = 30.0


@dataclass(frozen=True)
class StopReading:
    resets_at: int | None = None
    progress_at: float | None = None


class StopTranscripts:
    """Bounded parent-transcript reads for stopped workers. An unchanged file is parsed once;
    children and tool results cannot impersonate a new parent prompt or successful response."""
    def __init__(self) -> None:
        self._cache: dict[str, tuple[tuple[int, int, int, int], StopReading]] = {}

    def read_all(self, paths: set[str]) -> dict[str, StopReading]:
        self._cache = {path: cached for path, cached in self._cache.items() if path in paths}
        readings: dict[str, StopReading] = {}
        for path in paths:
            try:
                stat = Path(path).stat()
                stamp = (stat.st_ino, stat.st_mtime_ns, stat.st_ctime_ns, stat.st_size)
                cached = self._cache.get(path)
                if cached is not None and cached[0] == stamp:
                    readings[path] = cached[1]
                    continue
                reading = self._read(path)
            except OSError:
                continue
            self._cache[path] = (stamp, reading)
            readings[path] = reading
        return readings

    @staticmethod
    def _read(path: str) -> StopReading:
        for record in records_newest_first(Path(path), TAIL_BYTES):
            if not isinstance(record, dict) or record.get("isSidechain") is True:
                continue
            kind = record.get("type")
            if kind not in ("user", "assistant"):
                continue
            if record.get("isApiErrorMessage") is True:
                return StopReading(resets_at=_resets_at(record.get("apiErrorParams")))
            if kind == "user":
                message = record.get("message")
                content = message.get("content") if isinstance(message, dict) else None
                text = content if isinstance(content, str) else "\n".join(
                    part["text"] for part in content if isinstance(part, dict) and isinstance(part.get("text"), str)
                ) if isinstance(content, list) else ""
                origin = record.get("origin")
                continuation = isinstance(origin, dict) and origin.get("kind") == "auto-continuation"
                # Background handbacks and local slash commands are user-role records too. They
                # can arrive while the parent is still stopped, without starting a model turn.
                if (not text.strip() or record.get("isMeta") is True and not continuation
                        or any(marker in text for marker in ("<task-notification>", "<local-command-", "<command-name>"))
                        or isinstance(content, list) and any(isinstance(part, dict) and part.get("type") == "tool_result"
                                                             for part in content)):
                    continue
            return StopReading(progress_at=iso_seconds(record.get("timestamp")))
        return StopReading()


def _resets_at(params: Any) -> int | None:
    info = params.get("rate_limit_info") if isinstance(params, dict) else None
    resets_at = info.get("resetsAt") if isinstance(info, dict) else None
    # A bool is an int to Python, and no time.
    return resets_at if isinstance(resets_at, int) and not isinstance(resets_at, bool) and resets_at > 0 else None
