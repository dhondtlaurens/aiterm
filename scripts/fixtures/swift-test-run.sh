#!/bin/zsh
# Compiler boundary fixture for the test runner's completion checks; never builds source.
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
        case "${AITERM_FIXTURE_TEST_RUN:-passed}" in
            passed) print '✔ Test run with 1 test passed after 0.001 seconds.' ;;
            zero) print '✔ Test run with 0 tests passed after 0.001 seconds.' ;;
            incomplete) print '◇ Test run started.' ;;
            failed) print '✘ Test run with 1 test failed after 0.001 seconds.' ;;
            nonzero) print '✔ Test run with 1 test passed after 0.001 seconds.'; exit 1 ;;
            *) exit 2 ;;
        esac ;;
    *) exit 2 ;;
esac
