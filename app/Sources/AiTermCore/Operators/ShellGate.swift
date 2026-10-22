import Foundation

/// Sorts a shell command the Operator wants to run into a read that goes ahead at once or one the Oracle
/// judges first (spec §A.1). It is a pure function of the text: nothing is run, and whenever it is unsure,
/// which is the answer for anything it does not know by name, the command is `.oracle`, never `.read`.
public enum ShellGate {
    public enum Route: Equatable {
        /// Runs at once. `rewrite` is the command to run instead, when the one asked for would show a secret.
        case read(rewrite: String?)
        case oracle
    }

    /// What a bare `env` or `printenv` runs instead: every variable, with the value of any whose name holds
    /// TOKEN, SECRET, KEY or PASSWORD (in any case) replaced by `***`. A line that does not start `NAME=` is
    /// the rest of a multi-line value, which could be a private key, so it is dropped. The programs are
    /// named in full: the command has to work with nothing but `/bin` on the PATH.
    public static let maskedEnv = """
        /usr/bin/env | /usr/bin/awk '/^[A-Za-z_][A-Za-z0-9_]*=/ { name = $0; sub(/=.*/, "", name); \
        if (toupper(name) ~ /TOKEN|SECRET|KEY|PASSWORD/) print name "=***"; else print $0 }'
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
    /// an expansion (`$`, a backtick), a subshell, a newline, a backslash, a lone `&`, any other redirect, an
    /// unbalanced quote, or a segment with nothing in it.
    private static func segments(of command: String) -> [[String]]? {
        if command.contains(where: \.isNewline) { return nil }
        let characters = Array(command)
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quoted = false
        var redirected = false
        var quote: Character?

        func endWord() -> Bool {
            defer { word = ""; inWord = false; quoted = false; redirected = false }
            guard inWord else { return true }
            if redirected {
                guard !quoted, harmlessRedirects.contains(word) else { return false }
                return true
            }
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
        while i < characters.count {
            let c = characters[i]
            let next = i + 1 < characters.count ? characters[i + 1] : nil
            i += 1
            if let open = quote {
                if c == open { quote = nil; continue }
                if open == "\"", ["\\", "$", "`"].contains(c) { return nil }
                word.append(c)
                continue
            }
            switch c {
            case "'", "\"":
                quote = c; inWord = true; quoted = true
            case "\\", "$", "`", "(", ")":
                return nil
            case " ", "\t":
                guard endWord() else { return nil }
            case ";":
                guard endSegment() else { return nil }
            case "|":
                guard endSegment() else { return nil }
                if next == "|" { i += 1 }
            case "&":
                if next != "&", inWord, !quoted, word == "2>" {
                    word.append(c)
                } else if next == "&" {
                    guard endSegment() else { return nil }
                    i += 1
                } else {
                    return nil
                }
            case "<", ">":
                word.append(c); inWord = true; redirected = true
            default:
                word.append(c); inWord = true
            }
        }
        guard quote == nil, endSegment() else { return nil }
        return segments
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
            "which": Judge.which, "type": Judge.which, "command": Judge.commandV, "pwd": Judge.pwd,
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

        // MARK: Arguments

        private static func isOption(_ word: String) -> Bool { word.hasPrefix("-") && word.count > 1 }

        /// The letters of a `-abc` cluster; nil for a long option or a word that is no option.
        private static func letters(_ word: String) -> Substring? {
            isOption(word) && !word.hasPrefix("--") ? word.dropFirst() : nil
        }

        /// A long option's name without its dashes or `=value`.
        private static func name(_ word: String) -> String? {
            word.hasPrefix("--") ? String(word.dropFirst(2).prefix { $0 != "=" }) : nil
        }

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
            switch subcommand {
            case "status", "log", "show", "diff", "rev-parse", "merge-base":
                // Each of these writes or runs a program with the options below, or with `--no-index` reads outside the repository.
                return !rest.contains { ["output", "ext-diff", "textconv", "no-index"].contains(Judge.name($0) ?? "") || $0.hasPrefix("--output") }
            case "branch":
                var i = 0
                while i < rest.count {
                    if ["-a", "-r", "-v", "-vv", "--list", "--show-current"].contains(rest[i]) {
                        i += 1
                    } else if rest[i] == "--contains", i + 1 < rest.count, !Judge.isOption(rest[i + 1]) {
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
                return rest.count == 2 && rest[0] == "get-url" && !Judge.isOption(rest[1])
            case "ls-remote", "fetch":
                return !rest.contains { ["upload-pack", "receive-pack", "exec"].contains(Judge.name($0) ?? "") }
            default:
                return false
            }
        }

        private func glab(_ args: [String]) -> Bool { host(args, groups: ["mr": ["view", "list", "diff"], "ci": ["status", "view", "list"]]) }
        private func gh(_ args: [String]) -> Bool { host(args, groups: ["pr": ["view", "list", "diff", "checks"], "run": ["view", "list"]]) }

        /// `glab` and `gh`: a few read subcommands, and `api` as long as it is a GET with nothing to send.
        private func host(_ args: [String], groups: [String: Set<String>]) -> Bool {
            guard let group = args.first else { return false }
            if group == "api" { return Judge.isGet(Array(args.dropFirst())) }
            return args.count >= 2 && groups[group]?.contains(args[1]) == true
        }

        /// An `api` call that names a path, asks for no method but GET and sends no field or input.
        private static func isGet(_ args: [String]) -> Bool {
            var path = false
            var i = 0
            while i < args.count {
                let word = args[i]
                i += 1
                if word == "-X" || word == "--method" || word.hasPrefix("--method=") || word.hasPrefix("-X") {
                    let value = word.hasPrefix("--method=") ? String(word.dropFirst(9))
                        : word.hasPrefix("-X") && word.count > 2 ? String(word.dropFirst(2))
                        : i < args.count ? args[i] : ""
                    if word == "-X" || word == "--method" { i += 1 }
                    guard value.uppercased() == "GET" else { return false }
                } else if word.hasPrefix("-f") || word.hasPrefix("-F") || ["field", "raw-field", "input"].contains(name(word) ?? "") {
                    return false
                } else if !isOption(word) {
                    path = true
                }
            }
            return path
        }

        private func npm(_ args: [String]) -> Bool {
            guard let subcommand = args.first else { return false }
            let rest = Array(args.dropFirst())
            switch subcommand {
            case "-v", "--version": return rest.isEmpty
            case "outdated", "ls", "list", "view": return true
            case "audit": return !rest.contains { $0.drop { $0 == "-" } == "fix" }
            case "config":
                guard let action = rest.first else { return false }
                if action == "list" { return true }
                // A key that names a credential would print it.
                let secret = ["token", "auth", "password", "secret", "key", "cert"]
                return action == "get" && rest.count == 2 && !secret.contains { rest[1].lowercased().contains($0) }
            default: return false
            }
        }

        /// Only npm-check-updates, which changes package.json with `-u`/`--upgrade`, `-i` and `--doctor`.
        private func npx(_ args: [String]) -> Bool {
            guard let tool = args.first, ["npm-check-updates", "ncu"].contains(tool) else { return false }
            return !args.dropFirst().contains {
                let option = Judge.name($0)
                return option == "upgrade" || option == "doctor" || option == "interactive"
                    || (Judge.letters($0)?.contains { $0 == "u" || $0 == "i" } ?? false)
            }
        }

        private func node(_ args: [String]) -> Bool { args == ["-v"] || args == ["--version"] }
        private func which(_ args: [String]) -> Bool { true }
        private func commandV(_ args: [String]) -> Bool { args.count == 2 && args[0] == "-v" && !Judge.isOption(args[1]) }
        private func pwd(_ args: [String]) -> Bool { args.allSatisfy(Judge.isOption) }

        /// `cat`, `head`, `tail`, `ls`, `wc`, `stat`, `file`, `grep` and `rg`: every file they name, or the
        /// directory when they name none, has to be inside the roots, and none of the options that follow
        /// links, wait, run a program or read the names or patterns from a file may be there. `grep` and `rg`
        /// always need the directory inside, since they search it with `-r` or none at all.
        private func files(_ program: String, _ args: [String]) -> Bool {
            let searches = program == "grep" || program == "rg"
            var paths: [String] = []
            var optionsEnded = false
            var patternFromOption = false
            for word in args {
                if optionsEnded || !Judge.isOption(word) {
                    paths.append(word)
                } else if word == "--" {
                    optionsEnded = true
                } else if refuses(program, word) {
                    return false
                } else if Judge.name(word) == "regexp" || Judge.name(word) == "files" || Judge.letters(word)?.contains("e") == true {
                    patternFromOption = true
                }
            }
            // The first word `grep` and `rg` are given is the pattern, not a file, unless an option gave it
            // (or, for `rg --files`, there is none). Dropping it is safe: no file comes before the pattern.
            if searches, !patternFromOption, !paths.isEmpty { paths.removeFirst() }
            if searches || paths.isEmpty, !isInside(directory) { return false }
            return paths.allSatisfy(isInside)
        }

        /// The options of these programs that follow a link, wait for ever, run a program or read names or
        /// patterns from a file.
        private func refuses(_ program: String, _ option: String) -> Bool {
            let name = Judge.name(option), letters = Judge.letters(option)
            switch program {
            case "tail": return name == "follow" || letters?.contains { $0 == "f" || $0 == "F" } == true
            case "wc": return name == "files0-from"
            case "file": return ["files-from", "magic-file", "compile"].contains(name ?? "") || letters?.contains { "fCm".contains($0) } == true
            case "grep":
                return ["file", "exclude-from", "include-from", "dereference-recursive"].contains(name ?? "")
                    || letters?.contains { $0 == "f" || $0 == "R" } == true
            case "rg":
                return ["file", "ignore-file", "ignore-file-case-insensitive", "pre", "pre-glob", "hostname-bin", "follow", "config-path"]
                    .contains(name ?? "") || letters?.contains { $0 == "f" || $0 == "L" } == true
            default: return false
            }
        }
    }
}
