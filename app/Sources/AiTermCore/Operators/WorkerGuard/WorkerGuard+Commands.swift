import Foundation

extension WorkerGuard {
    public static func argvDenial(program: String, arguments: [String], branch: String, allowsPush: Bool) -> String? {
        let program = URL(fileURLWithPath: program).lastPathComponent
        switch program {
        case "git": return gitDenial(arguments, branch: branch, allowsPush: allowsPush)
        case "gh", "glab": return hostDenial(program, arguments: arguments, allowsPush: allowsPush)
        default: return nil
        }
    }
    static func gitCommand(_ args: [String]) -> (verb: String, arguments: [String])? {
        var index = 0
        while index < args.count, args[index].hasPrefix("-") { index += ShellGate.gitValued.contains(args[index]) ? 2 : 1 }
        guard index < args.count else { return nil }
        return (args[index], Array(args.dropFirst(index + 1)))
    }
    private static func gitDenial(_ args: [String], branch: String, allowsPush: Bool) -> String? {
        for (index, word) in args.enumerated() {
            let setting = ["-c", "--config-env"].contains(word) && index + 1 < args.count ? args[index + 1]
                : word.hasPrefix("-c") ? String(word.dropFirst(2)) : word.hasPrefix("--config-env=") ? String(word.dropFirst(13)) : ""
            if setting.lowercased().hasPrefix("core.hookspath=") { return "A worker may not override its push hook." }
        }
        guard let command = gitCommand(args) else { return nil }
        guard command.verb == "push" else { return nil }
        guard allowsPush else { return "Publishing is not enabled for this worker." }
        var refs: [String] = [], index = 0
        while index < command.arguments.count {
            let word = command.arguments[index]; index += 1
            if word == "--" { refs += command.arguments.dropFirst(index); break }
            if word.hasPrefix("-") {
                let flag = String(word.split(separator: "=", maxSplits: 1)[0])
                if flag.hasPrefix("--force") || ["--all", "--mirror", "--delete", "--tags"].contains(flag)
                    || (flag.hasPrefix("--no-v") && "--no-verify".hasPrefix(flag))
                    || (!flag.hasPrefix("--") && flag.dropFirst().prefix(while: { $0 != "o" }).contains("f")) {
                    return "Workers never force-push, skip the push hook or push multiple branches."
                }
                if ["-o", "--push-option", "--repo", "--receive-pack", "--exec"].contains(flag), !word.contains("=") { index += 1 }
                continue
            }
            refs.append(word)
        }
        // The first positional is the remote. Its actual URL and every resulting ref are checked
        // by pre-push, including implicit push.default and remote refspecs.
        for refspec in refs.dropFirst() {
            if refspec.hasPrefix("+") { return "Workers never force-push." }
            let parts = refspec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let target = WorkerGuard.shortBranch(parts.last ?? "")
            let source = WorkerGuard.shortBranch(parts.first ?? "")
            guard parts.count <= 2, [branch, "HEAD"].contains(target), [branch, "HEAD"].contains(source) else {
                return "A worker may push only its own task branch."
            }
        }
        return nil
    }
    static func graphqlMerges(_ query: String) -> Bool {
        // Field values and comments are data, including a comment that names this mutation.
        let code = query.replacingOccurrences(of: #"\"(?:\\.|[^\"\\])*\"|#[^\n]*"#, with: " ", options: .regularExpression)
        return code.range(of: #"\b(?:mergePullRequest|mergeRequestAccept)\s*\("#, options: .regularExpression) != nil
    }
    private static func hostField(_ arguments: [String], at index: Int) -> String? {
        let arg = arguments[index]
        if ["-f", "-F", "--field", "--raw-field"].contains(arg), index + 1 < arguments.count { return arguments[index + 1] }
        if arg.hasPrefix("--field=") { return String(arg.dropFirst(8)) }
        if arg.hasPrefix("--raw-field=") { return String(arg.dropFirst(12)) }
        if (arg.hasPrefix("-f") || arg.hasPrefix("-F")), arg.count > 2 { return String(arg.dropFirst(2)) }
        return nil
    }
    private static func hostDenial(_ tool: String, arguments: [String], allowsPush: Bool) -> String? {
        let positionals = ShellGate.hostPositionals(arguments)
        let group = tool == "gh" ? "pr" : "mr"
        if positionals.first == group, positionals.count >= 2 {
            if ["merge", "accept"].contains(positionals[1]) { return "Workers never merge; AiTerm performs an enabled merge through the host." }
            if !allowsPush, ["create", "new", "ready", "update"].contains(positionals[1]) { return "Publishing is not enabled for this worker." }
        }
        if positionals.first == "api", positionals.count > 1 {
            let endpoint = positionals[1].removingPercentEncoding ?? positionals[1]
            var query: String?
            for index in arguments.indices {
                let field = hostField(arguments, at: index)
                if let field, field.hasPrefix("query=") { query = String(field.dropFirst(6)) }
            }
            if let query, graphqlMerges(query) { return "Workers never merge through an API." }
            if ShellGate.sendsToTheAPI(arguments), endpoint.range(of: #"(?i)/merge(?:$|\?)"#, options: .regularExpression) != nil {
                return "Workers never merge through an API."
            }
        }
        return nil
    }
}
