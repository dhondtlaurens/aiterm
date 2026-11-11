#!/bin/zsh
# Isolated real-process regressions for FIFO admission and dead waiters.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
pids=()
trap 'for pid in $pids; do kill "$pid" 2>/dev/null || true; done; rm -rf "$scratch"' EXIT
fail() { print -u2 -- "$1"; exit 1; }
wait_for() {
    local attempt
    for attempt in {1..200}; do [[ -e "$1" ]] && return 0; sleep 0.025; done
    fail "timed out waiting for $1"
}
wait_queued() {
    local attempt
    for attempt in {1..200}; do grep -q 'Waiting for another test run' "$scratch/$1.log" 2>/dev/null && return 0; sleep 0.025; done
    fail "timed out waiting for $1 to queue"
}
start() {
    local name="$1"
    AITERM_TEST_LOCK_HELD= AITERM_TEST_LOCK="$scratch/lock" ROOT="$ROOT" SCRATCH="$scratch" NAME="$name" "${PYTHON:-python3}" "$ROOT/scripts/test-queue.py" "$scratch/lock" fixture "$ROOT" zsh -c '
        set -euo pipefail
        print -r -- "$NAME" >>"$SCRATCH/order"
        print $$ >"$SCRATCH/$NAME.pid"
        touch "$SCRATCH/$NAME.running"
        if [[ "$NAME" == crashing ]]; then
            (until [[ -e "$SCRATCH/child.release" ]]; do sleep 0.025; done) &
            print $! >"$SCRATCH/child.pid"
        fi
        until [[ -e "$SCRATCH/$NAME.release" ]]; do sleep 0.025; done
    ' >"$scratch/$name.log" 2>&1 &
    pids+=($!)
}
# Stale registration and holder metadata must not block a new live run.
mkdir -p "$scratch/lock.queue"
touch "$scratch/lock.queue/00000000000000000000.ticket"
print 'stale holder' >"$scratch/lock.holder"
print 'interrupted old counter' >"$scratch/lock.queue/sequence"
start first
wait_for "$scratch/first.running"
start second
wait_queued second
"${PYTHON:-python3}" - "$scratch/lock.runs" "$pids[-1]" <<'PYLIVE'
import fcntl
import json
from pathlib import Path
import sys
records = [(path, json.loads(path.read_text())) for path in Path(sys.argv[1]).glob("*.json")]
path, record = next((path, record) for path, record in records if record["supervisor_pid"] == int(sys.argv[2]))
assert record["state"] == "queued" and record["started_at"] is None and record["exit_code"] is None
assert isinstance(record["ticket"], int)
with path.with_suffix(".lock").open("r+") as stream:
    try:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        raise AssertionError("a queued run's activity liveness lock was not held")
PYLIVE
start third
wait_queued third
touch "$scratch/first.release"
wait_for "$scratch/second.running"
[[ ! -e "$scratch/third.running" ]] || fail 'third overtook second'
touch "$scratch/second.release"
wait_for "$scratch/third.running"
touch "$scratch/third.release"
wait
[[ "$(cat "$scratch/order")" == $'first\nsecond\nthird' ]] || fail 'test admission was not FIFO'

start holder
wait_for "$scratch/holder.running"
start canceled
wait_queued canceled
kill -KILL "$pids[-1]"
wait "$pids[-1]" 2>/dev/null || true
start survivor
wait_queued survivor
touch "$scratch/holder.release"
wait_for "$scratch/survivor.running"
touch "$scratch/survivor.release"
wait
[[ ! -e "$scratch/canceled.running" ]] || fail 'a canceled waiter ran'
start crashing
wait_for "$scratch/child.pid"
crashed_pid="$pids[-1]"
child_pid="$(cat "$scratch/child.pid")"
pids+=("$child_pid")
runner_pid="$(cat "$scratch/crashing.pid")"
pids+=("$runner_pid")
kill -KILL "$crashed_pid" "$runner_pid"
wait "$crashed_pid" 2>/dev/null || true
start aftercrash
wait_queued aftercrash
[[ ! -e "$scratch/aftercrash.running" ]] || fail 'a crashed holder released the slot while its child still ran'
touch "$scratch/child.release"
wait_for "$scratch/aftercrash.running"
touch "$scratch/aftercrash.release"
wait
metadata_rc=0
"${PYTHON:-python3}" "$ROOT/scripts/test-queue.py" "$scratch/result-lock" fixture "$ROOT/." /bin/sh -c 'exit 17' || metadata_rc=$?
[[ "$metadata_rc" == 17 ]] || fail 'the helper did not return its own command exit status'
"${PYTHON:-python3}" - "$scratch/result-lock.runs" "$ROOT" <<'PYMETA'
import fcntl
import json
import os
from pathlib import Path
import sys
path, = Path(sys.argv[1]).glob("*.json")
record = json.loads(path.read_text())
assert record["state"] == "completed" and record["exit_code"] == 17
assert record["root"] == os.path.realpath(sys.argv[2])
assert isinstance(record["ticket"], int) and record["ticket"] > 0
assert record["started_at"] is not None and record["finished_at"] is not None
with path.with_suffix(".lock").open("r+") as stream:
    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
PYMETA
# Optional history must never change either the command result or its activity record.
review_errors=()
for expected in 0 17; do
    history_lock="$scratch/history-$expected"
    mkdir "$history_lock.history.jsonl"
    actual=0
    "${PYTHON:-python3}" "$ROOT/scripts/test-queue.py" "$history_lock" fixture "$ROOT" \
        /bin/sh -c "exit $expected" >"$scratch/history-$expected.stdout" 2>"$scratch/history-$expected.stderr" || actual=$?
    [[ "$actual" == "$expected" ]] || review_errors+=("unwritable history changed command exit $expected to $actual")
    grep -qi 'could not retain gate history' "$scratch/history-$expected.stderr" || review_errors+=('history failure did not warn')
    if ! "${PYTHON:-python3}" - "$history_lock.runs" "$expected" <<'PYRESULT'
import json, sys
from pathlib import Path
path, = Path(sys.argv[1]).glob('*.json')
assert json.loads(path.read_text())['exit_code'] == int(sys.argv[2]), 'history rewrote the activity result'
PYRESULT
    then review_errors+=('history rewrote the activity result'); fi
 done
# Kill only the supervisor: its live command must still write both original streams and hold
# admission until its own exit. SIGINT also exercises output after an interrupted supervisor.
for termination in KILL INT; do
    name="output-$termination"
    output_lock="$scratch/$name.lock"
    "${PYTHON:-python3}" "$ROOT/scripts/test-queue.py" "$output_lock" fixture "$ROOT" \
        "${PYTHON:-python3}" - "$scratch" "$name" >"$scratch/$name.stdout" 2>"$scratch/$name.stderr" <<'PYCHILD' &
import os, shutil, sys, time
from pathlib import Path
folder, name = Path(sys.argv[1]), sys.argv[2]
(folder / (name + '.pid')).write_text(str(os.getpid()))
while not (folder / (name + '.release')).exists(): time.sleep(0.01)
result = 0
try:
    os.write(1, b'normal output after supervisor exit\n')
    os.write(2, b'error output after supervisor exit\n')
except BrokenPipeError:
    result = 17
(folder / (name + '.exit')).write_text(str(result))
if report_dir := os.environ.get('AITERM_TEST_REPORT_DIR'):
    shutil.rmtree(report_dir, ignore_errors=True)
PYCHILD
    supervisor=$!
    pids+=($supervisor)
    wait_for "$scratch/$name.pid"
    live_child="$(cat "$scratch/$name.pid")"
    pids+=($live_child)
    kill -"$termination" "$supervisor"
    supervisor_exit=0
    wait "$supervisor" 2>/dev/null || supervisor_exit=$?
    print "$supervisor_exit" >"$scratch/$name.supervisor-exit"
    "${PYTHON:-python3}" "$ROOT/scripts/test-queue.py" "$output_lock" fixture "$ROOT" \
        /usr/bin/touch "$scratch/$name.next-ran" >"$scratch/$name-next.log" 2>&1 &
    successor=$!
    pids+=($successor)
    wait_queued "$name-next"
    [[ ! -e "$scratch/$name.next-ran" ]] || review_errors+=('live writer lost the execution lock')
    touch "$scratch/$name.release"
    wait_for "$scratch/$name.exit"
    [[ "$(cat "$scratch/$name.exit")" == 0 ]] || review_errors+=("$termination supervisor left the command writing to a broken pipe")
    wait "$successor"
    [[ -e "$scratch/$name.next-ran" ]] || review_errors+=('successor never ran')
    grep -Fxq 'normal output after supervisor exit' "$scratch/$name.stdout" || review_errors+=('normal output was lost')
    grep -Fxq 'error output after supervisor exit' "$scratch/$name.stderr" || review_errors+=('error output was lost or merged')
    if grep -Fq 'error output after supervisor exit' "$scratch/$name.stdout"; then review_errors+=('stderr was merged into stdout'); fi
 done
# Preserve the old inherited-stdout regression at the actual queue boundary. The observer uses
# regular files, so only a proxy inside the supervisor could wait for the grandchild's stdout EOF.
"${PYTHON:-python3}" - "$ROOT" "$scratch" <<'PYGRANDCHILD'
import os, shutil, subprocess, sys, time
from pathlib import Path
root, folder = map(Path, sys.argv[1:])
release, pid, finished = (folder / ('inherited.' + suffix) for suffix in ('release', 'pid', 'exit'))
worker = '''
import os, shutil, sys, time
from pathlib import Path
release, pid, finished = map(Path, sys.argv[1:])
pid.write_text(str(os.getpid()))
while not release.exists(): time.sleep(0.01)
if report_dir := os.environ.get('AITERM_TEST_REPORT_DIR'):
    shutil.rmtree(report_dir, ignore_errors=True)
finished.write_text('0')
'''
parent = '''
import subprocess, sys
subprocess.Popen([sys.executable, '-c', sys.argv[1], *sys.argv[2:]], close_fds=False)
raise SystemExit(17)
'''
with (folder / 'inherited.stdout').open('wb') as output, (folder / 'inherited.stderr').open('wb') as error:
    helper = subprocess.Popen([sys.executable, str(root / 'scripts/test-queue.py'), str(folder / 'inherited.lock'),
        'fixture', str(root), sys.executable, '-c', parent, worker, str(release), str(pid), str(finished)],
        stdout=output, stderr=error)
    (folder / 'inherited.supervisor.pid').write_text(str(helper.pid))
    try:
        code = helper.wait(timeout=5)
        (folder / 'inherited.supervisor.exit').write_text(str(code))
        assert code == 17, code
        assert not finished.exists(), 'grandchild was not still holding stdout'
    finally:
        release.touch()
        try:
            helper.wait(timeout=5)
        except subprocess.TimeoutExpired:
            helper.kill()
            helper.wait()
    deadline = time.monotonic() + 5
    while not finished.exists() and time.monotonic() < deadline: time.sleep(0.01)
    assert pid.exists() and finished.read_text() == '0'
PYGRANDCHILD

if (( ${#review_errors} )); then
    print -rl -u2 -- $review_errors
    fail 'review regressions: optional history and inherited output failed'
fi

print 'Test queue: FIFO, crashed waiter, inherited holder, command results, optional history and separate live-child streams passed.'
