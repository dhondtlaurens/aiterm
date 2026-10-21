#!/bin/zsh
# scripts/test-test-select.sh — guards scripts/test-select.sh and its table, scripts/test-routes.tsv:
# each case names the paths a change touches and the selectors the table must turn them into.
# A wrong route is silent (a suite that should have run just does not), so every row of the table
# that carries a decision is pinned here. Add a case with `check`; no build is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELECT="$ROOT/scripts/test-select.sh"

[[ -x "$SELECT" ]] || { print -u2 "missing selector: $SELECT"; exit 1; }

# check <name> <expected selectors…> -- <changed paths…>
# Pipes the paths, one per line, into the selector and compares what it prints with the expected
# selectors, which come out sorted. No paths after `--` is an empty change. With NO_NEWLINE=1 before
# the call the last path has no trailing newline, as from `printf` or a tool that does not end its output.
check() {
    local name="$1"
    shift
    local expected=()
    while (( $# )) && [[ "$1" != -- ]]; do expected+=("$1"); shift; done
    (( $# )) || { print -u2 "check '$name' needs a -- before its paths"; exit 2; }
    shift
    local want got
    want="$(print -rl -- "${(@o)expected}")"
    (( ${#expected} )) || want=""
    if [[ -n "${NO_NEWLINE:-}" ]]; then
        got="$( { (( $# )) && print -rn -- "${(pj:\n:)@}" || true } | "$SELECT" )"
    else
        got="$( { (( $# )) && print -rl -- "$@" || true } | "$SELECT" )"
    fi
    if [[ "$got" != "$want" ]]; then
        print -u2 "FAIL $name"
        print -u2 "  expected: ${want//$'\n'/ }"
        print -u2 "  got:      ${got//$'\n'/ }"
        exit 1
    fi
    print "ok   $name"
}

# unaccounted_readers <root> — prints one line for each test under <root>/app/Tests or
# <root>/daemon/tests that reads outside its own target and that <root>/scripts/test-routes.tsv does
# not account for; prints nothing when every reader is. The detection is a plain grep, so it is a net
# and not a proof. It finds Swift files that use `#filePath` or `#file` (which Swift 5 mode also makes
# a real path; `#fileID` is not one), and daemon tests that climb out of
# daemon/ with `parents[2]` or more, `parents[1] / "hooks"`, or three `.parent`s. It misses a reader
# that finds the repo another way (`git rev-parse`, a `..` in a string, `parents[1]` into some folder
# other than hooks), and it cannot tell what a `#filePath` file reads, so a file that only builds a
# temp path under its own target has to be listed as reading only its own target.
# The table accounts for a reader in one of these ways:
#   a Swift one: `suite:<Target>.<File>` on a row, or its name on a `# reads only its own target:`
#   line, or on a `# opt-in, reads outside its target:` line (spends quota, so no row selects it);
#   a daemon one: `<test file>=<path it reads>` on a `# daemon readers outside daemon/:` line, with
#   a row that routes that path to `daemon`.
unaccounted_readers() {
    local root="$1" routes="$1/scripts/test-routes.tsv" line glob selectors
    local -a own optin daemon_reads suites globs sels
    for line in "${(@f)$(<"$routes")}"; do
        case "$line" in
            "# reads only its own target:"*) own+=(${=line#*:}) ;;
            "# opt-in, reads outside its target:"*) optin+=(${=line#*:}) ;;
            "# daemon readers outside daemon/:"*) daemon_reads+=(${=line#*:}) ;;
            "#"*|"") ;;
            *) glob="${line%%$'\t'*}"; selectors="${line#*$'\t'}"
               globs+=("$glob"); sels+=("$selectors"); suites+=(${(M)${=selectors}:#suite:*}) ;;
        esac
    done

    # A moved or renamed test directory would otherwise find no readers and pass without a word, so the
    # directories must exist and each kind of reader must turn up at least once (the tree has both today).
    local file target base swift_found=0 daemon_found=0
    [[ -d "$root/app/Tests" ]] || { print -r -- "app/Tests is missing, so no Swift reader could be checked"; return; }
    [[ -d "$root/daemon/tests" ]] || { print -r -- "daemon/tests is missing, so no daemon reader could be checked"; return; }

    for file in $(grep -rlE '#file(Path)?([^A-Za-z]|$)' "$root/app/Tests" --include='*.swift' | sort); do
        swift_found=1
        target="${${file#$root/app/Tests/}%%/*}"
        base="${${file:t}%.swift}"
        (( ${suites[(Ie)suite:$target.$base]} + ${own[(Ie)$base]} + ${optin[(Ie)$base]} )) && continue
        print -r -- "${file#$root/}: reads outside its target (#file or #filePath) but no row has suite:$target.$base and it is on no reader line in scripts/test-routes.tsv"
    done

    local entry read_path i routed
    for file in $(grep -rlE 'parents\[([2-9]|[1-9][0-9])\]|parents\[1\] */ *"hooks"|\.parent\.parent\.parent' "$root/daemon/tests" --include='*.py' | sort); do
        daemon_found=1
        base="${file:t}"
        entry=""
        for line in $daemon_reads; do [[ "$line" == "$base="* ]] && entry="$line"; done
        if [[ -z "$entry" ]]; then
            print -r -- "${file#$root/}: climbs out of daemon/ but is not on a '# daemon readers outside daemon/:' line in scripts/test-routes.tsv"
            continue
        fi
        read_path="${entry#*=}"
        routed=0
        for (( i = 1; i <= ${#globs}; i++ )); do
            [[ "$read_path" == ${~globs[i]} ]] && (( ${${=sels[i]}[(Ie)daemon]} )) && routed=1
        done
        (( routed )) || print -r -- "${file#$root/}: reads $read_path but no row routes that path to daemon"
    done

    (( swift_found )) || print -r -- "app/Tests holds no #file or #filePath reader, so the detection looks broken"
    (( daemon_found )) || print -r -- "daemon/tests holds no test that climbs out of daemon/, so the detection looks broken"
}

check "docs only runs nothing" -- docs/architecture.md README.md
check "daemon code runs the daemon" daemon -- daemon/aitermd/service.py
check "wire fixtures add the wire contract" daemon suite:AiTermCoreTests.WireContractTests -- daemon/tests/wire/manifest.json
check "core runs every swift target" target:AiTermCoreTests target:AiTermTests target:AiTermUITests -- app/Sources/AiTermCore/Models.swift
check "app code adds the design rules" suite:AiTermUITests.DesignRulesTests target:AiTermTests -- app/Sources/AiTerm/AppController.swift
check "a suite inside a selected target is dropped" target:AiTermTests target:AiTermUITests -- app/Sources/AiTerm/AppController.swift app/Tests/AiTermUITests/SelectTests.swift
check "the plist adds the release feed" suite:AiTermCoreTests.ReleaseFeedTests suite:AiTermUITests.DesignRulesTests target:AiTermTests -- app/Sources/AiTerm/Resources/Info.plist
check "hooks run the daemon and the shim" daemon suite:AiTermCoreTests.StatusLineShimTests -- hooks/claude-statusline-shim.sh
check "the toolchain runs everything" everything toolchain -- .swift-version
check "the manifest runs the toolchain guard and every swift target" target:AiTermCoreTests target:AiTermTests target:AiTermUITests toolchain -- app/Package.swift
check "an unknown path runs everything" everything -- Makefile
check "a rename routes both sides" daemon target:AiTermTests -- app/Tests/AiTermTests/A.swift daemon/b.py
check "no paths runs nothing" --
NO_NEWLINE=1 check "a last path without a newline still counts" daemon -- daemon/x.py
NO_NEWLINE=1 check "only the last of several paths lacks its newline" daemon target:AiTermTests -- daemon/b.py app/Tests/AiTermTests/A.swift

# A test that reads a file outside its own target is a route the table must know about, or a change
# to what it reads silently stops running it. Each case runs the reader check on a root directory
# laid out like the repo: the real tree, and a scratch copy of app/Tests, daemon/tests and the table
# with one new reader dropped in. The real tree is never written to.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/aiterm-test-select.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# copy_tree <dest> — the parts of the repo the reader check looks at.
copy_tree() {
    mkdir -p "$1/app" "$1/daemon" "$1/scripts"
    cp -R "$ROOT/app/Tests" "$1/app/Tests"
    cp -R "$ROOT/daemon/tests" "$1/daemon/tests"
    cp "$ROOT/scripts/test-routes.tsv" "$1/scripts/test-routes.tsv"
}

# reader_check_passes <name> <root> / reader_check_fails <name> <root> <text the report must contain>
reader_check_passes() {
    local report nl=$'\n'
    report="$(unaccounted_readers "$2")"
    [[ -z "$report" ]] || { print -u2 "FAIL $1"; print -u2 "  ${report//$'\n'/${nl}  }"; exit 1; }
    print "ok   $1"
}
reader_check_fails() {
    local report
    report="$(unaccounted_readers "$2")"
    [[ "$report" == *"$3"* ]] || { print -u2 "FAIL $1"; print -u2 "  expected a report naming: $3"; print -u2 "  got:      ${report:-nothing}"; exit 1; }
    print "ok   $1"
}

reader_check_passes "every reader today is accounted for" "$ROOT"

copy_tree "$SCRATCH/swift"
print -r -- 'let here = #filePath' >"$SCRATCH/swift/app/Tests/AiTermCoreTests/NewReaderTests.swift"
reader_check_fails "a new swift #filePath reader fails, naming the file" "$SCRATCH/swift" "app/Tests/AiTermCoreTests/NewReaderTests.swift"

copy_tree "$SCRATCH/daemon"
print -r -- 'APP = Path(__file__).resolve().parents[2] / "app"' >"$SCRATCH/daemon/daemon/tests/test_new_reader.py"
reader_check_fails "a new daemon test reaching outside daemon/ fails, naming the file" "$SCRATCH/daemon" "daemon/tests/test_new_reader.py"

# `#file` is a real path in Swift 5 mode, so it is a reader too; `#fileID` is not.
copy_tree "$SCRATCH/hashfile"
print -r -- 'let here = URL(fileURLWithPath: #file)' >"$SCRATCH/hashfile/app/Tests/AiTermUITests/FileReaderTests.swift"
reader_check_fails "a new swift #file reader fails, naming the file" "$SCRATCH/hashfile" "app/Tests/AiTermUITests/FileReaderTests.swift"
copy_tree "$SCRATCH/fileid"
print -r -- 'let here = #fileID' >"$SCRATCH/fileid/app/Tests/AiTermUITests/FileIDTests.swift"
reader_check_passes "#fileID is not a path, so it is not a reader" "$SCRATCH/fileid"

# A guard that finds nothing must say so, not pass: a moved test directory would otherwise look clean.
copy_tree "$SCRATCH/nodaemon"
rm -rf "$SCRATCH/nodaemon/daemon/tests"
reader_check_fails "a missing daemon/tests fails" "$SCRATCH/nodaemon" "daemon/tests is missing"
copy_tree "$SCRATCH/noswift"
rm -rf "$SCRATCH/noswift/app/Tests"
reader_check_fails "a missing app/Tests fails" "$SCRATCH/noswift" "app/Tests is missing"

print "test selector guard passed"
