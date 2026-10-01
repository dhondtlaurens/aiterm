#!/bin/zsh
# scripts/snapshots.sh — renders the sidebar and every New Task step to PNGs, offscreen, so the
# implementation can be checked against the design without a screen recorder.
# Text fields and pop-up buttons render as a yellow placeholder: ImageRenderer cannot draw
# AppKit-backed controls, so their *frames* are what these images verify, not their contents.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/snapshots}"
(cd "$ROOT/app" && "$ROOT/scripts/swift.sh" build 2>&1 | grep -v libSwiftScan | tail -1)
AITERM_SNAPSHOT_DIR="$OUT" "$ROOT/app/.build/debug/AiTerm"
