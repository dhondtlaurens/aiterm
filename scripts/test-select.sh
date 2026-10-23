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
# scripts/test-select.sh --why < changed-paths prints instead, for each path, one `<selector><TAB><path>`
# line per selector that path picks by itself (in input order, none dropped), so scripts/test.sh can
# say which paths chose what.
set -euo pipefail

ROUTES="$(cd "$(dirname "$0")" && pwd)/test-routes.tsv"
[[ -r "$ROUTES" ]] || { print -u2 "missing routes table: $ROUTES"; exit 1; }
why=0
if [[ "${1:-}" == --why ]]; then why=1; shift; fi
(( $# == 0 )) || { print -u2 "usage: scripts/test-select.sh [--why] < changed-paths"; exit 2; }

# Read and validate the table once, before matching any changed paths.
globs=() routes=()
while IFS=$'\t' read -r glob selectors; do
    [[ -n "$glob" && "$glob" != \#* ]] || continue
    [[ -n "${selectors//[[:space:]]/}" ]] || { print -u2 "scripts/test-routes.tsv: the row for $glob names no selectors"; exit 1; }
    globs+=("$glob"); routes+=("$selectors")
done <"$ROUTES"

selected=()
# Not `path`: in zsh that variable is tied to PATH.
# `|| [[ -n ... ]]` keeps a last path with no trailing newline: read fails on it but has filled the variable.
while IFS= read -r changed || [[ -n "$changed" ]]; do
    [[ -n "$changed" ]] || continue
    matched=0
    picked=()
    for (( i = 1; i <= ${#globs}; i++ )); do
        if [[ "$changed" == ${~globs[i]} ]]; then
            matched=1
            picked+=(${=routes[i]})
        fi
    done
    (( matched )) || picked+=(everything)
    if (( why )); then
        for item in ${(u)picked:#none}; do print -r -- "$item"$'\t'"$changed"; done
    fi
    selected+=($picked)
done
(( why )) && exit 0

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
