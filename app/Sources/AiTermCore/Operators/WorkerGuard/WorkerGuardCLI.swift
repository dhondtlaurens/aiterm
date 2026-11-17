import Foundation

/// The production app and a test-only probe call this same entry before constructing any UI or
/// live controller. Host I/O has a seam; the shell rules and Git ref checks are always the real ones.
public enum WorkerGuardCLI {
    public struct Dependencies: Sendable {
        public var git: any GitRunning
        public var fence: @Sendable (WorkerGuard.Scope) async throws -> WorkerGuard.Fence
        public init(git: any GitRunning, fence: @escaping @Sendable (WorkerGuard.Scope) async throws -> WorkerGuard.Fence) {
            self.git = git; self.fence = fence
        }
    }
    public struct Output: Sendable {
        public var status: Int32
        public var output: String
        public var error: String
    }
    public static func run(_ arguments: [String], input: Data = Data(), dependencies: Dependencies) async -> Output {
        let hook = arguments.first == "hook"
        do {
            guard arguments.count >= 2 else { throw WorkerGuard.GuardFailure("The worker guard needs its scope file.") }
            let file = URL(fileURLWithPath: arguments[1])
            let scope = try await read(file)
            let reason: String?
            switch arguments[0] {
            case "hook":
                let json = try JSONDecoder().decode(JSONValue.self, from: input)
                guard json["tool_name"] == "Bash", let command = json["tool_input"]?["command"]?.stringValue else {
                    throw WorkerGuard.GuardFailure("The worker guard could not read this Bash call.")
                }
                let cwd = json["cwd"]?.stringValue ?? scope.worktree
                reason = try await BackgroundWork.run {
                    ShellGate.publishingDenial(command) { program, args in
                        if let why = WorkerGuard.argvDenial(program: program, arguments: args, branch: scope.branch, allowsPush: scope.allowsPush) { return why }
                        return configuredAliasDenial(program, args: args, cwd: cwd, scope: scope, git: dependencies.git)
                    }
                }
            case "argv":
                guard arguments.count >= 3 else { throw WorkerGuard.GuardFailure("The worker guard needs the program's arguments.") }
                let program = arguments[2], args = Array(arguments.dropFirst(3)), cwd = FileManager.default.currentDirectoryPath
                reason = try await BackgroundWork.run {
                    WorkerGuard.argvDenial(program: program, arguments: args, branch: scope.branch, allowsPush: scope.allowsPush)
                        ?? configuredAliasDenial(program, args: args, cwd: cwd, scope: scope, git: dependencies.git)
                }
            case "push":
                guard arguments.count == 4, scope.allowsPush else { throw WorkerGuard.GuardFailure("Publishing is not enabled for this worker.") }
                let refs = try WorkerGuard.pushes(String(decoding: input, as: UTF8.self)), remote = arguments[3]
                guard WorkerGuard.sameLocation(remote, scope.remote) else { throw WorkerGuard.GuardFailure("This push goes to another repository.") }
                let head = try await BackgroundWork.run {
                    let branch = try dependencies.git.run(["symbolic-ref", "--short", "HEAD"], in: scope.worktree)
                    guard branch == scope.branch else { throw WorkerGuard.GuardFailure("The worktree is no longer on its task branch.") }
                    return try dependencies.git.run(["rev-parse", "--verify", "refs/heads/" + scope.branch + "^{commit}"], in: scope.worktree)
                }
                let fence = try await dependencies.fence(scope)
                guard try await read(file) == scope else { throw WorkerGuard.GuardFailure("The worker's authority changed while the host was read.") }
                reason = try await BackgroundWork.run {
                    guard try dependencies.git.run(["symbolic-ref", "--short", "HEAD"], in: scope.worktree) == scope.branch,
                          try dependencies.git.run(["rev-parse", "--verify", "refs/heads/" + scope.branch + "^{commit}"], in: scope.worktree) == head else {
                        throw WorkerGuard.GuardFailure("The worker's branch or head changed while the host was read.")
                    }
                    return try WorkerGuard.pushDenial(refs, scope: scope, remote: remote, head: head, defaultBranch: fence.defaultBranch,
                                              protection: fence.protection) { old, new in
                        do { _ = try dependencies.git.run(["merge-base", "--is-ancestor", old, new], in: scope.worktree); return true }
                        catch let error as GitError where error.code == 1 && !error.timedOut { return false }
                    }
                }
            default: throw WorkerGuard.GuardFailure("Unknown worker guard mode.")
            }
            guard try await read(file) == scope else { throw WorkerGuard.GuardFailure("The worker's authority changed during this check.") }
            return result(reason, hook: hook)
        } catch { return result(OperationIssue.reason(of: error), hook: hook) }
    }
    private static func read(_ file: URL) async throws -> WorkerGuard.Scope {
        try await BackgroundWork.run { try JSONDecoder().decode(WorkerGuard.Scope.self, from: Data(contentsOf: file)) }
    }
    private static func result(_ reason: String?, hook: Bool) -> Output {
        if hook {
            let value: JSONValue = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": .string(reason == nil ? "allow" : "deny"),
                                                          "permissionDecisionReason": .string(reason ?? "The local worker guard allows this command.")]]
            let bytes = try! JSONEncoder().encode(value)
            return Output(status: 0, output: String(decoding: bytes, as: UTF8.self), error: "")
        }
        return Output(status: reason == nil ? 0 : 2, output: "", error: reason ?? "")
    }
    /// The argv shim sees expanded arguments. Scan a configured git alias once with the argv rules.
    private static func configuredAliasDenial(_ program: String, args: [String], cwd: String, scope: WorkerGuard.Scope, git: any GitRunning) -> String? {
        let name = URL(fileURLWithPath: program).lastPathComponent
        do {
            if name == "git", let command = WorkerGuard.gitCommand(args) {
                let globalCount = args.count - command.arguments.count - 1
                let query = Array(args.prefix(globalCount)) + ["config", "--get", "alias." + command.verb]
                if let alias = try git.ask(query, in: cwd, none: [1]) {
                    let globals = Array(args.prefix(globalCount)).map(AgentCommand.shellWord).joined(separator: " ")
                    let extra = command.arguments.map(AgentCommand.shellWord).joined(separator: " ")
                    let text = (alias.hasPrefix("!") ? String(alias.dropFirst()) : "git " + globals + " " + alias) + " " + extra
                    return ShellGate.publishingDenial(text) { nested, words in
                        WorkerGuard.argvDenial(program: nested, arguments: words, branch: scope.branch, allowsPush: scope.allowsPush)
                    }
                }
            }
        } catch { return "The worker guard could not verify this command: " + OperationIssue.reason(of: error) }
        return nil
    }
}
