#!/bin/zsh
# scripts/compat-check.sh [claude,codex,pi] — after Claude Code, Codex or PI updates: does AiTerm still
# work with it? Run from a worktree with iTerm2 open; it takes several minutes, opens iTerm2 windows
# and spends a little of each CLI's quota on its cheapest model. Never part of the gate.
#
#   1. Captures each CLI live (daemon/tools/compat_capture.py): its hooks, status line, session and
#      transcript files, model lists, --help and headless answers, scrubbed of anything private, into
#      daemon/tests/fixtures/compat/<agent>/ in place of the last capture.
#   2. Runs the delivery check for Claude Code and Codex, which writes Messaging's verdict for the
#      versions installed, and reads that verdict back: its exit code says nothing.
#   3. Runs the contract suites over the captures: tests/test_compat_captures.py and the Swift
#      CompatContractTests and CompatTranscriptTests.
#   4. Only when all three passed, records each CLI's major and minor in compat/verified.json, which
#      the app bundles for each Settings › Agents card's line.
#
# It commits nothing: review the capture's diff (what the CLI changed) and commit it with the list.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="${1:-claude,codex,pi}"
PY="$ROOT/daemon/.venv/bin/python"
[[ -x "$PY" ]] || { print -u2 "No daemon venv at $ROOT/daemon/.venv: run scripts/test.sh daemon once to create it"; exit 2; }
work="$(mktemp -d -t aiterm-compat-check)"
trap 'rm -rf "$work"' EXIT
versions="$work/versions.json"
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
failed=()

print "1/4 Capturing $AGENTS"
(cd "$ROOT/daemon" && env -u PYTHONPATH "$PY" -m tools.compat_capture capture --agents "$AGENTS" --written "$versions") \
    || failed+=("capture")
[[ -s "$versions" ]] || { print -u2 "Nothing was captured."; exit 1; }

# The CLIs AiTerm types into, among those asked for.
messaged=()
for agent in claude codex; do
    if [[ ",$AGENTS," == *",$agent,"* ]]; then messaged+=("$agent"); fi
done
if (( ${#messaged} )); then
    print "2/4 Delivery check for ${(j:, :)messaged}"
    (cd "$ROOT/daemon" && env -u PYTHONPATH "$PY" -m tools.delivery_check --agents "${(j:,:)messaged}" --skip-iterm --write) \
        || failed+=("delivery check")
    (cd "$ROOT/daemon" && env -u PYTHONPATH "$PY" -m tools.compat_capture gate --versions "$versions" --since "$since" \
        --policy "$HOME/Library/Application Support/AiTerm/delivery-policy.json") || failed+=("messaging")
else
    print "2/4 No CLI captured that AiTerm messages"
fi

print "3/4 Contract suites"
(cd "$ROOT/daemon" && env -u PYTHONPATH "$ROOT/daemon/.venv/bin/pytest" -q tests/test_compat_captures.py) || failed+=("daemon contract")
"$ROOT/scripts/test.sh" swift -- --filter 'Compat(Contract|Transcript)Tests' || failed+=("Swift contract")

if (( ${#failed} )); then
    print -u2 "4/4 Not verified: ${(j:, :)failed} failed. compat/verified.json is unchanged."
    print -u2 "The capture's diff shows what the CLI changed: git diff --stat daemon/tests/fixtures/compat"
    exit 1
fi
(cd "$ROOT/daemon" && env -u PYTHONPATH "$PY" -m tools.compat_capture verified --versions "$versions")
print "4/4 Verified: $(cat "$versions" | tr -d '\n ')"
git -C "$ROOT" diff --stat -- daemon/tests/fixtures/compat compat/verified.json
print "Review the diff, then commit the captures with compat/verified.json."
