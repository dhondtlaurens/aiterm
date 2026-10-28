#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A toolchain that reports whatever version AITERM_FIXTURE_SWIFT_VERSION names.
OTHER_SWIFT="$ROOT/scripts/fixtures/swift-version.sh"
GOOD_SWIFT="${SWIFT:-$HOME/.swiftly/bin/swift}"
PINNED_VERSION="$(sed -nE 's/^([0-9]+\.[0-9]+).*/\1/p' "$ROOT/.swift-version")"

[[ -x "$OTHER_SWIFT" ]] || { print -u2 "missing fixture: $OTHER_SWIFT"; exit 1; }
[[ -x "$GOOD_SWIFT" ]] || { print -u2 "missing Swift toolchain: $GOOD_SWIFT (install with ~/.swiftly/bin/swiftly install --use $PINNED_VERSION)"; exit 1; }
[[ -n "$PINNED_VERSION" ]] || { print -u2 "missing major.minor version in $ROOT/.swift-version"; exit 1; }
# A release either side of the pin: neither is the toolchain the release is built with.
pinned_major="${PINNED_VERSION%%.*}" pinned_minor="${PINNED_VERSION#*.}"
if (( pinned_minor > 0 )); then
    OLDER_VERSION="$pinned_major.$(( pinned_minor - 1 ))"
else
    OLDER_VERSION="$(( pinned_major - 1 )).10"
fi
NEWER_VERSION="$pinned_major.$(( pinned_minor + 1 ))"

bad_output="$(mktemp)"
trap 'rm -f "$bad_output"' EXIT
fail() { print -u2 -- "$1"; sed -n '1,30p' "$bad_output" >&2; exit 1; }
for other in "$OLDER_VERSION" "$NEWER_VERSION"; do
    if AITERM_FIXTURE_SWIFT_VERSION="$other" SWIFT="$OTHER_SWIFT" "$ROOT/scripts/swift.sh" --version >"$bad_output" 2>&1; then
        print -u2 "expected Swift $other to be rejected"
        exit 1
    fi
    grep -Fq "AiTerm requires Swift $PINNED_VERSION. Found: $other" "$bad_output" || fail "expected the pinned-toolchain diagnostic for Swift $other"
done

good_output="$(SWIFT="$GOOD_SWIFT" "$ROOT/scripts/swift.sh" --version)"
[[ "$good_output" == *"Swift version $PINNED_VERSION"* ]] || {
    print -u2 "expected pinned Swift $PINNED_VERSION to be accepted"
    exit 1
}

package_tools_version="$(SWIFT="$GOOD_SWIFT" "$ROOT/scripts/swift.sh" package --package-path "$ROOT/app" tools-version)"
[[ "$package_tools_version" == "$PINNED_VERSION.0" ]] || {
    print -u2 "expected app package to require Swift tools $PINNED_VERSION.0, found $package_tools_version"
    exit 1
}

manifest_diagnostics=""
if ! manifest_diagnostics="$(SWIFT="$GOOD_SWIFT" "$ROOT/scripts/swift.sh" package --package-path "$ROOT/app" dump-package 2>&1 >/dev/null)"; then
    print -u2 "expected the app package manifest to load with the pinned Swift toolchain"
    print -u2 -- "$manifest_diagnostics"
    exit 1
fi
if print -r -- "$manifest_diagnostics" | grep -Eq '(^|[[:space:]])(warning|error):'; then
    print -u2 "expected the app package manifest to load without compiler diagnostics"
    print -u2 -- "$manifest_diagnostics"
    exit 1
fi

# Exercise the runner without a real build: empty, unfinished, failed and nonzero runs
# must fail even when the compiler process reports success. Avoid recursing through this guard.
# A fixture run keeps no logs (AITERM_TEST_LOGS_KEEP=0): the failures here are meant, and the runs
# that do not set TMPDIR would otherwise leave them in the user's temp directory on every guard run.
if [[ "${TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER:-0}" != "1" ]]; then
    "$ROOT/scripts/fixtures/check-bundle-verifier.sh"
    "$ROOT/scripts/fixtures/check-build-scripts.sh"
    (
        runner_logs="$(mktemp -d -t aiterm-runner-fixture)"
        trap 'touch "$runner_logs/release"; wait || true; rm -rf "$runner_logs"' EXIT
        export AITERM_TEST_LOGS_KEEP=0
        logs_before=(${TMPDIR:-/tmp}/aiterm-test.*(N/))
        for result in passed zero incomplete failed nonzero; do
            runner_status=0
            TMPDIR="$runner_logs/" TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER=1 AITERM_FIXTURE_TEST_RUN="$result" \
                SWIFT="$ROOT/scripts/fixtures/swift-test-run.sh" "$ROOT/scripts/test.sh" swift -- --filter fixture \
                >"$bad_output" 2>&1 || runner_status=$?
            if [[ "$result" == passed && "$runner_status" -ne 0 ]] || \
               [[ "$result" != passed && "$runner_status" -eq 0 ]]; then
                fail "unexpected test-runner status $runner_status for $result fixture"
            fi
        done

        # A domain naming AiTerm that a passing run leaves in the preferences fails it; one that was
        # there before, and one of another app's, do not.
        preferences="$runner_logs/preferences"
        mkdir -p "$preferences"
        print -n >"$preferences/com.laurensdhondt.aiterm.plist"
        preferences_run() {
            runner_status=0
            AITERM_TEST_PREFERENCES="$preferences" TMPDIR="$runner_logs/" TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER=1 \
                AITERM_FIXTURE_TEST_RUN="$1" SWIFT="$ROOT/scripts/fixtures/swift-test-run.sh" \
                "$ROOT/scripts/test.sh" swift -- --filter fixture >"$bad_output" 2>&1 || runner_status=$?
        }
        preferences_run passed
        [[ "$runner_status" -eq 0 ]] || fail "expected a domain that was there before the run to pass it"
        preferences_run leaks
        if [[ "$runner_status" -eq 0 ]] || \
           ! grep -Fxq "The tests left preferences domains in $preferences: aiterm-fixture-tests.plist" "$bad_output"; then
            fail "expected a domain naming AiTerm, and only that one, to fail the run (status $runner_status)"
        fi

        # A run waits while another holds the test lock, and gets it once that one ends; a run
        # started inside one that holds it (as these fixture runs are) does not wait at all.
        zmodload zsh/system
        lock="$runner_logs/test.lock"
        : >"$lock"
        zsh -c "zmodload zsh/system; zsystem flock -f fd '$lock'; print -n >'$runner_logs/held'; until [[ -e '$runner_logs/release' ]]; do sleep 0.05; done" &
        until [[ -e "$runner_logs/held" ]]; do sleep 0.05; done
        for held in 1 ''; do
            : >"$bad_output"
            if [[ -z "$held" ]]; then
                # Release only after the waiter reaches the lock; a slow runner still tests contention.
                (
                    for attempt in {1..200}; do
                        grep -Fq "Waiting for another test run" "$bad_output" && break
                        sleep 0.05
                    done
                    touch "$runner_logs/release"
                ) &
            fi
            runner_status=0
            AITERM_TEST_LOCK="$lock" AITERM_TEST_LOCK_HELD="$held" TMPDIR="$runner_logs/" \
                TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER=1 SWIFT="$ROOT/scripts/fixtures/swift-test-run.sh" \
                "$ROOT/scripts/test.sh" swift -- --filter fixture >"$bad_output" 2>&1 || runner_status=$?
            waited=0
            grep -Fq "Waiting for another test run to finish" "$bad_output" && waited=1
            if [[ "$runner_status" -ne 0 || "$waited" -ne $(( ${#held} == 0 )) ]]; then
                fail "unexpected test-lock behaviour (status $runner_status, waited $waited, inherited '${held}')"
            fi
        done
        wait

        # The default suite runs what the changed paths can affect, which AITERM_TEST_PATHS names in
        # place of git. The fixtures write what was called to $calls: the Swift fixture its arguments,
        # this pytest the word `pytest`. Its distinct status proves the daemon's tests were reached,
        # and stops the run before their lint, which needs the venv a fresh worktree lacks.
        calls="$runner_logs/calls"
        pytest="$runner_logs/pytest"
        print -rl -- '#!/bin/zsh' 'print pytest >>"$AITERM_FIXTURE_CALLS"' 'exit 73' >"$pytest"
        chmod +x "$pytest"
        # changed_case <name> <expected status> <expected calls> <paths> [test.sh arguments…]
        changed_case() {
            local name="$1" want_status="$2" want_calls="$3" paths="$4" case_root="${CASE_ROOT:-$ROOT}"
            shift 4
            : >"$calls"
            runner_status=0
            AITERM_TEST_PATHS="$paths" AITERM_FIXTURE_CALLS="$calls" TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER=1 \
                SWIFT="$ROOT/scripts/fixtures/swift-test-run.sh" PYTEST="$pytest" \
                "$case_root/scripts/test.sh" "$@" >"$bad_output" 2>&1 || runner_status=$?
            if [[ "$runner_status" != "$want_status" || "$(<"$calls")" != "$want_calls" ]]; then
                fail "changed suite, $name: status $runner_status (expected $want_status), called '$(<"$calls")' (expected '$want_calls')"
            fi
        }
        changed_case "docs only" 0 '' docs/x.md
        grep -Fq "Nothing to test: only docs/x.md changed." "$bad_output" || fail "expected a docs-only change to say there is nothing to test"
        changed_case "no paths" 0 '' ''
        grep -Fxq "Nothing changed in AITERM_TEST_PATHS." "$bad_output" || fail "expected an empty AITERM_TEST_PATHS to say it names nothing"
        changed_case "daemon code" 73 pytest daemon/aitermd/x.py
        if grep -Fq "test selector guard passed" "$bad_output"; then
            fail "expected a fixture run to leave the reader guard to the run that started it"
        fi
        # A run that is no fixture runs the reader guard whatever it picked, here only the daemon.
        : >"$calls"
        runner_status=0
        env -u TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER AITERM_TEST_PATHS=daemon/aitermd/x.py AITERM_FIXTURE_CALLS="$calls" \
            SWIFT="$ROOT/scripts/fixtures/swift-test-run.sh" PYTEST="$pytest" \
            "$ROOT/scripts/test.sh" >"$bad_output" 2>&1 || runner_status=$?
        if [[ "$runner_status" != 73 || "$(<"$calls")" != pytest ]] || ! grep -Fq "test selector guard passed" "$bad_output"; then
            fail "expected a daemon-only change to run the reader guard before the daemon's tests (status $runner_status)"
        fi
        # The snapshot suites a target holds run in a pass of their own, after the rest of it.
        app_main='swift test --filter ^AiTermUITests\.DesignRulesTests/ --filter ^AiTermTests\. --skip ^AiTermTests\.BroadcastSetupSnapshotTests/ --skip ^AiTermTests\.OperatorSnapshotTests/'
        app_snapshots='swift test --filter ^AiTermTests\.BroadcastSetupSnapshotTests/ --filter ^AiTermTests\.OperatorSnapshotTests/'
        changed_case "app code" 0 "$app_main"$'\n'"$app_snapshots" app/Sources/AiTerm/X.swift
        grep -Fq "app/Sources/AiTerm/X.swift" "$bad_output" || fail "expected the selection to name the path that picked it"
        changed_case "docs only, with swift test arguments" 0 'swift test --filter fixture' docs/x.md -- --filter fixture
        # A filtered run must reach every host its selectors name and finish every suite they name.
        for result in nosuite onehost; do
            AITERM_FIXTURE_TEST_RUN="$result" changed_case "app code, $result" 1 "$app_main" app/Sources/AiTerm/X.swift
        done

        # A git that finds the merge base but then fails to list the changes must stop the run: going
        # on with what it did list could test nothing and still pass.
        mkdir -p "$runner_logs/broken-git"
        print -rl -- '#!/bin/zsh' \
            'case " $* " in' \
            '    *" merge-base "*) print 0000000000000000000000000000000000000000 ;;' \
            '    *" diff "*) print -u2 "fatal: broken git fixture"; exit 128 ;;' \
            "    *) exec $(whence -p git) \"\$@\" ;;" \
            'esac' >"$runner_logs/broken-git/git"
        chmod +x "$runner_logs/broken-git/git"
        : >"$calls"
        runner_status=0
        env -u AITERM_TEST_PATHS PATH="$runner_logs/broken-git:$PATH" AITERM_FIXTURE_CALLS="$calls" \
            TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER=1 SWIFT="$ROOT/scripts/fixtures/swift-test-run.sh" PYTEST="$pytest" \
            "$ROOT/scripts/test.sh" >"$bad_output" 2>&1 || runner_status=$?
        if [[ "$runner_status" != 1 || -s "$calls" ]] || ! grep -Fq "could not list the changes since main" "$bad_output"; then
            fail "expected a failing git diff to stop the run (status $runner_status, called '$(<"$calls")')"
        fi

        # Without a main to compare with, nothing says what changed, so everything runs: a scratch
        # repository with these scripts and no main branch gets as far as the daemon's tests.
        repo="$runner_logs/repo"
        mkdir -p "$repo/app" "$repo/daemon"
        cp -R "$ROOT/scripts" "$repo/"
        cp "$ROOT/.swift-version" "$repo/"
        cp "$ROOT/app/Package.swift" "$repo/app/"
        git -C "$repo" init -q -b trunk
        git -C "$repo" add -A
        git -C "$repo" -c user.name=fixture -c user.email=fixture@invalid -c commit.gpgsign=false \
            commit -q --no-verify -m fixture
        : >"$calls"
        runner_status=0
        env -u AITERM_TEST_PATHS AITERM_FIXTURE_CALLS="$calls" TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER=1 \
            SWIFT="$repo/scripts/fixtures/swift-test-run.sh" PYTEST="$pytest" \
            "$repo/scripts/test.sh" >"$bad_output" 2>&1 || runner_status=$?
        if [[ "$runner_status" != 73 || "$(<"$calls")" != pytest ]] || ! grep -Fxq "  everything" "$bad_output"; then
            fail "expected a checkout with no main to select everything (status $runner_status)"
        fi

        # A route the runner cannot act on stops the run; skipping it would test less than it says.
        for row in $'bad/*\tfrobnicate' $'bad/*\ttarget:NoSuchTests' $'bad/*\tsuite:AiTermTests' 'bad/*'; do
            cp "$ROOT/scripts/test-routes.tsv" "$repo/scripts/test-routes.tsv"
            print -r -- "$row" >>"$repo/scripts/test-routes.tsv"
            CASE_ROOT="$repo" changed_case "bad route $row" 1 '' bad/x
            grep -Fq "test-routes.tsv" "$bad_output" || fail "expected a route diagnostic for $row"
        done

        logs_after=(${TMPDIR:-/tmp}/aiterm-test.*(N/))
        leaked=(${logs_after:|logs_before})
        if (( ${#leaked} )); then
            print -u2 "the runner's fixture runs left their logs behind: ${(j:, :)leaked}"
            exit 1
        fi
    )
fi

print "swift toolchain guard passed"
