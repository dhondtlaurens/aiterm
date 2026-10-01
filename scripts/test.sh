#!/bin/zsh
# Runs every automated suite with the same validated Swift toolchain as builds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
DAEMON_VENV="$ROOT/daemon/.venv"
DEFAULT_PYTEST="$DAEMON_VENV/bin/pytest"
PYTEST="${PYTEST:-$DEFAULT_PYTEST}"

# Validate first, before spending time on daemon tests with an unusable Swift compiler.
TEST_SWIFT_TOOLCHAIN_SKIP_AGGREGATE=1 "$ROOT/scripts/test-swift-toolchain.sh"
"$ROOT/scripts/swift.sh" --version >/dev/null

if [[ ! -x "$PYTEST" ]]; then
    if [[ "$PYTEST" != "$DEFAULT_PYTEST" ]]; then
        print -u2 "Configured pytest is not executable: $PYTEST"
        exit 1
    fi

    print "Daemon test environment is missing; creating $DAEMON_VENV"
    "$PYTHON" -m venv "$DAEMON_VENV"
    # App launches may export a bundled daemon on PYTHONPATH. It must not satisfy
    # this venv's dependencies or shadow the checkout under test.
    env -u PYTHONPATH "$DAEMON_VENV/bin/python" -m pip install --quiet --disable-pip-version-check -e "$ROOT/daemon[dev]"
fi
(cd "$ROOT/daemon" && env -u PYTHONPATH "$PYTEST" -q)
# The daemon's lint: types across the package and the tests (FakeIterm is checked against the
# ItermPort it stands in for), then ruff. Both come with the venv's `dev` extra, and are always the
# venv's, not tools beside a PYTEST override: that need not be in a venv (the toolchain guard passes
# /usr/bin/true).
for tool in mypy ruff; do
    if [[ ! -x "$DAEMON_VENV/bin/$tool" ]]; then
        print -u2 "$tool is missing from $DAEMON_VENV; install the dev extra: $DAEMON_VENV/bin/python -m pip install -e '$ROOT/daemon[dev]'"
        exit 1
    fi
done
(cd "$ROOT/daemon" && env -u PYTHONPATH "$DAEMON_VENV/bin/mypy" aitermd tests && env -u PYTHONPATH "$DAEMON_VENV/bin/ruff" check aitermd tests)

TEST_LOGS="$(mktemp -d -t aiterm-test)"
trap 'if [[ $? -eq 0 ]]; then rm -rf "$TEST_LOGS"; else print -u2 "Swift test logs kept in $TEST_LOGS"; fi' EXIT

# `swift test` exits 0 on a run that never finished: a host that dies mid-run
# (a modal alert once ended one's run loop), and a --filter that matches nothing
# is only a warning. Neither shows in the exit status, so a pass is green only if it also
# printed what swift-testing prints when a run reaches its end -- one
# "Test run with N tests ... passed" line per test host that got there.
swift_test() {
    local label="$1" expect_runs="$2" expect_tests="$3"
    shift 3
    local log rc runs passed tests
    log="$TEST_LOGS/$label.log"

    set +e
    (cd "$ROOT/app" && "$ROOT/scripts/swift.sh" test "$@") 2>&1 | tee "$log"
    rc=${pipestatus[1]}
    set -e
    if [[ "$rc" -ne 0 ]]; then
        print -u2 "$label pass: swift test exited $rc."
        return "$rc"
    fi

    runs=$(grep -cE 'Test run with [0-9]+ test' "$log" || true)
    passed=$(grep -cE 'Test run with [0-9]+ test.* passed ' "$log" || true)
    tests=$(sed -nE 's/.*Test run with ([0-9]+) test.*/\1/p' "$log" | awk '{ n += $1 } END { print n + 0 }')

    if [[ -n "$expect_runs" && "$runs" -ne "$expect_runs" ]]; then
        print -u2 "$label pass: $runs test hosts finished their run, expected $expect_runs."
        print -u2 "  A host that dies before its run ends still exits 0. See $log."
        return 1
    fi
    if [[ -n "$expect_tests" && "$tests" -ne "$expect_tests" ]]; then
        print -u2 "$label pass: ran $tests tests, expected $expect_tests."
        print -u2 "  A truncated run, or a filter that no longer matches, still exits 0. See $log."
        return 1
    fi
    if [[ "$passed" -ne "$runs" ]]; then
        print -u2 "$label pass: a test host reported its run as failed. See $log."
        return 1
    fi
}

# One host per test target, so that is what the run must report; pinning its test count instead
# would churn on every test added. No test raises a real modal alert — the app's questions go
# through a `Prompter` that tests script — so every test runs in this one pass.
swift_test main "$(grep -c '\.testTarget(' "$ROOT/app/Package.swift")" ''
