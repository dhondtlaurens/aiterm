#!/bin/zsh
# scripts/test-test-select.sh — guards scripts/test-select.sh and its table, scripts/test-routes.tsv:
# each case names the paths a change touches and the selectors the table must turn them into.
# A wrong route is silent (a suite that should have run just does not), so every row of the table
# that carries a decision is pinned here. Add a case with `check`; no build is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELECT="$ROOT/scripts/test-select.sh"

[[ -x "$SELECT" ]] || { print -u2 "missing selector: $SELECT"; exit 1; }

# check <name> <expected selectors…> -- <changed paths…>
# Pipes the paths, one per line, into the selector and compares what it prints with the expected
# selectors, which come out sorted. No paths after `--` is an empty change.
check() {
    local name="$1"
    shift
    local expected=()
    while (( $# )) && [[ "$1" != -- ]]; do expected+=("$1"); shift; done
    (( $# )) || { print -u2 "check '$name' needs a -- before its paths"; exit 2; }
    shift
    local want got
    want="$(print -rl -- "${(@o)expected}")"
    (( ${#expected} )) || want=""
    got="$( { (( $# )) && print -rl -- "$@" || true } | "$SELECT" )"
    if [[ "$got" != "$want" ]]; then
        print -u2 "FAIL $name"
        print -u2 "  expected: ${want//$'\n'/ }"
        print -u2 "  got:      ${got//$'\n'/ }"
        exit 1
    fi
    print "ok   $name"
}

check "docs only runs nothing" -- docs/architecture.md README.md
check "daemon code runs the daemon" daemon -- daemon/aitermd/service.py
check "wire fixtures add the wire contract" daemon suite:AiTermCoreTests.WireContractTests -- daemon/tests/wire/manifest.json
check "core runs every swift target" target:AiTermCoreTests target:AiTermTests target:AiTermUITests -- app/Sources/AiTermCore/Models.swift
check "app code adds the design rules" suite:AiTermUITests.DesignRulesTests target:AiTermTests -- app/Sources/AiTerm/AppController.swift
check "a suite inside a selected target is dropped" target:AiTermTests target:AiTermUITests -- app/Sources/AiTerm/AppController.swift app/Tests/AiTermUITests/SelectTests.swift
check "the plist adds the release feed" suite:AiTermCoreTests.ReleaseFeedTests suite:AiTermUITests.DesignRulesTests target:AiTermTests -- app/Sources/AiTerm/Resources/Info.plist
check "hooks run the daemon and the shim" daemon suite:AiTermCoreTests.StatusLineShimTests -- hooks/claude-statusline-shim.sh
check "the toolchain runs everything" everything toolchain -- .swift-version
check "an unknown path runs everything" everything -- Makefile
check "a rename routes both sides" daemon target:AiTermTests -- app/Tests/AiTermTests/A.swift daemon/b.py
check "no paths runs nothing" --

print "test selector guard passed"
