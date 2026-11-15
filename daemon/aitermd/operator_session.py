"""One session authority, outside repository worktrees. The app alone writes its files."""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import stat
import time
from collections.abc import Callable
from pathlib import Path
from uuid import UUID

from .operator_token import well_formed


class OperatorSessionTokens:
    def __init__(self, root: Path | None = None, clock: Callable[[], float] = time.monotonic):
        self.root, self.clock = root, clock
        self._current: tuple[str, int, str] | None = None
        self._revoked: set[tuple[str, int]] = set()
        self._retiring: tuple[str, int] | None = None
        self._loaded_at = float("-inf")
        self._load()

    def register(self, session_id: str, generation: int, token: str) -> None:
        session_id = str(UUID(session_id)).upper()
        if type(generation) is not int or generation < 1 or not well_formed(token):
            raise ValueError("an Operator authority needs a positive generation and a 64 hex token")
        if (old := self._current) is not None and old[0] == session_id:
            if generation < old[1] or (generation == old[1] and token != old[2]):
                raise ValueError("this Operator generation is already registered with another token")
        if (session_id, generation) in self._revoked:
            raise ValueError("this Operator generation was revoked")
        self._current = (session_id, generation, token)
        self._retiring = None

    def owner_for(self, token: str) -> tuple[str, int] | None:
        if not well_formed(token):
            return None
        if self._current is None or not hmac.compare_digest(token.encode(), self._current[2].encode()):
            self._load()
        if (current := self._current) is not None and hmac.compare_digest(token.encode(), current[2].encode()):
            return current[0], current[1]
        return None

    def owns(self, session_id: str, generation: int) -> bool:
        return self._current is not None and self._current[:2] == (session_id, generation)

    def revoke(self, session_id: str, generation: int | None = None) -> None:
        session_id = str(UUID(session_id)).upper()
        current = self._current
        if current is not None:
            if current[0] != session_id or (generation is not None and generation != current[1]):
                return
            self._retiring = current[:2]
            self._revoked.add(current[:2])
            self._current = None
        elif self._retiring is None or self._retiring[0] != session_id or (generation is not None and generation != self._retiring[1]):
            return
        if self.root is not None:
            # A failed deletion remains owed on retry, including when memory has already revoked it.
            (self.root / "token").unlink(missing_ok=True)
        self._retiring = None

    @staticmethod
    def _private(path: Path, directory: bool = False) -> bool:
        info = path.lstat()
        return info.st_uid == os.getuid() and not stat.S_IMODE(info.st_mode) & 0o077 and (
            stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))

    def _load(self) -> None:
        if self.root is None or self.clock() - self._loaded_at < 1:
            return
        self._loaded_at = self.clock()
        try:
            if not self._private(self.root, directory=True):
                return
            token_path, manifest_path = self.root / "token", self.root / "session.json"
            if not self._private(token_path) or not self._private(manifest_path):
                return
            token = token_path.read_text().strip()
            manifest = json.loads(manifest_path.read_text())
            if not isinstance(manifest, dict) or manifest.get("tokenHash") != hashlib.sha256(token.encode()).hexdigest():
                return
            session_id, generation = manifest.get("id"), manifest.get("generation")
            if not isinstance(session_id, str) or type(generation) is not int:
                return
            self.register(session_id, generation, token)
        except (OSError, ValueError, TypeError):
            return  # Missing, mismatched, unreadable and retired files confer no authority.
