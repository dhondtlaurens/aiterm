import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The overview of the design's operation — "Newsletter signup": two tickets, one building on the
/// other across pluto-cms and pluto-web, and two loose to-dos — at each of its moments: the plan
/// waiting, at work, and done (proposal steps 5, 7 and 8).
@MainActor
struct OperationOverviewTests {
    let cms = OperatorUIFixtures.project("pluto-cms"), web = OperatorUIFixtures.project("pluto-web")
    let schemaId = UUID(), homepageId = UUID(), footerId = UUID(), nuxtId = UUID()

    /// The four tasks, each in `states`' state, with the shas and ends given.
    private func tasks(_ run: UUID, _ states: [OperatedState], shas: [String?] = [nil, nil, nil, nil],
                       ends: [TaskEnd] = [.commit, .commit, .commit, .commit], flags: [Set<OperatedFlag>] = [[], [], [], []],
                       takenOver: [Bool] = [false, false, false, false]) -> [TaskItem] {
        func operated(_ i: Int, _ key: String, dependsOn: [TaskDependency] = [], stackedOn: UUID? = nil) -> OperatedTask {
            OperatorUIFixtures.operated(run: run, key: key, state: states[i], end: ends[i], dependsOn: dependsOn, stackedOn: stackedOn,
                                        sha: shas[i], takenOver: takenOver[i], flags: flags[i])
        }
        return [
            OperatorUIFixtures.task("The signup block schema", id: schemaId, jira: "PLUTO-231", project: cms.id,
                                    operated: operated(0, "pluto-231")),
            OperatorUIFixtures.task("The homepage section", id: homepageId, jira: "PLUTO-232", project: web.id,
                                    operated: operated(1, "pluto-232", dependsOn: [TaskDependency(task: schemaId, kind: .code)],
                                                       stackedOn: schemaId)),
            OperatorUIFixtures.task("Fix the /privacy footer link", id: footerId, agent: .codex, project: web.id,
                                    operated: operated(2, "privacy-footer")),
            OperatorUIFixtures.task("nuxt 3.19.2 → 3.19.4", id: nuxtId, agent: .codex, project: web.id,
                                    operated: operated(3, "nuxt-bump")),
        ]
    }

    private func state(_ run: OperatorRun, _ tasks: [TaskItem]) -> AppState {
        var state = AppState()
        state.append(project: cms)
        state.append(project: web)
        state.tasks = tasks
        state.runs = [run]
        return state
    }

    @Test func whileAPlanWaitsItIsAllTheOverviewShows() {
        let run = OperatorUIFixtures.run(state: .planning, planRevision: 1, approvedRevision: nil, decisions: [
            OperatorDecision(key: "plan-1", text: "2 now branches from 1’s commit.", task: nil, at: OperatorUIFixtures.epoch,
                             challenge: "2 should build on 1’s schema change, not only wait for it."),
        ])
        let overview = OperationOverview.make(run: run, state: state(run, tasks(run.id, [.planned, .planned, .planned, .planned],
                                                                                ends: [.commit, .commit, .commit, .merge])))
        #expect(overview.title == "Newsletter signup")
        #expect(overview.subtitle == "Operator · done when: a commit per item, tests green, I review and push")
        let plan = overview.plan
        #expect(plan?.revision == 1)
        #expect(plan?.help == "Nothing starts until you approve. Codex gave a second opinion; one change came of it.")
        #expect(plan?.rows.map(\.key) == [.ticket("PLUTO-231"), .ticket("PLUTO-232"), .todo, .todo])
        #expect(plan?.rows.map(\.sign) == ["+", "+", "+", "+"], "a first plan only adds")
        #expect(plan?.rows.map(\.detail) == ["pluto-cms · Claude · commit", "pluto-web · Claude · builds on PLUTO-231 · commit",
                                             "pluto-web · Codex · commit", "pluto-web · Codex · merge"])
        #expect(overview.groups.isEmpty, "what waits for approval is in the plan, not on the board")
        #expect(OperationOverview.PlanRow(id: "t", change: .changed, key: .todo, title: "t", detail: "d").sign == "~")
        #expect(overview.footer == .planWaits)
    }

    @Test func atWorkTheBoardRunsDownFromWhatWaitsOnYou() {
        let run = OperatorUIFixtures.run(questions: [OperatorUIFixtures.question("Codex asks to run npm install", task: footerId)],
                                         decisions: [OperatorDecision(key: "subtitle",
                                                                      text: "Gave the block an optional subtitle field: the design shows one, the ticket doesn’t mention it.",
                                                                      task: schemaId, at: OperatorUIFixtures.epoch, challenge: nil)])
        let all = tasks(run.id, [.accepted, .working, .working, .working], shas: ["4f2a91c0ffee", nil, nil, nil],
                        flags: [[], [], [.waitingOnYou], []])
        let overview = OperationOverview.make(run: run, state: state(run, all), acting: [homepageId])
        #expect(overview.groups.map(\.title) == ["Waiting on you", "Working", "Done"], "Up next is empty, so it is left out")
        #expect(overview.groups[0].attention == 1)
        #expect(overview.groups[0].items == [OperationOverview.Item(id: footerId.uuidString, mark: .waiting, key: .todo,
                                                                     title: "Codex asks to run npm install", link: .openTask(footerId))])
        #expect(overview.groups[1].items.map(\.title) == ["The homepage section", "nuxt 3.19.2 → 3.19.4"])
        #expect(overview.groups[1].items[0].detail == "answering Claude")
        #expect(overview.groups[1].items[0].avatars == AvatarGroup(marks: [.claude], overflow: 0, operatorPresence: .acting))
        #expect(overview.groups[1].items[1].avatars == AvatarGroup(marks: [.codex], overflow: 0, operatorPresence: .driving))
        #expect(overview.groups[2].items.map(\.detail) == ["4f2a91c"])
        #expect(overview.decisionsTitle == "Decided on its own · 1")
        #expect(overview.decisions.map(\.why) == ["Overrule it in the window if not."])
        #expect(overview.plan == nil)
        #expect(overview.footer == .working)
    }

    @Test func doneItSaysWhatEachTaskEndedAt() {
        let run = OperatorUIFixtures.run(state: .complete)
        let all = tasks(run.id, [.accepted, .accepted, .published, .noChange], shas: ["4f2a91c0", "9b3e07d0", "11c5d2e0", nil],
                        ends: [.commit, .commit, .merge, .commit])
        let overview = OperationOverview.make(run: run, state: state(run, all))
        #expect(overview.groups.map(\.title) == ["Done · 4 of 4"])
        #expect(overview.groups[0].items.map(\.detail) == ["4f2a91c", "9b3e07d · builds on 4f2a91c", "merged · 11c5d2e", "no change"])
        #expect(overview.footer == .done)
    }

    @Test func aQuestionAboutTheWholeOperationIsAnsweredInTheWindow() {
        let run = OperatorUIFixtures.run(state: .paused, questions: [OperatorUIFixtures.question("Should the block be on every page?", id: "scope")])
        let all = tasks(run.id, [.queued, .working, .queued, .queued], takenOver: [false, true, false, false])
        let overview = OperationOverview.make(run: run, state: state(run, all))
        #expect(overview.groups.map(\.title) == ["Waiting on you", "Working", "Up next"])
        #expect(overview.groups[0].items == [OperationOverview.Item(id: "scope", mark: .waiting, key: .question,
                                                                     title: "Should the block be on every page?", link: .answerInWindow)])
        #expect(overview.groups[1].items[0].detail == "taken over")
        #expect(overview.groups[1].items[0].avatars?.operatorPresence == nil, "you have it now")
        #expect(overview.groups[2].items.map(\.detail) == ["", "", ""])
        #expect(overview.footer == .paused)
        #expect(OperationOverview.make(run: OperatorUIFixtures.run(state: .operatorOffline), state: AppState()).footer == .paused)
    }

    @Test func whatTheSidebarRowWouldNotCallWaitingIsNotWaitingHere() {
        let resolved = OperatorQuestion(id: "q", text: "Codex asks to run npm install", task: footerId, askedAt: OperatorUIFixtures.epoch,
                                        resolution: "stopped")
        let run = OperatorUIFixtures.run(questions: [resolved])
        // A finished task's leftover flag asks nothing; a resolved question is not open; a taken-over
        // task that failed says it failed, as its row's caption does.
        let all = tasks(run.id, [.accepted, .failed, .working, .working], shas: ["4f2a91c0", nil, nil, nil],
                        flags: [[.waitingOnYou], [], [], []], takenOver: [false, true, false, false])
        let overview = OperationOverview.make(run: run, state: state(run, all))
        #expect(overview.groups.map(\.title) == ["Working", "Done"])
        #expect(overview.groups[0].items.map(\.detail) == ["failed", "", ""])
        #expect(overview.groups[0].items[0].avatars?.operatorPresence == nil)
        #expect(SidebarModel.operationRow(run: run, tasks: all).attention == 0)
    }

    @Test func theWaitingCountIsTheSidebarRowsAttentionCount() {
        let run = OperatorUIFixtures.run(questions: [OperatorUIFixtures.question("Codex asks to run npm install", task: footerId),
                                                     OperatorUIFixtures.question("Which brand?", id: "brand")])
        let all = tasks(run.id, [.working, .blocked, .working, .working], flags: [[.waitingOnYou], [], [], []])
        let overview = OperationOverview.make(run: run, state: state(run, all))
        #expect(overview.groups[0].title == "Waiting on you")
        #expect(overview.groups[0].attention == SidebarModel.operationRow(run: run, tasks: all).attention)
        #expect(overview.groups[0].attention == overview.groups[0].items.count)
        #expect(Set(overview.groups[0].items.map(\.id)).count == overview.groups[0].items.count)
    }

    @Test func aTaskIdThatRepeatsDoesNotBreakTheOverview() {
        let run = OperatorUIFixtures.run()
        var all = tasks(run.id, [.working, .working, .working, .working])
        all.append(all[0])
        let overview = OperationOverview.make(run: run, state: state(run, all))
        #expect(overview.groups.map(\.title) == ["Working"])
    }

    /// The sheet's `ForEach`s draw these items by id, so a question or a task that repeats, in the board,
    /// the plan or the decisions, is told apart by its place — and the first keeps its own id.
    @Test func everyRowsIdIsUniqueEvenWhenWhatItIsMadeFromRepeats() {
        let twice = [OperatorUIFixtures.question("First?", id: "scope"), OperatorUIFixtures.question("Again?", id: "scope"),
                     OperatorUIFixtures.question("About the task", id: "q", task: footerId),
                     OperatorUIFixtures.question("About it again", id: "q", task: footerId)]
        let decision = OperatorDecision(key: "same", text: "Did it.", task: nil, at: OperatorUIFixtures.epoch, challenge: nil)
        let run = OperatorUIFixtures.run(questions: twice, decisions: [decision, decision])
        var all = tasks(run.id, [.accepted, .working, .working, .queued])
        all.append(all[1]); all.append(all[3])
        let overview = OperationOverview.make(run: run, state: state(run, all))
        func unique(_ ids: [String]) -> Bool { Set(ids).count == ids.count }
        #expect(overview.groups.map(\.title).contains("Waiting on you"))
        for group in overview.groups { #expect(unique(group.items.map(\.id)), "\(group.title)") }
        #expect(overview.groups[0].items.map(\.id).first == "scope", "the first of a repeat keeps its id")
        #expect(unique(overview.decisions.map(\.id)) && overview.decisions.map(\.key) == ["same", "same"])

        let planning = OperatorUIFixtures.run(state: .planning, planRevision: 1, approvedRevision: nil)
        var planned = tasks(planning.id, [.planned, .planned, .planned, .planned])
        planned.append(planned[0])
        let plan = OperationOverview.make(run: planning, state: state(planning, planned)).plan
        #expect(plan.map { unique($0.rows.map(\.id)) } == true && plan?.rows.count == 5)
    }
}
