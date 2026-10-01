#!/bin/zsh
# Resolves the compatible Swift toolchain used by every AiTerm build command.
set -euo pipefail

candidate="${SWIFT:-$HOME/.swiftly/bin/swift}"

if [[ ! -x "$candidate" ]]; then
    print -u2 "AiTerm requires Swift 6.4 or newer. Install it with:"
    print -u2 "  ~/.swiftly/bin/swiftly install --use 6.4"
    print -u2 "No executable Swift toolchain found at: $candidate"
    exit 1
fi

version_output="$("$candidate" --version 2>&1)"
version="$(print -r -- "$version_output" | sed -nE 's/^.*Swift version ([0-9]+)\.([0-9]+).*$/\1.\2/p' | head -n 1)"
major="${version%%.*}"
minor="${version#*.}"

if [[ -z "$version" || "$major" -lt 6 || ( "$major" -eq 6 && "$minor" -lt 4 ) ]]; then
    print -u2 "AiTerm requires Swift 6.4 or newer. Found: ${version:-unknown} at $candidate"
    print -u2 "Install and select it with: ~/.swiftly/bin/swiftly install --use 6.4"
    exit 1
fi

exec "$candidate" "$@"
