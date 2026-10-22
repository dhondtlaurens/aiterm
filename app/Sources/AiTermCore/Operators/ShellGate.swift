import Foundation

/// Sorts a shell command the Operator wants to run into a read that goes ahead at once or one the Oracle
/// judges first (spec §A.1). It is a pure function of the text: nothing is run, and whenever it is unsure,
/// which is the answer for anything it does not know by name, the command is `.oracle`, never `.read`.
///
/// Every program's options are an allowlist: a flag that is not named, including a clustered short flag
/// and a long option cut short (git and GNU tools accept `--upload-pa` for `--upload-pack`), is `.oracle`.
public enum ShellGate {
    public enum Route: Equatable {
        /// Runs at once. `rewrite` is the command to run instead, when the one asked for would show a secret.
        case read(rewrite: String?)
        case oracle
    }

    /// What a bare `env` or `printenv` runs instead: every variable, with the value of any whose name holds
    /// TOKEN, SECRET, KEY or PASSWORD (in any case) replaced by `***`. The variables are read NUL-separated
    /// and judged one at a time, so a value of several lines is masked whole, and a value that holds a
    /// line like `NAME=x` is never taken for a variable of its own. The programs are named in full: the
    /// command has to work with nothing but `/bin` on the PATH.
    public static let maskedEnv = """
        /usr/bin/env -0 | /usr/bin/tr '\\000' '\\001' | /usr/bin/awk 'BEGIN { RS = "\\001" } /^[A-Za-z_][A-Za-z0-9_]*=/ { name = $0; sub(/=.*/, "", name); if (toupper(name) ~ /TOKEN|SECRET|KEY|PASSWORD/) print name "=***"; else print $0 }'
        """

    /// `directory` is where the command runs; every file it names has to sit under one of `roots`, once `resolve`
    /// has followed its symlinks.
    public static func route(_ command: String, in directory: String, roots: [String],
                             resolve: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) -> Route {
        guard let segments = segments(of: command), !segments.isEmpty else { return .oracle }
        if segments.count == 1, segments[0] == ["env"] || segments[0] == ["printenv"] { return .read(rewrite: maskedEnv) }
        return withoutActuallyEscaping(resolve) { resolve in
            let judge = Judge(directory: directory, roots: roots, resolve: resolve)
            return segments.allSatisfy(judge.isRead) ? .read(rewrite: nil) : .oracle
        }
    }

    // MARK: Tokenizing

    /// Redirects that write nowhere or only join the error to the output; any other `<` or `>` is a redirect
    /// that could write a file or read one, and sends the command to the Oracle.
    private static let harmlessRedirects: Set<String> = ["2>&1", ">/dev/null", "2>/dev/null"]

    /// The command as its words, one list per segment between `|`, `||`, `&&` and `;`, with quotes taken off
    /// and the harmless redirects dropped. Nil for anything that can run or write something this does not see:
    /// an expansion (`$`, a backtick, and unquoted `{ } * ? [ !`, a `~` or `=` that starts a word), a subshell, a control character (a
    /// newline, a tab), a non-ASCII character outside quotes, a backslash, a lone `&`, any other redirect, an
    /// unbalanced quote, or a segment with nothing in it. It walks unicode scalars, not characters: the
    /// shell parses bytes, and a combining mark after a quote or `;` would otherwise hide it.
    private static func segments(of command: String) -> [[String]]? {
        let scalars = Array(command.unicodeScalars)
        if scalars.contains(where: { $0.properties.generalCategory == .control }) { return nil }
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quoted = false
        var redirected = false
        var quote: Unicode.Scalar?

        func endWord() -> Bool {
            defer { word = ""; inWord = false; quoted = false; redirected = false }
            guard inWord else { return true }
            if redirected { return !quoted && harmlessRedirects.contains(word) }
            words.append(word)
            return true
        }
        func endSegment() -> Bool {
            guard endWord(), !words.isEmpty else { return false }
            segments.append(words)
            words = []
            return true
        }

        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            i += 1
            if let open = quote {
                if c == open { quote = nil; continue }
                if open == "\"", c == "\\" || c == "$" || c == "`" { return nil }
                word.unicodeScalars.append(c)
                continue
            }
            guard c.isASCII else { return nil }
            // zsh, which runs these, expands a word that starts with `=` to the path of that command, and it does
            // so after empty quotes too (`''=ls`): so while the word's text is empty, whatever was quoted.
            if c == "=", word.isEmpty { return nil }
            switch c {
            case "'", "\"":
                quote = c; inWord = true; quoted = true
            case "\\", "$", "`", "(", ")", "{", "}", "*", "?", "[", "!":
                return nil
            case "~":
                // Tilde expansion needs a word that starts with it (or one after `=` or `:`); `HEAD~1` is only a revision.
                guard inWord, let last = word.unicodeScalars.last, last != "=", last != ":", last != "<", last != ">" else { return nil }
                word.unicodeScalars.append(c)
            case " ":
                guard endWord() else { return nil }
            case ";":
                guard endSegment() else { return nil }
            case "|":
                guard endSegment() else { return nil }
                if next == "|" { i += 1 }
            case "&":
                if next != "&", inWord, !quoted, word == "2>" {
                    word.unicodeScalars.append(c)
                } else if next == "&" {
                    guard endSegment() else { return nil }
                    i += 1
                } else {
                    return nil
                }
            case "<", ">":
                word.unicodeScalars.append(c); inWord = true; redirected = true
            default:
                word.unicodeScalars.append(c); inWord = true
            }
        }
        guard quote == nil, endSegment() else { return nil }
        return segments
    }

    // MARK: Options

    private static func isOption(_ word: String) -> Bool { word.hasPrefix("-") && word.count > 1 }

    private static func matches(_ word: String, _ pattern: String) -> Bool {
        word.range(of: pattern, options: .regularExpression) != nil
    }

    /// What a program is allowed to be given. Every option has to be named: a switch, a flag with a value
    /// (the next word, or `--name=value` for a long one) that the value check accepts, or a whole-word
    /// pattern for the ones with a number in them.
    private struct Options {
        var switches: Set<String> = []
        var values: [String: (String) -> Bool] = [:]
        var patterns: [String] = []
        var positionals: ClosedRange<Int> = 0...Int.max
        var positional: (String) -> Bool = { _ in true }

        /// The words that are no option, and the names of the options given; nil when anything is not allowed.
        func parse(_ args: [String]) -> (words: [String], seen: Set<String>)? {
            var words: [String] = []
            var seen: Set<String> = []
            var ended = false
            var i = 0
            while i < args.count {
                let word = args[i]
                i += 1
                if ended || !ShellGate.isOption(word) {
                    words.append(word)
                } else if word == "--" {
                    ended = true
                } else if switches.contains(word) {
                    seen.insert(word)
                } else if let check = values[word] {
                    guard i < args.count, check(args[i]) else { return nil }
                    i += 1
                    seen.insert(word)
                } else if word.hasPrefix("--"), let equals = word.firstIndex(of: "="),
                          let check = values[String(word[..<equals])], check(String(word[word.index(after: equals)...])) {
                    seen.insert(String(word[..<equals]))
                } else if patterns.contains(where: { ShellGate.matches(word, $0) }) {
                    seen.insert(word)
                } else {
                    return nil
                }
            }
            guard positionals.contains(words.count), words.allSatisfy(positional) else { return nil }
            return (words, seen)
        }
    }

    // MARK: Judging

    /// One segment's program and arguments against the table of reads. `directory` and `roots` decide which
    /// files a read may name.
    private struct Judge {
        let directory: String
        let roots: [String]
        let resolve: (String) -> String

        /// Built on each use: a table of closures is not Sendable, so it cannot be a stored static.
        static var programs: [String: (Judge) -> ([String]) -> Bool] { [
            "git": Judge.git, "glab": Judge.glab, "gh": Judge.gh, "npm": Judge.npm, "npx": Judge.npx, "node": Judge.node,
            "which": { _ in { _ in true } }, "type": { _ in { _ in true } }, "command": Judge.commandV, "pwd": Judge.pwd,
            "cat": files("cat"), "head": files("head"), "tail": files("tail"), "ls": files("ls"), "wc": files("wc"),
            "stat": files("stat"), "file": files("file"), "grep": files("grep"), "rg": files("rg"),
        ] }

        private static func files(_ program: String) -> (Judge) -> ([String]) -> Bool {
            { judge in { judge.files(program, $0) } }
        }

        func isRead(_ words: [String]) -> Bool {
            guard let program = words.first, let judge = Judge.programs[program] else { return false }
            return judge(self)(Array(words.dropFirst()))
        }

        // MARK: Paths

        /// Whether `path` is, once symlinks are followed, a root or something under one. A `..`, a `~`, a glob
        /// or a brace is refused rather than worked out: the shell would expand them to something else.
        func isInside(_ path: String) -> Bool {
            guard !path.isEmpty, !path.hasPrefix("~"), !path.contains(where: { "*?[]{}".contains($0) }),
                  !path.split(separator: "/").contains("..") else { return false }
            let absolute = path.hasPrefix("/") ? path : directory + "/" + path
            let resolved = Self.standardized(resolve(absolute))
            return roots.contains { root in
                let root = Self.standardized(resolve(root))
                return resolved == root || resolved.hasPrefix(root == "/" ? "/" : root + "/")
            }
        }

        private static func standardized(_ path: String) -> String {
            URL(fileURLWithPath: path).standardized.path
        }

        // MARK: Value checks

        private static func anything(_ value: String) -> Bool { true }
        private static func digits(_ value: String) -> Bool { ShellGate.matches(value, #"^[0-9]+$"#) }
        private static func count(_ value: String) -> Bool { ShellGate.matches(value, #"^\+?[0-9]+$"#) }
        private static func get(_ value: String) -> Bool { value == "GET" }
        /// A jq expression that does not mention `env` or `$ENV`, which would print the environment.
        private static func jq(_ value: String) -> Bool { !ShellGate.matches(value, #"(?i)(^|[^A-Za-z0-9_])env($|[^A-Za-z0-9_])"#) }
        private static func workspace(_ value: String) -> Bool { ShellGate.matches(value, #"^[A-Za-z0-9@][A-Za-z0-9@._/-]*$"#) }
        private static func omit(_ value: String) -> Bool { ["dev", "optional", "peer"].contains(value) }
        private static func auditLevel(_ value: String) -> Bool { ["info", "low", "moderate", "high", "critical", "none"].contains(value) }
        /// A package, with or without a version or a field: `react`, `@scope/pkg@1`, `dist.tarball`.
        private static func package(_ value: String) -> Bool { ShellGate.matches(value, #"^[A-Za-z0-9@][A-Za-z0-9@._/-]*$"#) }
        /// A remote or a branch: no `+`, no `:` (a refspec with a destination writes a local branch, a
        /// URL with `::` runs a helper) and no leading `-`.
        private static func plainName(_ value: String) -> Bool { ShellGate.matches(value, #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#) }
        private static func plainPattern(_ value: String) -> Bool { ShellGate.matches(value, #"^[A-Za-z0-9][A-Za-z0-9._/*-]*$"#) }

        // MARK: Programs

        private func git(_ args: [String]) -> Bool {
            var args = args[...]
            var location = directory
            if args.first == "-C" {
                guard args.count >= 2, isInside(args[args.startIndex + 1]) else { return false }
                let path = args[args.startIndex + 1]
                location = path.hasPrefix("/") ? path : directory + "/" + path
                args = args.dropFirst(2)
            }
            guard isInside(location), let subcommand = args.first else { return false }
            let rest = Array(args.dropFirst())
            // A word that is a revision or a path cannot be told apart here, so each is held to the roots as a path
            // from where git runs: `git diff /a /b` with both outside the repository turns into `--no-index` by itself.
            let here = Judge(directory: location, roots: roots, resolve: resolve)
            func inside(_ options: Options) -> Bool {
                guard let parsed = options.parse(rest) else { return false }
                return parsed.words.allSatisfy(here.isInside)
            }
            switch subcommand {
            case "status":
                return inside(Options(switches: ["-s", "-b", "--short", "--branch", "--porcelain"]))
            case "log", "show":
                return inside(Options(switches: ["--oneline", "--stat", "--name-only", "--name-status", "--graph", "--decorate", "--all", "-p", "--no-ext-diff"],
                                      values: ["-n": Judge.digits],
                                      patterns: [#"^-[0-9]+$"#, #"^--(format|pretty|since|until|author)=.+$"#]))
            case "diff":
                return inside(Options(switches: ["--stat", "--name-only", "--name-status", "--cached", "--staged", "--no-ext-diff"],
                                      patterns: [#"^-U[0-9]+$"#]))
            case "rev-parse":
                return inside(Options(switches: ["--abbrev-ref", "--short", "--show-toplevel", "--verify", "--symbolic-full-name",
                                                 "--is-inside-work-tree", "--git-dir"]))
            case "merge-base":
                return inside(Options(switches: ["--is-ancestor"]))
            case "branch":
                var i = 0
                while i < rest.count {
                    if ["-a", "-r", "-v", "-vv", "--list", "--show-current"].contains(rest[i]) {
                        i += 1
                    } else if rest[i] == "--contains", i + 1 < rest.count, !ShellGate.isOption(rest[i + 1]) {
                        i += 2
                    } else {
                        return false
                    }
                }
                return true
            case "worktree":
                return rest == ["list"] || rest == ["list", "--porcelain"]
            case "remote":
                if rest == ["-v"] { return true }
                return rest.count == 2 && rest[0] == "get-url" && !ShellGate.isOption(rest[1])
            case "ls-remote":
                return Options(switches: ["--heads", "--tags", "--symref"], positional: Judge.plainPattern).parse(rest) != nil
            case "fetch":
                return Options(switches: ["--prune", "--all", "--tags", "--quiet"], positional: Judge.plainName).parse(rest) != nil
            default:
                return false
            }
        }

        private func glab(_ args: [String]) -> Bool {
            host(args, groups: [
                "mr": ["view": Judge.listing(["--comments", "-c"], positionals: 1),
                       "list": Judge.listing(["--all", "--closed", "--merged", "--draft", "--not-draft"],
                                             ["--author", "--assignee", "--reviewer", "--label", "--per-page", "-P", "--page", "-p",
                                              "--source-branch", "-s", "--target-branch", "-t"]),
                       "diff": Judge.listing(["--raw"], positionals: 1)],
                "ci": ["status": Judge.listing([], ["--branch", "-b"]),
                       "view": Judge.listing([], ["--branch", "-b"], positionals: 1),
                       "list": Judge.listing([], ["--per-page", "-P", "--page", "-p", "--status", "-s"])],
            ])
        }

        private func gh(_ args: [String]) -> Bool {
            let output = ["--json", "--jq", "-q"]
            return host(args, groups: [
                "pr": ["view": Judge.listing(["--comments"], output, positionals: 1),
                       "list": Judge.listing([], output + ["--state", "-s", "--author", "--limit", "-L", "--base", "--head", "--label"]),
                       "diff": Judge.listing(["--name-only", "--patch"], positionals: 1),
                       "checks": Judge.listing(["--required"], output, positionals: 1)],
                "run": ["view": Judge.listing(["--log", "--log-failed", "--verbose", "-v", "--exit-status"], output + ["--job", "-j"], positionals: 1),
                        "list": Judge.listing([], output + ["--limit", "-L", "--branch", "-b", "--workflow", "-w", "--status", "-s", "--user", "-u"])],
            ])
        }

        /// A read subcommand's options: its switches and its flags with a value, `-R`/`--repo` besides.
        private static func listing(_ switches: [String], _ values: [String] = [], positionals: Int = 0) -> Options {
            var checks: [String: (String) -> Bool] = [:]
            for name in values + ["-R", "--repo"] { checks[name] = name == "--jq" || name == "-q" ? Judge.jq : Judge.anything }
            return Options(switches: Set(switches), values: checks, positionals: 0...positionals, positional: { !ShellGate.isOption($0) })
        }

        /// `glab` and `gh`: a few read subcommands, and `api` as a GET of one path that sends nothing.
        private func host(_ args: [String], groups: [String: [String: Options]]) -> Bool {
            guard let group = args.first else { return false }
            let rest = Array(args.dropFirst())
            if group == "api" {
                return Options(switches: ["-i", "--include", "--paginate"],
                               values: ["--jq": Judge.jq, "-q": Judge.jq, "--hostname": Judge.anything,
                                        "-X": Judge.get, "--method": Judge.get],
                               positionals: 1...1).parse(rest) != nil
            }
            guard let subcommand = rest.first, let options = groups[group]?[subcommand] else { return false }
            return options.parse(Array(rest.dropFirst())) != nil
        }

        private func npm(_ args: [String]) -> Bool {
            guard let subcommand = args.first else { return false }
            let rest = Array(args.dropFirst())
            switch subcommand {
            case "-v", "--version": return rest.isEmpty
            case "outdated", "ls", "list":
                // npm takes shortened option names and writes a log or a cache wherever one points: only these.
                return Options(switches: ["--json", "--long", "--all", "--workspaces", "--parseable"],
                               values: ["--depth": Judge.digits, "--workspace": Judge.workspace, "-w": Judge.workspace, "--omit": Judge.omit],
                               positional: Judge.package).parse(rest) != nil
            case "view":
                return Options(switches: ["--json"], positionals: 1...3, positional: Judge.package).parse(rest) != nil
            case "audit":
                return Options(switches: ["--json"], values: ["--audit-level": Judge.auditLevel], positionals: 0...0).parse(rest) != nil
            case "config":
                guard let action = rest.first else { return false }
                if action == "list" { return Options(switches: ["--json", "-l"], positionals: 0...0).parse(Array(rest.dropFirst())) != nil }
                // A key that names a credential would print it, and an option in its place would be taken as one.
                let secret = ["token", "auth", "password", "secret", "key", "cert"]
                return action == "get" && rest.count == 2 && ShellGate.matches(rest[1], #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#)
                    && !secret.contains { rest[1].lowercased().contains($0) }
            default: return false
            }
        }

        /// Only npm-check-updates, named in full, and only the options that report: `-u`/`--upgrade`, `-i` and `--doctor`
        /// change things. Never `ncu`, its bin's short name: npx resolves a name it finds in no `node_modules` from the
        /// registry, where `ncu` is another package, and installs and runs it without asking in a shell with no terminal.
        private func npx(_ args: [String]) -> Bool {
            guard args.first == "npm-check-updates" else { return false }
            let values = ["--format", "--target", "-t", "--filter", "-f", "--reject", "-x"]
            return Options(switches: ["--workspaces", "--deep", "--peer"],
                           values: Dictionary(uniqueKeysWithValues: values.map { ($0, Judge.anything) }),
                           positionals: 0...0).parse(Array(args.dropFirst())) != nil
        }

        private func node(_ args: [String]) -> Bool { args == ["-v"] || args == ["--version"] }
        private func commandV(_ args: [String]) -> Bool { args.count == 2 && args[0] == "-v" && !ShellGate.isOption(args[1]) }
        private func pwd(_ args: [String]) -> Bool { args.allSatisfy(ShellGate.isOption) }

        /// `cat`, `head`, `tail`, `ls`, `wc`, `stat`, `file`, `grep` and `rg`: only the options named below
        /// (none follows a link, waits, runs a program or reads names or patterns from a file), and every file
        /// they name, or the directory when they name none, inside the roots. `grep` and `rg` always need the
        /// directory inside, since they search it with `-r` or none at all.
        private func files(_ program: String, _ args: [String]) -> Bool {
            // Annotated: inferred, the merged dictionaries of function references fail a cast at run time.
            let digits: [String: (String) -> Bool] = ["-A": Judge.digits, "-B": Judge.digits, "-C": Judge.digits, "-m": Judge.digits]
            let grepValues: [String: (String) -> Bool] = ["-e": Judge.anything, "--regexp": Judge.anything]
            let rgValues: [String: (String) -> Bool] = ["-e": Judge.anything, "--regexp": Judge.anything, "-g": Judge.anything,
                                                         "--glob": Judge.anything, "-t": Judge.anything, "--type": Judge.anything]
            let options: Options
            switch program {
            case "cat": options = Options(switches: ["-n"])
            case "head", "tail": options = Options(values: ["-n": Judge.count, "-c": Judge.count], patterns: [#"^-[0-9]+$"#, #"^-[nc][0-9]+$"#])
            case "ls": options = Options(patterns: [#"^-[lAahtrS1d]+$"#])
            case "wc": options = Options(patterns: [#"^-[lwcm]+$"#])
            case "stat": options = Options(switches: ["-x"])
            case "file": options = Options(switches: ["-b", "-i"])
            case "grep":
                options = Options(values: digits.merging(grepValues) { $1 },
                                  patterns: [#"^-[rnHhiIcvlwxEFos]+$"#, #"^-[ABCm][0-9]+$"#, #"^--(include|exclude|exclude-dir)=.+$"#])
            case "rg":
                options = Options(switches: ["--files", "--hidden", "--no-heading", "--line-number", "--ignore-case", "--smart-case",
                                             "--fixed-strings", "--word-regexp", "--files-with-matches", "--count"],
                                  values: digits.merging(rgValues) { $1 },
                                  patterns: [#"^-[nisSwFlc]+$"#, #"^-[ABCm][0-9]+$"#])
            default: return false
            }
            guard let parsed = options.parse(args) else { return false }
            var paths = parsed.words
            // The first word `grep` and `rg` are given is the pattern, not a file, unless an option gave it
            // (or, for `rg --files`, there is none). Dropping it is safe: no file comes before the pattern.
            let searches = program == "grep" || program == "rg"
            let patternFromOption = !parsed.seen.isDisjoint(with: ["-e", "--regexp", "--files"])
            if searches, !patternFromOption, !paths.isEmpty { paths.removeFirst() }
            if searches || paths.isEmpty, !isInside(directory) { return false }
            return paths.allSatisfy(isInside)
        }
    }
}
