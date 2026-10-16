"""The operator's MCP server (Operators spec §5, §6): the run tokens that open it, the tools it
serves, and the `/operator` route that forwards every tool call to the app."""
from __future__ import annotations

import hmac
import logging
import os
import re
import stat
from pathlib import Path

log = logging.getLogger(__name__)
# Where the app keeps each run's folder, named by its id: brief.md, mcp.json and `token` (spec §5.1).
RUNS_ROOT = Path.home() / "Library" / "Application Support" / "AiTerm" / "operators" / "runs"
# A run's token: the app's 32 random bytes, as hex.
_TOKEN = re.compile(r"[0-9a-fA-F]{64}")


def well_formed(token: str) -> bool:
    return _TOKEN.fullmatch(token) is not None


def _run_folder_name(run_id: str) -> bool:
    """Whether `run_id` names one folder inside the runs root, and nothing above or beside it."""
    return bool(run_id) and run_id not in (".", "..") and os.sep not in run_id and "/" not in run_id


class OperatorTokens:
    """Each run's token, the only thing that opens /operator, and the run it names (spec §5.2). The
    app writes each run's `token` file (mode 0600) and registers it; the daemon loads every one at
    start and reads the folder again when a well-formed token it does not know arrives, so a daemon
    restart costs the operator nothing (spec §11). It stops a worker from acting as an operator by
    accident or because a ticket told it to; it is no wall against a process of the same user, which
    can read the run folder. With no runs root, tokens live in memory only."""

    def __init__(self, runs_root: Path | None = None) -> None:
        self._root = runs_root
        self._runs: dict[str, str] = {}    # token -> run id
        self._tokens: dict[str, str] = {}  # run id -> token
        self._load()

    def register(self, run_id: str, token: str) -> None:
        """Opens /operator to `token` for `run_id`, in place of any token the run had. In memory:
        the file is the app's to write."""
        if not well_formed(token):
            raise ValueError("a run token is 64 hex characters")
        if (owner := self._runs.get(token)) is not None and owner != run_id:
            raise ValueError("that token belongs to another run")
        self._forget(run_id)
        self._runs[token], self._tokens[run_id] = run_id, token

    def revoke(self, run_id: str) -> None:
        """Closes /operator to the run for good: its token leaves memory, and its file goes, so no
        later read of the folder brings it back. The run folder itself is the app's."""
        self._forget(run_id)
        if self._root is not None and _run_folder_name(run_id):
            try:
                (self._root / run_id / "token").unlink(missing_ok=True)
            except OSError:
                log.exception("could not delete the token file of run %s", run_id)

    def _forget(self, run_id: str) -> None:
        if (token := self._tokens.pop(run_id, None)) is not None:
            self._runs.pop(token, None)

    def run_for(self, token: str) -> str | None:
        """The run `token` opens, if any. An unknown well-formed token reads the folder once more
        first: the app may have written a run's file since this daemon looked."""
        if (run := self._known(token)) is not None or not well_formed(token):
            return run
        self._load()
        return self._known(token)

    def _known(self, token: str) -> str | None:
        """Compared in constant time, as bytes: a str compare_digest raises on anything but ASCII,
        and a header can carry anything."""
        offered = token.encode("utf-8", "replace")
        return next((run for known, run in self._runs.items() if hmac.compare_digest(known.encode(), offered)), None)

    def _load(self) -> None:
        """Adopts every run folder's token that memory does not contradict: memory wins, as it holds
        what the app registered last. AiTerm's own folder, a few small files: read on the loop."""
        if self._root is None:
            return
        try:
            folders = [path for path in self._root.iterdir() if path.is_dir()]
        except OSError:
            return  # no runs yet
        for folder in folders:
            path = folder / "token"
            try:
                if not path.is_file():
                    continue
                if stat.S_IMODE(path.stat().st_mode) & 0o077:
                    log.warning("skipped the token of run %s: others can read %s", folder.name, path)
                    continue
                token = path.read_text(encoding="utf-8").strip()
            except (OSError, ValueError):
                log.warning("skipped the token of run %s: it cannot be read", folder.name)
                continue
            if not well_formed(token):
                log.warning("skipped the token of run %s: it is malformed", folder.name)
                continue
            if folder.name not in self._tokens and token not in self._runs:
                self._runs[token], self._tokens[folder.name] = folder.name, token
