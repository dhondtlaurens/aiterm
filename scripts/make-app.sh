#!/bin/zsh
# scripts/make-app.sh — builds AiTerm.app into build/.
# Requires: the Swift `.swift-version` pins (managed by Swiftly by default) and python3 >= 3.11 on PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/AiTerm.app"
PY="${PYTHON:-python3}"
# `swift.sh` selects the pinned Swiftly toolchain by default. `SWIFT` remains an override, but its
# version is validated there too.
"$PY" -c 'import sys; assert sys.version_info >= (3, 11), sys.version' || { echo "python3 >= 3.11 required"; exit 1; }

# `--product AiTerm`: the app alone. A plain release build works too, but would also build
# AiTermTestSupport, which a release has no use for. The log is kept: on success only its last line
# is shown, on a failure its last 50, where the compiler's diagnostics are.
mkdir -p "$ROOT/build"
BUILD_LOG="$ROOT/build/swift-build-release.log"
if ! (cd "$ROOT/app" && "$ROOT/scripts/swift.sh" build -c release --product AiTerm >"$BUILD_LOG" 2>&1); then
    tail -50 "$BUILD_LOG" >&2
    print -u2 "swift build failed; the whole log is $BUILD_LOG"
    exit 1
fi
grep -v libSwiftScan "$BUILD_LOG" | tail -1
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/daemon" "$OUT/Contents/Resources/hooks"
cp "$ROOT/app/.build/release/AiTerm" "$OUT/Contents/MacOS/AiTerm"
cp "$ROOT/app/Sources/AiTerm/Resources/Info.plist" "$OUT/Contents/Info.plist"
cp "$ROOT/app/Sources/AiTerm/Resources/AiTerm.icns" "$OUT/Contents/Resources/AiTerm.icns"
# GPL-3.0 asks for a copy with every distribution; it also covers the bundled GPLv2+ iterm2 package.
cp "$ROOT/LICENSE" "$OUT/Contents/Resources/LICENSE"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable AiTerm" "$OUT/Contents/Info.plist"
# Every local build is a dev build: DEV on its Dock icon, no self-update. Only release.sh sets
# AITERM_RELEASE=1.
[[ "${AITERM_RELEASE:-0}" == 1 ]] || /usr/libexec/PlistBuddy -c "Add :AiTermDevBuild bool true" "$OUT/Contents/Info.plist"
"$PY" -m pip install --quiet --no-compile --target "$OUT/Contents/Resources/daemon" "$ROOT/daemon"
find "$OUT/Contents/Resources/daemon" -name '__pycache__' -type d -prune -exec rm -rf {} +
cp "$ROOT/hooks/claude-statusline-shim.sh" "$OUT/Contents/Resources/hooks/"
cp "$ROOT/hooks/pi-aiterm-status.ts" "$OUT/Contents/Resources/hooks/"
chmod +x "$OUT/Contents/Resources/hooks/claude-statusline-shim.sh"
cp "$ROOT/hooks/grok-statusline-shim.sh" "$OUT/Contents/Resources/hooks/"
chmod +x "$OUT/Contents/Resources/hooks/grok-statusline-shim.sh"
# Dev builds are ad-hoc. Releases pass SIGN_IDENTITY="AiTerm Release": a stable identity keeps
# macOS's iTerm2 automation permission across updates, and is what an update is verified against.
codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$OUT"
codesign --verify --deep --strict "$OUT"
echo "built $OUT"
