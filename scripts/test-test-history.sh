#!/bin/zsh
# Isolated checks of runner history and the exact-HEAD release precondition. Never runs release.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
"${PYTHON:-python3}" - "$ROOT/scripts/test-history.py" "$scratch" <<'PY'
import json
import contextlib
import io
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import time

history = runpy.run_path(sys.argv[1])
root = Path(sys.argv[2]) / "repo"
root.mkdir()
environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
environment.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                   GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@invalid",
                   GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@invalid")
def git(*arguments):
    return subprocess.run(["git", "-C", str(root), *arguments], env=environment, check=True, capture_output=True, text=True).stdout.strip()
git("init", "-q", "-b", "main")
(root / "tracked").write_text("first\n")
git("add", "tracked")
git("commit", "-q", "-m", "first")
state = history["source"](str(root))
assert state["clean"] and state["head"]
path = Path(sys.argv[2]) / "lock.history.jsonl"
records = Path(sys.argv[2]) / "lock.runs"
records.mkdir()
activity = records / "one.json"
activity.write_text('{"version": 1}\n')
now = time.time()
def entry(**changes):
    return dict(dict(version=1, finished_at=now, before=state, after=state, full_gate=True, exit_code=0), **changes)
def save(**changes):
    history["append"](path, entry(**changes))
def green():
    return history["green"](path, str(root))
def cli():
    return subprocess.run([sys.executable, sys.argv[1], "require-full", str(root), str(path)], check=False).returncode
assert not green(), "missing history became a full pass"
save(full_gate=False)
assert not green(), "a filtered pass became a full pass"
save(exit_code=None, finished_at=now + 1)
assert not green(), "an incomplete result became a full pass"
save(finished_at=now + 2)
assert green() and cli() == 0
(root / "tracked").write_text("changed\n")
assert not green() and cli() == 1, "dirty HEAD accepted"
(root / "tracked").write_text("first\n")
assert green()
save(exit_code=1, finished_at=now + 3)
assert not green(), "a later failed full gate did not revoke the pass"
save(finished_at=now + 4)
save(full_gate=False, exit_code=1, finished_at=now + 5)
assert green(), "a filtered failure replaced the full result"
save(after=state | {"clean": False}, finished_at=now + 6)
assert not green(), "edits during a gate accepted"
save(finished_at=now + 7)
git("commit", "-q", "--allow-empty", "-m", "next")
assert not green(), "another commit's proof accepted"
# A successful full gate follows the commit across this scratch repository's worktrees.
git("reset", "--hard", state["head"])
sibling = Path(sys.argv[2]) / "sibling"
git("worktree", "add", "-q", "--detach", str(sibling))
assert history["green"](path, str(sibling))
save(finished_at=now - 8 * 86400, run_id="expired")
save(finished_at=now - 6 * 86400, run_id="retained")
save(finished_at=now + 8)
assert all(item.get("run_id") != "expired" for item in history["read"](path, now))
assert any(item.get("run_id") == "retained" for item in history["read"](path, now))
assert "expired" not in path.read_text(), "expired history was not pruned on write"
assert activity.read_text() == '{"version": 1}\n', "history changed a daemon activity record"
path.write_text(path.read_text() + 'incomplete JSON\n{"finished_at": null}\n')
assert green(), "an interrupted history append hid the completed result"
# Eligibility comes from the real invocation, never merely the suite label.
command = [str(root / "scripts/test.sh"), "all"]
assert history["is_full"]("all", str(root), command, {})
assert not history["is_full"]("all", str(root), command + ["--", "--filter", "fixture"], {})
assert not history["is_full"]("changed", str(root), command, {})
for key in ["SWIFT", "PYTEST", "PYTEST_ADDOPTS", "AITERM_TEST_PATHS", "TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER", "AITERM_FIXTURE_TEST_RUN"]:
    assert not history["is_full"]("all", str(root), command, {key: "fixture"})
parsed = history["results"]('''Gate pass: main
✔ Suite One passed after 1.250 seconds.
━ Suite Known passed after 0.020 seconds with 1 known issue.
✘ Test broken(x:) recorded an issue at X.swift:2
✘ Test broken(x:) with 2 test cases failed after 0.010 seconds.
1521 passed, 1 skipped in 18.32s
FAILED tests/test_example.py::test_nope - AssertionError
FAIL route fixture
Gate pass: snapshots
✔ Suite SnapshotTests passed after 2,500 seconds.
''')
assert [(item["name"], item["seconds"]) for item in parsed["suites"]] == [
    ("One", 1.25), ("Known", 0.02), ("pytest", 18.32), ("SnapshotTests", 2.5)]
assert parsed["suites"][-1]["pass"] == "snapshots"
assert parsed["failing_tests"] == ["broken(x:)", "route fixture", "tests/test_example.py::test_nope"]
# A grandchild holding the output pipe must not add its lifetime to the gate's duration.
release = Path(sys.argv[2]) / "stdout.release"
worker_pid = Path(sys.argv[2]) / "stdout.pid"
worker_exit = Path(sys.argv[2]) / "stdout.exit"
worker = """
import os, sys, time
from pathlib import Path
release, pid, status = map(Path, sys.argv[1:])
pid.write_text(str(os.getpid()))
while not release.exists(): time.sleep(0.01)
status.write_text('0')
"""
parent = """
import subprocess, sys
subprocess.Popen([sys.executable, '-c', sys.argv[1], *sys.argv[2:]])
print('✘ Test heldStdout() failed after 0.010 seconds.', flush=True)
raise SystemExit(17)
"""
child = subprocess.Popen([sys.executable, "-c", parent, worker, str(release), str(worker_pid), str(worker_exit)],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
def expired(_signum, _frame):
    raise AssertionError("history waited for a grandchild's stdout instead of the command's exit")
signal.signal(signal.SIGALRM, expired)
signal.alarm(5)
try:
    forwarded = io.BytesIO()
    stream = io.TextIOWrapper(forwarded, encoding="utf-8")
    with contextlib.redirect_stdout(stream):
        code, output = history["wait"](child)
    stream.flush()
    assert forwarded.getvalue().decode() == output
finally:
    signal.alarm(0)
    release.touch()
    child.wait(timeout=5)
assert code == 17 and "heldStdout()" in output
until = time.monotonic() + 5
while not worker_exit.exists() and time.monotonic() < until:
    time.sleep(0.01)
assert worker_pid.exists() and worker_exit.read_text() == "0"
print("Gate history: timings, failures, retention, clean exact HEAD, full-run eligibility and inherited stdout passed.")
PY
zsh -n "$ROOT/scripts/release.sh"
