#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A toolchain that reports whatever version AITERM_FIXTURE_SWIFT_VERSION names.
OTHER_SWIFT="$ROOT/scripts/fixtures/swift-version.sh"
GOOD_SWIFT="$HOME/.swiftly/bin/swift"
PINNED_VERSION="$(sed -nE 's/^([0-9]+\.[0-9]+).*/\1/p' "$ROOT/.swift-version")"

[[ -x "$OTHER_SWIFT" ]] || { print -u2 "missing fixture: $OTHER_SWIFT"; exit 1; }
[[ -x "$GOOD_SWIFT" ]] || { print -u2 "missing fixture: $GOOD_SWIFT"; exit 1; }
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
aggregate_output=""
trap 'rm -f "$bad_output" "$aggregate_output"' EXIT
for other in "$OLDER_VERSION" "$NEWER_VERSION"; do
    if AITERM_FIXTURE_SWIFT_VERSION="$other" SWIFT="$OTHER_SWIFT" "$ROOT/scripts/swift.sh" --version >"$bad_output" 2>&1; then
        print -u2 "expected Swift $other to be rejected"
        exit 1
    fi
    grep -Fq "AiTerm requires Swift $PINNED_VERSION. Found: $other" "$bad_output" || {
        print -u2 "expected the pinned-toolchain diagnostic for Swift $other"
        sed -n '1,20p' "$bad_output" >&2
        exit 1
    }
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

if [[ "${TEST_SWIFT_TOOLCHAIN_SKIP_AGGREGATE:-0}" == "1" ]]; then
    print "swift toolchain guard passed"
    exit 0
fi

aggregate_output="$(mktemp)"
if AITERM_FIXTURE_SWIFT_VERSION="$OLDER_VERSION" SWIFT="$OTHER_SWIFT" PYTEST=false "$ROOT/scripts/test.sh" >"$aggregate_output" 2>&1; then
    print -u2 "expected the aggregate command to reject Swift $OLDER_VERSION"
    exit 1
fi
grep -Fq "AiTerm requires Swift $PINNED_VERSION. Found: $OLDER_VERSION" "$aggregate_output" || {
    print -u2 "expected the aggregate command to stop at the toolchain guard"
    sed -n '1,20p' "$aggregate_output" >&2
    exit 1
}

normal_output="$(mktemp)"
trap 'rm -f "$bad_output" "$aggregate_output" "$normal_output"' EXIT
if ! SWIFT="$GOOD_SWIFT" PYTEST=/usr/bin/true "$ROOT/scripts/test.sh" >"$normal_output" 2>&1; then
    print -u2 "expected the aggregate command to pass with the pinned Swift toolchain"
    sed -n '1,80p' "$normal_output" >&2
    exit 1
fi
grep -Fq "swift toolchain guard passed" "$normal_output" || {
    print -u2 "expected the aggregate command to run the toolchain guard"
    sed -n '1,80p' "$normal_output" >&2
    exit 1
}

print "swift toolchain guard passed"
