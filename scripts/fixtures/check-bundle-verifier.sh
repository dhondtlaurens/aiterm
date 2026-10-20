#!/bin/zsh
# A minimal bundle reaches the interpreter boundary without building or signing an app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_dir="$(mktemp -d -t aiterm-bundle-fixture)"
trap 'rm -rf "$fixture_dir"' EXIT
app="$fixture_dir/AiTerm.app"
mkdir -p "$app/Contents/Resources/hooks" "$app/Contents/MacOS"
cp "$ROOT/app/Sources/AiTerm/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$ROOT/app/Sources/AiTerm/Resources/AiTerm.icns" "$app/Contents/Resources/"
cp "$ROOT/hooks/"* "$app/Contents/Resources/hooks/"
touch "$app/Contents/MacOS/AiTerm"
chmod +x "$app/Contents/MacOS/AiTerm"
cat > "$fixture_dir/python" <<'PYTHON'
#!/bin/zsh
# A distinct status proves the configured interpreter was reached.
exit 73
PYTHON
chmod +x "$fixture_dir/python"
rc=0
PYTHON="$fixture_dir/python" "$ROOT/scripts/test-app-bundle.sh" "$app" >"$fixture_dir/output" 2>&1 || rc=$?
[[ "$rc" == 73 ]] || { print -u2 "bundle verifier ignored PYTHON (status $rc)"; cat "$fixture_dir/output" >&2; exit 1; }
for hook in claude-statusline-shim.sh grok-statusline-shim.sh pi-aiterm-status.ts; do
    print 'stale bundled resource' >> "$app/Contents/Resources/hooks/$hook"
    rc=0
    PYTHON="$fixture_dir/python" "$ROOT/scripts/test-app-bundle.sh" "$app" >"$fixture_dir/output" 2>&1 || rc=$?
    [[ "$rc" == 1 ]] && grep -Fq "bundled $hook differs from source" "$fixture_dir/output" || {
        print -u2 "bundle verifier missed changed resource $hook (status $rc)"
        cat "$fixture_dir/output" >&2
        exit 1
    }
    cp "$ROOT/hooks/$hook" "$app/Contents/Resources/hooks/$hook"
done
