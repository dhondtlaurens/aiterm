"""Observe exact-worktree test run records without guessing from machine-wide processes.

The record format is documented for any project's test runner in docs/configuration.md ("Show your
project's test runs"); this repository's scripts/test-queue.py is its reference writer."""
from __future__ import annotations

import fcntl
import json
import math
import os
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, cast

from .models import SessionInfo, TestActivity
from .sessions import SessionRegistry

RESULT_SECONDS = 300
# The documented record format. A record without a version is version 1; another version is skipped.
FORMAT_VERSION = 1


def _live(path: Path) -> bool:
    # A stable sidecar inode, inherited by the suite and its children. A dead supervisor PID is
    # insufficient evidence: the actual test process can still hold the execution slot.
    try:
        fd = os.open(path.with_suffix(".lock"), os.O_RDWR)
    except OSError:
        return False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False
    finally:
        os.close(fd)


def _number(value: Any) -> float:
    return float(value) if isinstance(value, (int, float)) and math.isfinite(value) else 0


def _worktree_boundary(cwd: Path | None) -> Path | None:
    """The nearest checkout, including a linked worktree's .git file rather than directory."""
    if cwd is not None:
        for directory in (cwd, *cwd.parents):
            if (directory / ".git").exists():
                return directory
    return None


@dataclass(frozen=True)
class ActivityRead:
    activities: dict[str, TestActivity]
    # The captured session, its resolved directory and its nearest checkout. All filesystem
    # observation happens in read(); apply() only matches these values against the live registry.
    locations: dict[str, tuple[SessionInfo, Path | None, Path | None]]


class TestActivityReader:
    __test__ = False

    def __init__(self, directory: Path = Path("/tmp/aiterm-test.lock.runs"),
                 clock: Callable[[], float] = time.time):
        self.directory, self.clock = directory, clock
        self._records: dict[Path, tuple[tuple[int, int, int, int, int], dict[str, Any]]] = {}
        self._results: dict[tuple[str, int | None, str | None], tuple[str, TestActivity]] = {}
        self._identity: dict[str, tuple[int | None, str | None]] = {}
        self._replaced_at: dict[str, float] = {}

    def read(self, sessions: Iterable[SessionInfo] = ()) -> ActivityRead:
        """Blocking observation only. The caller captures session values before leaving the loop."""
        records: list[tuple[dict[str, Any], bool]] = []
        now = self.clock()
        seen: set[Path] = set()
        for path in self.directory.glob("*.json"):
            seen.add(path)
            try:
                data = self._record(path)
                if data is None:
                    continue
                # Compute age before touching the lock, but an old locked run still counts.
                # Kernel lock ownership cannot be cached by a file stamp.
                stamp = _number(data.get("finished_at")) or _number(data.get("queued_at"))
                expired = now - stamp > RESULT_SECONDS
                live = _live(path)
                if expired and not live:
                    continue
                records.append((data, live))
            except (OSError, ValueError, TypeError):
                self._records.pop(path, None)
                continue
        self._records = {path: value for path, value in self._records.items() if path in seen}
        live_queued = sorted((data for data, live in records if live and data["state"] == "queued"),
                             key=lambda data: (_number(data.get("ticket")) or _number(data.get("queued_at")), data["run_id"]))
        positions = {data["run_id"]: i + 1 for i, data in enumerate(live_queued)}
        holder = next((f'{data["suite"]} in {data["root"]}' for data, live in records
                       if live and data["state"] == "running"), None)
        result: dict[str, TestActivity] = {}
        # Active work outranks any retained exit, then the newest run for that exact worktree wins.
        for data, live in sorted(records, key=lambda item: (item[1], _number(item[0].get("queued_at")), item[0]["run_id"])):
            state = data["state"] if live or data["state"] == "completed" else "interrupted"
            # A completed marker may briefly coexist with inherited children holding the lock.
            # It reports the runner's exit; only queued/running markers claim ongoing suite work.
            exit_code = data.get("exit_code")
            result[str(Path(data["root"]).resolve())] = TestActivity(
                run_id=data["run_id"], suite=data["suite"],
                state=cast(Literal["queued", "running", "completed", "interrupted"], state),
                queue_position=positions.get(data["run_id"]) if state == "queued" else None,
                holder=holder if state == "queued" else None,
                exit_code=exit_code if state == "completed" and type(exit_code) is int else None,
                finished_at=_number(data.get("finished_at")) or None)
        locations: dict[str, tuple[SessionInfo, Path | None, Path | None]] = {}
        locate = bool(result) or bool(self._results)
        for session in sessions:
            cwd = (Path(session.agent_cwd or session.cwd).resolve()
                   if locate and (session.cwd or session.agent_cwd) else None)
            locations[session.session_id] = (session, cwd, _worktree_boundary(cwd))
        return ActivityRead(result, locations)

    def _record(self, path: Path) -> dict[str, Any] | None:
        stat = path.stat()
        stamp = (stat.st_dev, stat.st_ino, stat.st_ctime_ns, stat.st_mtime_ns, stat.st_size)
        cached = self._records.get(path)
        if cached is not None and cached[0] == stamp:
            return cached[1]
        self._records.pop(path, None)
        with path.open() as stream:
            before = os.fstat(stream.fileno())
            data = json.load(stream)
            after = os.fstat(stream.fileno())
        if not isinstance(data, dict) or data.get("version", FORMAT_VERSION) != FORMAT_VERSION:
            return None
        if not all(isinstance(data.get(key), str) and data[key] for key in ("run_id", "root", "suite")):
            return None
        if not Path(data["root"]).is_absolute() or data.get("state") not in ("queued", "running", "completed"):
            return None
        actual = (after.st_dev, after.st_ino, after.st_ctime_ns, after.st_mtime_ns, after.st_size)
        if actual == (before.st_dev, before.st_ino, before.st_ctime_ns, before.st_mtime_ns, before.st_size):
            self._records[path] = (actual, data)
        return data

    def apply(self, registry: SessionRegistry, reading: ActivityRead) -> list[str]:
        """Apply a still-current snapshot on the loop, retaining worktree ownership as one pass."""
        readings, assigned, changed = reading.activities, set(), []
        sessions = registry.all()
        # Assignment is one ordered pass. If a hook changed an input during the read, retry the
        # whole view next tick instead of moving a skipped main worker's activity to a sibling.
        if len(sessions) != len(reading.locations):
            return []
        for session in sessions:
            if (location := reading.locations.get(session.session_id)) is None:
                return []
            captured = location[0]
            if ((session.agent, session.job_pid, session.conversation_id, session.agent_cwd, session.cwd) !=
                    (captured.agent, captured.job_pid, captured.conversation_id, captured.agent_cwd, captured.cwd)):
                return []
        live_keys = {(s.session_id, s.job_pid, s.conversation_id) for s in sessions}
        self._results = {key: value for key, value in self._results.items() if key in live_keys}
        live_ids = {s.session_id for s in sessions}
        self._identity = {sid: value for sid, value in self._identity.items() if sid in live_ids}
        self._replaced_at = {sid: value for sid, value in self._replaced_at.items() if sid in live_ids}
        # Worktree activity belongs to the task, not each sibling tab. Prefer its main worker and
        # attach once; closed sessions disappear from the registry and leave nothing remembered here.
        for session in sorted(sessions, key=lambda s: (s.tab_key is not None, s.tab_index, s.session_id)):
            _, cwd, boundary = reading.locations[session.session_id]
            # A CLI commonly chdirs into app/ or daemon/. Match a real path boundary and the
            # deepest recorded worktree, so a parent project or a similarly named neighbor cannot win.
            roots = [root for root in readings if cwd is not None and cwd.is_relative_to(Path(root))
                     and (boundary is None or Path(root).is_relative_to(boundary))]
            root = max(roots, key=lambda value: len(Path(value).parts), default="")
            identity = (session.job_pid, session.conversation_id)
            old_identity = self._identity.get(session.session_id)
            if old_identity is not None and old_identity != identity:
                self._replaced_at[session.session_id] = self.clock()
            self._identity[session.session_id] = identity
            key = (session.session_id, *identity)
            if not root and cwd is not None and key in self._results:
                old_root, old_activity = self._results[key]
                if cwd.is_relative_to(Path(old_root)) and (boundary is None or Path(old_root).is_relative_to(boundary)):
                    root = old_root
                    # A long-running command can crash after its on-disk stale marker has aged
                    # out. Having observed it live, retain explicit unavailable-exit evidence.
                    readings[root] = (TestActivity(run_id=old_activity.run_id, suite=old_activity.suite,
                                                   state="interrupted")
                                      if old_activity.state in ("queued", "running") else old_activity)
            activity = readings.get(root) if session.agent != "shell" and root not in assigned else None
            if activity and activity.state in ("completed", "interrupted") and session.session_id in self._replaced_at:
                if (activity.finished_at or 0) < self._replaced_at[session.session_id]:
                    activity = None
            if activity:
                assigned.add(root)
                self._results[key] = (root, activity)
            if session.test_activity != activity:
                session.test_activity = activity
                changed.append(session.session_id)
        return changed
