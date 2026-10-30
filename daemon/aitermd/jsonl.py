"""Incremental byte cursors and reverse records for JSONL files; callers own record semantics."""
from __future__ import annotations

import json
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(slots=True)
class JsonlCursor:
    inode: int
    offset: int = 0
    partial: bytes = b""

    def rewritten(self, inode: int, size: int) -> bool:
        return self.inode != inode or size < self.offset

    def read_lines(self, path: Path, size: int) -> list[bytes]:
        """Read to the stamped size, retaining an incomplete final line. OSError leaves the
        cursor unchanged, and a short read advances only by the bytes actually read."""
        if size <= self.offset:
            return []
        with path.open("rb") as stream:
            stream.seek(self.offset)
            chunk = stream.read(size - self.offset)
        self.offset += len(chunk)
        *lines, self.partial = (self.partial + chunk).split(b"\n")
        return lines


def records_newest_first(path: Path, limit: int | None, *, containing: bytes = b"",
                         discard_boundary: bool = False) -> Iterator[Any]:
    """Parsed records, newest first; invalid JSON yields None and I/O errors reach the caller.

    With a byte limit, read only that tail and exclude its clipped first line. An unfinished
    final line yields a None barrier before earlier complete records. `discard_boundary` also
    excludes the first line when the whole file exactly fills the limit (Claude subagent tails).
    Without a limit, scan the whole file in filtered blocks, including an unterminated last line.
    """
    if limit is None:
        lines = _lines_reverse(path, containing)
    else:
        with path.open("rb") as stream:
            stream.seek(0, 2)
            start = max(0, stream.tell() - limit)
            stream.seek(start)
            tail = stream.read(limit)
        if not tail.endswith(b"\n"):
            yield None
        complete = tail.split(b"\n")[:-1]
        if start or (discard_boundary and len(tail) >= limit):
            complete = complete[1:]
        lines = reversed(complete)
    for line in lines:
        if containing not in line:
            continue
        try:
            yield json.loads(line)
        except (UnicodeDecodeError, ValueError):
            yield None


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
