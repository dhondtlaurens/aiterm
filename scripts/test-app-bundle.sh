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
# Settings › Agents' Run check runs it from the bundle, beside the helper's package.
cmp -s "$ROOT/daemon/tools/delivery_check.py" "$APP/Contents/Resources/daemon/tools/delivery_check.py" \
    || { echo "the bundled delivery check is missing or differs from the repo's" >&2; exit 1; }
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$APP/Contents/Resources/daemon" "$PYTHON" - "$ROOT/daemon/pyproject.toml" "$APP/Contents/Resources/daemon" <<'PYCODE'
import importlib.metadata
import re
import sys
import tomllib
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
PYCODE
cmp -s "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE" || { echo "bundled LICENSE is missing or differs from the repo's" >&2; exit 1; }
feed="$(/usr/libexec/PlistBuddy -c 'Print :AiTermUpdateFeed' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$feed" == github:dhondtlaurens/aiterm ]] || { echo "expected AiTermUpdateFeed=github:dhondtlaurens/aiterm, got ${feed:-<missing>}" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
echo "verified executable, resources, pinned helper dependencies, and signature in $APP"
