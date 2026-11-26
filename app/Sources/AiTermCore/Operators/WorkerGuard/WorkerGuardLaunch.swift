import Foundation
import CryptoKit
import Darwin

/// A private per-worker launch environment. Nothing is installed in the repository or the
/// person's git/CLI settings. The existing project pre-push hook keeps its arguments and stdin.
public enum WorkerGuardLaunch {
    public static func command(_ command: String, task: TaskItem, remote: String?, home: URL,
                               executable: URL, git: any GitRunning, slot: String = "main", publishes: Bool = false) throws -> String {
        var scope = WorkerGuard.Scope(task: task.id, worktree: task.worktreePath, branch: task.branch,
                                      remote: remote ?? ((try? git.run(["remote", "get-url", "origin"], in: task.worktreePath)) ?? ""), allowsPush: publishes)
        scope.ownership = task.signalTask?.ownership ?? 0
        scope.stage = task.signalTask?.stage
        return try prepare(scope: scope, home: home, slot: slot, executable: executable).wrap(command, agent: task.agent)
    }
    /// A signal task's agent in its worktree, given `prompt` (empty for none) and resuming `conversation` when there is
    /// one, wrapped in its branch guard on `slot`: the guarded command line its tab runs. A driven task's agent runs as
    /// a worker; a review's may not push. Blocking: it writes the guard's files.
    public static func workerCommand(task: TaskItem, prompt: String, resuming conversation: String?, slot: String,
                                     remote: String?, home: URL, executable: URL, git: any GitRunning) throws -> String {
        let command = try AgentCommand.build(agent: task.agent, model: task.model, reasoning: task.reasoning, prompt: prompt,
            worktreePath: task.worktreePath, git: git, worker: true,
            promptFile: "signal-" + UUID().uuidString + ".md", publishing: true, resuming: conversation)
        return try Self.command(command, task: task, remote: remote, home: home, executable: executable, git: git,
                                slot: slot, publishes: task.kind != .review)
    }
    public struct Prepared: Sendable {
        public var folder: URL
        public var settings: URL
        public var scopeFile: URL
        let executable: URL
        public func wrap(_ command: String, agent: AgentKind) throws -> String {
            let script = folder.appendingPathComponent("launch-" + agent.rawValue + ".sh")
            let content = WorkerGuardLaunch.launchScript(command: command, folder: folder)
            try PrivateFile.write(Data(content.utf8), to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            return "/bin/sh " + AgentCommand.shellQuote(script.path)
        }
    }
    public static func recordedScope(task: UUID, home: URL, slot: String = "main") -> WorkerGuard.Scope? {
        let file = folder(task: task, home: home, slot: slot).appendingPathComponent("scope.json")
        guard case .bytes(let data) = RegularFile.read(file.path, limit: 65536) else { return nil }
        return try? JSONDecoder().decode(WorkerGuard.Scope.self, from: data)
    }
    private static func folder(task: UUID, home: URL, slot: String) -> URL {
        let key = slot == "main" ? slot : SHA256.hash(data: Data(slot.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return AiTermPaths.supportDirectory(home: home).appendingPathComponent("workers/" + task.uuidString + "/" + key)
    }
    public static func prepare(scope: WorkerGuard.Scope, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               slot: String = "main", executable: URL) throws -> Prepared {
        let folder = folder(task: scope.task, home: home, slot: slot)
        let manager = FileManager.default
        for path in [folder, folder.appendingPathComponent("bin"), folder.appendingPathComponent("hooks")] {
            try manager.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let lock = Darwin.open(folder.appendingPathComponent("scope.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        if let old = recordedScope(task: scope.task, home: home, slot: slot),
           old.ownership > scope.ownership || (old.ownership == scope.ownership && (old.stage ?? 0) > (scope.stage ?? 0)) {
            throw CocoaError(.fileWriteNoPermission)
        }
        let config = folder.appendingPathComponent("scope.json"), settings = folder.appendingPathComponent("settings.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try PrivateFile.write(encoder.encode(scope), to: config)
        let check = AgentCommand.shellQuote(executable.path) + " --worker-guard hook " + AgentCommand.shellQuote(config.path)
        let hooks: JSONValue = ["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": .string(check), "timeout": 30]]]]]]
        try PrivateFile.write(encoder.encode(hooks), to: settings)
        for tool in ["git", "gh", "glab", "claude", "codex", "agy"] {
            let path = folder.appendingPathComponent("bin/" + tool)
            try PrivateFile.write(Data(shim(tool, folder: folder, executable: executable).utf8), to: path)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let hook = folder.appendingPathComponent("hooks/pre-push")
        try PrivateFile.write(Data(pushHook(folder: folder, executable: executable).utf8), to: hook)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        return Prepared(folder: folder, settings: settings, scopeFile: config, executable: executable)
    }
    private static func shim(_ tool: String, folder: URL, executable: URL) -> String {
        let variable = "AITERM_REAL_" + tool.uppercased()
        if tool == "codex" || tool == "claude" || tool == "agy" {
            // Codex exec_command defaults to a login shell, which resets PATH and loses the guard.
            // A per-launch setting preserves the shims without changing personal CLI settings.
            // Antigravity's commands inherit its PATH, so its own shim only passes the launch on.
            let options = switch tool {
            case "codex": "-c allow_login_shell=false "
            case "claude": "--settings " + AgentCommand.shellQuote(folder.appendingPathComponent("settings.json").path) + " "
            default: ""
            }
            return "#!/bin/sh\nset -eu\nexec \"$\(variable)\" " + options + "\"$@\"\n"
        }
        let exec = tool == "git"
            ? "exec \"$\(variable)\" -c " + AgentCommand.shellQuote("core.hooksPath=" + folder.appendingPathComponent("hooks").path) + " \"$@\""
            : "exec \"$\(variable)\" \"$@\""
        return """
        #!/bin/sh
        set -eu
        \(AgentCommand.shellQuote(executable.path)) --worker-guard argv \(AgentCommand.shellQuote(folder.appendingPathComponent("scope.json").path)) \(tool) "$@"
        if [ -z "${\(variable):-}" ]; then
            /usr/bin/printf '%s\\n' '\(tool) was not found in this worker environment.' >&2
            exit 127
        fi
        \(exec)

        """
    }
    private static func pushHook(folder: URL, executable: URL) -> String {
        """
        #!/bin/sh
        set -eu
        umask 077
        aiterm_guard_input=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/aiterm-pre-push.XXXXXX")
        trap '/bin/rm -f "$aiterm_guard_input"' EXIT HUP INT TERM
        /bin/cat > "$aiterm_guard_input"
        \(AgentCommand.shellQuote(executable.path)) --worker-guard push \(AgentCommand.shellQuote(folder.appendingPathComponent("scope.json").path)) "$1" "$2" < "$aiterm_guard_input"
        if [ -n "${AITERM_PREVIOUS_PRE_PUSH:-}" ] && [ -x "$AITERM_PREVIOUS_PRE_PUSH" ] && [ "$AITERM_PREVIOUS_PRE_PUSH" != "$0" ]; then
            "$AITERM_PREVIOUS_PRE_PUSH" "$@" < "$aiterm_guard_input"
        fi

        """
    }
    private static func launchScript(command: String, folder: URL) -> String {
        """
        #!/bin/sh
        set -eu
        umask 077
        AITERM_REAL_GIT=${AITERM_REAL_GIT:-$(/usr/bin/which git)}
        AITERM_REAL_GH=${AITERM_REAL_GH:-$(/usr/bin/which gh 2>/dev/null || true)}
        AITERM_REAL_GLAB=${AITERM_REAL_GLAB:-$(/usr/bin/which glab 2>/dev/null || true)}
        AITERM_REAL_CLAUDE=${AITERM_REAL_CLAUDE:-$(/usr/bin/which claude 2>/dev/null || true)}
        AITERM_REAL_CODEX=${AITERM_REAL_CODEX:-$(/usr/bin/which codex 2>/dev/null || true)}
        AITERM_REAL_AGY=${AITERM_REAL_AGY:-$(/usr/bin/which agy 2>/dev/null || true)}
        export AITERM_REAL_GIT AITERM_REAL_GH AITERM_REAL_GLAB AITERM_REAL_CLAUDE AITERM_REAL_CODEX AITERM_REAL_AGY
        aiterm_guard_previous=$("$AITERM_REAL_GIT" rev-parse --git-path hooks/pre-push)
        if [ "$aiterm_guard_previous" != \(AgentCommand.shellQuote(folder.appendingPathComponent("hooks/pre-push").path)) ]; then
            AITERM_PREVIOUS_PRE_PUSH=$aiterm_guard_previous
            export AITERM_PREVIOUS_PRE_PUSH
        fi
        aiterm_guard_count=${GIT_CONFIG_COUNT:-0}
        case "$aiterm_guard_count" in *[!0-9]*) /usr/bin/printf '%s\\n' 'The git environment has an invalid config count.' >&2; exit 2;; esac
        while [ "${#aiterm_guard_count}" -gt 1 ] && [ "${aiterm_guard_count#0}" != "$aiterm_guard_count" ]; do
            aiterm_guard_count=${aiterm_guard_count#0}
        done
        if [ "${#aiterm_guard_count}" -gt 4 ] || [ "$aiterm_guard_count" -gt 1024 ]; then
            /usr/bin/printf '%s\\n' 'The git environment has too many config entries to extend.' >&2
            exit 2
        fi
        export "GIT_CONFIG_KEY_${aiterm_guard_count}=core.hooksPath"
        export "GIT_CONFIG_VALUE_${aiterm_guard_count}=\(folder.appendingPathComponent("hooks").path)"
        GIT_CONFIG_COUNT=$((aiterm_guard_count + 1))
        PATH=\(AgentCommand.shellQuote(folder.appendingPathComponent("bin").path)):"$PATH"
        export GIT_CONFIG_COUNT PATH
        \(command)

        """
    }
}
