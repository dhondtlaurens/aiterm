"""Incremental byte cursors for append-only JSONL files; callers own record semantics."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


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
