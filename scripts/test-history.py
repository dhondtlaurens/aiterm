#!/usr/bin/env python3
"""Runner-owned seven-day timing history, separate from the daemon's activity records."""
from __future__ import annotations

import fcntl
import json
import os
import re
import select
import subprocess
import sys
import time
import tempfile
from pathlib import Path

RETENTION = 7 * 86400


def wait(child: subprocess.Popen[bytes]) -> tuple[int, str]:
    """Tee the child, stopping at its exit even if a grandchild keeps stdout open."""
    assert child.stdout is not None
    descriptor = child.stdout.fileno()
    os.set_blocking(descriptor, False)
    with tempfile.TemporaryFile() as log:
        def drain() -> bool:
            try:
                chunk = os.read(descriptor, 65536)
            except BlockingIOError:
                return False
            if not chunk:
                return False
            log.write(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            return True

        while child.poll() is None:
            if select.select([descriptor], [], [], 0.1)[0] and not drain():
                break
        result = child.wait()
        while drain():
            pass
        child.stdout.close()
        log.seek(0)
        return result, log.read().decode("utf-8", errors="replace")


def source(root: str) -> dict[str, object]:
    def git(*args: str) -> str | None:
        result = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, check=False,
                                env={key: value for key, value in os.environ.items() if not key.startswith("GIT_")})
        return result.stdout.strip() if result.returncode == 0 else None

    common = git("rev-parse", "--git-common-dir")
    return {
        "head": git("rev-parse", "--verify", "HEAD"),
        "common_dir": str((Path(root) / common).resolve()) if common else None,
        "clean": git("status", "--porcelain", "--untracked-files=all") == "",
    }


def is_full(suite: str, root: str, command: list[str], environment: dict[str, str]) -> bool:
    return (suite == "all" and len(command) == 2 and command[1] == "all"
            and Path(command[0]).resolve() == (Path(root) / "scripts/test.sh").resolve()
            and not any(key in environment for key in (
                "SWIFT", "PYTEST", "PYTEST_ADDOPTS", "AITERM_TEST_PATHS", "TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER",
                "AITERM_FIXTURE_TEST_RUN")))


def results(output: str) -> dict[str, object]:
    suites: list[dict[str, object]] = []
    failures: set[str] = set()
    label = ""
    for line in output.splitlines():
        if line.startswith("Gate pass: "):
            label = line.removeprefix("Gate pass: ")
        match = re.search(r"[✔━✘] Suite (.+?) (passed|failed) after ([\d.,]+) seconds", line)
        if match:
            suites.append({"pass": label, "name": match[1], "result": match[2],
                           "seconds": float(match[3].replace(",", "."))})
        match = re.search(r"✘ Test (.+?) (?:failed after|recorded an issue)", line)
        if match:
            failures.add(re.sub(r" with \d+ test cases?$", "", match[1]))
        if line.startswith("FAILED "):
            failures.add(line.removeprefix("FAILED ").split(" - ", 1)[0])
        if line.startswith("FAIL "):
            failures.add(line.removeprefix("FAIL "))
        if re.search(r"\d+ (?:passed|failed)", line):
            match = re.search(r" in ([\d.]+)s", line)
            if match:
                suites.append({"pass": "daemon", "name": "pytest", "result": "failed" if re.search(r"\d+ failed", line) else "passed",
                               "seconds": float(match[1])})
    return {"suites": suites, "failing_tests": sorted(failures)}


def read(path: Path, now: float) -> list[dict[str, object]]:
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError:
        return []
    entries = []
    for line in lines:
        try:
            entry = json.loads(line)
            stamp = entry.get("finished_at")
            if isinstance(stamp, (int, float)) and now - stamp <= RETENTION:
                entries.append(entry)
        except (ValueError, AttributeError):
            continue
    return entries


def append(path: Path, entry: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with Path(str(path) + ".lock").open("a") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        entries = read(path, time.time()) + [entry]
        temporary = Path(str(path) + f".{os.getpid()}.tmp")
        try:
            temporary.write_text("".join(json.dumps(item) + "\n" for item in entries))
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def green(path: Path, root: str) -> bool:
    current = source(root)
    if not current["clean"] or not current["head"] or not current["common_dir"]:
        return False
    attempts = [entry for entry in read(path, time.time())
                if entry.get("full_gate") is True and entry.get("before") == current]
    if not attempts:
        return False
    latest = max(attempts, key=lambda entry: entry["finished_at"])
    return latest.get("exit_code") == 0 and latest.get("after") == current


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] != "require-full":
        raise SystemExit("usage: test-history.py require-full ROOT HISTORY")
    try:
        raise SystemExit(0 if green(Path(sys.argv[3]), sys.argv[2]) else 1)
    except (OSError, ValueError):
        raise SystemExit(1)
