#!/bin/zsh
# Draw the sidebar, boards, sheets and README fixture with the app's snapshot renderer.
# AITERM_SNAPSHOT_HOSTED=1 uses real windows; native capture also needs screen-capture permission.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/snapshots}"
"$ROOT/scripts/build-app.sh" debug
# Only the images: the folder is the caller's, and may hold anything else (`build`, say).
mkdir -p "$OUT"
find "$OUT" -maxdepth 1 -type f -name '*.png' -delete
AITERM_SNAPSHOT_DIR="$OUT" "$ROOT/app/.build/debug/AiTerm"
