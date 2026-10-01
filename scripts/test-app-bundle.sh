#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/AiTerm.app}"
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
[[ -x "$APP/Contents/Resources/hooks/claude-statusline-shim.sh" ]] || { echo "missing hook shim" >&2; exit 1; }
[[ -x "$APP/Contents/Resources/hooks/grok-statusline-shim.sh" ]] || { echo "missing Grok status-line shim" >&2; exit 1; }
[[ -f "$APP/Contents/Resources/hooks/pi-aiterm-status.ts" ]] || { echo "missing PI extension" >&2; exit 1; }
cmp -s "$ROOT/hooks/pi-aiterm-status.ts" "$APP/Contents/Resources/hooks/pi-aiterm-status.ts" || { echo "bundled PI extension differs from source" >&2; exit 1; }
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$APP/Contents/Resources/daemon" python3 - <<'PYCODE'
import importlib.metadata
import aitermd.service
import iterm2
for name, expected in [("iterm2", "2.23"), ("websockets", "17.1"), ("protobuf", "7.36.1")]:
    assert importlib.metadata.version(name) == expected, name
PYCODE
cmp -s "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE" || { echo "bundled LICENSE is missing or differs from the repo's" >&2; exit 1; }
feed="$(/usr/libexec/PlistBuddy -c 'Print :AiTermUpdateFeed' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$feed" == github:dhondtlaurens/aiterm ]] || { echo "expected AiTermUpdateFeed=github:dhondtlaurens/aiterm, got ${feed:-<missing>}" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
echo "verified executable, resources, pinned helper dependencies, and signature in $APP"
