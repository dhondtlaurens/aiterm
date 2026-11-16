#!/bin/zsh
# Prove the workspace reset on scratch files only, preserving all other saved values.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/aiterm reset.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
"${PYTHON:-python3}" - "$ROOT" "$scratch" <<'PY'
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
script = root / "scripts/reset-operator-state.sh"


def check(name, original, expected):
    path = scratch / f"{name}.json"
    path.write_bytes(original)
    source_mtime = 1_700_000_000_000_000_000
    os.utime(path, ns=(source_mtime, source_mtime))
    result = subprocess.run([str(script), str(path)], capture_output=True, text=True)
    assert result.returncode == 0, f"FAIL {name}: {result.stderr}"
    assert result.stdout == f"Operator records removed from {path}.\n", result.stdout
    assert json.loads(path.read_bytes()) == expected, f"FAIL {name}: saved values differ"
    backups = list(scratch.glob(f"{path.name}.before-reset-*"))
    assert len(backups) == 1, f"FAIL {name}: expected exactly one dated copy"
    backup = backups[0]
    assert re.fullmatch(re.escape(path.name) + r"\.before-reset-\d{8}-\d{6}", backup.name), backup
    assert backup.read_bytes() == original, f"FAIL {name}: dated copy differs"
    assert backup.stat().st_mtime_ns == source_mtime, f"FAIL {name}: copy lost its date"
    print(f"ok   {name}: saved values and dated copy preserved")
    return json.loads(path.read_bytes())


fixture = (root / "app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/state.json").read_bytes()
expected = json.loads(fixture)
assert "operatorSession" in expected
assert any("signalTask" in task for task in expected["tasks"])
assert any("signalTask" in entry["task"] for entry in expected["archive"])
del expected["operatorSession"]
for task in expected["tasks"] + [entry["task"] for entry in expected["archive"]]:
    assert task.get("signalTask", {}).get("takenOver") is not True
    task.pop("signalTask", None)
actual = check("saved-state fixture", fixture, expected)


def has_signal_record(value):
    if isinstance(value, dict):
        return "signalTask" in value or any(map(has_signal_record, value.values()))
    if isinstance(value, list):
        return any(map(has_signal_record, value))
    return False


assert "operatorSession" not in actual and not has_signal_record(actual)

state = {
    "operatorSession": {"id": "scratch-session"},
    "tasks": [
        {"id": "driven", "signalTask": {"takenOver": False}},
        {"id": "taken-over", "signalTask": {"takenOver": True}},
        {"id": "ordinary", "conversations": [{"id": "worker-session"}]},
        {"id": "unmarked", "signalTask": {}},
        {"id": "non-boolean", "signalTask": {"takenOver": 1}},
    ],
    "archive": [
        {"task": {"id": "archived-taken-over", "signalTask": {"takenOver": True}}, "at": "kept"},
        {"task": {"id": "archived-ordinary"}, "extra": None},
    ],
    "unknown": {"null": None, "nested": [[1, "é", True], [None, {"kept": "value"}]]},
}
expected = {
    "tasks": [
        {"id": "driven"},
        {"id": "taken-over", "takenOver": True},
        {"id": "ordinary", "conversations": [{"id": "worker-session"}]},
        {"id": "unmarked"},
        {"id": "non-boolean"},
    ],
    "archive": [
        {"task": {"id": "archived-taken-over", "takenOver": True}, "at": "kept"},
        {"task": {"id": "archived-ordinary"}, "extra": None},
    ],
    "unknown": copy.deepcopy(state["unknown"]),
}
check("takeover and unknown values", json.dumps(state, ensure_ascii=False).encode(), expected)
ordinary = {"tasks": [{"id": "ordinary"}], "unknown": None}
check("no archive or Operator session", json.dumps(ordinary).encode(), ordinary)
check("no task arrays", b'{"unknown": [null, [1, 2]]}', {"unknown": [None, [1, 2]]})

missing = scratch / "missing.json"
before = set(scratch.iterdir())
result = subprocess.run([str(script), str(missing)], capture_output=True, text=True)
assert result.returncode != 0, "FAIL missing file: reset succeeded"
assert set(scratch.iterdir()) == before, "FAIL missing file: created a file"
print("ok   missing file: non-zero exit and no file created")
print("Operator state reset guard passed.")
PY
