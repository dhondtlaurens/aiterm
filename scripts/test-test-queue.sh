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
print 'Test queue: FIFO, crashed waiter, inherited holder and own-command result metadata passed.'
