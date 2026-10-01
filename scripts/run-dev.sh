#!/bin/zsh
# scripts/run-dev.sh — builds build/AiTerm.app and runs it in place of whichever AiTerm is open.
# Two AiTerms must never run at once: they share state.json, the daemon socket and the hook port.
# Back to the release: quit this one and open /Applications/AiTerm.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID="com.laurensdhondt.aiterm"
SOCKET="$HOME/Library/Application Support/AiTerm/aitermd.sock"

die() { print -u2 "run-dev: $*"; exit 1; }
running() { pgrep -f '/AiTerm\.app/Contents/MacOS/AiTerm$' >/dev/null; }

"$ROOT/scripts/make-app.sh"

# A normal quit, not a signal: it saves state and stops the daemon the app started.
if running; then
    print "quitting the running AiTerm"
    osascript -e "tell application id \"$ID\" to quit" >/dev/null
    for _ in {1..40}; do running || break; sleep 0.25; done
    running && die "AiTerm is still running; quit it and run this again"
fi
# A daemon with no app is an orphan from a crash. The new app would adopt it and keep serving its
# old code, so it goes too.
if pkill -f "aitermd run --socket $SOCKET" 2>/dev/null; then
    print "stopped an orphaned aitermd"
fi

open "$ROOT/build/AiTerm.app"
