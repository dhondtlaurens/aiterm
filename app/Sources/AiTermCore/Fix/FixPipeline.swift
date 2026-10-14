import Foundation
import Synchronization

/// A fix's four stages as closures, so the app's session is tested with fakes and the live ones are
/// built once from the units. Every closure runs off the main actor: git through `BackgroundWork`,
/// the agent and `verify` through `AgentProcess`, landing on `TaskWorkflow`'s queue.
public struct FixPipeline: Sendable {
    /// Makes the clone the fix works in.
    public var prepare: @Sendable (FixRequest) async throws(FixRefusal) -> FixClone
    /// The agent's read-only run: a checked proposal or its reason for none, and the session to resume.
    public var look: @Sendable (FixerAgent, FixClone, FixRequest) async throws(FixRefusal) -> (FixLook, session: String)
    /// The agent's run that makes the fix in the clone, then AiTerm's own checks and the proposal's
    /// `verify`. Returns the tip the checks passed — the one commit `land` may bring in.
    public var apply: @Sendable (FixerAgent, FixClone, FixProposal, String) async throws(FixRefusal) -> String
    /// Brings the checked tip into the project, keeping the old one as a backup.
    public var land: @Sendable (FixClone, String) async throws(FixRefusal) -> FixLanding

    public init(prepare: @escaping @Sendable (FixRequest) async throws(FixRefusal) -> FixClone,
                look: @escaping @Sendable (FixerAgent, FixClone, FixRequest) async throws(FixRefusal) -> (FixLook, session: String),
                apply: @escaping @Sendable (FixerAgent, FixClone, FixProposal, String) async throws(FixRefusal) -> String,
                land: @escaping @Sendable (FixClone, String) async throws(FixRefusal) -> FixLanding) {
        self.prepare = prepare; self.look = look; self.apply = apply; self.land = land
    }

    public static let lookTimeout: Duration = .seconds(180), applyTimeout: Duration = .seconds(600)
    /// The least `verify` gets when the agent used up nearly all of Apply's budget.
    static let verifyFloor: Duration = .seconds(30)

    /// The real one. `model` gives the agent's card defaults; `locate` the CLI's path (the harness
    /// runner's locator, which may ask a login shell); `project` the project the fix lands in.
    public static func live(git: any GitRunning, workflow: TaskWorkflow, project: Project,
                            model: @escaping @Sendable (FixerAgent) -> (model: String, reasoning: String?),
                            locate: @escaping @Sendable (String) -> String?) -> FixPipeline {
        // Each clone's branch tips as Look found them, by the clone's path, for Apply's “moved only
        // what it said” check. A pipeline serves every fix of its project, so one clone's tips must
        // never be another's; an entry goes when its Apply ends, or once its clone is gone.
        let tipsAtLook = Mutex<[String: [String: String]]>([:])
        return FixPipeline(
            prepare: { request throws(FixRefusal) in
                try await BackgroundWork.run { () throws(FixRefusal) -> FixClone in try FixClone.make(for: request, git: git) }
            },
            look: { agent, clone, request throws(FixRefusal) in
                let tips = try await read(clone) { try $0.branchTips() }
                tipsAtLook.withLock { known in
                    known = known.filter { FileManager.default.fileExists(atPath: $0.key) }   // declined proposals' clones
                    known[clone.path] = tips
                }
                let choice = model(agent)
                let invocation = try FixerLaunch.look(agent, model: choice.model, reasoning: choice.reasoning, clone: clone,
                                                      request: request, sessionID: UUID().uuidString.lowercased())
                let output = try await run(agent, invocation, in: clone, timeout: lookTimeout, locate: locate)
                // Read-only is the agent's word: Claude's `git log --output=` can still write `.git/config`.
                try clone.checkSettings()
                let (answer, session) = try FixerLaunch.lookAnswer(agent, output: output, invocation: invocation)
                let localOnly = try await read(clone) { try $0.localOnly() }
                return (try FixLook(validating: answer, request: request, localOnly: localOnly, agent: agent), session)
            },
            apply: { agent, clone, proposal, session throws(FixRefusal) in
                defer { tipsAtLook.withLock { $0[clone.path] = nil } }
                guard let before = tipsAtLook.withLock({ $0[clone.path] }) else {
                    throw .checkFailed("Couldn’t check the fix: its branches were not read before it was made, so nothing was changed.")
                }
                let started = ContinuousClock.now
                let choice = model(agent)
                let invocation = try FixerLaunch.apply(agent, model: choice.model, reasoning: choice.reasoning, clone: clone,
                                                       proposal: proposal, sessionID: session)
                let output = try await run(agent, invocation, in: clone, timeout: applyTimeout, locate: locate)
                try clone.checkSettings()
                _ = try FixApplied(validating: try FixerLaunch.applyAnswer(agent, output: output, invocation: invocation), agent: agent)
                let checked = try await BackgroundWork.run { () throws(FixRefusal) -> String in
                    try FixGuard.check(clone, proposal: proposal, before: before)
                }
                // Then `verify`, never before the checks: a test run that touches tracked files must not
                // read as uncommitted changes. Never unconfined: without `sandbox-exec` there is no
                // `verify` (spec §11.5).
                guard let verify = proposal.verify, VerifySandbox.isAvailable else { return checked }
                let left = applyTimeout - (ContinuousClock.now - started)
                do throws(FixRefusal) {
                    try await VerifySandbox.run(verify, in: clone.path, timeout: max(left, verifyFloor))
                } catch {
                    // `run` reports a cancelled command as a failed one.
                    if Task.isCancelled { throw .cancelled }
                    throw error
                }
                // The sandbox lets `verify` write the clone, `.git` included — its settings, and its
                // branch: only the tip the checks passed may land.
                try clone.checkSettings()
                let now = try await BackgroundWork.run { () throws(FixRefusal) -> String in
                    do { return try clone.tip(clone.branch) } catch { throw .uncheckable(error) }
                }
                guard now == checked else { throw .movedAfterCheck(clone.branch) }
                return checked
            },
            land: { clone, checked throws(FixRefusal) in try await workflow.landFix(from: clone, tip: checked, in: project) })
    }

    /// One agent run in the clone — the process's working directory, which Codex's `exec resume`
    /// needs as it takes no `-C`.
    private static func run(_ agent: FixerAgent, _ invocation: FixerInvocation, in clone: FixClone, timeout: Duration,
                            locate: @escaping @Sendable (String) -> String?) async throws(FixRefusal) -> ProcessOutput {
        let name = invocation.executable
        guard let executable = await BackgroundWork.run({ locate(name) }) else {
            throw .agentExited(agent, status: 127, stderr: "\(name) is not installed.")
        }
        // As the harness runner does: a CLI installed by npm is a `#!/usr/bin/env node` script, and an
        // app opened from the Dock has launchd's `PATH`, which has no node on it.
        var environment = invocation.environment
        let bin = (executable as NSString).deletingLastPathComponent
        environment["PATH"] = [bin, environment["PATH"] ?? ProcessRunner.inheritedEnvironment["PATH"]].compactMap { $0 }.joined(separator: ":")
        do {
            return try await AgentProcess.run(executable, invocation.arguments, environment: environment, in: clone.path, timeout: timeout)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .agentExited(agent, status: -1, stderr: GitError.displayReason(of: error))
        }
    }

    /// Git that reads the clone, off the cooperative pool; a failure is the clone's.
    private static func read<Value: Sendable>(_ clone: FixClone,
                                              _ body: @escaping @Sendable (FixClone) throws -> Value) async throws(FixRefusal) -> Value {
        try await BackgroundWork.run { () throws(FixRefusal) -> Value in
            do { return try body(clone) } catch { throw .cloneFailed(GitError.displayReason(of: error)) }
        }
    }
}
