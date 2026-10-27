"""When the usage limit that ended a Claude turn resets, as the session's own transcript records it (SessionInfo.stopped_on).
Blocking file I/O: the service runs it on a worker thread."""
from __future__ import annotations

import json
import os
from collections.abc import Iterator
from typing import Any

from .claude_subagents import TAIL_BYTES

# The StopFailure errors that are a usage or rate limit, which resets: Claude Code may carry on by itself then.
LIMIT_ERRORS = frozenset({"rate_limit"})
# How long after its StopFailure a limit's reset is looked for in the transcript. Claude Code writes in batches, so its
# record of the limit can reach the file a moment after the hook; one not there by then is not coming.
RESET_READ_SECONDS = 30.0


def limit_resets_at(path: str) -> int | None:
    """When the limit that ended the transcript's last turn resets, in epoch seconds: its last message, the API error
    Claude Code wrote for the limit, gives it as `apiErrorParams.rate_limit_info.resetsAt`. None when that message is
    no such error -- not written yet, or a prompt since, Claude Code's own once the limit reset among them -- when the
    error names no reset, and when the transcript cannot be read."""
    last = next((r for r in _records_newest_first(path) if r.get("type") in ("user", "assistant")), None)
    if last is None or last.get("type") != "assistant" or last.get("isApiErrorMessage") is not True:
        return None
    return _resets_at(last.get("apiErrorParams"))


def _resets_at(params: Any) -> int | None:
    info = params.get("rate_limit_info") if isinstance(params, dict) else None
    resets_at = info.get("resetsAt") if isinstance(info, dict) else None
    # A bool is an int to Python, and no time.
    return resets_at if isinstance(resets_at, int) and not isinstance(resets_at, bool) and resets_at > 0 else None


def _records_newest_first(path: str) -> Iterator[dict[str, Any]]:
    """The complete records at the end of the transcript, newest first: none of a line still being written, or of one
    the tail begins inside of, nor one that does not parse. Nothing when the file cannot be read."""
    try:
        with open(path, "rb") as f:
            start = max(0, os.fstat(f.fileno()).st_size - TAIL_BYTES)
            f.seek(start)
            lines = f.read(TAIL_BYTES).split(b"\n")[:-1]
    except OSError:
        return
    for line in reversed(lines[1:] if start else lines):
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict):
            yield record
