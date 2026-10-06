#!/bin/zsh
# scripts/snapshots.sh — renders the sidebar and every New Task step to PNGs, offscreen, so the
# implementation can be checked against the design without a screen recorder.
# Text fields and pop-up buttons render as a yellow placeholder: ImageRenderer cannot draw
# AppKit-backed controls, so their *frames* are what these images verify, not their contents.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/snapshots}"
# The log is kept: on success only its last line is shown, on a failure its last 50.
mkdir -p "$ROOT/build"
BUILD_LOG="$ROOT/build/swift-build-debug.log"
if ! (cd "$ROOT/app" && "$ROOT/scripts/swift.sh" build >"$BUILD_LOG" 2>&1); then
    tail -50 "$BUILD_LOG" >&2
    print -u2 "swift build failed; the whole log is $BUILD_LOG"
    exit 1
fi
grep -v libSwiftScan "$BUILD_LOG" | tail -1
AITERM_SNAPSHOT_DIR="$OUT" "$ROOT/app/.build/debug/AiTerm"
