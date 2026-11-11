"""What one steady tick costs, as counts rather than timings.

Each number here is what the daemon did when the budget was written (2026-11-10), kept as a ceiling: a
change that lowers one lowers its ceiling with it, and none may raise one. The workload is a
workspace at rest, read a second time with nothing changed: the tick the daemon runs every two
seconds for as long as it is up.
"""
import json
import sys
import threading
from datetime import datetime

import pytest

from aitermd import codex_sessions, process_agents
from aitermd.models import Frame, RawSession
from aitermd.hook_events import HookEvent
from aitermd.test_activity import TestActivityReader
from tests.test_claude_background import launch, write
from tests.test_codex_sessions import token_count, write_rollout


@pytest.fixture(autouse=True)
def scan_date(monkeypatch):
    """Keep this workspace's local and UTC scan dates independent of the wall clock."""
    class ScanDate(datetime):
        @classmethod
        def now(cls, tz=None):
            return cls(2026, 11, 11, 0, 30, tzinfo=tz)

    monkeypatch.setattr(codex_sessions, "datetime", ScanDate)


class Audit:
    """File opens, directory listings and process spawns, counted while `watching` a folder. An
    audit hook cannot be removed, so one is installed for the process and counts only on demand; it
    sees the worker threads the tick reads on, which patching one module's `open` would not."""

    def __init__(self):
        self._lock = threading.Lock()
        self._root: str | None = None
        self.opens: list[str] = []
        self.listings: list[str] = []
        self.spawns: list[str] = []
        sys.addaudithook(self._hook)

    def _hook(self, event: str, args: tuple) -> None:
        root = self._root
        if root is None:
            return
        if event == "subprocess.Popen":
            with self._lock:
                self.spawns.append(str(args[0]))
        elif event in ("open", "os.scandir", "os.listdir") and args and isinstance(args[0], (str, bytes)):
            path = args[0].decode() if isinstance(args[0], bytes) else args[0]
            if path.startswith(root):
                with self._lock:
                    (self.opens if event == "open" else self.listings).append(path[len(root):])

    def watch(self, root) -> None:
        with self._lock:
            self.opens, self.listings, self.spawns = [], [], []
        self._root = str(root)

    def stop(self) -> None:
        self._root = None


AUDIT = Audit()


async def workspace_at_rest(make_service, tmp_path, *, claude: int, codex: int, shells: int, records: int):
    """A service over `claude` working Claude tabs, each with a session file and a transcript holding
    one background launch, `codex` Codex tabs, each bound to a rollout that reports its context,
    `shells` plain tabs, and `records` finished test runs in the queue's folder; ticked until
    nothing is left to read for the first time."""
    svc = make_service()
    runs = tmp_path / "runs"
    runs.mkdir()
    svc.test_activity = TestActivityReader(directory=runs, clock=svc.test_activity.clock)
    for index in range(records):
        (runs / f"run-{index}.json").write_text(json.dumps({
            "run_id": f"run-{index}", "root": f"/checkout-{index}", "suite": "all", "state": "completed",
            "queued_at": 900, "finished_at": 990, "exit_code": 0}))
    svc.claude_files.root.mkdir(parents=True)
    pid = 4000
    for index in range(claude):
        pid += 1
        _, sid = await svc.iterm.create_window("/wt", f"claude-{index}", {"aiterm_task": f"c{index}"}, Frame(0, 0, 10, 10))
        await svc.iterm.user_runs(sid, "claude", job_pid=pid)
        (svc.claude_files.root / f"{pid}.json").write_text(json.dumps(
            {"pid": pid, "sessionId": f"conversation-{index}", "cwd": "/wt", "status": "busy", "updatedAt": 1}))
        await svc.tick()
        transcript = tmp_path / f"claude-{index}.jsonl"
        write(transcript, launch())
        svc.status.apply_metadata(sid, conversation=f"conversation-{index}", transcript=str(transcript), context=40)
        svc.status.apply_event(sid, HookEvent("claude", "sessionStart", None, f"conversation-{index}", "/wt"))
        svc.status.apply_event(sid, HookEvent("claude", "working", None, f"conversation-{index}", "/wt"))
    for index in range(codex):
        pid += 1
        _, sid = await svc.iterm.create_window("/wt", f"codex-{index}", {"aiterm_task": f"x{index}"}, Frame(0, 0, 10, 10))
        await svc.iterm.user_runs(sid, "codex", job_pid=pid, title="Codex")
        await svc.tick()
        await svc.hook_router.handle_hook("/hook/codex", {
            "hook_event_name": "SessionStart", "session_id": f"thread-{index}", "cwd": "/wt", "model": "gpt-6",
            "_aiterm_iterm_session_id": sid})
        write_rollout(svc.codex_files.root, f"thread-{index}", [
            {"type": "session_meta", "payload": {"id": f"thread-{index}", "session_id": f"thread-{index}"}},
            token_count(66_020, 258_400)])
    for index in range(shells):
        await svc.iterm.create_window("/wt", f"shell-{index}", {"aiterm_task": f"s{index}"}, Frame(0, 0, 10, 10))
    for _ in range(3):
        await svc.tick()
    return svc


async def counted_tick(svc, monkeypatch, root):
    """One more tick: how often it sorted the registry, and what it opened, listed and spawned under `root`."""
    sorts = 0
    read = svc.registry.all

    def counted():
        nonlocal sorts
        sorts += 1
        return read()

    monkeypatch.setattr(svc.registry, "all", counted)
    AUDIT.watch(root)
    try:
        await svc.tick()
    finally:
        AUDIT.stop()
        monkeypatch.setattr(svc.registry, "all", read)
    return sorts, len(AUDIT.opens), len(AUDIT.listings), len(AUDIT.spawns)


# claude, codex, shells, records -> registry sorts, file opens, directory listings, process spawns.
@pytest.mark.parametrize(("shape", "ceiling"), [
    ((0, 0, 6, 0), (6, 0, 2, 0)),
    # One more registry sort for each Codex tab that reports its context.
    ((2, 2, 2, 0), (8, 0, 2, 0)),
    ((6, 6, 6, 0), (12, 0, 2, 0)),
    # Two opens for each finished test run still in the queue's folder: its record, and its lock.
    ((2, 2, 2, 20), (8, 40, 2, 0)),
])
async def test_a_steady_tick_stays_within_its_work_budget(make_service, tmp_path, monkeypatch, shape, ceiling):
    claude, codex, shells, records = shape
    svc = await workspace_at_rest(make_service, tmp_path, claude=claude, codex=codex, shells=shells, records=records)
    assert len(svc.registry.all()) == claude + codex + shells
    counts = await counted_tick(svc, monkeypatch, tmp_path)
    names = ("registry sorts", "file opens", "directory listings", "process spawns")
    over = [f"{name}: {count} > {limit}" for name, count, limit in zip(names, counts, ceiling, strict=True) if count > limit]
    assert not over, f"a steady tick over {shape} did {counts}; over budget: {', '.join(over)}"
    # A ceiling far above what the tick does guards nothing: lower it with the change that earned it.
    assert counts == ceiling, f"a steady tick over {shape} did {counts}, under its ceiling {ceiling}: lower the ceiling"


def test_every_snapshot_with_a_foreground_runner_reads_the_process_table(monkeypatch):
    """A tab running anything that is no agent and no login shell (a dev server, vim, ssh) costs one
    process-table read for every snapshot, for as long as it runs: five snapshots, five reads."""
    reads = 0

    def read():
        nonlocal reads
        reads += 1
        return []

    monkeypatch.setattr(process_agents, "read_processes", read)
    sessions = [RawSession("s1", "w1", 0, "npm run dev", 500, "dev", "/wt", {})]
    for _ in range(5):
        process_agents.resolve_agents(sessions)
    assert reads == 5
