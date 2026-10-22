#!/bin/zsh
# Compiler boundary fixture for the test runner's completion checks; never builds source.
# With AITERM_FIXTURE_CALLS set, each `swift test` appends its arguments there as one line.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
case "$1" in
    --version) print "Swift version $(cat "$ROOT/.swift-version")" ;;
    package)
        case "${@: -1}" in
            tools-version) print "$(sed -nE 's/^([0-9]+\.[0-9]+).*/\1.0/p' "$ROOT/.swift-version")" ;;
            dump-package) print '{}' ;;
            *) exit 2 ;;
        esac ;;
    test)
        [[ -z "${AITERM_FIXTURE_CALLS:-}" ]] || print -r -- "swift $*" >>"$AITERM_FIXTURE_CALLS"
        # A real filtered run prints one `Test run` line per test host its filters reach, and a
        # `Suite` line per suite: a filter like ^Target\. reaches that target's host, and one like
        # ^Target\.Suite/ that suite too. Any other filter stands for a single host.
        hosts=() suites=()
        for arg in "$@"; do
            if [[ "$arg" =~ '^\^([A-Za-z0-9_]+)\\\.(([A-Za-z0-9_]+)/)?$' ]]; then
                hosts+=("$match[1]")
                [[ -z "$match[3]" ]] || suites+=("$match[3]")
            fi
        done
        (( ${#hosts} )) || hosts=(one)
        hosts=(${(u)hosts})
        # `nosuite` leaves the suite lines out and `onehost` every host but the first.
        run="${AITERM_FIXTURE_TEST_RUN:-passed}"
        case "$run" in
            passed|nosuite|onehost)
                [[ "$run" != onehost ]] || hosts=("$hosts[1]")
                [[ "$run" == nosuite ]] || for suite in $suites; do print "✔ Suite $suite passed after 0.001 seconds."; done
                for host in $hosts; do print '✔ Test run with 1 test passed after 0.001 seconds.'; done ;;
            zero) print '✔ Test run with 0 tests passed after 0.001 seconds.' ;;
            incomplete) print '◇ Test run started.' ;;
            failed) print '✘ Test run with 1 test failed after 0.001 seconds.' ;;
            nonzero) print '✔ Test run with 1 test passed after 0.001 seconds.'; exit 1 ;;
            *) exit 2 ;;
        esac ;;
    *) exit 2 ;;
esac
