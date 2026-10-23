#!/bin/zsh
# Exercise packaging and snapshot scripts without building or signing an app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_dir="$(mktemp -d -t aiterm-build-fixture)"
trap 'rm -rf "$fixture_dir"' EXIT
repo="$fixture_dir/repo"
mkdir -p "$repo/app/.build/"{debug,release} "$repo/app/Sources/AiTerm/Resources" "$repo/daemon/tools" "$repo/hooks"
cp -R "$ROOT/scripts" "$repo/"
cp "$ROOT/app/Sources/AiTerm/Resources/Info.plist" "$repo/app/Sources/AiTerm/Resources/"
touch "$repo/app/Sources/AiTerm/Resources/AiTerm.icns" "$repo/LICENSE"
for file in __init__.py delivery_check.py wire_frames.py; do touch "$repo/daemon/tools/$file"; done
for file in claude-statusline-shim.sh pi-aiterm-status.ts; do touch "$repo/hooks/$file"; done
cat >"$repo/scripts/swift.sh" <<'SWIFT'
#!/bin/zsh
print -r -- "$*" >>"$AITERM_FIXTURE_BUILD_CALLS"
print 'fixture build diagnostic'
exit "${AITERM_FIXTURE_BUILD_STATUS:-0}"
SWIFT
cat >"$repo/app/.build/debug/AiTerm" <<'APP'
#!/bin/zsh
mkdir -p "$AITERM_SNAPSHOT_DIR"
print drawn >"$AITERM_SNAPSHOT_DIR/current.png"
APP
cp "$repo/app/.build/debug/AiTerm" "$repo/app/.build/release/AiTerm"
chmod +x "$repo/app/.build/"{debug,release}/AiTerm
export AITERM_FIXTURE_BUILD_CALLS="$fixture_dir/calls"
failures=0
fail() { print -u2 -- "$*"; cat "$fixture_dir/output" >&2; failures=$(( failures + 1 )); }
mkdir -p "$repo/build/pictures/kept"
touch "$repo/build/pictures/stale.png" "$repo/build/pictures/notes.txt"
"$repo/scripts/snapshots.sh" "$repo/build/pictures" >"$fixture_dir/output" 2>&1
[[ ! -e "$repo/build/pictures/stale.png" && -e "$repo/build/pictures/current.png" ]] || fail 'snapshots retained a stale image'
[[ -e "$repo/build/pictures/notes.txt" && -d "$repo/build/pictures/kept" ]] || fail 'snapshots deleted more than its images'
grep -Fxq 'build --product AiTerm' "$AITERM_FIXTURE_BUILD_CALLS" || fail 'snapshots built more than the app'
rc=0
AITERM_FIXTURE_BUILD_STATUS=73 "$repo/scripts/snapshots.sh" "$repo/build/pictures" >"$fixture_dir/output" 2>&1 || rc=$?
[[ "$rc" == 1 && -e "$repo/build/pictures/current.png" ]] || fail 'failed build erased the last snapshots or succeeded'
grep -Fq 'fixture build diagnostic' "$fixture_dir/output" || fail 'failed build hid its diagnostic'

mkdir -p "$fixture_dir/bin"
for tool in python codesign; do
    print -rl -- '#!/bin/zsh' 'exit 0' >"$fixture_dir/bin/$tool"
    chmod +x "$fixture_dir/bin/$tool"
done
print -rl -- '#!/bin/zsh' 'exit 0' >"$repo/scripts/test-app-bundle.sh"
PATH="$fixture_dir/bin:$PATH" PYTHON="$fixture_dir/bin/python" SIGN_IDENTITY=- "$repo/scripts/make-app.sh" >"$fixture_dir/output" 2>&1
bundled="$repo/build/AiTerm.app/Contents/Resources/daemon/tools"
[[ -f "$bundled/__init__.py" && -f "$bundled/delivery_check.py" && ! -e "$bundled/wire_frames.py" ]] || fail 'bundle must contain only the delivery check tools'

# An old Python must be rejected before creating a venv, not by pip afterwards.
cat >"$fixture_dir/bin/python" <<'PYTHON'
#!/bin/zsh
[[ "$1" == -c ]] && exit 1
print 'venv creation reached'
exit 73
PYTHON
rc=0
TEST_SWIFT_TOOLCHAIN_SKIP_RUNNER=1 AITERM_TEST_LOCK_HELD=1 PYTHON="$fixture_dir/bin/python" "$repo/scripts/test.sh" daemon >"$fixture_dir/output" 2>&1 || rc=$?
[[ "$rc" == 1 ]] && grep -Fq 'python3 >= 3.11 required' "$fixture_dir/output" || fail 'old Python reached venv creation'

(( failures == 0 ))
