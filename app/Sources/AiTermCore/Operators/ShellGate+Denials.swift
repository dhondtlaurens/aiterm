import Foundation

/// What the Operator's shell is refused whatever the Oracle says, and whether or not it can answer (spec §A.2): a push,
/// the changes to a checkout that only a worker's task makes, and a merge or a change to a merge request on the host.
/// They are AiTerm's own, read from the command's words before any allowance, read or Oracle, so they hold on every path
/// that lets a command run unchallenged. `OperatorCommand.shellDenials` is Claude's backstop for when AiTerm isn't there.
///
/// The words are read the way the shell splits them, but forgivingly: where `route` gives up on what it can't see
/// through, this looks inside. Every simple command between `;`, `&&`, `||`, `|`, `&`, a newline or parentheses counts,
/// and so does one inside `$( )` or backticks, in the string a shell's `-c` or `eval` runs, and in git's own
/// `-c alias.<name>=…`. A command spelled so that no reading of its words names git, gh or glab (`$(echo git) push`) is past
/// it: the Oracle is the brake for those.
extension ShellGate {
    /// Why AiTerm refuses `command` outright, naming what does it instead; nil when nothing in it is a hard denial.
    public static func hardDenial(_ command: String) -> String? {
        denial(in: command, depth: 0)
    }

    static let pushDenial = "AiTerm refuses `git push` from the Operator's shell: pushes go through finish_task."

    static func workerDenial(_ what: String) -> String {
        "AiTerm refuses `\(what)` from the Operator's shell: commits, hard resets, checkouts and cleans are a worker's. "
            + "Send it to the task's worker with message_task."
    }

    static func hostDenial(_ what: String) -> String {
        "AiTerm refuses `\(what)` from the Operator's shell: merges and changes to a merge request are AiTerm's, through finish_task."
    }

    static func apiDenial(_ tool: String) -> String {
        "AiTerm refuses a `\(tool) api` call other than a GET from the Operator's shell: changes on the host, merges and merge "
            + "requests among them, are AiTerm's, through finish_task."
    }

    // MARK: Reading the words

    /// How deep a command inside a command is read: `sh -c "eval '…'"` and the like, a few levels and no more.
    private static let deepest = 4

    private static func denial(in command: String, depth: Int) -> String? {
        guard depth < deepest else { return nil }
        let (commands, nested) = simpleCommands(command)
        for words in commands {
            if let why = denial(of: words[...], depth: depth) { return why }
        }
        for text in nested {
            if let why = denial(in: text, depth: depth + 1) { return why }
        }
        return nil
    }

    /// The simple commands in `command` as their words, quotes and backslashes taken off and redirects with their targets
    /// dropped, and the text of each command substitution in it, which runs too.
    private static func simpleCommands(_ command: String) -> (commands: [[String]], nested: [String]) {
        let s = Array(command.unicodeScalars)
        var commands: [[String]] = [], nested: [String] = [], words: [String] = []
        var word = "", inWord = false, target = false, quote: Unicode.Scalar?

        func endWord() {
            if inWord { if target { target = false } else { words.append(word) } }
            word = ""; inWord = false
        }
        func endCommand() {
            endWord()
            target = false
            if !words.isEmpty { commands.append(words) }
            words = []
        }
        /// The text up to the `)` that closes the `$(` before `start`, nested parentheses counted, and the index past it.
        func substitution(from start: Int) -> (String, Int) {
            var depth = 1, j = start, text = String.UnicodeScalarView()
            while j < s.count {
                if s[j] == "(" { depth += 1 } else if s[j] == ")" { depth -= 1; if depth == 0 { return (String(text), j + 1) } }
                text.append(s[j]); j += 1
            }
            return (String(text), j)
        }
        /// The text up to the backtick that closes the one before `start`, and the index past it.
        func backticked(from start: Int) -> (String, Int) {
            var j = start, text = String.UnicodeScalarView()
            while j < s.count, s[j] != "`" { text.append(s[j]); j += 1 }
            return (String(text), min(j + 1, s.count))
        }

        var i = 0
        while i < s.count {
            let c = s[i], next = i + 1 < s.count ? s[i + 1] : nil
            if quote == "'" {
                if c == "'" { quote = nil } else { word.unicodeScalars.append(c) }
                i += 1
                continue
            }
            // A substitution runs inside double quotes as well as outside them.
            if c == "$", next == "(" {
                let (text, end) = substitution(from: i + 2)
                nested.append(text); inWord = true; i = end
                continue
            }
            if c == "`" {
                let (text, end) = backticked(from: i + 1)
                nested.append(text); inWord = true; i = end
                continue
            }
            if c == "\\" {
                if let next, next != "\n" { word.unicodeScalars.append(next); inWord = true }
                i += 2
                continue
            }
            if quote == "\"" {
                if c == "\"" { quote = nil } else { word.unicodeScalars.append(c) }
                i += 1
                continue
            }
            switch c {
            case "'", "\"":
                quote = c; inWord = true
            case " ", "\t":
                endWord()
            case "\n", "\r", ";", "&", "|", "(", ")":
                endCommand()
            case "<", ">":
                // A descriptor's number before it (`2>`) is no word; the operator's own characters after it (`>>`, `>&`,
                // `>|`) are part of it, and the word after it is its target, no argument.
                if inWord, !word.isEmpty, word.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) { word = ""; inWord = false }
                endWord()
                while i + 1 < s.count, ["<", ">", "|", "&"].contains(s[i + 1]) { i += 1 }
                target = true
            default:
                word.unicodeScalars.append(c); inWord = true
            }
            i += 1
        }
        endCommand()
        return (commands, nested)
    }

    private static func isAssignment(_ word: String) -> Bool {
        word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
    }

    /// Words a command can start with that run the command after them: keywords, and wrappers whose options and numbers
    /// (`nice -n 5`, `timeout 10`) come before it.
    private static let prefixes: Set<String> = [
        "{", "}", "!", "if", "then", "elif", "else", "do", "while", "until", "time", "coproc", "exec", "command", "builtin",
        "nohup", "noglob", "nocorrect", "sudo", "doas", "env", "nice", "timeout", "xargs", "caffeinate",
    ]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    private static func denial(of command: ArraySlice<String>, depth: Int) -> String? {
        var words = command
        while let first = words.first, isAssignment(first) || prefixes.contains(first) {
            words = words.dropFirst()
            guard prefixes.contains(first) else { continue }
            while let option = words.first,
                  option.hasPrefix("-") || isAssignment(option) || option.range(of: #"^[0-9.]+[smhd]?$"#, options: .regularExpression) != nil {
                words = words.dropFirst()
            }
        }
        guard let first = words.first else { return nil }
        let program = first.split(separator: "/").last.map(String.init) ?? first
        let args = Array(words.dropFirst())
        switch program {
        case "git":
            return gitDenial(args, depth: depth)
        case "gh":
            return requestDenial(tool: "gh", args, group: "pr", verbs: ghVerbs)
        case "glab":
            return requestDenial(tool: "glab", args, group: "mr", verbs: glabVerbs)
        case "eval":
            return denial(in: args.joined(separator: " "), depth: depth + 1)
        case _ where shells.contains(program):
            // `sh -c 'git push'`, `bash -lc …`: the string after the short option that holds `c`.
            guard let flag = args.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }),
                  flag + 1 < args.count else { return nil }
            return denial(in: args[flag + 1], depth: depth + 1)
        default:
            return nil
        }
    }

    // MARK: git

    /// git's options before its subcommand that take the next word as their value.
    private static let gitValued: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"]

    /// `git` with any of its options before the subcommand (`-C <dir>`, `-c k=v`, `--no-pager`, `--git-dir=…`).
    private static func gitDenial(_ args: [String], depth: Int) -> String? {
        var i = 0
        while i < args.count, args[i].hasPrefix("-") {
            guard gitValued.contains(args[i]) else { i += 1; continue }
            if args[i] == "-c", i + 1 < args.count, let why = aliasDenial(args[i + 1], depth: depth) { return why }
            i += 2
        }
        guard i < args.count else { return nil }
        let subcommand = args[i], rest = args[(i + 1)...]
        switch subcommand {
        case "push": return pushDenial
        case "commit", "checkout", "switch", "clean": return workerDenial("git " + subcommand)
        case "reset" where rest.contains("--hard"): return workerDenial("git reset --hard")
        default: return nil
        }
    }

    /// `-c alias.<name>=<value>`: what the alias would run, as git runs it, a `!` one in the shell.
    private static func aliasDenial(_ setting: String, depth: Int) -> String? {
        guard setting.lowercased().hasPrefix("alias."), let equals = setting.firstIndex(of: "=") else { return nil }
        let value = setting[setting.index(after: equals)...]
        return value.hasPrefix("!") ? denial(in: String(value.dropFirst()), depth: depth + 1) : denial(in: "git " + value, depth: depth + 1)
    }

    // MARK: gh and glab

    /// The `gh pr` and `glab mr` subcommands, aliases included, that merge a request or change it.
    private static let ghVerbs: Set<String> = ["merge", "close", "reopen", "edit", "review", "ready", "create", "new", "comment", "lock",
                                               "unlock", "update-branch"]
    private static let glabVerbs: Set<String> = ["merge", "accept", "close", "reopen", "approve", "revoke", "unapprove", "update", "note",
                                                 "comment", "create", "new", "rebase", "delete"]
    /// gh's and glab's options that take the next word as their value, wherever they stand.
    private static let hostValued: Set<String> = ["-R", "--repo", "--hostname", "-X", "--method", "-f", "-F", "--field", "--raw-field",
                                                  "-H", "--header", "--input", "-q", "--jq", "-t", "--template", "-p", "--preview", "--cache"]

    private static func requestDenial(tool: String, _ args: [String], group: String, verbs: Set<String>) -> String? {
        var positionals: [String] = [], i = 0
        while i < args.count, positionals.count < 2 {
            let word = args[i]
            if word.hasPrefix("-") { i += hostValued.contains(word) ? 2 : 1 } else { positionals.append(word); i += 1 }
        }
        if positionals.first == "api" { return sendsToTheAPI(args) ? apiDenial(tool) : nil }
        guard positionals.count == 2, positionals[0] == group, verbs.contains(positionals[1]) else { return nil }
        return hostDenial("\(tool) \(group) \(positionals[1])")
    }

    /// Whether an `api` call's method is not GET: one named (`-X PUT`, `-XPUT`, `--method=PUT`, `-iXPUT`), or, with none
    /// named, fields or a body, which gh and glab send as a POST.
    private static func sendsToTheAPI(_ args: [String]) -> Bool {
        var method: String?, sends = false, i = 0
        while i < args.count {
            let word = args[i]
            i += 1
            if word == "--" { break }
            if word.hasPrefix("--") {
                let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
                let name = parts[0], inline = parts.count > 1 ? parts[1] : nil
                switch name {
                case "--method": method = inline ?? (i < args.count ? args[i] : nil)
                case "--field", "--raw-field", "--input": sends = true
                default: break
                }
                if inline == nil, hostValued.contains(name) { i += 1 }
            } else if word.hasPrefix("-"), word.count > 1 {
                // A cluster of short options: the first that takes a value takes the rest of the word, or the next word.
                var cluster = Substring(word.dropFirst())
                while let flag = cluster.first {
                    cluster = cluster.dropFirst()
                    guard hostValued.contains("-" + String(flag)) else { continue }
                    let value = cluster.isEmpty ? (i < args.count ? args[i] : nil) : String(cluster)
                    if cluster.isEmpty { i += 1 }
                    if flag == "X" { method = value } else if flag == "f" || flag == "F" { sends = true }
                    break
                }
            }
        }
        if let method { return method.uppercased() != "GET" }
        return sends
    }
}
