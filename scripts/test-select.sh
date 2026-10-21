#!/bin/zsh
# scripts/test-select.sh < changed-paths — turns the repo-relative paths a change touches (one per
# line on stdin) into the suites worth running, one selector per line, sorted and unique:
#   everything            every suite (printed alone, `toolchain` beside it when a toolchain path chose it)
#   toolchain             the toolchain guard
#   daemon                the daemon's tests and lint
#   target:<Target>       every suite of an AiTermCoreTests, AiTermUITests or AiTermTests target
#   suite:<Target>.<Suite>  one suite (dropped when its target is selected whole)
# The routes live in scripts/test-routes.tsv, which says why each is there. A path takes the union of
# every row it matches; a path no row matches selects `everything`. No output means nothing to run.
set -euo pipefail

ROUTES="$(cd "$(dirname "$0")" && pwd)/test-routes.tsv"
[[ -r "$ROUTES" ]] || { print -u2 "missing routes table: $ROUTES"; exit 1; }

selected=()
# Not `path`: in zsh that variable is tied to PATH.
while IFS= read -r changed; do
    [[ -n "$changed" ]] || continue
    matched=0
    while IFS=$'\t' read -r glob selectors; do
        [[ -n "$glob" && "$glob" != \#* ]] || continue
        if [[ "$changed" == ${~glob} ]]; then
            matched=1
            selected+=(${=selectors})
        fi
    done <"$ROUTES"
    (( matched )) || selected+=(everything)
done

# `none` only marks a path as routed; it selects nothing.
selected=(${selected:#none})
selected=(${(u)selected})

if (( ${selected[(Ie)everything]} )); then
    print -r -- everything
    (( ${selected[(Ie)toolchain]} )) && print -r -- toolchain
    exit 0
fi

# A suite already runs inside its whole target.
for item in $selected; do
    if [[ "$item" == suite:* ]]; then
        target="${${item#suite:}%%.*}"
        (( ${selected[(Ie)target:$target]} )) && continue
    fi
    print -r -- "$item"
done | sort -u
