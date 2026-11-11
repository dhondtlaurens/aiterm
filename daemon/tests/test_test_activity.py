import fcntl
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from aitermd.models import RawSession
from aitermd.sessions import SessionRegistry
from aitermd.test_activity import TestActivityReader


def apply(reader, registry):
    return reader.apply(registry, reader.read(registry.all()))


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
        assert reader.read().activities[str(root)].state == "running"  # PID is deliberately absent.
    finally:
        os.close(fd)
    activity = reader.read().activities[str(root)]
    assert activity.state == "interrupted" and activity.exit_code is None
    record(folder, "1", root, "completed", finished_at=21, exit_code=7)
    activity = reader.read().activities[str(root)]
    assert activity.state == "completed" and activity.exit_code == 7


def test_queue_position_and_holder_include_only_live_tickets(tmp_path):
    folder = tmp_path / "runs"
    holder = record(folder, "1", tmp_path / "holder", "running", started_at=11)
    stale = record(folder, "2", tmp_path / "stale")
    queued = record(folder, "3", tmp_path / "own")
    fds = [hold(holder), hold(queued)]
    try:
        own = TestActivityReader(folder, clock=lambda: 20).read().activities[str(tmp_path / "own")]
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
        assert TestActivityReader(folder, clock=lambda: 20).read().activities[str(root)].run_id == "2"
    finally:
        os.close(fd)
    assert TestActivityReader(folder, clock=lambda: 1000).read().activities == {}


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
        assert apply(reader, registry) == ["main"]
        assert registry.get("main").test_activity.run_id == "1"
        assert registry.get("extra").test_activity is None
        assert registry.get("neighbor").test_activity is None
        assert apply(reader, registry) == []
        registry.apply_snapshot(rows[1:])
        assert apply(reader, registry) == ["extra"]
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
        apply(TestActivityReader(folder, clock=lambda: 20), registry)
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
        apply(TestActivityReader(folder, clock=lambda: 20), registry)
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
    assert apply(reader, registry) == ["main"]
    now[0] = 1000
    assert apply(reader, registry) == []
    assert registry.get("main").test_activity.exit_code == 7
    row.job_pid = 13
    registry.apply_snapshot([row])
    apply(reader, registry)
    assert registry.get("main").test_activity is None


def test_conversation_replacement_drops_previous_exit_even_while_record_retained(tmp_path):
    folder, root = tmp_path / "runs", tmp_path / "own"
    record(folder, "1", root, "completed", finished_at=15, exit_code=0)
    registry = SessionRegistry()
    registry.apply_snapshot([RawSession("main", "w", 0, "claude", 12, "", str(root))])
    reader = TestActivityReader(folder, clock=lambda: 20)
    apply(reader, registry)
    registry.get("main").conversation_id = "new-conversation"
    apply(reader, registry)
    assert registry.get("main").test_activity is None


def test_observed_long_run_losing_its_lock_has_explicit_unavailable_exit(tmp_path):
    folder, root = tmp_path / "runs", tmp_path / "own"
    path = record(folder, "1", root, "running")
    fd = hold(path)
    registry = SessionRegistry()
    registry.apply_snapshot([RawSession("main", "w", 0, "claude", 12, "", str(root))])
    now = [20]
    reader = TestActivityReader(folder, clock=lambda: now[0])
    apply(reader, registry)
    os.close(fd)
    now[0] = 1000
    apply(reader, registry)
    assert registry.get("main").test_activity.state == "interrupted"
    assert registry.get("main").test_activity.exit_code is None


def test_a_record_of_another_format_version_is_not_read(tmp_path):
    folder = tmp_path / "runs"
    record(folder, "1", tmp_path / "current", "completed", finished_at=15, exit_code=0, version=1)
    record(folder, "2", tmp_path / "newer", "completed", finished_at=15, exit_code=0, version=2)
    assert set(TestActivityReader(folder, clock=lambda: 20).read().activities) == {str(tmp_path / "current")}


def test_a_minimal_record_as_documented_reaches_a_session_in_any_repository(tmp_path):
    # docs/configuration.md, "Show your project's test runs": the required fields and the lock, nothing of AiTerm's.
    folder, root = tmp_path / "runs", tmp_path / "shop"
    (root / "web").mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    folder.mkdir()
    path = folder / "run-1.json"
    fd = os.open(folder / "run-1.lock", os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    path.write_text(json.dumps({"version": 1, "run_id": "run-1", "root": str(root), "suite": "unit", "state": "running"}))
    registry = SessionRegistry()
    registry.apply_snapshot([RawSession("main", "w", 0, "codex", 12, "", str(root / "web"))])
    reader = TestActivityReader(folder, clock=lambda: 20)
    try:
        apply(reader, registry)
        assert registry.get("main").test_activity.state == "running"
        assert registry.get("main").test_activity.suite == "unit"
        path.write_text(json.dumps({"version": 1, "run_id": "run-1", "root": str(root), "suite": "unit",
                                    "state": "completed", "finished_at": 19, "exit_code": 1}))
    finally:
        os.close(fd)
    apply(reader, registry)
    assert registry.get("main").test_activity.state == "completed"
    assert registry.get("main").test_activity.exit_code == 1


def test_the_reference_writer_records_what_the_reader_reads(tmp_path):
    writer = Path(__file__).resolve().parents[2] / "scripts" / "test-queue.py"
    lock, root, release = tmp_path / "lock", tmp_path / "own", tmp_path / "release"
    root.mkdir()
    folder = Path(str(lock) + ".runs")
    run = subprocess.Popen([sys.executable, str(writer), str(lock), "unit", str(root), "sh", "-c",
                            f"until [ -e '{release}' ]; do sleep 0.05; done; exit 3"])
    try:
        reader = TestActivityReader(folder)
        deadline = time.monotonic() + 10
        while (activity := reader.read().activities.get(str(root.resolve()))) is None or activity.state != "running":
            assert time.monotonic() < deadline, "the writer's run never read as running"
            time.sleep(0.05)
        assert activity.suite == "unit"
        assert all(json.loads(path.read_text())["version"] == 1 for path in folder.glob("*.json"))
        release.touch()
        assert run.wait(timeout=10) == 3
    finally:
        release.touch()
        run.wait(timeout=10)
    activity = reader.read().activities[str(root.resolve())]
    assert activity.state == "completed" and activity.exit_code == 3


def test_record_cache_follows_rewrites_with_the_same_size_and_date(tmp_path):
    folder, root = tmp_path / "runs", tmp_path / "wt"
    path = record(folder, "1", root, "completed", finished_at=15)
    reader = TestActivityReader(folder, clock=lambda: 20)
    assert reader.read().activities[str(root)].suite == "swift"
    stamp = path.stat()
    path.write_text(path.read_text().replace('"swift"', '"other"'))
    os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
    assert path.stat().st_size == stamp.st_size
    assert reader.read().activities[str(root)].suite == "other"


def test_record_cache_stamps_the_opened_symlink_target(tmp_path):
    folder, root = tmp_path / "runs", tmp_path / "wt"
    first = record(tmp_path / "first", "1", root, "completed", finished_at=15)
    second = record(tmp_path / "second", "1", root, "completed", finished_at=15, suite="other")
    stamp = first.stat()
    os.utime(second, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
    folder.mkdir()
    link = folder / "1.json"
    link.symlink_to(first)
    reader = TestActivityReader(folder, clock=lambda: 20)
    assert reader.read().activities[str(root)].suite == "swift"
    link.unlink()
    link.symlink_to(second)
    assert reader.read().activities[str(root)].suite == "other"


def test_record_cache_retries_an_unreadable_file_without_a_stamp_change(tmp_path, monkeypatch):
    folder, root = tmp_path / "runs", tmp_path / "wt"
    path = record(folder, "1", root, "completed", finished_at=15)
    reader, original = TestActivityReader(folder, clock=lambda: 20), type(path).open

    def failed(candidate, *args, **kwargs):
        if candidate == path:
            raise PermissionError("temporarily unreadable")
        return original(candidate, *args, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(type(path), "open", failed)
        assert reader.read().activities == {}
    assert reader.read().activities[str(root)].state == "completed"


def test_old_records_still_report_a_held_lock(tmp_path):
    folder, root = tmp_path / "runs", tmp_path / "wt"
    path = record(folder, "1", root, "completed", finished_at=15)
    fd = hold(path)
    reader = TestActivityReader(folder, clock=lambda: 1000)
    try:
        assert reader.read().activities[str(root)].state == "completed"
    finally:
        os.close(fd)
    assert reader.read().activities == {}


def test_empty_activity_resolves_no_session_directories(tmp_path, monkeypatch):
    registry = SessionRegistry()
    registry.apply_snapshot([RawSession(str(i), "w", i, "claude", i, "", str(tmp_path), {}) for i in range(5)])
    resolved, original = [], Path.resolve

    def resolve(path, *args, **kwargs):
        resolved.append(path)
        return original(path, *args, **kwargs)

    monkeypatch.setattr(Path, "resolve", resolve)
    reader = TestActivityReader(tmp_path / "runs")
    assert reader.apply(registry, reader.read(registry.all())) == []
    assert resolved == []  # Before: five resolutions, one per session with no activity to place.
