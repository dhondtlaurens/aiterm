#!/usr/bin/env python3
"""Runner-owned seven-day timing history, separate from the daemon's activity records."""
from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

RETENTION = 7 * 86400


# Loaded as a pytest plugin only by the gate. Reporting never owns stdout or stderr.
_pytest_started = 0.0
_pytest_failures: set[str] = set()


def pytest_sessionstart(session) -> None:
    global _pytest_started
    _pytest_started = time.monotonic()
    _pytest_failures.clear()


def pytest_runtest_logreport(report) -> None:
    if report.failed:
        _pytest_failures.add(report.nodeid)


def pytest_sessionfinish(session, exitstatus) -> None:
    report = os.environ.get("AITERM_TEST_PYTEST_REPORT")
    if not report:
        return
    result = {"suites": [{"pass": "daemon", "name": "pytest", "result": "passed" if exitstatus == 0 else "failed",
                           "seconds": time.monotonic() - _pytest_started}],
              "failing_tests": sorted(_pytest_failures)}
    try:
        Path(report).write_text(json.dumps(result))
    except OSError as error:
        print(f"Warning: could not retain pytest history: {error}", file=sys.stderr)


def collect(directory: Path) -> dict[str, object]:
    suites: list[dict[str, object]] = []
    failures: set[str] = set()
    for label in ("main", "snapshots"):
        path = directory / (label + ".log")
        if path.exists():
            parsed = results("Gate pass: " + label + "\n" + path.read_text(errors="replace"))
            suites.extend(parsed["suites"])
            failures.update(parsed["failing_tests"])
    daemon = directory / "daemon.json"
    if daemon.exists():
        parsed = json.loads(daemon.read_text())
        suites.extend(parsed["suites"])
        failures.update(parsed["failing_tests"])
    return {"suites": suites, "failing_tests": sorted(failures)}


def source_environment() -> dict[str, str]:
    return {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def source(root: str) -> dict[str, object]:
    def git(*args: str) -> str | None:
        result = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, check=False,
                                env=source_environment())
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
        # Swift Testing's closing summary ("Test run with 1915 tests in 170 suites failed after ...") names no test.
        if match and not re.fullmatch(r"run with \d+ tests?(?: in \d+ suites?)?", match[1]):
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


def same_inputs(root: str, before: object, current: dict[str, object]) -> bool:
    if (not isinstance(before, dict) or before.get("clean") is not True
            or before.get("common_dir") != current["common_dir"]):
        return False
    if not before.get("head"):
        return False
    if before["head"] == current["head"]:
        return True
    environment = source_environment()
    changed = subprocess.run(
        ["git", "-C", root, "diff", "--no-ext-diff", "--no-textconv", "--name-only", "--no-renames", "-z",
         str(before["head"]), str(current["head"]), "--"],
        capture_output=True, text=True, check=False, env=environment)
    if changed.returncode != 0:
        return False
    paths = changed.stdout.rstrip("\0").split("\0") if changed.stdout else []
    if not paths:
        return True
    # Changed routing cannot justify its own reuse of an older pass.
    if {"scripts/test-select.sh", "scripts/test-routes.tsv"}.intersection(paths):
        return False
    # The routing reader accepts one path per line. An unusual name must not become two paths.
    if any("\n" in name or "\r" in name for name in paths):
        return False
    selected = subprocess.run(
        ["zsh", str(Path(root) / "scripts/test-select.sh")], input="".join(name + "\n" for name in paths),
        capture_output=True, text=True, check=False, env=environment)
    return selected.returncode == 0 and not selected.stdout.strip()


def green(path: Path, root: str) -> bool:
    current = source(root)
    if not current["clean"] or not current["head"] or not current["common_dir"]:
        return False
    for entry in sorted(read(path, time.time()), key=lambda item: item["finished_at"], reverse=True):
        if entry.get("full_gate") is True and same_inputs(root, entry.get("before"), current):
            return entry.get("exit_code") == 0 and entry.get("after") == entry.get("before")
    return False


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] != "require-full":
        raise SystemExit("usage: test-history.py require-full ROOT HISTORY")
    try:
        raise SystemExit(0 if green(Path(sys.argv[3]), sys.argv[2]) else 1)
    except (OSError, ValueError):
        raise SystemExit(1)
