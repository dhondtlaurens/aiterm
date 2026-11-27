"""Commands too long for the line discipline of a newly opened terminal."""
from __future__ import annotations

import hashlib
import re
import shlex
import tempfile
from pathlib import Path

from .models import support_dir


class StagedCommands:
    def __init__(self) -> None:
        self.folder = support_dir() / "tab-commands"
        self.pending: dict[str, Path] = {}
        self.swept = False

    @staticmethod
    def _prefix(session: str) -> str:
        return hashlib.sha256(session.encode()).hexdigest() + "-"

    def line(self, session: str, command: str) -> str:
        # Match AgentCommand.inlineLimit, including control characters a terminal treats as keys.
        if len(command.encode()) <= 1000 and all(c == "\n" or ord(c) >= 32 and c != "\x7f" for c in command):
            return command
        self.folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=self.folder, prefix=self._prefix(session), delete=False) as f:
            path = self.pending[session] = Path(f.name)
            quoted = shlex.quote(str(path))
            # The shell has opened this file when rm runs. Source it so "exit" closes that shell.
            f.write(("/bin/rm -f " + quoted + "\n" + command + "\n").encode())
        return ". " + quoted

    def forget(self, session: str) -> None:
        if path := self.pending.pop(session, None):
            path.unlink(missing_ok=True)

    def sweep(self, live: set[str]) -> None:
        """The first connected snapshot can reclaim files whose owning tab went away while offline."""
        if not self.swept and self.folder.is_dir():
            owners = {self._prefix(sid): sid for sid in live}
            for path in self.folder.iterdir():
                if not re.fullmatch(r"[0-9a-f]{64}-[a-z0-9_]+", path.name) or not path.is_file():
                    continue
                owner = owners.get(path.name[:65])
                if owner is None:
                    path.unlink(missing_ok=True)
                else:
                    self.pending[owner] = path
        self.swept = True
