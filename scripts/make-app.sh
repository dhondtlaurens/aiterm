#!/bin/zsh
# scripts/make-app.sh — builds AiTerm.app into build/.
# Requires: Swift 6.4+ (managed by Swiftly by default) and python3 >= 3.11 on PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/AiTerm.app"
PY="${PYTHON:-python3}"
# `swift.sh` selects the pinned Swiftly toolchain by default. `SWIFT` remains an override, but its
# version is validated there too.
"$PY" -c 'import sys; assert sys.version_info >= (3, 11), sys.version' || { echo "python3 >= 3.11 required"; exit 1; }

(cd "$ROOT/app" && "$ROOT/scripts/swift.sh" build -c release 2>&1 | grep -v libSwiftScan | tail -1)
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
# Signed with "AiTerm Release" whenever that certificate is in the keychain, dev builds included: a
# stable identity keeps macOS's iTerm2 automation permission and the Keychain's "Always Allow"
# across rebuilds and updates, and is what an update is verified against. Without the certificate
# a build is ad-hoc, which macOS sees as a new app every time. SIGN_IDENTITY overrides both.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY=-
    security find-identity -p codesigning | grep -q '"AiTerm Release"' && SIGN_IDENTITY="AiTerm Release"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$OUT"
codesign --verify --deep --strict "$OUT"
echo "built $OUT"
