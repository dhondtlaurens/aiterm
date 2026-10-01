#!/bin/zsh
# hooks/claude-statusline-shim.sh — installed as Claude Code's statusLine command by AiTerm.
# 1. forwards the statusline JSON to the AiTerm daemon (fire and forget, 300 ms cap)
# 2. preserves a previously configured status line, otherwise prints nothing.
# The statusLine callback supplies the usage payload. AiTerm uses it as a telemetry bridge,
# without adding its own terminal display or requiring a display preference.
# Claude Code runs this on every tick, so it starts nothing it can avoid: the port is the app's
# fixed hook port (AiTermPaths.hookPort), and HookInstaller saves the original command as plain text.
# The redirection wraps the whole backgrounded pipeline, not just curl: a redirection written after
# only the last command leaves printf's stderr pointed at this script's own — a grandchild holding
# that pipe open past the parent's exit, exactly the pattern ProcessRunner.swift warns about.
set -u
INPUT="$(cat)"
SUPPORT="$HOME/Library/Application Support/AiTerm"
{ printf '%s' "$INPUT" | curl -s -m 0.3 -X POST -H 'Content-Type: application/json' -H 'X-AiTerm-Hook: 1' -H 'Expect:' --data-binary @- "http://127.0.0.1:47821/statusline"; } >/dev/null 2>&1 &
ORIG_FILE="$SUPPORT/statusline-original.cmd"
if [ -f "$ORIG_FILE" ]; then
  ORIG_CMD="$(<"$ORIG_FILE")" 2>/dev/null
  if [ -n "$ORIG_CMD" ]; then printf '%s' "$INPUT" | /bin/zsh -c "$ORIG_CMD"; exit $?; fi
fi
exit 0
