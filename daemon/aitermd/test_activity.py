"""Observe test.sh's exact-worktree run records without guessing from machine-wide processes."""
from __future__ import annotations

import fcntl
import json
import math
import os
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, Literal, cast

from .models import TestActivity
from .sessions import SessionRegistry

RESULT_SECONDS = 300


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


class TestActivityReader:
    __test__ = False

    def __init__(self, directory: Path = Path("/tmp/aiterm-test.lock.runs"),
                 clock: Callable[[], float] = time.time):
        self.directory, self.clock = directory, clock
        self._results: dict[tuple[str, int | None, str | None], tuple[str, TestActivity]] = {}
        self._identity: dict[str, tuple[int | None, str | None]] = {}
        self._replaced_at: dict[str, float] = {}

    def read(self) -> dict[str, TestActivity]:
        records: list[tuple[dict[str, Any], bool]] = []
        now = self.clock()
        for path in self.directory.glob("*.json"):
            try:
                data = json.loads(path.read_text())
                if not isinstance(data, dict):
                    continue
                if not all(isinstance(data.get(key), str) and data[key] for key in ("run_id", "root", "suite")):
                    continue
                if not Path(data["root"]).is_absolute() or data.get("state") not in ("queued", "running", "completed"):
                    continue
                live = _live(path)
                # An unlocked queued/running record is interrupted, never assumed successful. Old
                # results are bounded in the UI as well as by the runner's disk retention policy.
                stamp = _number(data.get("finished_at")) or _number(data.get("queued_at"))
                if not live and now - stamp > RESULT_SECONDS:
                    continue
                records.append((data, live))
            except (OSError, ValueError, TypeError):
                continue
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
        return result

    def apply(self, registry: SessionRegistry) -> list[str]:
        readings, assigned, changed = self.read(), set(), []
        live_keys = {(s.session_id, s.job_pid, s.conversation_id) for s in registry.all()}
        self._results = {key: value for key, value in self._results.items() if key in live_keys}
        live_ids = {s.session_id for s in registry.all()}
        self._identity = {sid: value for sid, value in self._identity.items() if sid in live_ids}
        self._replaced_at = {sid: value for sid, value in self._replaced_at.items() if sid in live_ids}
        # Worktree activity belongs to the task, not each sibling tab. Prefer its main worker and
        # attach once; closed sessions disappear from the registry and leave nothing remembered here.
        for session in sorted(registry.all(), key=lambda s: (s.tab_key is not None, s.tab_index, s.session_id)):
            cwd = Path(session.agent_cwd or session.cwd).resolve() if session.cwd or session.agent_cwd else None
            boundary = _worktree_boundary(cwd)
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
