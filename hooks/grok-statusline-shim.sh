#!/bin/zsh
# hooks/grok-statusline-shim.sh — installed as Grok Build's [ui.status_line] command by AiTerm.
# 1. forwards the status-line JSON to the AiTerm daemon (300 ms cap): Grok's status line is the
#    only place it reports how full a session's context window is;
# 2. runs the status line the user had before, otherwise prints nothing (Grok then hides the row).
# Same recipe as claude-statusline-shim.sh, including why the redirection wraps the whole
# backgrounded pipeline, with one difference: Grok kills whatever a status-line script leaves
# running once it exits (25-status-line.md, "Background work does not survive"), so the post runs
# beside the original command but is waited for on every path. curl's -m 0.3 still bounds it, well
# inside Grok's 10 s timeout. ${ITERM_SESSION_ID-} keeps `set -u` from aborting outside iTerm2.
# (The no-`${` rule is for Grok hook commands, which Grok parses; this script is only run by it.)
set -u
INPUT="$(cat)"
SUPPORT="$HOME/Library/Application Support/AiTerm"
{ printf '%s' "$INPUT" | curl -s -m 0.3 -X POST -H 'Content-Type: application/json' -H 'X-AiTerm-Hook: 1' -H "X-AiTerm-iTerm-Session: ${ITERM_SESSION_ID-}" -H 'Expect:' --data-binary @- "http://127.0.0.1:47821/statusline/grok"; } >/dev/null 2>&1 &
POST=$!
ORIG_FILE="$SUPPORT/grok-statusline-original.cmd"
if [ -f "$ORIG_FILE" ]; then
  ORIG_CMD="$(<"$ORIG_FILE")" 2>/dev/null
  if [ -n "$ORIG_CMD" ]; then printf '%s' "$INPUT" | /bin/zsh -c "$ORIG_CMD"; STATUS=$?; wait $POST; exit $STATUS; fi
fi
wait $POST
exit 0
