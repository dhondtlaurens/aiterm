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

# Exercise the real Python metadata checks with isolated stub modules and distribution metadata.
# The signer boundary returns 73; no signature is created or claimed by this fixture.
cp "$ROOT/LICENSE" "$app/Contents/Resources/LICENSE"
daemon_dir="$app/Contents/Resources/daemon"
mkdir -p "$daemon_dir/aitermd"
touch "$daemon_dir/aitermd/__init__.py" "$daemon_dir/aitermd/service.py" "$daemon_dir/iterm2.py"
"${PYTHON:-python3}" - "$ROOT/daemon/pyproject.toml" "$daemon_dir" <<'PYCODE'
from pathlib import Path
import sys
import tomllib
with open(sys.argv[1], "rb") as manifest:
    dependencies = tomllib.load(manifest)["project"]["dependencies"]
for dependency in dependencies:
    name, version = dependency.split("==")
    metadata = Path(sys.argv[2], f"{name}-{version}.dist-info", "METADATA")
    metadata.parent.mkdir()
    metadata.write_text(f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n")
PYCODE
cat > "$fixture_dir/codesign" <<'CODESIGN'
#!/bin/zsh
exit 73
CODESIGN
chmod +x "$fixture_dir/codesign"
rc=0
PATH="$fixture_dir:$PATH" "$ROOT/scripts/test-app-bundle.sh" "$app" >"$fixture_dir/output" 2>&1 || rc=$?
[[ "$rc" == 73 ]] || { print -u2 "bundle verifier rejected valid dependency metadata (status $rc)"; cat "$fixture_dir/output" >&2; exit 1; }
for metadata in "$daemon_dir/"*.dist-info/METADATA; do
    cp "$metadata" "$fixture_dir/metadata"
    sed -i '' 's/^Version: .*/Version: 0/' "$metadata"
    rc=0
    PATH="$fixture_dir:$PATH" "$ROOT/scripts/test-app-bundle.sh" "$app" >"$fixture_dir/output" 2>&1 || rc=$?
    [[ "$rc" == 1 ]] && grep -Fq AssertionError "$fixture_dir/output" || {
        print -u2 "bundle verifier missed a wrong bundled dependency version (status $rc)"
        cat "$fixture_dir/output" >&2
        exit 1
    }
    cp "$fixture_dir/metadata" "$metadata"
done
