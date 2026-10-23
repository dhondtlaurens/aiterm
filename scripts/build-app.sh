#!/bin/zsh
# Build only the app, keeping the full log and showing diagnostics on failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"
[[ "$configuration" == (debug|release) ]] || { print -u2 'usage: scripts/build-app.sh [debug|release]'; exit 2; }
mkdir -p "$ROOT/build"
BUILD_LOG="$ROOT/build/swift-build-$configuration.log"
build_arguments=()
[[ "$configuration" == debug ]] || build_arguments=(-c release)
if ! (cd "$ROOT/app" && "$ROOT/scripts/swift.sh" build $build_arguments --product AiTerm >"$BUILD_LOG" 2>&1); then
    tail -50 "$BUILD_LOG" >&2
    print -u2 "swift build failed; the whole log is $BUILD_LOG"
    exit 1
fi
grep -v libSwiftScan "$BUILD_LOG" | tail -1
