#!/bin/zsh -f
# hooks/agy-statusline-shim.sh — installed as Antigravity CLI's statusLine command by AiTerm.
# 1. forwards the status-line JSON to the AiTerm daemon, whose `agent_state` and
#    `tool_confirmation_pending` check the hooks and say when a tool waits for approval
# 2. runs the person's own status line, if they had one, and prints what it prints; otherwise nothing.
# Antigravity runs this on every change of state, at most every 300 ms, and stops a run after five
# seconds. As Claude Code's shim does, it starts nothing it can avoid: `-f` skips the rc files, stdin
# is read with a builtin, and the hook port (AiTermPaths.hookPortURL) and the person's own command
# (statusline-original-agy.cmd) are plain-text files AgyDriver writes in the support folder. The post
# is not put in the background: agy may stop the run's process group once it prints, and the daemon
# is local, so the wait is short and capped at 300 ms.
set -u
IFS= read -r -d '' INPUT || true
SUPPORT="$HOME/Library/Application Support/AiTerm"
PORT=""
[ -f "$SUPPORT/hook-port" ] && { PORT="$(<"$SUPPORT/hook-port")" 2>/dev/null; }
# Only a port, 1-65535 in digits, goes into the URL: a zsh pattern, so the check forks nothing.
if [[ $PORT == <1-65535> ]]; then
  printf '%s' "$INPUT" | curl -s -m 0.3 -o /dev/null -X POST -H 'Content-Type: application/json' -H 'X-AiTerm-Hook: 1' \
    -H "X-AiTerm-iTerm-Session: ${ITERM_SESSION_ID:-}" -H 'Expect:' --data-binary @- "http://127.0.0.1:$PORT/statusline/agy" >/dev/null 2>&1
fi
ORIG_FILE="$SUPPORT/statusline-original-agy.cmd"
if [ -f "$ORIG_FILE" ]; then
  ORIG_CMD="$(<"$ORIG_FILE")" 2>/dev/null
  if [ -n "$ORIG_CMD" ]; then printf '%s' "$INPUT" | /bin/sh -c "$ORIG_CMD"; exit $?; fi
fi
exit 0
