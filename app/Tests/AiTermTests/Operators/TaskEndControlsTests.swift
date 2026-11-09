import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// What the person does from a card of a broadcast set up with the Task step (broadcast setup v2, Board): change one
/// running task's end, and answer a task out of its fix rounds. Each is saved and wakes the Operator with what was done.
@MainActor @Suite struct TaskEndControlsTests {
    let project = OperatorServiceFixtures.project()

    func makeWorld(taskState: OperatedState = .accepted, end: TaskEnd = .merge, merge: Bool = true,
                   publication: TaskPublication? = nil, fixRoundsAsked: Bool = false, key: String = "cart-drawer",
                   asked: (UUID) -> [OperatorQuestion] = { _ in [] }) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        var profile = OperatorServiceFixtures.profile()
        profile.slices = Slices(merge: merge)
        var run = OperatorServiceFixtures.run(profile, projects: [project], state: .active, planRevision: 1,
                                              agents: OperatorServiceFixtures.agents,
                                              taskSettings: OperatorServiceFixtures.taskSettings)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: key, state: taskState, worktree: "/tmp/aiterm-wt",
                                                end: end)
        task.operated?.publication = publication
        // Asked before the world starts, so it is no news of its own: the answer is the wake's only news.
        if fixRoundsAsked {
            run.questions = [OperatorQuestion(id: "fix-rounds", text: "Out of fix rounds: one more, or accept it?", task: task.id,
                                              askedAt: Date(timeIntervalSince1970: 0), about: OperatorQuestion.fixRounds)]
        }
        run.questions += asked(task.id)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: .done)])
        return (world, run, task)
    }

    /// The wake lines delivered once one has been: other news may follow the one a test is about.
    private func wakes(_ world: OperatorWorld) async throws -> [String] {
        try await world.daemon.received("session.deliver")
        return world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }
    }

    @Test func changingAnEndSavesItAndWakesTheOperator() async throws {
        let waiting = TaskPublication(pushedSHA: "abc1234", mergeRequestURL: "https://gitlab.example/acme/shop/-/merge_requests/412",
                                      mergeRequestNumber: 412, waitingSince: Date(timeIntervalSince1970: 0), mergeRefusal: "Not yet.")
        let (world, run, task) = try makeWorld(publication: waiting)
        try world.controller.changeEnd(of: task.id, to: .draftMR)
        let operated = try #require(world.task(task.id)?.operated)
        #expect(operated.end == .draftMR && operated.publication?.waitingSince == nil && operated.publication?.mergeRefusal == nil)
        #expect(operated.publication?.mergeRequestNumber == 412)
        #expect(world.workspace.flush())
        #expect(try world.workspace.file.load().tasks.first?.operated?.end == .draftMR, "saved")
        #expect(world.run(run.id)?.leftForYou == [])
        #expect(try await wakes(world).contains("[AiTerm] You changed cart-drawer’s end to draft MR, call run_status"))
    }

    @Test func aSwitchBelowWhatIsDoneFinishesTheTaskAndCanCompleteTheBroadcast() async throws {
        let open = TaskPublication(pushedSHA: "abc1234", mergeRequestURL: "https://gitlab.example/acme/shop/-/merge_requests/412",
                                   mergeRequestNumber: 412)
        let (world, run, task) = try makeWorld(publication: open)
        try world.controller.changeEnd(of: task.id, to: .commit)
        #expect(world.task(task.id)?.operated?.isFinished == true)
        #expect(world.run(run.id)?.leftForYou.first?.hasPrefix("Close or merge !412 in Shop yourself") == true)
        #expect(world.run(run.id)?.state == .complete, "its last open task finished")
        // One wake carries both: the change, and the completion it brought.
        #expect(try await wakes(world).contains("[AiTerm] You changed cart-drawer’s end to commit, and the broadcast is complete, call run_status"))
    }

    @Test func aTaskYouTookOverKeepsItsEnd() throws {
        let (world, _, task) = try makeWorld()
        world.workspace.mutate { $0.updateOperated(task.id) { $0.takenOver = true } }
        #expect(throws: ActionUnavailable.self) { try world.controller.changeEnd(of: task.id, to: .draftMR) }
        #expect(world.task(task.id)?.operated?.end == .merge)
    }

    /// A merge end opened and waiting, on an active broadcast: what the finisher would watch.
    private var openRequest: TaskPublication {
        TaskPublication(pushedSHA: "abc1234", mergeRequestURL: "https://gitlab.example/acme/shop/-/merge_requests/412", mergeRequestNumber: 412)
    }

    @Test func anEndChangedToMergeWaitsForTheOperatorsFinishTask() throws {
        let (world, _, task) = try makeWorld(publication: openRequest)
        try world.controller.changeEnd(of: task.id, to: .draftMR)
        #expect(!world.controller.finisher.watching.contains(task.id))
        try world.controller.changeEnd(of: task.id, to: .merge)
        #expect(!world.controller.finisher.watching.contains(task.id), "no merge starts without a finish_task")
        #expect(world.task(task.id)?.operated?.publication?.problem == TaskEndChange.mergeWaitsForFinish)
        // A pass that resumes every watch, as a Resume or a hand back runs, starts none either.
        world.controller.finisher.resumeWatching()
        #expect(!world.controller.finisher.watching.contains(task.id))
    }

    @Test func aTakeoversHoldGoesWithItsMergeAndAMergeAgainIsHeld() async throws {
        let (world, _, task) = try makeWorld(publication: openRequest)
        try await world.controller.takeOver(task: task.id)
        try await world.controller.handBack(task: task.id)
        #expect(world.task(task.id)?.operated?.publication?.problem == TaskFinisher.takenOverProblem)
        // A draft MR end has no merge to hold: no stale "taken over" on its card.
        try world.controller.changeEnd(of: task.id, to: .draftMR)
        #expect(world.task(task.id)?.operated?.publication?.problem == nil)
        // Back to Merge: held until the Operator's finish_task, as every switch to Merge is.
        try world.controller.changeEnd(of: task.id, to: .merge)
        #expect(world.task(task.id)?.operated?.publication?.problem == TaskEndChange.mergeWaitsForFinish)
        #expect(!world.controller.finisher.watching.contains(task.id))
    }

    @Test func aChangeTheCardCantOfferIsRefused() throws {
        let (world, _, task) = try makeWorld(merge: false)
        let refusal = #expect(throws: ActionUnavailable.self) { try world.controller.changeEnd(of: task.id, to: .mergeLocal) }
        #expect(refusal?.message == "Merge is off for this broadcast, so a task ends at a commit or a draft MR.")
        #expect(world.task(task.id)?.operated?.end == .merge, "nothing changed")


    }

    @Test func answeringFixRoundsWakesTheOperatorWithTheAnswerAndLeavesTheQuestionToIt() async throws {
        let (world, run, task) = try makeWorld(taskState: .working, end: .draftMR, fixRoundsAsked: true)
        try world.controller.answerFixRounds(of: task.id, .oneMoreRound)
        #expect(try await wakes(world).contains("[AiTerm] You answered cart-drawer’s fix rounds: one more round, call run_status"))
        #expect(world.run(run.id)?.questions.first?.resolution == nil, "the Operator resolves it, as with an answer in its chat")
        #expect(world.run(run.id)?.questions.first?.answeredOnCard == "oneMoreRound", "kept on the question, for run_status and the card")

        // A second click, before the Operator resolved it, says nothing: the first answer stands. (The waker may say the
        // first again until the Operator looks, as it does every reason.)
        try world.controller.answerFixRounds(of: task.id, .acceptAsItIs)
        await world.controller.waker.lastCoalesce?.value
        await world.controller.waker.lastSend?.value
        let lines = world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }
        #expect(!lines.contains { $0.contains(BroadcastBoard.FixRoundsAnswer.acceptAsItIs.words) })
        #expect(world.run(run.id)?.questions.first?.answeredOnCard == "oneMoreRound")

        // Taken over, the task is yours: nothing is answered for it.
        world.workspace.mutate { $0.updateOperated(task.id) { $0.takenOver = true } }
        #expect(throws: ActionUnavailable.self) { try world.controller.answerFixRounds(of: task.id, .oneMoreRound) }
        world.workspace.mutate { $0.updateOperated(task.id) { $0.takenOver = false; $0.state = .noChange } }
        #expect(throws: ActionUnavailable.self) { try world.controller.answerFixRounds(of: task.id, .oneMoreRound) }

        // With no such question open there is nothing to answer.
        world.workspace.mutate { $0.updateOperated(task.id) { $0.state = .working } }
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.questions[0].resolution = "One more round." } }
        #expect(throws: ActionUnavailable.self) { try world.controller.answerFixRounds(of: task.id, .acceptAsItIs) }
    }

    /// An answer in a question's block under Waiting on you (D1a): recorded once, the Operator woken with a fixed line that
    /// names the task and never the answer, the question left open for it. T2's question doesn't hold, so it is still
    /// answered after T2 is accepted; a fix-rounds question answered on its card shows answered here, and the other way round.
    @Test func answeringInTheListRecordsItOnceAndWakesTheOperatorWithAFixedLine() async throws {
        // Accepted as a commit-only task, T2 has finished: its question that doesn't hold still waits. Asked before the
        // world starts, so the answer is the wake's only news.
        let (world, run, task) = try makeWorld(taskState: .accepted, end: .commit, fixRoundsAsked: true, key: "PAY-232") { task in
            [OperatorQuestion(id: "t2-gate", text: "Keep the access gate for admins?", task: task, askedAt: Date(timeIntervalSince1970: 0),
                              holds: false, choices: ["Keep it for admins", "Drop it for admins"]),
             OperatorQuestion(id: "reviewer", text: "Which Sofie reviews?", task: nil, askedAt: Date(timeIntervalSince1970: 0))]
        }
        #expect(world.task(task.id)?.operated?.isFinished == true)
        try world.controller.answer(question: "t2-gate", in: run.id, with: "Drop it for admins")
        let line = "[AiTerm] the person answered PAY-two-three-two's question in AiTerm, call run_status"
        let delivered = try await wakes(world)
        #expect(delivered.contains(line), "\(delivered)")
        #expect(OperatorWaker.isPlain(OperatorController.answeredReason(task: "PAY-232")))
        let asked = try #require(world.run(run.id)?.questions.first { $0.id == "t2-gate" })
        #expect(asked.answeredHere == "Drop it for admins" && asked.answeredHereAt != nil && asked.resolution == nil)

        let again = #expect(throws: ActionUnavailable.self) { try world.controller.answer(question: "t2-gate", in: run.id, with: "Keep it") }
        #expect(again?.message == "Already answered: wait for the Operator, or answer again in its chat.")
        #expect(world.run(run.id)?.questions.first { $0.id == "t2-gate" }?.answeredHere == "Drop it for admins")

        try world.controller.answer(question: "reviewer", in: run.id, with: "sofie.maes")
        #expect(OperatorController.answeredReason(task: nil) == "the person answered one question in AiTerm")
        #expect(world.run(run.id)?.questions.first { $0.id == "reviewer" }?.answeredHere == "sofie.maes")
        // The finished task's fix rounds held it: they ask nothing now.
        #expect(throws: ActionUnavailable.self) { try world.controller.answer(question: "fix-rounds", in: run.id, with: "One More Round") }
    }

    @Test func aFixRoundsBlockAnswersAsItsCardDoes() throws {
        let (world, run, task) = try makeWorld(taskState: .working, end: .draftMR, fixRoundsAsked: true)
        try world.controller.answer(question: "fix-rounds", in: run.id, with: "One More Round")
        #expect(world.run(run.id)?.questions.first?.answeredOnCard == "oneMoreRound")
        #expect(world.run(run.id)?.questions.first?.answer == "One More Round")
        // Answered in the list, the card's links do nothing more.
        try world.controller.answerFixRounds(of: task.id, .acceptAsItIs)
        #expect(world.run(run.id)?.questions.first?.answeredOnCard == "oneMoreRound")

        // Answered on the card, the list refuses it.
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.questions[0].answeredOnCard = nil } }
        try world.controller.answerFixRounds(of: task.id, .acceptAsItIs)
        #expect(throws: ActionUnavailable.self) { try world.controller.answer(question: "fix-rounds", in: run.id, with: "One More Round") }
        #expect(world.run(run.id)?.questions.first?.answeredOnCard == "acceptAsItIs")
    }

    @Test func aQuestionAnsweredElsewhereOrNoLongerYoursIsRefused() throws {
        let (world, run, task) = try makeWorld(taskState: .working, end: .draftMR)
        world.workspace.mutate { state in
            state.updateRun(id: run.id) {
                $0.questions = [
                    OperatorQuestion(id: "prompt-\(task.id.uuidString)-1", text: "Claude Code asks for permission", task: task.id,
                                     askedAt: Date(timeIntervalSince1970: 0)),
                    OperatorQuestion(id: "gate-1", text: "The Oracle stopped `npm publish`.", task: nil, askedAt: Date(timeIntervalSince1970: 0),
                                     gate: GateRequest(command: "npm publish", directory: "/w")),
                    OperatorQuestion(id: "scope", text: "Keep drafts?", task: task.id, askedAt: Date(timeIntervalSince1970: 0), holds: false),
                    OperatorQuestion(id: "done", text: "Old?", task: nil, askedAt: Date(timeIntervalSince1970: 0), resolution: "Yes."),
                ]
            }
        }
        let prompt = #expect(throws: ActionUnavailable.self) {
            try world.controller.answer(question: "prompt-\(task.id.uuidString)-1", in: run.id, with: "yes")
        }
        #expect(prompt?.message == "Answer it in its worker’s window.")
        let gate = #expect(throws: ActionUnavailable.self) { try world.controller.answer(question: "gate-1", in: run.id, with: "yes") }
        #expect(gate?.message == "Answer it in the Operator’s chat.")
        #expect(throws: ActionUnavailable.self) { try world.controller.answer(question: "done", in: run.id, with: "No.") }
        world.workspace.mutate { $0.updateOperated(task.id) { $0.takenOver = true } }
        #expect(throws: ActionUnavailable.self) { try world.controller.answer(question: "scope", in: run.id, with: "Keep them") }
        #expect(world.run(run.id)?.questions.allSatisfy { $0.answeredHere == nil } == true)
    }

    @Test func theFixRoundsAnswersWords() {
        #expect(BroadcastBoard.FixRoundsAnswer.allCases.map(\.title) == ["One More Round", "Accept As It Is"])
        #expect(BoardCardView.answered(.oneMoreRound) == "You answered: one more round.")
        #expect(BroadcastBoard.FixRoundsAnswer.acceptAsItIs.words == "accept it as it is")
    }
}
