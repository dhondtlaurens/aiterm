import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct SignalSavedFormatTests {
    @Test func theSignalWorkspaceKeepsItsAuthorityPendingStageAndArchive() throws {
        let folder = try ScratchFolder.make("aiterm-signal-contract-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("state.json")), state = Self.state()
        try store.save(state)
        let bytes = try Data(contentsOf: store.url)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/operator-signals/state.json")
        if ProcessInfo.processInfo.environment["AITERM_RECORD_SIGNAL_STATE"] == "1" { try bytes.write(to: fixture) }
        #expect(bytes == (try Data(contentsOf: fixture)))
        let loaded = try store.load()
        #expect(loaded == state)
        #expect(loaded.tasks[0].signalTask?.pendingStages.count == 1)
        #expect(loaded.archive[0].task.signalTask?.phase == .archived)
        #expect(loaded.tasks[1].takenOver && loaded.tasks[1].signalTask == nil && !loaded.tasks[0].takenOver)
        #expect(loaded.operatorSession?.generation == 2)
        #expect(loaded.operatorSession?.lifecycle == .open(since: Date(timeIntervalSince1970: 1_794_657_600), wake: nil))
        #expect(loaded.operatorSession?.waitingOnYou == 1)
        #expect(loaded.operatorSession?.oracleRounds.count == 1)
    }
    /// A question saved before withdrawals existed loads open and waiting, and a withdrawn one is saved
    /// with its reason and loads closed.
    @Test func aQuestionSavedWithoutWithdrawnLoadsAndAWithdrawnOneRoundTrips() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/operator-signals/state.json")
        let bytes = try Data(contentsOf: fixture)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("withdrawn"))
        let folder = try ScratchFolder.make("aiterm-signal-withdrawn-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("state.json"))
        try bytes.write(to: store.url)
        var loaded = try store.load()
        #expect(loaded.operatorSession?.waitingOnYou == 1 && loaded.operatorSession?.questions.allSatisfy { $0.withdrawn == nil } == true)
        let gated = #"{"id":"gate-1","text":"May the Operator run this command?","openedAt":0,"gate":{"command":"./deploy","directory":"/synthetic"}}"#
        let old = try JSONDecoder().decode(OperatorSession.Question.self, from: Data(gated.utf8))
        #expect(old.gate?.command == "./deploy" && old.withdrawn == nil && old.resolvedAt == nil)
        loaded.operatorSession?.questions.append(old)
        #expect(loaded.operatorSession?.withdrawGateQuestions(at: Date(timeIntervalSince1970: 1_794_657_700), reason: "Dropped.") == true)
        try store.save(loaded)
        let again = try StateStore(url: store.url).load()
        #expect(again == loaded && again.operatorSession?.waitingOnYou == 1)
        #expect(again.operatorSession?.questions.last?.withdrawn == "Dropped.")
    }
    /// A workspace saved before the Operator's section could be open,
    /// opens on the projects; the Operator open is kept, and the default is written as it always was.
    @Test func theProjectsAreTheDefaultSectionAndAnOpenOperatorIsKept() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let old = try decoder.decode(AppState.self, from: Data(#"{"items":[],"tasks":[],"terminals":[]}"#.utf8))
        #expect(!old.operatorOpen)
        let plain = try #require(JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any])
        #expect(plain["operatorOpen"] == nil)
        var open = old; open.operatorOpen = true
        #expect(try decoder.decode(AppState.self, from: encoder.encode(open)).operatorOpen)
    }

    private static func state() -> AppState {
        func id(_ n: Int) -> UUID { UUID(uuidString: "E7A1C0DE-0000-4000-8000-" + String(format: "%012X", n))! }
        let at = Date(timeIntervalSince1970: 1_794_657_600)
        let claude = AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")
        let codex = AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")
        let project = Project.make(id: id(1), name: "Shop", path: "/synthetic/shop", provider: .gitlab,
            remoteUrl: "https://git.example/shop/web", addedAt: at)
        let first = Signal(id: id(2), name: "Plan tickets", createdAt: at,
            start: SignalTrigger(source: .jira, description: "Tickets labelled operator", query: "labels = operator"),
            done: SignalTrigger(source: .jira, query: "status = Done"), work: SignalWork(prompt: "/psg:plan"),
            agents: [claude, codex], finish: SignalFinish(then: .keep))
        let next = Signal(id: id(3), name: "Build tickets", createdAt: at.addingTimeInterval(1),
            start: SignalTrigger(source: .jira, query: "labels = ready"),
            done: SignalTrigger(source: .gitLab, description: "When it is approved", query: "review-state:approved"),
            work: SignalWork(prompt: "/psg:implement, then /psg:review"),
            agents: [codex], finish: SignalFinish(then: .archive, mergesWhenReady: true))
        var task = TaskItem.make(id: id(4), project: project.id, title: "Make retries safe", branch: "feat/pay-1",
            worktreePath: "/synthetic/shop/.worktrees/pay-1", jira: JiraRef(key: "PAY-1", summary: "Make retries safe", url: "https://jira.example/browse/PAY-1"),
            model: claude.model, reasoning: claude.reasoning, firstPrompt: first.work.prompt, createdAt: at, windowId: "worker-window")
        task.conversations = [TaskConversation(agent: .claude, id: "worker-conversation")]
        var record = SignalTask(current: SignalStage(signal: first.id, item: .ticket(site: "https://jira.example", key: "PAY-1"), matchedAt: at,
            configuration: first, prompt: first.work.prompt), startedAt: at)
        record.phase = .working; record.doneMatched = false
        record.launch = LaunchAttempt(number: 1, requestedAt: at, openedAt: at, workerPending: false)
        record.pendingStages = [SignalStage(signal: next.id, item: record.current.item, matchedAt: at, configuration: next)]
        record.pendingReplies = ["main": SignalWorkerReply(at: at, fingerprint: "previous-reply")]
        record.extraTabs = [ExtraTab(key: "inspect", agent: .codex, model: codex.model, reasoning: codex.reasoning,
            modelReason: "Inspect the boundary.", brief: "Inspect the retry boundary.", launch: LaunchAttempt(number: 1, requestedAt: at), sessionId: "extra-session")]
        record.journal = [TaskJournal.Entry(id: id(5), at: at, stage: 1, text: .ours("The worker is planning retries."), key: "note")]
        task.signalTask = record
        var archived = task; archived.id = id(6); archived.title = "Earlier work"; archived.windowId = nil
        archived.branch = "feat/pay-2"; archived.worktreePath = "/synthetic/shop/.worktrees/pay-2"
        archived.conversations = [TaskConversation(agent: .claude, id: "archived-conversation")]
        archived.jira = JiraRef(key: "PAY-2", summary: "Earlier work", url: "https://jira.example/browse/PAY-2")
        archived.signalTask?.current.item = .ticket(site: "https://jira.example", key: "PAY-2")
        archived.signalTask?.phase = .archived; archived.signalTask?.pendingStages = []; archived.signalTask?.pendingReplies = nil
        archived.signalTask?.extraTabs = []; archived.signalTask?.thenApplied = true
        // A task the person took over: an ordinary task of its project, its record gone and the mark on it.
        var taken = TaskItem.make(id: id(8), project: project.id, title: "Tidy checkout", branch: "feat/pay-3",
            worktreePath: "/synthetic/shop/.worktrees/pay-3", jira: JiraRef(key: "PAY-3", summary: "Tidy checkout", url: "https://jira.example/browse/PAY-3"),
            model: claude.model, reasoning: claude.reasoning, firstPrompt: first.work.prompt, createdAt: at, windowId: nil)
        taken.takenOver = true
        var session = OperatorSession(id: id(7), createdAt: at); session.generation = 2
        session.window = "operator-window"; session.session = "operator-session"; session.conversation = "operator-conversation"
        session.lifecycle = .open(since: at, wake: nil)
        var question = OperatorSession.Question(id: "locale", task: task.id, text: "Which locale?", openedAt: at)
        question.stage = 1; question.ownership = 0; question.tab = "main"; question.workerQuestion = "Which locale?"
        session.questions = [question]
        session.oracleRounds = [OracleRound(id: "round", tool: "answer_worker", stage: .delivered, critique: "Use the order's locale.",
                                            askedAt: at, askedEvidence: "question-bound", round: 1)]
        session.remember(key: "tool:note:note", result: ["status": "recorded"], at: at, arguments: "{}")
        var state = AppState(); state.append(project: project); state.signals = [first, next]; state.tasks = [task, taken]
        state.archive = [ArchivedTask(task: archived, archivedAt: at)]; state.operatorSession = session
        state.signalSeen = [SignalSeen(signal: first.id, item: record.current.item, disposition: .started, at: at)]
        return state
    }
}
