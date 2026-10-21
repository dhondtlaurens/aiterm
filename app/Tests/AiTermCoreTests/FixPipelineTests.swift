import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// The pipeline against a real conflict: prepare, check and land run for real, and the agent is
/// either left out (`fake`) or a shell script standing in for `claude` (`live`) that answers the
/// schema and, when resumed, resolves the conflict with git in the clone.
@Suite(.blocking) final class FixPipelineTests {
    let git = GitRunner.hermetic()
    let world: ConflictWorld
    init() throws { world = try ConflictWorld(git: .hermetic()) }
    deinit { world.removeAll() }

    var request: FixRequest {
        FixRequest(title: "t", reason: nil, detail: nil, projectPath: world.repo, branch: "feat/x",
                   recreateRebase: true, retry: .createReview)
    }

    @Test func aForcePushIsFixedAndLandedEndToEnd() async throws {
        let request = request
        let mine = try world.sha("feat/x", in: world.repo)
        let pipeline = FixPipeline.fake(git: git, root: world.root,
            look: { _ in FixLookAnswer(outcome: "fix", headline: "An older copy.", why: "w", steps: ["Reset to origin’s"],
                                       moves: ["feat/x"], drops: [mine], verify: nil, reason: nil) },
            apply: { [git] clone in
                try git.run(["rebase", "--abort"], in: clone.path)
                try git.run(["reset", "-q", "--hard", "origin/feat/x"], in: clone.path)
            })
        let clone = try await pipeline.prepare(request)
        defer { clone.remove() }
        let (look, session) = try await pipeline.look(.claude, clone, request)
        guard case .fix(let proposal) = look else { Issue.record("expected a proposal"); return }
        let checked = try await pipeline.apply(.claude, clone, proposal, session)
        let landing = try await pipeline.land(clone, checked)
        #expect(try world.sha("feat/x", in: world.repo) == world.sha("origin/feat/x", in: world.repo))
        #expect(landing.old == mine)
    }

    // -- The live pipeline, with a script for the agent --

    /// A `claude` that logs where it ran, answers a Look with `look` (after `lookBody`) and an
    /// Apply — the run with `--resume S1` — with “applied” after `applyBody`.
    private func agent(look: String, lookBody: String = "", applyBody: String) throws -> (script: String, log: String) {
        let script = world.root + "/claude.sh", log = world.root + "/claude.log"
        try """
        #!/bin/sh
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
        pwd -P >> '\(log)'
        if [ "$3" = "--resume" ]; then
          [ "$4" = "S1" ] || { echo "resumed $4" >&2; exit 3; }
          \(applyBody)
          printf '%s' '{"session_id":"S1","structured_output":{"outcome":"applied","summary":"Reset to origin."}}'
        else
          \(lookBody)
          printf '%s' '{"session_id":"S1","structured_output":\(look)}'
        fi
        """.write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        return (script, log)
    }

    private func fixAnswer(drops: [String], verify: String? = nil) -> String {
        let verify = verify.map { "\"\($0)\"" } ?? "null"
        return #"{"outcome":"fix","headline":"An older copy.","why":"Origin was rewritten.","steps":["Take origin’s"],"moves":["feat/x"],"#
            + #""drops":[\#(drops.map { "\"\($0)\"" }.joined(separator: ","))],"verify":\#(verify),"reason":null}"#
    }

    private func live(_ script: String?) -> FixPipeline {
        let project = Project(id: UUID(), name: "repo", path: world.repo, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        return FixPipeline.live(git: git, workflow: TaskWorkflow(git: git), project: project, model: { _ in ("m", nil) },
                                locate: { name in name == "claude" ? script : nil })
    }

    @Test func theLivePipelineRunsTheAgentInTheCloneAndLandsWhatPassedTheChecks() async throws {
        let request = request
        let mine = try world.sha("feat/x", in: world.repo)
        let (script, log) = try agent(look: fixAnswer(drops: [String(mine.prefix(7))]),
                                      applyBody: "git rebase --abort && git reset -q --hard origin/feat/x || exit 4")
        let pipeline = live(script)
        let clone = try await pipeline.prepare(request)
        defer { clone.remove() }
        #expect(clone.path.hasPrefix(VerifySandbox.realPath(NSTemporaryDirectory())), "a clone in the temporary directory")
        let (look, session) = try await pipeline.look(.claude, clone, request)
        #expect(session == "S1")
        guard case .fix(let proposal) = look else { Issue.record("expected a proposal, got \(look)"); return }
        #expect(proposal.drops == [mine], "the short sha is the full one once validated")
        let checked = try await pipeline.apply(.claude, clone, proposal, session)
        let landing = try await pipeline.land(clone, checked)
        #expect(landing == FixLanding(branch: "feat/x", old: mine, new: try world.sha("origin/feat/x", in: world.repo)))
        #expect(try world.sha("feat/x", in: world.repo) == world.sha("origin/feat/x", in: world.repo))
        #expect(try world.sha("aiterm/backup/feat/x", in: world.repo) == mine)
        let ran = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(ran == [clone.path, clone.path], "both runs in the clone, never in the project")
    }

    /// Cancel while looking: the agent's group is killed and the run says it was cancelled.
    @Test func aCancelledLookStopsTheAgent() async throws {
        let request = request
        let (script, log) = try agent(look: fixAnswer(drops: []), lookBody: "sleep 30", applyBody: "")
        let pipeline = live(script)
        let clone = try await pipeline.prepare(request)
        defer { clone.remove() }
        let started = ContinuousClock.now
        let looking = Task { _ = try await pipeline.look(.claude, clone, request) }
        // Cancelled once the agent runs, which it logs first thing: mid-look, not before it began.
        await eventually(describing: "the agent to start looking") { FileManager.default.fileExists(atPath: log) }
        looking.cancel()
        await #expect(throws: FixRefusal.cancelled) { try await looking.value }
        #expect(ContinuousClock.now - started < .seconds(15), "not the script's 30 s")
    }

    @Test func anAgentThatIsNotInstalledIsSaidSo() async throws {
        let request = request
        let pipeline = live(nil)
        let clone = try await pipeline.prepare(request)
        defer { clone.remove() }
        await #expect(throws: FixRefusal.agentExited(.claude, status: 127, stderr: "claude is not installed.")) {
            _ = try await pipeline.look(.claude, clone, request)
        }
    }

    /// M3: an Apply with no Look before it has no tips to check against; that is a failed check.
    @Test func anApplyWithNoLookBeforeItIsACheckThatFailed() async throws {
        let request = request
        let pipeline = live(nil)
        let clone = try await pipeline.prepare(request)
        defer { clone.remove() }
        let proposal = FixProposal(headline: "h", why: "w", steps: ["s"], moves: ["feat/x"], drops: [], verify: nil)
        await #expect(throws: FixRefusal.checkFailed("Couldn’t check the fix: its branches were not read before it was made, so nothing was changed.")) {
            _ = try await pipeline.apply(.claude, clone, proposal, "S")
        }
    }

    /// The guard runs on the clone the agent left, not on its word: “applied” with the rebase still stopped.
    @Test func anApplyThatLeavesTheRebaseStoppedIsRefused() async throws {
        let request = request
        let mine = try world.sha("feat/x", in: world.repo)
        let (script, _) = try agent(look: fixAnswer(drops: [mine]), applyBody: ":")
        let pipeline = live(script)
        let clone = try await pipeline.prepare(request)
        defer { clone.remove() }
        let (look, session) = try await pipeline.look(.claude, clone, request)
        guard case .fix(let proposal) = look else { Issue.record("expected a proposal, got \(look)"); return }
        await #expect(throws: FixRefusal.operationInProgress) { _ = try await pipeline.apply(.claude, clone, proposal, session) }
        #expect(try world.sha("feat/x", in: world.repo) == mine)
    }

    // -- The clone's git settings, which the agent may not change --

    /// A script that leaves a marker when it runs — as git runs a planted `core.fsmonitor`.
    private func plant() throws -> (hook: String, marker: String) {
        let hook = world.root + "/plant.sh", marker = world.root + "/planted-ran"
        try "#!/bin/sh\ntouch '\(marker)'\n".write(toFile: hook, atomically: true, encoding: .utf8)
        chmod(hook, 0o755)
        return (hook, marker)
    }

    /// C1: an Apply that writes `core.fsmonitor` into the clone's config is refused before AiTerm's
    /// own `git status` runs it — as the person, outside every sandbox.
    @Test func anApplyThatPlantsAGitSettingIsRefusedAndThePlantNeverRuns() async throws {
        let request = request
        let mine = try world.sha("feat/x", in: world.repo)
        let (hook, marker) = try plant()
        let (script, _) = try agent(look: fixAnswer(drops: [mine]),
                                    applyBody: "git rebase --abort && git reset -q --hard origin/feat/x && git config core.fsmonitor '\(hook)' || exit 4")
        let pipeline = live(script)
        let clone = try await pipeline.prepare(request)
        defer { clone.remove() }
        let (look, session) = try await pipeline.look(.claude, clone, request)
        guard case .fix(let proposal) = look else { Issue.record("expected a proposal, got \(look)"); return }
        await #expect(throws: FixRefusal.settingsChanged) { _ = try await pipeline.apply(.claude, clone, proposal, session) }
        #expect(!FileManager.default.fileExists(atPath: marker), "the planted command never ran")
        #expect(try world.sha("feat/x", in: world.repo) == mine)
    }

    /// C1 at Look: a read-only run can still write the config (`git log --output=.git/config`); it
    /// is refused before AiTerm reads the clone again.
    @Test func aLookThatPlantsAGitSettingIsRefused() async throws {
        let request = request
        let (hook, marker) = try plant()
        let (script, _) = try agent(look: fixAnswer(drops: []), lookBody: "git config core.fsmonitor '\(hook)'", applyBody: "")
        let pipeline = live(script)
        let clone = try await pipeline.prepare(request)
        defer { clone.remove() }
        await #expect(throws: FixRefusal.settingsChanged) { _ = try await pipeline.look(.claude, clone, request) }
        #expect(!FileManager.default.fileExists(atPath: marker), "the planted command never ran")
    }

    /// C1 after `verify`: the sandbox lets it write the clone, `.git` included, so its changes to the
    /// settings are refused as the agent's are.
    @Test(.enabled(if: VerifySandbox.isAvailable)) func aVerifyThatPlantsAGitSettingIsRefused() async throws {
        let request = request
        let mine = try world.sha("feat/x", in: world.repo)
        let (hook, marker) = try plant()
        let (script, _) = try agent(look: fixAnswer(drops: [mine], verify: "git config core.fsmonitor \(hook)"),
                                    applyBody: "git rebase --abort && git reset -q --hard origin/feat/x || exit 4")
        let pipeline = live(script)
        let clone = try await pipeline.prepare(request)
        defer { clone.remove() }
        let (look, session) = try await pipeline.look(.claude, clone, request)
        guard case .fix(let proposal) = look else { Issue.record("expected a proposal, got \(look)"); return }
        await #expect(throws: FixRefusal.settingsChanged) { _ = try await pipeline.apply(.claude, clone, proposal, session) }
        #expect(!FileManager.default.fileExists(atPath: marker), "the planted command never ran")
    }

    /// I1: `verify` runs after the checks and may write the clone; a run that moves the branch —
    /// here by a commit — is refused, so nothing unchecked can land.
    @Test(.enabled(if: VerifySandbox.isAvailable)) func aVerifyThatMovesTheBranchIsRefusedAndNothingLands() async throws {
        let request = request
        let mine = try world.sha("feat/x", in: world.repo)
        let (script, _) = try agent(look: fixAnswer(drops: [mine], verify: "git reset -q --hard HEAD~1"),
                                    applyBody: "git rebase --abort && git reset -q --hard origin/feat/x || exit 4")
        let pipeline = live(script)
        let clone = try await pipeline.prepare(request)
        defer { clone.remove() }
        let (look, session) = try await pipeline.look(.claude, clone, request)
        guard case .fix(let proposal) = look else { Issue.record("expected a proposal, got \(look)"); return }
        await #expect(throws: FixRefusal.movedAfterCheck("feat/x")) {
            let checked = try await pipeline.apply(.claude, clone, proposal, session)
            _ = try await pipeline.land(clone, checked)
        }
        #expect(try world.sha("feat/x", in: world.repo) == mine, "nothing landed")
        #expect(try git.run(["for-each-ref", "refs/aiterm"], in: world.repo).isEmpty, "no backup, no leftover ref")
    }

    @Test(.enabled(if: VerifySandbox.isAvailable)) func aVerifyThatFailsRefusesTheFix() async throws {
        let request = request
        let mine = try world.sha("feat/x", in: world.repo)
        let (script, _) = try agent(look: fixAnswer(drops: [mine], verify: "false"),
                                    applyBody: "git rebase --abort && git reset -q --hard origin/feat/x || exit 4")
        let pipeline = live(script)
        let clone = try await pipeline.prepare(request)
        defer { clone.remove() }
        let (look, session) = try await pipeline.look(.claude, clone, request)
        guard case .fix(let proposal) = look else { Issue.record("expected a proposal, got \(look)"); return }
        await #expect(throws: FixRefusal.verifyFailed("false", status: 1)) { _ = try await pipeline.apply(.claude, clone, proposal, session) }
    }
}
