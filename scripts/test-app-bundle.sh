#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/AiTerm.app}"
PYTHON="${PYTHON:-python3}"
ICON_NAME="AiTerm.icns"
SOURCE_ICON="$ROOT/app/Sources/AiTerm/Resources/$ICON_NAME"
BUNDLED_ICON="$APP/Contents/Resources/$ICON_NAME"

[[ -d "$APP" ]] || { echo "missing app bundle: $APP" >&2; exit 1; }
[[ -f "$SOURCE_ICON" ]] || { echo "missing source icon: $SOURCE_ICON" >&2; exit 1; }

actual_icon="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$actual_icon" == "$ICON_NAME" ]] || {
    echo "expected CFBundleIconFile=$ICON_NAME, got ${actual_icon:-<missing>}" >&2
    exit 1
}

[[ -f "$BUNDLED_ICON" ]] || { echo "missing bundled icon: $BUNDLED_ICON" >&2; exit 1; }
cmp -s "$SOURCE_ICON" "$BUNDLED_ICON" || { echo "bundled icon differs from source icon" >&2; exit 1; }

[[ -x "$APP/Contents/MacOS/AiTerm" ]] || { echo "missing app executable" >&2; exit 1; }
for hook in claude-statusline-shim.sh pi-aiterm-status.ts; do
    bundled="$APP/Contents/Resources/hooks/$hook"
    [[ -f "$bundled" ]] || { echo "missing bundled hook: $hook" >&2; exit 1; }
    if [[ "$hook" == *.sh && ! -x "$bundled" ]]; then
        echo "bundled hook is not executable: $hook" >&2
        exit 1
    fi
    cmp -s "$ROOT/hooks/$hook" "$bundled" || { echo "bundled $hook differs from source" >&2; exit 1; }
done
# Each Settings › Agents card's verified line reads it (`CompatVerified.bundled`).
cmp -s "$ROOT/compat/verified.json" "$APP/Contents/Resources/compat/verified.json" \
    || { echo "the bundled compat/verified.json is missing or differs from the repo's" >&2; exit 1; }
# Settings › Agents' Run check runs it from the bundle, beside the helper's package.
cmp -s "$ROOT/daemon/tools/delivery_check.py" "$APP/Contents/Resources/daemon/tools/delivery_check.py" \
    || { echo "the bundled delivery check is missing or differs from the repo's" >&2; exit 1; }
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$APP/Contents/Resources/daemon" "$PYTHON" - "$ROOT/daemon/pyproject.toml" "$APP/Contents/Resources/daemon" "$ROOT/daemon/tools" <<'PYCODE'
import ast
import importlib.metadata
import re
import sys
import tomllib
from pathlib import Path
import aitermd.service
import iterm2

with open(sys.argv[1], "rb") as manifest:
    dependencies = tomllib.load(manifest)["project"]["dependencies"]
# Read only bundled metadata: an installed developer package cannot satisfy a missing resource.
installed = {
    dist.metadata["Name"].lower().replace("_", "-"): dist.version
    for dist in importlib.metadata.distributions(path=[sys.argv[2]])
}
for requirement in dependencies:
    pin = re.fullmatch(r"([A-Za-z0-9_.-]+)==([^ ;]+)", requirement)
    assert pin is not None, f"bundle dependency must have an exact pin: {requirement}"
    name, expected = pin.groups()
    assert installed.get(name.lower().replace("_", "-")) == expected, requirement

# The delivery check imports its own `tools.*` modules from the bundle: each must be there, current.
bundled_tools, source_tools = Path(sys.argv[2], "tools"), Path(sys.argv[3])
pending, seen = ["delivery_check"], set()
while pending:
    module = pending.pop()
    if module in seen:
        continue
    seen.add(module)
    bundled = bundled_tools / f"{module}.py"
    assert bundled.is_file() and bundled.read_bytes() == (source_tools / f"{module}.py").read_bytes(), (
        f"the bundled tools/{module}.py, which the delivery check needs, is missing or differs from the repo's"
    )
    for node in ast.walk(ast.parse(bundled.read_text())):
        names = [node.module or ""] if isinstance(node, ast.ImportFrom) else [a.name for a in node.names] if isinstance(node, ast.Import) else []
        pending += [name.split(".")[1] for name in names if name.startswith("tools.")]
PYCODE
cmp -s "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE" || { echo "bundled LICENSE is missing or differs from the repo's" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
echo "verified executable, resources, pinned helper dependencies, and signature in $APP"
