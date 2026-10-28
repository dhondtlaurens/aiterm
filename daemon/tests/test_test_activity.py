import fcntl
import json
import os

from aitermd.models import RawSession
from aitermd.sessions import SessionRegistry
from aitermd.test_activity import TestActivityReader


def record(folder, run_id, root, state="queued", **fields):
    folder.mkdir(exist_ok=True)
    path = folder / f"{run_id}.json"
    path.write_text(json.dumps({"run_id": run_id, "root": str(root), "suite": "swift", "pid": 999999,
                                "state": state, "queued_at": 10, **fields}))
    return path


def hold(path):
    fd = os.open(path.with_suffix(".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def test_kernel_liveness_overrides_dead_parent_and_stale_state(tmp_path):
    root, folder = tmp_path / "worktree", tmp_path / "runs"
    path = record(folder, "1", root, "running", started_at=12)
    fd = hold(path)
    reader = TestActivityReader(folder, clock=lambda: 20)
    try:
        assert reader.read()[str(root)].state == "running"  # PID is deliberately absent.
    finally:
        os.close(fd)
    activity = reader.read()[str(root)]
    assert activity.state == "interrupted" and activity.exit_code is None
    record(folder, "1", root, "completed", finished_at=21, exit_code=7)
    activity = reader.read()[str(root)]
    assert activity.state == "completed" and activity.exit_code == 7


def test_queue_position_and_holder_include_only_live_tickets(tmp_path):
    folder = tmp_path / "runs"
    holder = record(folder, "1", tmp_path / "holder", "running", started_at=11)
    stale = record(folder, "2", tmp_path / "stale")
    queued = record(folder, "3", tmp_path / "own")
    fds = [hold(holder), hold(queued)]
    try:
        own = TestActivityReader(folder, clock=lambda: 20).read()[str(tmp_path / "own")]
        assert own.state == "queued" and own.queue_position == 1
        assert own.holder == f"swift in {tmp_path / 'holder'}"
        assert stale.exists()  # reader observes, never deletes another run's files.
    finally:
        for fd in fds:
            os.close(fd)


def test_new_active_run_beats_completed_and_results_expire(tmp_path):
    folder, root = tmp_path / "runs", tmp_path / "own"
    record(folder, "1", root, "completed", finished_at=10, exit_code=0)
    path = record(folder, "2", root, queued_at=11)
    fd = hold(path)
    try:
        assert TestActivityReader(folder, clock=lambda: 20).read()[str(root)].run_id == "2"
    finally:
        os.close(fd)
    assert TestActivityReader(folder, clock=lambda: 1000).read() == {}


def test_exact_worktree_projects_once_and_closed_sessions_are_forgotten(tmp_path):
    folder, root = tmp_path / "runs", tmp_path / "own"
    path = record(folder, "1", root)
    fd = hold(path)
    registry = SessionRegistry()
    rows = [RawSession(sid, "w", i, "claude", 10 + i, "", str(cwd), {"aiterm_task": "t"})
            for i, (sid, cwd) in enumerate([("main", root), ("extra", root), ("neighbor", root / "child")])]
    registry.apply_snapshot(rows)
    reader = TestActivityReader(folder, clock=lambda: 20)
    try:
        assert reader.apply(registry) == ["main"]
        assert registry.get("main").test_activity.run_id == "1"
        assert registry.get("extra").test_activity is None
        assert registry.get("neighbor").test_activity is None
        assert reader.apply(registry) == []
        registry.apply_snapshot(rows[1:])
        assert reader.apply(registry) == ["extra"]
    finally:
        os.close(fd)


def test_nested_cwd_uses_deepest_worktree_at_a_path_boundary(tmp_path):
    folder, root = tmp_path / "runs", tmp_path / "project"
    outer = record(folder, "1", root)
    inner = record(folder, "2", root / "task")
    fds = [hold(outer), hold(inner)]
    registry = SessionRegistry()
    registry.apply_snapshot([RawSession("nested", "w", 0, "claude", 12, "", str(root / "task" / "app")),
                             RawSession("neighbor", "w2", 0, "claude", 13, "", str(tmp_path / "project2"))])
    try:
        TestActivityReader(folder, clock=lambda: 20).apply(registry)
        assert registry.get("nested").test_activity.run_id == "2"
        assert registry.get("neighbor").test_activity is None
    finally:
        for fd in fds:
            os.close(fd)


def test_parent_checkout_run_cannot_hold_a_nested_distinct_worktree(tmp_path):
    folder, root = tmp_path / "runs", tmp_path / "project"
    root.mkdir()
    (root / ".git").mkdir()
    inner = root / ".worktrees" / "task"
    inner.mkdir(parents=True)
    (inner / ".git").write_text("gitdir: /some/git/worktrees/task\n")
    path = record(folder, "1", root, "running")
    fd = hold(path)
    registry = SessionRegistry()
    registry.apply_snapshot([RawSession("inner", "w", 0, "claude", 12, "", str(inner / "app"))])
    try:
        TestActivityReader(folder, clock=lambda: 20).apply(registry)
        assert registry.get("inner").test_activity is None
    finally:
        os.close(fd)


def test_observed_exit_survives_disk_retention_until_session_replaced(tmp_path):
    folder, root = tmp_path / "runs", tmp_path / "own"
    record(folder, "1", root, "completed", finished_at=15, exit_code=7)
    registry = SessionRegistry()
    row = RawSession("main", "w", 0, "claude", 12, "", str(root))
    registry.apply_snapshot([row])
    now = [20]
    reader = TestActivityReader(folder, clock=lambda: now[0])
    assert reader.apply(registry) == ["main"]
    now[0] = 1000
    assert reader.apply(registry) == []
    assert registry.get("main").test_activity.exit_code == 7
    row.job_pid = 13
    registry.apply_snapshot([row])
    reader.apply(registry)
    assert registry.get("main").test_activity is None


def test_conversation_replacement_drops_previous_exit_even_while_record_retained(tmp_path):
    folder, root = tmp_path / "runs", tmp_path / "own"
    record(folder, "1", root, "completed", finished_at=15, exit_code=0)
    registry = SessionRegistry()
    registry.apply_snapshot([RawSession("main", "w", 0, "claude", 12, "", str(root))])
    reader = TestActivityReader(folder, clock=lambda: 20)
    reader.apply(registry)
    registry.get("main").conversation_id = "new-conversation"
    reader.apply(registry)
    assert registry.get("main").test_activity is None


def test_observed_long_run_losing_its_lock_has_explicit_unavailable_exit(tmp_path):
    folder, root = tmp_path / "runs", tmp_path / "own"
    path = record(folder, "1", root, "running")
    fd = hold(path)
    registry = SessionRegistry()
    registry.apply_snapshot([RawSession("main", "w", 0, "claude", 12, "", str(root))])
    now = [20]
    reader = TestActivityReader(folder, clock=lambda: now[0])
    reader.apply(registry)
    os.close(fd)
    now[0] = 1000
    reader.apply(registry)
    assert registry.get("main").test_activity.state == "interrupted"
    assert registry.get("main").test_activity.exit_code is None
