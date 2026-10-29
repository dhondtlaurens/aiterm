#!/bin/zsh
# scripts/test.sh [changed|all|swift|daemon] [-- <swift test arguments>] — runs AiTerm's automated suites
# with the same validated Swift toolchain as builds.
#   changed (the default) what this checkout's changes since main can affect: its commits, what is
#           staged and unstaged, and new files. scripts/test-select.sh turns those paths into suites
#           (scripts/test-routes.tsv says why each goes where), and this prints them, with the paths
#           that picked each, before it runs them. Nothing a test reads changed: nothing runs. A run
#           that waited for the lock picks again, from what changed while it waited.
#   all     the toolchain guard, the daemon's tests and lint, then every Swift test
#   swift   the toolchain guard and the Swift tests
#   daemon  the daemon's tests and lint
# The toolchain guard is scripts/test-swift-toolchain.sh; `changed` runs it only when the toolchain,
# the manifest or the runner changed, or when it runs everything. The reader guard,
# scripts/test-test-select.sh, runs before every run that tests anything.
# Anything after `--` goes to `swift test`, e.g. `scripts/test.sh swift -- --filter DesignRulesTests`.
# With no suite named (`scripts/test.sh -- --filter X`) the suite is `changed` and the arguments
# replace the Swift tests it picked, running even when it picked none; the daemon and the toolchain
# guard run only if it picked them.
# AITERM_TEST_PATHS, one path per line, stands in for the changed paths (the guard's fixture runs set
# it), and AITERM_TEST_LOGS_KEEP=0 drops a failed run's logs instead of keeping them.
set -euo pipefail
TEST_RUN_ARGS=("$@")

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
DAEMON_VENV="$ROOT/daemon/.venv"
DEFAULT_PYTEST="$DAEMON_VENV/bin/pytest"
PYTEST="${PYTEST:-$DEFAULT_PYTEST}"

usage() { print -u2 "usage: scripts/test.sh [changed|all|swift|daemon] [-- <swift test arguments>]"; exit 2; }
SUITE=changed
if (( $# )) && [[ "$1" != -- ]]; then SUITE="$1"; shift; fi
[[ "$SUITE" == (changed|all|swift|daemon) ]] || usage
SWIFT_ARGS=()
if (( $# )); then
    [[ "$1" == -- ]] || usage
    shift
    SWIFT_ARGS=("$@")
    [[ "$SUITE" != daemon ]] || { print -u2 "swift test arguments need the changed, swift or all suite"; usage; }
fi

# What runs. A filtered Swift run has one target: or suite: selector per filter.
RUN_TOOLCHAIN=0 RUN_DAEMON=0 RUN_SWIFT=0
SWIFT_SELECTORS=()
case "$SUITE" in
    all) RUN_TOOLCHAIN=1 RUN_DAEMON=1 RUN_SWIFT=1 ;;
    swift) RUN_TOOLCHAIN=1 RUN_SWIFT=1 ;;
    daemon) RUN_DAEMON=1 ;;
esac

changes_unlisted() { print -u2 "git could not list the changes since main, so there is no telling what to test."; exit 1; }

# The paths this checkout changed since it left main, into CHANGED: its commits, what is staged and
# unstaged (both sides of a rename, since a test may read either), and files git neither tracks nor
# ignores. Fails when there is no main, or no merge base with it, to compare with. A git that finds
# the merge base and then cannot list the changes stops the run: errexit is off inside a function
# called as a condition, and going on with a partial list could test nothing and pass.
changed_paths() {
    local base committed worktree untracked
    base="$(git -C "$ROOT" merge-base HEAD main 2>/dev/null)" || return 1
    committed="$(git -C "$ROOT" diff --name-only --no-renames -z "$base" HEAD)" || changes_unlisted
    worktree="$(git -C "$ROOT" diff --name-only --no-renames -z HEAD)" || changes_unlisted
    untracked="$(git -C "$ROOT" ls-files --others --exclude-standard -z)" || changes_unlisted
    CHANGED=(${(0)committed} ${(0)worktree} ${(0)untracked})
    CHANGED=(${(u)CHANGED})
}

route_error() { print -u2 "scripts/test-routes.tsv: $1"; exit 1; }

# A selector this script does not know, or one naming a target the package lacks, is an error, never
# skipped: a skipped selector is a run that tested less than it says.
check_swift_selector() {
    local item="$1" rest="${1#*:}" targets
    targets=(${(f)"$(sed -nE 's/.*\.testTarget\(name: "([^"]+)".*/\1/p' "$ROOT/app/Package.swift")"})
    if [[ "$item" == target:* ]]; then
        [[ "$rest" =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]] || route_error "malformed selector $item"
    else
        [[ "$rest" =~ '^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$' ]] || route_error "malformed selector $item, expected suite:<Target>.<Suite>"
    fi
    (( ${targets[(Ie)${rest%%.*}]} )) || route_error "$item names no test target of app/Package.swift"
}

# The changed paths into CHANGED, the selectors they pick into SELECTION, and into WHY one
# `<selector><TAB><path>` per path that picked it. SINCE says where the paths came from; it is empty
# when there is no main to compare with, and then the selection is everything.
select_changed() {
    local selection_output why_output
    CHANGED=() SELECTION=() WHY=()
    if [[ -n "${AITERM_TEST_PATHS+set}" ]]; then
        CHANGED=(${(f)AITERM_TEST_PATHS})
        SINCE="in AITERM_TEST_PATHS"
    elif changed_paths; then
        SINCE="since main"
    else
        SINCE=""
        SELECTION=(everything)
    fi
    if [[ -n "$SINCE" ]]; then
        selection_output="$(print -rl -- $CHANGED | "$ROOT/scripts/test-select.sh")" || exit 1
        why_output="$(print -rl -- $CHANGED | "$ROOT/scripts/test-select.sh" --why)" || exit 1
        SELECTION=(${(f)selection_output})
        WHY=(${(f)why_output})
    fi
}

# What SELECTION runs, into RUN_* and SWIFT_SELECTORS, and says so.
use_selection() {
    local item pair
    RUN_TOOLCHAIN=0 RUN_DAEMON=0 RUN_SWIFT=0
    SWIFT_SELECTORS=()
    for item in $SELECTION; do
        case "$item" in
            everything) RUN_TOOLCHAIN=1 RUN_DAEMON=1 RUN_SWIFT=1 ;;
            toolchain) RUN_TOOLCHAIN=1 ;;
            daemon) RUN_DAEMON=1 ;;
            target:*|suite:*) check_swift_selector "$item"; RUN_SWIFT=1; SWIFT_SELECTORS+=("$item") ;;
            *) route_error "unknown selector $item" ;;
        esac
    done
    # Everything is every Swift test, not a filtered few.
    if (( ${SELECTION[(Ie)everything]} )); then SWIFT_SELECTORS=(); fi
    if (( ${#SWIFT_ARGS} )); then RUN_SWIFT=1; fi

    if [[ -z "$SINCE" ]]; then
        print "No merge base with main to tell what changed, so this runs:"
        print "  everything"
    elif (( ${#SELECTION} )); then
        print -r -- "The changes $SINCE select:"
        for item in $SELECTION; do
            print -r -- "  $item"
            for pair in $WHY; do
                [[ "${pair%%$'\t'*}" != "$item" ]] || print -r -- "      ${pair#*$'\t'}"
            done
        done
    elif (( ${#CHANGED} )); then
        print -r -- "Nothing to test: only ${(j:, :)CHANGED} changed."
    else
        print -r -- "Nothing changed $SINCE."
    fi
    if (( ${#SWIFT_ARGS} )); then
        print -r -- "The Swift tests are the arguments after --: ${SWIFT_ARGS[*]}"
    fi
}

# Chosen before the lock is taken, so a run with nothing to do never waits for one.
if [[ "$SUITE" == changed ]]; then
    select_changed
    use_selection
    (( RUN_TOOLCHAIN || RUN_DAEMON || RUN_SWIFT )) || exit 0
fi

# FIFO admission across worktrees; canceled or crashed waiters release their kernel-locked tickets.
source "$ROOT/scripts/test-queue.sh"

# The build reads the files as they are once the lock is held, so a run that waited picks again from
# what changed meanwhile: an edit made during the wait is built, and its suites must run too. Paths
# named in AITERM_TEST_PATHS cannot have moved. A run that did not wait has had no time to.
if [[ "$SUITE" == changed && -z "${AITERM_TEST_PATHS+set}" ]] && (( WAITED_FOR_LOCK )); then
    picked_before=("${SELECTION[@]}")
    select_changed
    if [[ "${(pj:\n:)SELECTION}" != "${(pj:\n:)picked_before}" ]]; then
        print "What changed moved while this waited, so it picks again."
        use_selection
        (( RUN_TOOLCHAIN || RUN_DAEMON || RUN_SWIFT )) || exit 0
    fi
fi

if (( RUN_TOOLCHAIN )); then
    # Validate first, before spending time on daemon tests with an unusable Swift compiler.
    "$ROOT/scripts/test-swift-toolchain.sh"
fi

# The reader guard: it pins the routing table and fails on a test that reads outside its own target
# with no row to say so. It runs before every run that tests anything, not only with the toolchain:
# a branch that adds such a reader changes only that test's target, which selects no toolchain, so a
# plain run would pass it. Running it only when a test file changed would also catch that, but is one
# more rule that has to stay true; the guard is plain shell and takes about 3 s, little beside any
# suite. The toolchain guard's fixture runs (TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER) skip it: the run that
# started them runs it itself, and running it in each of them tripled the toolchain guard's time.
if [[ "${TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER:-0}" != 1 ]]; then
    "$ROOT/scripts/test-test-select.sh"
fi

# The daemon's tests, then its lint.
daemon_suite() {
    if [[ ! -x "$PYTEST" ]]; then
        if [[ "$PYTEST" != "$DEFAULT_PYTEST" ]]; then
            print -u2 "Configured pytest is not executable: $PYTEST"
            exit 1
        fi

        "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 11))' || { print -u2 "python3 >= 3.11 required"; exit 1; }
        print "Daemon test environment is missing; creating $DAEMON_VENV"
        "$PYTHON" -m venv "$DAEMON_VENV"
        # App launches may export a bundled daemon on PYTHONPATH. It must not satisfy
        # this venv's dependencies or shadow the checkout under test.
        env -u PYTHONPATH "$DAEMON_VENV/bin/python" -m pip install --quiet --disable-pip-version-check -e "$ROOT/daemon[dev]"
    fi
    (cd "$ROOT/daemon" && env -u PYTHONPATH "$PYTEST" -q)
    # The daemon's lint: types across the package, the tests and the tools (FakeIterm is checked against the
    # ItermPort it stands in for), then ruff. Both come with the venv's `dev` extra, and are always the
    # venv's, not tools beside a PYTEST override: that need not be in a venv (the toolchain guard passes
    # /usr/bin/true).
    for tool in mypy ruff; do
        if [[ ! -x "$DAEMON_VENV/bin/$tool" ]]; then
            print -u2 "$tool is missing from $DAEMON_VENV; install the dev extra: $DAEMON_VENV/bin/python -m pip install -e '$ROOT/daemon[dev]'"
            exit 1
        fi
    done
    (cd "$ROOT/daemon" && env -u PYTHONPATH "$DAEMON_VENV/bin/mypy" aitermd tests tools && env -u PYTHONPATH "$DAEMON_VENV/bin/ruff" check aitermd tests tools)
}

if (( RUN_DAEMON )); then daemon_suite; fi
if (( ! RUN_SWIFT )); then exit 0; fi

# In TMPDIR, as the toolchain guard expects: macOS's `mktemp -t` would use the user's temp directory
# whatever TMPDIR says.
TEST_LOGS="$(mktemp -d "${TMPDIR:-/tmp}/aiterm-test.XXXXXX")"

# `swift test` exits 0 on a run that never finished: a host that dies mid-run
# (a modal alert once ended one's run loop), and a --filter that matches nothing
# is only a warning. Neither shows in the exit status, so a pass is green only if it also
# printed what swift-testing prints when a run reaches its end -- one
# "Test run with N tests ... passed" line per test host that got there -- and, for each suite it
# was asked for by name, that suite's "Suite <Suite> passed" line.
swift_test() {
    local label="$1" expect_runs="$2" expect_suites="$3"
    shift 3
    local log rc runs passed tests suite
    log="$TEST_LOGS/$label.log"

    set +e
    # Hundreds of main-actor fixture setups can otherwise queue ahead of a test's awaited work.
    # Swift 6.4's Testing runtime owns case concurrency; SwiftPM's --num-workers is XCTest-only.
    (cd "$ROOT/app" && SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-4}" \
        "$ROOT/scripts/swift.sh" test "$@") 2>&1 | tee "$log"
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
        print -u2 "  A host that dies before its run ends still exits 0, and so does one its filter matches nothing in. See $log."
        return 1
    fi
    if [[ "$runs" -eq 0 ]]; then
        print -u2 "$label pass: no test host finished a run. A filter that matches nothing still exits 0. See $log."
        return 1
    fi
    if [[ "$tests" -eq 0 ]]; then
        print -u2 "$label pass: no tests ran. A filter that matches nothing still exits 0. See $log."
        return 1
    fi
    if [[ "$passed" -ne "$runs" ]]; then
        print -u2 "$label pass: a test host reported its run as failed. See $log."
        return 1
    fi
    for suite in ${=expect_suites}; do
        if ! grep -Fq "Suite $suite passed " "$log"; then
            print -u2 "$label pass: suite $suite did not report passing. A suite filter that matches nothing still exits 0. See $log."
            return 1
        fi
    done
}

# One host per test target, so that is what a full run must report; pinning its test count instead
# would churn on every test added. No test raises a real modal alert — the app's questions go
# through a `Prompter` that tests script, and the test controller's default one fails the test on a
# question nobody scripted — so no test needs a pass of its own for that. (AiTermTestSupport is a
# library, not a test target: it adds no host.)
# A run filtered to selectors (^<Target>\. for a target, ^<Target>\.<Suite>/ for a suite: Swift
# Testing's IDs read AiTermCoreTests.ReleaseFeedTests/missingFeedIsNoFeed()) reports only the hosts
# its filters reach. Measured on Swift 6.4: a host the filters match nothing in prints no "Test run
# with" line at all, not one with 0 tests, so filters on a Core and a UI suite printed two, none for
# AiTermTests. Every selector names a target with tests in it, so the run must report exactly one
# line per distinct target the selectors name, and each named suite its own passing line.
# The snapshot suites run in a pass of their own, after the rest (SNAPSHOT_SUITES says why); a run
# that reaches none of them has no such pass.
# Arguments after `--` narrow the run to hosts that are not known beforehand, so it is green when at
# least one finished and every one that did passed. They run as given, in one pass.
swift_suite() {
    if (( ${#SWIFT_ARGS} )); then
        swift_test main '' '' "${SWIFT_ARGS[@]}"
        return
    fi
    local item rest filters=() targets=() suites=() skips=() snapshots=()
    for item in $SNAPSHOT_SUITES; do skips+=(--skip "^${item%%.*}\\.${item#*.}/"); done
    if (( ${#SWIFT_SELECTORS} )); then
        for item in $SWIFT_SELECTORS; do
            rest="${item#*:}"
            if (( ${SNAPSHOT_SUITES[(Ie)$rest]} )); then
                snapshots+=("$rest")
                continue
            fi
            targets+=("${rest%%.*}")
            if [[ "$item" == suite:* ]]; then
                suites+=("${rest#*.}")
                filters+=(--filter "^${rest%%.*}\\.${rest#*.}/")
            else
                filters+=(--filter "^$rest\\.")
                snapshots+=(${(M)SNAPSHOT_SUITES:#$rest.*})
            fi
        done
        targets=(${(u)targets})
        if (( ${#filters} )); then
            swift_test main "${#targets}" "${suites[*]}" "${filters[@]}" "${skips[@]}" || return 1
        fi
    else
        swift_test main "$(grep -c '\.testTarget(' "$ROOT/app/Package.swift")" '' "${skips[@]}" || return 1
        snapshots=($SNAPSHOT_SUITES)
    fi

    snapshots=(${(u)snapshots})
    (( ${#snapshots} )) || return 0
    filters=() targets=() suites=()
    for item in $snapshots; do
        targets+=("${item%%.*}")
        suites+=("${item#*.}")
        filters+=(--filter "^${item%%.*}\\.${item#*.}/")
    done
    targets=(${(u)targets})
    swift_test snapshots "${#targets}" "${suites[*]}" "${filters[@]}"
}

# The snapshot suites, as <Target>.<Suite>: every suite named *SnapshotTests, a struct, class, actor or enum whatever
# its attributes and access. They draw each image
# twice and hold the two to the same bytes. Beside suites that host windows, the setup sheet's AppKit
# stand-ins drew one colour level apart from one drawing to the next, so they run apart from every
# other suite rather than with a looser comparison.
SNAPSHOT_SUITES=(${(f)"$( (cd "$ROOT/app/Tests" 2>/dev/null && grep -rEo '\b(struct|class|actor|enum) [A-Za-z0-9_]+SnapshotTests\b' .) \
    | sed -E 's|^\./([^/]+)/[^:]*:[a-z]+ ([A-Za-z0-9_]+)$|\1.\2|' | sort -u)"})

# The preferences domains naming AiTerm, one file name per line. A test's UserDefaults suite named
# like an app lands in ~/Library/Preferences and stays there, if only as an empty plist
# (ScratchDefaults says why), so a domain that appears during the Swift pass fails it. Only those
# naming AiTerm: other apps make domains of their own during a run that takes minutes.
# AITERM_TEST_PREFERENCES stands in for the folder.
PREFERENCES="${AITERM_TEST_PREFERENCES:-$HOME/Library/Preferences}"
aiterm_domains() {
    setopt local_options extended_glob
    print -rl -- $PREFERENCES/(#i)*aiterm*.plist(N:t)
}
domains_before=(${(f)"$(aiterm_domains)"})
domains_left() {
    local domain left=()
    for domain in ${(f)"$(aiterm_domains)"}; do
        (( ${domains_before[(Ie)$domain]} )) || left+=("$domain")
    done
    (( ${#left} )) || return 0
    print -u2 "The tests left preferences domains in $PREFERENCES: ${(j:, :)left}"
    print -u2 "  A suite named like an app lands there; a test's defaults come from ScratchDefaults.make()."
    return 1
}

# A failed run keeps its logs and says where, unless told not to (the toolchain guard's fixture runs
# fail on purpose). Not in an EXIT trap: zsh runs none when errexit ends the script from inside a
# function, as a failed pass does.
swift_passed=1
swift_suite || swift_passed=0
domains_left || swift_passed=0
if (( swift_passed )); then
    rm -rf "$TEST_LOGS"
elif [[ "${AITERM_TEST_LOGS_KEEP:-1}" == 0 ]]; then
    rm -rf "$TEST_LOGS"
    exit 1
else
    print -u2 "Swift test logs kept in $TEST_LOGS"
    exit 1
fi
