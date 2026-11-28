import AppKit
import SwiftUI
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// The submitted shell command is executed against isolated CLI receivers, never installed agents.
/// The receiver stays on a PTY until a follow-up arrives: flags alone do not prove that boundary.
@MainActor @Suite(.blocking, .serialized) struct ReviewLaunchTests {
    @Test func changingAgentReloadsSkillsInTheOpenReviewPrompt() async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        var context = CreationContext.scratch(home: fixture.root, catalogue: { _ in
            [AgentModel(id: "review-model", label: "Reviewer", detail: nil, efforts: ["low"], defaultEffort: "low")]
        })
        context.nativeSkills = NativeSkills { agent, _, _ in
            if agent == .agy {
                return #"[{"name":"demo","enabled":true,"skills":["before-switch"]}]"#
            }
            #expect(agent == .pi)
            return #"{"type":"response","command":"get_commands","id":"aiterm-skills","success":true,"data":{"commands":[{"name":"skill:after-switch","source":"skill","sourceInfo":{"scope":"user"}}]}}"#
        }
        var draft = ReviewDraft(mr: nil, agent: .agy, model: "review-model", reasoning: "low")
        draft.setBranch("topic"); draft.setTitle("Review topic")
        let model = ReviewCreationModel(project: fixture.project, draft: draft, context: context,
            searchMergeRequests: { _ in [] }, createReview: { _ in }, recover: { _ in })
        let host = testHost(NewReviewSheet(model: model).seeded(step: ReviewCreation.promptStep), size: CGSize(width: 600, height: 700))
        let window = testWindow(hosting: host)
        defer { window.orderOut(nil) }
        try #require(await eventually { model.completions.all.map(\.name) == ["demo:before-switch"] })
        let editor = try #require(host.firstDescendant(PromptTextView.self))
        editor.insertText("/after", replacementRange: editor.selectedRange())
        model.selectAgent(.pi)
        try #require(await eventually {
            model.agentIsReady && model.completions.visible.map(\.name) == ["skill:after-switch"]
        })
        #expect(model.completions.all.map(\.name) == ["skill:after-switch"])
        let currentEditor = try #require(host.firstDescendant(PromptTextView.self))
        let delegate = try #require(currentEditor.delegate)
        #expect(delegate.textView?(currentEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
        #expect(model.promptText == "/skill:after-switch ")
    }

    @Test(arguments: [false, true])
    func sheetCoordinatorSubmitsInteractiveReviewFromTheForm(existing: Bool) async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        if existing { _ = try await fixture.addTask(windowId: "alive") }
        else { try fixture.git.run(["branch", "feat/work"], in: fixture.repo.path) }
        fixture.controller.agents.availableAgents = [.claude]
        let daemon = RecordingDaemon()
        fixture.controller.helper.setDaemonClient(daemon)
        fixture.controller.sheets.presentNewReview(project: fixture.project)
        await fixture.controller.sheets.preparingSheet?.value
        guard case .newReview(let model) = fixture.controller.sheets.sheet else {
            Issue.record("New Review did not prepare its form"); return
        }
        model.draft.apply(mr: MergeRequest(iid: 7, title: "Review work", sourceBranch: "feat/work", targetBranch: "main",
                                          author: nil, state: "opened", draft: false,
                                          url: "https://example.com/repo/merge_requests/7", description: "Omitted request description"))
        model.draft.apply(ticket: JiraTicket(key: "DEMO-7", summary: "Work", description: "Omitted ticket description",
                                             issueType: nil, status: nil, url: "https://example.com/DEMO-7"))
        model.draft.appendRequest = false; model.draft.appendTicket = false
        model.promptText = "Start on my prompt now"
        let presentation = ReviewPresentation()
        let host = testHost(Color.clear.sheet(isPresented: Binding(get: { presentation.open }, set: { presentation.open = $0 })) {
            NewReviewSheet(model: model).seeded(step: ReviewCreation.promptStep)
        }, size: CGSize(width: 700, height: 800))
        let window = testWindow(hosting: host)
        defer { window.orderOut(nil) }
        try #require(await eventually { window.attachedSheet != nil && model.agentIsReady })
        let sheet = try #require(window.attachedSheet)
        settle(try #require(sheet.contentView))
        let event = try #require(keyDown("\r", code: 36, modifiers: [.command], in: sheet))
        _ = sheet.performKeyEquivalent(with: event)
        try #require(await eventually { !presentation.open })
        let method = existing ? "tab.create" : "window.createTask"
        let command = try #require(daemon.requests(method).first?.params["agentCommand"] as? String)
        #expect(command.hasPrefix("claude ") && command.contains("Start on my prompt now"))
        #expect(!command.contains("Omitted"))
    }

    @Test(arguments: AgentKind.allCases, [false, true])
    func sheetDiscoversAndSubmitsSkillsAndFileReferences(agent: AgentKind, existing: Bool) async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        try Data("Read me".utf8).write(to: fixture.repo.appendingPathComponent("README.md"))
        try fixture.git.run(["add", "README.md"], in: fixture.repo.path)
        try fixture.git.run(["commit", "-qm", "document the checkout"], in: fixture.repo.path)
        let owner = existing ? try await fixture.addTask(windowId: "alive") : nil
        if !existing { try fixture.git.run(["branch", "feat/work"], in: fixture.repo.path) }
        let home = fixture.root.appendingPathComponent("home")
        for dot in [".claude", ".codex"] {
            let skill = home.appendingPathComponent(dot + "/skills/interactive-review/SKILL.md")
            try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("---\ndescription: Interactive review\n---\n".utf8).write(to: skill)
        }
        var context = CreationContext.scratch(home: home, catalogue: { _ in
            [AgentModel(id: "review-model", label: "Reviewer", detail: nil, efforts: ["low"], defaultEffort: "low")]
        })
        let expectedDirectory = owner?.worktreePath ?? fixture.repo.path
        context.nativeSkills = NativeSkills { vendor, cwd, _ in
            if vendor == .agy {
                return #"[{"name":"demo","enabled":true,"skills":["interactive-review"]}]"#
            }
            #expect(vendor == .pi && cwd?.path == expectedDirectory)
            return #"{"type":"response","command":"get_commands","id":"aiterm-skills","success":true,"data":{"commands":[{"name":"skill:interactive-review","source":"skill","sourceInfo":{"scope":"user"}}]}}"#
        }
        var draft = ReviewDraft(mr: nil, agent: agent, model: "review-model", reasoning: "low")
        draft.setBranch("feat/work"); draft.setTitle("Review work")
        let daemon = RecordingDaemon()
        fixture.controller.helper.setDaemonClient(daemon)
        let model = ReviewCreationModel(project: fixture.project, draft: draft, context: context,
            owningTask: { _, _ in owner }, searchMergeRequests: { _ in [] },
            createReview: { try await fixture.controller.launcher.createReview(draft: $0, project: fixture.project) }, recover: { _ in })
        let host = testHost(NewReviewSheet(model: model).seeded(step: ReviewCreation.promptStep), size: CGSize(width: 600, height: 700))
        let window = testWindow(hosting: host)
        defer { window.orderOut(nil) }
        let editor = try #require(host.firstDescendant(PromptTextView.self))
        editor.insertText("/interactive", replacementRange: editor.selectedRange())
        let skillName = (agent == .agy ? "demo:" : agent == .pi ? "skill:" : "") + "interactive-review"
        try #require(await eventually { model.completions.visible.contains { $0.name == skillName } })
        model.completions.index = try #require(model.completions.visible.firstIndex { $0.name == skillName })
        let delegate = try #require(editor.delegate)
        #expect(delegate.textView?(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
        let invocation = (agent == .codex ? "$" : "/") + skillName + " "
        #expect(model.promptText == invocation)
        try #require(await eventually { model.completions.files.matches("READ").contains { $0.name == "README.md" } })
        editor.insertText("@READ", replacementRange: editor.selectedRange())
        try #require(model.completions.visible.contains { $0.name == "README.md" })
        #expect(delegate.textView?(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
        #expect(model.promptText == invocation + "@README.md ")
        try #require(await eventually { model.agentIsReady })
        #expect(await model.create())
        let method = existing ? "tab.create" : "window.createTask"
        let request = try #require(daemon.requests(method).first)
        let command = try #require(request.params["agentCommand"] as? String)
        #expect(command.hasPrefix(agent.harness.executable + " "))
        #expect(command.contains(invocation + "@README.md"))
    }

    @Test(arguments: AgentKind.allCases, [false, true])
    func submittedReviewStartsInteractiveAgentAndAcceptsFollowUp(agent: AgentKind, existing: Bool) async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let owner = existing ? try await fixture.addTask(windowId: "alive") : nil
        if !existing { try fixture.git.run(["branch", "feat/work"], in: fixture.repo.path) }
        try Data("local setup".utf8).write(to: fixture.repo.appendingPathComponent("setup.txt"))
        try Data("setup.txt\n".utf8).write(to: fixture.repo.appendingPathComponent(".gitignore"))
        try Data("setup.txt\n".utf8).write(to: fixture.repo.appendingPathComponent(".worktreeinclude"))
        let daemon = RecordingDaemon()
        fixture.controller.helper.setDaemonClient(daemon)
        var draft = ReviewDraft(mr: nil, agent: agent, model: "review-model", reasoning: "low")
        draft.apply(mr: MergeRequest(iid: 7, title: "Review work", sourceBranch: "feat/work", targetBranch: "main",
                                    author: "sam", state: "opened", draft: false,
                                    url: "https://example.com/repo/merge_requests/7", description: "Request constraints"))
        draft.apply(ticket: JiraTicket(key: "DEMO-7", summary: "Work", description: "Ticket constraints",
                                       issueType: nil, status: nil, url: "https://example.com/DEMO-7"))
        // Names and words associated with reviews must not select a different launch policy.
        let prompt = "/psg:adversarial-review @README.md\nRead-only one-shot review? Ask me first. It's $(literal)."
            + (existing ? "" : "\n" + String(repeating: "Long prompt. ", count: 150))
        draft.promptText = prompt
        let model = ReviewCreationModel(project: fixture.project, draft: draft,
            context: .scratch(home: fixture.root, catalogue: { _ in
                [AgentModel(id: "review-model", label: "Reviewer", detail: nil, efforts: ["low", "high"], defaultEffort: "high")]
            }), owningTask: { _, _ in owner }, searchMergeRequests: { _ in [] },
            createReview: { try await fixture.controller.launcher.createReview(draft: $0, project: fixture.project) },
            recover: { _ in })
        let host = testHost(NewReviewSheet(model: model).seeded(step: ReviewCreation.promptStep),
                            size: CGSize(width: 600, height: 700))
        let window = testWindow(hosting: host)
        defer { window.orderOut(nil) }
        try #require(await eventually { model.agentIsReady })
        #expect(await model.create(), "the same submit callback used by New Review")
        let method = existing ? "tab.create" : "window.createTask"
        let request = try #require(daemon.requests(method).first)
        let command = try #require(request.params["agentCommand"] as? String)
        let cwd = try #require(request.params["cwd"] as? String)
        // Never execute a product helper/app binary when this regression is present.
        try #require(command.hasPrefix(agent.harness.executable + " "), "manual submission must launch the selected interactive CLI: \(command)")
        #expect(request.params["background"] as? Bool == false)
        if let owner {
            #expect(cwd == owner.worktreePath)
            #expect(fixture.controller.state.tasks.map(\.id) == [owner.id])
        } else {
            let row = try #require(fixture.controller.state.tasks.first)
            #expect(row.kind == .review && row.agent == agent && row.model == "review-model" && row.reasoning == "low")
            #expect(try String(contentsOfFile: cwd + "/setup.txt", encoding: .utf8) == "local setup")
            #expect(try fixture.git.run(["branch", "--show-current"], in: cwd) == "feat/work")
        }
        let transcript = try await receive(command: command, cwd: cwd, root: fixture.root)
        let first = try #require(transcript.first)
        let followUp = try #require(transcript.last)
        #expect(first.tty && followUp.tty)
        #expect(first.pid == followUp.pid)
        #expect(first.cwd == cwd)
        #expect(followUp.message == "Continue in this same session.")
        let carried = try #require(first.argv.last)
        #expect(carried.contains(prompt.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(carried.contains("Request constraints") && carried.contains("Ticket constraints"))
        let options: [String]
        switch agent {
        case .claude: options = ["--model", "review-model", "--effort", "low"]
        case .codex: options = ["--dangerously-bypass-approvals-and-sandbox", "-m", "review-model", "-c", "model_reasoning_effort=low"]
        case .agy: options = ["--dangerously-skip-permissions", "--model", "review-model-low", "-i"]
        case .pi: options = ["--model", "review-model", "--thinking", "low"]
        }
        #expect(first.argv == options + [carried])
    }

    private struct Received: Decodable {
        let pid: Int
        let tty: Bool
        let cwd: String
        let argv: [String]
        let message: String?
    }

    private func receive(command: String, cwd: String, root: URL) async throws -> [Received] {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for agent in AgentKind.allCases {
            let executable = bin.appendingPathComponent(agent.harness.executable)
            try Self.receiver.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let output = try await BackgroundWork.run {
            try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/python3"), ["-c", Self.terminal, command, cwd, bin.path],
                                  environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], timeout: 20)
        }
        try #require(output.status == 0 && !output.timedOut, "\(output.stderr)\n\(output.stdout)")
        return try JSONDecoder().decode([Received].self, from: Data(output.stdout.utf8))
    }

    private nonisolated static let receiver = #"""
    #!/usr/bin/python3
    import json, os, sys
    def say(message=None):
        print(json.dumps(dict(pid=os.getpid(), tty=os.isatty(0), cwd=os.getcwd(), argv=sys.argv[1:], message=message)), flush=True)
    say()
    for line in sys.stdin:
        if line.strip() == 'quit':
            break
        say(line.rstrip('\n'))
    """#

    private nonisolated static let terminal = #"""
    import errno, json, os, pty, select, signal, sys, termios, time
    command, cwd, bin = sys.argv[1:]
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        settings = termios.tcgetattr(0)
        settings[3] &= ~termios.ECHO
        termios.tcsetattr(0, termios.TCSANOW, settings)
        os.execve('/bin/zsh', ['zsh', '-f', '-c', command], dict(PATH=bin+':/usr/bin:/bin', HOME=bin, TERM='dumb'))
    records, pending = [], b''
    deadline = time.monotonic() + 12
    try:
        while len(records) < 2:
            assert time.monotonic() < deadline, 'interactive receiver did not answer'
            if not select.select([fd], [], [], 0.1)[0]:
                continue
            pending += os.read(fd, 65536)
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                if not line.strip():
                    continue
                records.append(json.loads(line))
                if len(records) == 1:
                    os.write(fd, b'Continue in this same session.\n')
        os.write(fd, b'quit\n')
        print(json.dumps(records))
    finally:
        os.close(fd)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
    """#
}

@MainActor @Observable private final class ReviewPresentation { var open = true }
