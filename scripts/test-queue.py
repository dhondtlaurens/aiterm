#!/usr/bin/env python3
"""FIFO admission whose execution lock survives a killed runner in its live children.

BSD flock belongs to an open file description, unlike zsh/system's process-owned
POSIX lock. The inherited descriptor remains open through exec and ordinary child
commands, so a replacement suite waits until the previous suite actually exits.
"""
from __future__ import annotations

import fcntl
import json
import os
import signal
import subprocess
import sys
import time
import uuid
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path


@contextmanager
def guarded(path: Path) -> Iterator[None]:
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.lockf(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def acquire(lock: Path, suite: str, root: str, registered: Callable[[int], None]) -> tuple[int, bool]:
    queue = Path(str(lock) + ".queue")
    queue.mkdir(parents=True, exist_ok=True)
    guard = queue / "guard"
    ticket: Path | None = None
    ticket_fd: int | None = None
    execution_fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
    waited = False
    since = time.monotonic()
    try:
        with guarded(guard):
            # Recover an absent/corrupt old counter from live and stale ticket names. Atomic
            # replacement keeps a killed registrar from truncating it in the first place.
            tickets = [int(path.stem) for path in queue.glob("*.ticket") if path.stem.isdecimal()]
            try:
                counter = int((queue / "sequence").read_text())
            except (OSError, ValueError):
                counter = 0
            sequence = max([counter, *tickets]) + 1
            replacement = queue / f"sequence.{os.getpid()}"
            replacement.write_text(str(sequence))
            replacement.replace(queue / "sequence")
            ticket = queue / f"{sequence:020d}.ticket"
            ticket_fd = os.open(ticket, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
            fcntl.flock(ticket_fd, fcntl.LOCK_EX)
        registered(sequence)
        while True:
            with guarded(guard):
                first = True
                for predecessor in sorted(queue.glob("*.ticket")):
                    if predecessor == ticket:
                        break
                    try:
                        probe = os.open(predecessor, os.O_RDWR)
                    except FileNotFoundError:
                        continue
                    try:
                        try:
                            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            first = False
                            break
                        predecessor.unlink(missing_ok=True)
                    finally:
                        os.close(probe)
                if first:
                    try:
                        fcntl.flock(execution_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        pass
                    else:
                        ticket.unlink(missing_ok=True)
                        os.close(ticket_fd)
                        ticket_fd = None
                        os.set_inheritable(execution_fd, True)
                        Path(str(lock) + ".holder").write_text(
                            f"pid {os.getpid()}, {suite} in {root} since {time.strftime('%H:%M:%S')}\n")
                        if waited:
                            print(f"Waited {int(time.monotonic() - since)}s for the test lock.", file=sys.stderr, flush=True)
                        return execution_fd, waited
            if not waited:
                try:
                    holder = Path(str(lock) + ".holder").read_text().strip()
                except OSError:
                    holder = "holder unknown"
                print(f"Waiting for another test run to finish ({holder}); queued ticket {sequence}.", file=sys.stderr, flush=True)
                waited = True
            time.sleep(0.1)
    finally:
        if ticket is not None:
            ticket.unlink(missing_ok=True)
        if ticket_fd is not None:
            os.close(ticket_fd)


def publish(path: Path, record: dict[str, object]) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(record) + "\n")
    temporary.replace(path)


def prune(directory: Path) -> None:
    """Bound retained results; a live sidecar is never removed, regardless of its JSON age."""
    finished: list[tuple[float, Path]] = []
    for path in directory.glob("*.json"):
        try:
            record = json.loads(path.read_text())
            stamp = record.get("finished_at") or record.get("queued_at") or path.stat().st_mtime
            if not isinstance(stamp, (int, float)):
                continue
            finished.append((float(stamp), path))
        except (OSError, ValueError, AttributeError):
            continue
    for index, (stamp, path) in enumerate(sorted(finished, reverse=True)):
        if index < 100 and time.time() - stamp < 86400:
            continue
        try:
            descriptor = os.open(path.with_suffix(".lock"), os.O_RDWR)
        except FileNotFoundError:
            continue
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue
            path.unlink(missing_ok=True)
            path.with_suffix(".lock").unlink(missing_ok=True)
        finally:
            os.close(descriptor)


def main() -> None:
    if len(sys.argv) < 5:
        raise SystemExit("usage: test-queue.py LOCK SUITE ROOT COMMAND [ARGS...]")
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda caught, _frame: sys.exit(128 + caught))
    lock, suite, root, *command = sys.argv[1:]
    root = os.path.realpath(root)
    directory = Path(lock + ".runs")
    directory.mkdir(parents=True, exist_ok=True)
    prune(directory)
    run_id = str(uuid.uuid4())
    path = directory / (run_id + ".json")
    activity_fd = os.open(path.with_suffix(".lock"), os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
    fcntl.flock(activity_fd, fcntl.LOCK_EX)
    os.set_inheritable(activity_fd, True)
    record: dict[str, object] = {
        "run_id": run_id, "root": root, "suite": suite, "pid": os.getpid(),
        "supervisor_pid": os.getpid(), "state": "queued", "ticket": None,
        "queued_at": time.time(), "started_at": None, "finished_at": None, "exit_code": None,
    }
    publish(path, record)

    def registered(sequence: int) -> None:
        record["ticket"] = sequence
        publish(path, record)

    descriptor: int | None = None
    child: subprocess.Popen[bytes] | None = None
    try:
        descriptor, waited = acquire(Path(lock), suite, root, registered)
        environment = os.environ | {
            "AITERM_TEST_LOCK_HELD": "1", "AITERM_TEST_WAITED": str(int(waited)),
            "AITERM_TEST_LOCK_FD": str(descriptor), "AITERM_TEST_RUN_ID": run_id,
        }
        child = subprocess.Popen(command, env=environment, pass_fds=(descriptor, activity_fd))
        record.update(state="running", pid=child.pid, started_at=time.time())
        publish(path, record)
        result = child.wait()
        exit_code = result if result >= 0 else 128 - result
        record.update(state="completed", finished_at=time.time(), exit_code=exit_code)
        publish(path, record)
        raise SystemExit(exit_code)
    except SystemExit as error:
        if child is None:
            record.update(state="completed", finished_at=time.time(), exit_code=error.code)
            publish(path, record)
        # With a live child, retain its last state: its inherited lock proves liveness even if
        # this supervisor is interrupted. A missing final result must never become a success.
        raise
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(activity_fd)


if __name__ == "__main__":
    main()
