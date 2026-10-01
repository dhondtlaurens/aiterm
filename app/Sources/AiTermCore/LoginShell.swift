import Foundation

/// The user's interactive login shell, for what only it knows: the `PATH` their rc files build. A
/// GUI app inherits launchd's minimal one, with no Homebrew, `~/.local/bin` or version-manager
/// shims in it. It costs the better part of a second, so ask it everything at once.
public enum LoginShell {
    /// Runs `command` in `zsh -lic` and returns its standard output, or `nil` when the shell exited
    /// non-zero or ran out of time. The deadline is for an rc file that hangs: a shell that never
    /// answers must not stall startup.
    public static func run(_ command: String) -> String? {
        guard let result = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), ["-lic", command], timeout: 15),
              result.status == 0, !result.timedOut else { return nil }
        return result.stdout
    }
}

/// Where a CLI is, as the task window's shell would find it — the one answer the New Task sheet
/// and Settings both go by, so an agent is never offered in one and "unavailable" in the other.
extension LoginShell {
    /// For each name, what `command -v` says — a path, `alias name=…`, or the bare name of a
    /// function — then what `whence -p` says: the file on the `PATH`, whatever shadows it.
    /// A line each, `name<TAB>answer`. The trailing `true` keeps a missing last name from
    /// failing the command, whose output `run` would discard.
    static func locateQuery(_ names: [String]) -> String {
        "for c in \(names.joined(separator: " ")); do "
            + #"print -r -- "$c"$'\t'"$(command -v -- $c)"; print -r -- "$c"$'\t'"$(whence -p -- $c)"; "#
            + "done; true"
    }

    /// The executable each of `names` runs, found in one login shell; a name with no such file is
    /// absent. `nil` when the shell itself failed, which says nothing about what is installed.
    ///
    /// Only an absolute path to an executable file counts, because `Process` searches no `PATH`.
    /// An alias counts as its first absolute word — Claude's installer can leave
    /// `alias claude=~/.claude/local/claude` and nothing on the `PATH` — and a function, or an
    /// alias to a bare name, as the file on the `PATH` it most likely wraps. Only names that are
    /// safe unquoted in a command are asked about.
    public static func locate(_ names: [String], runner: (String) -> String? = run,
                              isExecutable: (String) -> Bool = isExecutableFile) -> [String: String]? {
        let asked = names.filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
        guard !asked.isEmpty else { return [:] }
        guard let output = runner(locateQuery(asked)) else { return nil }
        var found: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, case let name = String(fields[0]), asked.contains(name), found[name] == nil,
                  let path = executable(named: name, in: fields[1]), isExecutable(path) else { continue }
            found[name] = path
        }
        return found
    }

    /// The path an answer from `command -v` or `whence -p` names, if it names one.
    private static func executable(named name: String, in answer: Substring) -> String? {
        let answer = answer.trimmingCharacters(in: .whitespaces)
        guard answer.hasPrefix("alias \(name)=") else { return answer.hasPrefix("/") ? answer : nil }
        // zsh prints the alias's body as one quoted word; the body is itself a command line.
        guard let body = words(answer.dropFirst("alias \(name)=".count)).first else { return nil }
        return words(body[...]).lazy.map(expandingTilde).first { $0.hasPrefix("/") }
    }

    /// `text` split into words the way zsh splits a simple command, with the quotes removed.
    private static func words(_ text: Substring) -> [String] {
        var words: [String] = [], word = "", inWord = false, quote: Character?, escaped = false
        for c in text {
            if escaped { word.append(c); escaped = false; continue }
            switch (quote, c) {
            case (nil, "\\"), ("\"", "\\"): escaped = true; inWord = true
            case (nil, "'"), (nil, "\""): quote = c; inWord = true
            case ("'", "'"), ("\"", "\""): quote = nil
            case (nil, " "), (nil, "\t"):
                if inWord { words.append(word) }
                word = ""; inWord = false
            default: word.append(c); inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }

    private static func expandingTilde(_ word: String) -> String {
        word == "~" || word.hasPrefix("~/") ? NSHomeDirectory() + word.dropFirst() : word
    }

    /// An executable regular file: `FileManager.isExecutableFile` alone is true of a directory.
    public static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
