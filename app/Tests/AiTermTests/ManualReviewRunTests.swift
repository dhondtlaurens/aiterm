import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

private final class ManualReviewTestBundle {}

@MainActor @Suite(.blocking) struct ManualReviewRunTests {
    /// Exercise the real command submitted by the sheet through its usual daemon boundary.
    /// The opt-in spends vendor quota. The fixture never starts the GUI or contacts a real remote.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AITERM_LIVE_MANUAL_REVIEW"] == "1"),
          arguments: [false, true])
    func reviewerFindsTheUnchangedCaller(existingOwner: Bool) async throws {
        var ports = OperatorPorts.scratch()
        let app = Bundle(for: ManualReviewTestBundle.self).bundleURL.deletingLastPathComponent().appendingPathComponent("AiTerm")
        ports.workerGuardExecutable = app
        let fixture = try await RaceFixture(operatorPorts: ports)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let server = RecordingDaemon()
        fixture.controller.helper.setDaemonClient(server)
        let repo = fixture.repo, git = fixture.git
        let marker = fixture.root.appendingPathComponent("build-attempted")
        func put(_ name: String, _ value: String, in root: URL) throws {
            try Data(value.utf8).write(to: root.appendingPathComponent(name))
        }
        try put("limits.py", "def decode_limit(value):\n    return int(value or 1)\n", in: repo)
        try put("pages.py", "from limits import decode_limit\n\ndef render_pages(value):\n    return 80 // decode_limit(value)\n", in: repo)
        try put("notes", "original", in: repo)
        try put("Makefile", "build:\n\t@touch " + AgentCommand.shellQuote(marker.path) + "\n", in: repo)
        // Tracked vendor config belongs to the revision as data. Its startup effects would be visible here.
        let config = repo.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let hookMarker = fixture.root.appendingPathComponent("revision-hook")
        let mcpMarker = fixture.root.appendingPathComponent("revision-server")
        let hooks: JSONValue = ["fixture": ["SessionStart": [["type": "command",
            "command": .string("/usr/bin/touch " + AgentCommand.shellQuote(hookMarker.path))]]]]
        let servers: JSONValue = ["mcpServers": ["fixture": ["command": "/usr/bin/touch", "args": [.string(mcpMarker.path)]]]]
        try JSONEncoder().encode(hooks).write(to: config.appendingPathComponent("hooks.json"))
        try JSONEncoder().encode(servers).write(to: config.appendingPathComponent("mcp_config.json"))
        try git.run(["add", "."], in: repo.path)
        try git.run(["commit", "-qm", "Add pagination"], in: repo.path)
        let work: URL
        if existingOwner {
            work = URL(fileURLWithPath: try await fixture.addTask(windowId: "alive").worktreePath)
        } else {
            try git.run(["checkout", "-qb", "feat/work"], in: repo.path)
            work = repo
        }
        try put("limits.py", "def decode_limit(value):\n    return int(value or 0)\n", in: work)
        try git.run(["commit", "-qam", "Decode empty limit"], in: work.path)
        let head = try git.run(["rev-parse", "HEAD"], in: work.path)
        if !existingOwner { try git.run(["switch", "main"], in: repo.path) }
        let origin = fixture.root.appendingPathComponent("origin.git")
        try git.run(["clone", "--bare", repo.path, origin.path], in: fixture.root.path)
        try git.run(["remote", "add", "origin", origin.path], in: repo.path)
        try git.run(["fetch", "origin"], in: repo.path)
        try put("notes", "unrelated local edit", in: repo)
        if existingOwner { try put("pages.py", "def local_only(): return 1", in: work) }
        let refs = try git.run(["show-ref"], in: repo.path)
        let env = ProcessInfo.processInfo.environment
        let vendor = try #require(AgentKind(rawValue: env["AITERM_MANUAL_REVIEW_VENDOR"] ?? "agy"))
        let model = env["AITERM_MANUAL_REVIEW_MODEL"] ?? "gemini-3.8-flash"
        var draft = ReviewDraft(mr: nil, agent: vendor, model: model, reasoning: "low")
        draft.setBranch("feat/work")
        draft.setTitle("Review the limit change")
        try await fixture.controller.launcher.createReview(draft: draft, project: fixture.project)
        let request = try #require(server.requests.first { $0.method == (existingOwner ? "tab.create" : "window.createTask") })
        let command = try #require(request.params["agentCommand"] as? String)
        let cwd = try #require(request.params["cwd"] as? String)
        if !existingOwner { try put("pages.py", "def local_only(): return 1", in: URL(fileURLWithPath: cwd)) }
        let status = try git.run(["status", "--porcelain=v2"], in: cwd)
        let trees = try git.run(["worktree", "list", "--porcelain"], in: repo.path)
        let tracking = try git.ask(["config", "--get-regexp", "^branch\\."], in: repo.path, none: [1])
        var testEnvironment = ProcessRunner.inheritedEnvironment
        if let home = env["AITERM_MANUAL_REVIEW_TEST_HOME"] { testEnvironment["HOME"] = home }
        let environment = testEnvironment
        let result = try await BackgroundWork.run {
            try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", command], environment: environment, in: URL(fileURLWithPath: cwd), timeout: 960)
        }
        print("Manual review (owner=\(existingOwner), \(vendor.rawValue), \(model))\n" + result.stdout)
        #expect(result.status == 0, "\(result.stdout)\n\(result.stderr)")
        let findings = result.stdout.split(separator: "\n", maxSplits: 2).last ?? ""
        #expect(findings.contains(head))
        #expect(result.stdout.contains("render_pages"))
        #expect(result.stdout.lowercased().contains("zero"))
        #expect(try git.run(["show-ref"], in: repo.path) == refs)
        #expect(try git.run(["worktree", "list", "--porcelain"], in: repo.path) == trees)
        #expect(try git.ask(["config", "--get-regexp", "^branch\\."], in: repo.path, none: [1]) == tracking)
        #expect(try git.run(["status", "--porcelain=v2"], in: cwd) == status)
        #expect(try String(contentsOfFile: cwd + "/pages.py", encoding: .utf8) == "def local_only(): return 1")
        #expect(try String(contentsOf: repo.appendingPathComponent("notes"), encoding: .utf8) == "unrelated local edit")
        for file in [marker, hookMarker, mcpMarker] {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }
}

extension ManualReviewRunTests {
    @Test(arguments: ["missing", "timeout", "exit", "stdoutError", "empty", "overflow"])
    func reviewerFailuresAreVisibleThroughTheEntryPoint(_ failure: String) async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try await fixture.addTask(windowId: nil)
        let file = URL(fileURLWithPath: task.worktreePath).appendingPathComponent("changed")
        try Data("changed".utf8).write(to: file)
        try fixture.git.run(["add", "changed"], in: task.worktreePath)
        try fixture.git.run(["commit", "-qm", "change"], in: task.worktreePath)
        var draft = ReviewDraft(mr: nil, agent: .claude, model: "fixture", reasoning: nil)
        draft.setBranch(task.branch)
        let pending = try Repository(fixture.repo.path, git: fixture.git).manualReview(draft: draft, checkout: task.worktreePath)
        let error = await #expect(throws: ManualReviewError.self) {
            try await ManualReview.withClaim(at: pending.request) { review, folder in
                try await ManualReviewEntry.run(review, folder: folder, makeRunner: { _, capture in
                    if failure == "missing" { return .unavailable }
                    return HeadlessRun(locate: { _ in "/fixture" }, run: { _, _, _, _, _ in
                        if failure == "stdoutError" {
                            try capture.write(contentsOf: Data(#"{"type":"result","is_error":true,"result":"Sign-in expired"}"#.utf8))
                        }
                        return ProcessOutput(status: ["exit", "stdoutError"].contains(failure) ? 7 : 0, stdout: "", stderr: "fixture diagnostic",
                                      timedOut: failure == "timeout", stdoutTruncated: failure == "overflow")
                    })
                })
            }
        }
        let expected = ["missing": "installed", "timeout": "minutes", "exit": "status 7", "stdoutError": "Sign-in expired", "empty": "complete answer", "overflow": "capture limit"]
        #expect(error?.localizedDescription.contains(expected[failure]!) == true)
        #expect(!FileManager.default.fileExists(atPath: pending.folder.path))
    }
}

extension ManualReviewRunTests {
    @Test(arguments: [SIGINT, SIGHUP])
    func interruptingTheHelperReapsTheReviewerAndItsChild(_ sig: Int32) async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try await fixture.addTask(windowId: nil)
        let work = URL(fileURLWithPath: task.worktreePath)
        try Data("change".utf8).write(to: work.appendingPathComponent("feature"))
        try fixture.git.run(["add", "feature"], in: work.path)
        try fixture.git.run(["commit", "-qm", "feature"], in: work.path)
        var draft = ReviewDraft(mr: nil, agent: .claude, model: "fixture", reasoning: nil)
        draft.setBranch(task.branch)
        let pending = try Repository(fixture.repo.path, git: fixture.git).manualReview(draft: draft, checkout: work.path)
        defer { pending.discard() }

        let ids = fixture.root.appendingPathComponent("reviewer-pids")
        let cli = fixture.root.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        /bin/sleep 90 &
        echo "$$ $!" > \(AgentCommand.shellQuote(ids.path))
        wait
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let helper = Process()
        helper.executableURL = Bundle(for: ManualReviewTestBundle.self).bundleURL.deletingLastPathComponent().appendingPathComponent("AiTerm")
        helper.arguments = ["--manual-review", pending.request.path]
        helper.environment = ProcessRunner.inheritedEnvironment.merging(["PATH": fixture.root.path + ":/usr/bin:/bin"]) { _, new in new }
        helper.currentDirectoryURL = work
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }
        guard await eventually(describing: "the reviewer's child", timeout: 30, { FileManager.default.fileExists(atPath: ids.path) }) else { return }
        let pids = try String(contentsOf: ids, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        try #require(pids.count == 2)
        #expect(kill(helper.processIdentifier, sig) == 0)
        guard await eventually(describing: "the interrupted review to exit", timeout: 30, { !helper.isRunning }) else { return }
        #expect(helper.terminationStatus != 0)
        #expect(!FileManager.default.fileExists(atPath: pending.folder.path))
        await eventually(describing: "both reviewer processes to be reaped", timeout: 10) { pids.allSatisfy { kill($0, 0) != 0 && errno == ESRCH } }
    }

    @Test func unsupportedAntigravityStopsBeforeReview() async throws {
        let root = try ScratchFolder.make("review-version-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace"), home = root.appendingPathComponent("source-home")
        let credential = home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: credential)
        let cli = root.appendingPathComponent("agy"), marker = root.appendingPathComponent("unexpected-turn")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            [ -z "$UNRELATED" ] && [ "$HOME" = \(AgentCommand.shellQuote(root.appendingPathComponent("agy-home").path)) ] || exit 2
            touch \(AgentCommand.shellQuote(root.appendingPathComponent("checked-version").path))
            echo unsupported
        else
            touch \(AgentCommand.shellQuote(marker.path))
        fi
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let runner = HeadlessRun.manualReview(agent: .agy, capture: .nullDevice)
        let reason = await #expect(throws: ManualReviewError.self) {
            try await runner.run(cli.path, ["--agent", "fixture"], ["HOME": home.path, "UNRELATED": "fixture"], workspace.path, .seconds(30))
        }
        #expect(reason?.localizedDescription.contains(ManualReviewAgy.verifiedVersion) == true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("checked-version").path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
