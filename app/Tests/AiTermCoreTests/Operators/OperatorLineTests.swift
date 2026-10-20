import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// Everything the Operator says on a status line (spec §7, §13): a closed list of words, quiet while it
/// watches, acting while AiTerm carries out one of its acts, needs-you while something waits on you.
/// A request outranks an act, a detail is cut to fit with the whole of it in the tooltip, and a task you
/// took over has no line at all.
@Suite struct OperatorLineTests {
    private let web = OperatorUIFixtures.project("pluto-web")

    private func task(_ title: String = "The homepage section", id: UUID = UUID(), jira: String? = nil, agent: AgentKind = .claude,
                      run: OperatorRun, key: String = "t", _ state: OperatedState, end: TaskEnd = .commit,
                      dependsOn: [TaskDependency] = [], stackedOn: UUID? = nil, revision: Int = 1, sha: String? = nil,
                      takenOver: Bool = false, reason: String? = nil) -> TaskItem {
        OperatorUIFixtures.task(title, id: id, jira: jira, agent: agent, project: web.id,
                                operated: OperatorUIFixtures.operated(run: run.id, key: key, state: state, end: end, dependsOn: dependsOn,
                                                                      stackedOn: stackedOn, revision: revision, sha: sha,
                                                                      takenOver: takenOver, blockedReason: reason))
    }

    private func request(_ kind: BroadcastRequest.Kind, _ run: OperatorRun, _ task: TaskItem?, _ text: String) -> BroadcastRequest {
        BroadcastRequest(kind: kind, runId: run.id, taskId: task?.id, text: text, key: kind == .question ? UUID().uuidString : nil)
    }

    @Test func aRequestOutranksAnAct() throws {
        let run = OperatorUIFixtures.run()
        let footer = task("Fix the /privacy footer link", agent: .codex, run: run, .working)
        let homepage = task(run: run, key: "pluto-232", .working)
        let asks = request(.permission, run, footer, "Codex asks to run npm install in Fix the /privacy footer link.")
        // The broadcast: the Operator answering one agent while another waits on you reads the request.
        let line = OperatorLine.broadcast(run, tasks: [footer, homepage], acting: (.answering, task: "pluto-232"), requests: [asks])
        #expect(line.text == "waiting on you · npm install?")
        #expect(line.look == .needsYou)
        #expect(line.tooltip == "Codex asks to run npm install in Fix the /privacy footer link.")
        // And a task: its own request outranks what the Operator is doing to it.
        let row = try #require(OperatorLine.task(footer, run: run, acting: .answering, requests: [asks]))
        #expect(row.text == "waiting on you · npm install?" && row.look == .needsYou)
        // With no request, the act is what the line says, the task it is about named on the broadcast's.
        let acting = OperatorLine.broadcast(run, tasks: [footer, homepage], acting: (.answering, task: "pluto-232"), requests: [])
        #expect(acting == OperatorLine("answering Claude · The homepage section", look: .acting))
    }

    @Test func severalRequestsCount() {
        let run = OperatorUIFixtures.run()
        let footer = task("Fix the /privacy footer link", run: run, .working), bump = task("Bump nuxt", run: run, .blocked, reason: "the tests fail on main")
        let requests = [request(.permission, run, footer, "Claude Code asks for permission in Fix the /privacy footer link."),
                        request(.blocked, run, bump, "Bump nuxt is blocked: the tests fail on main.")]
        let line = OperatorLine.broadcast(run, tasks: [footer, bump], acting: nil, requests: requests)
        #expect(line.text == "waiting on you · 2 tasks")
        #expect(line.look == .needsYou)
        #expect(line.tooltip.contains("Claude Code asks for permission") && line.tooltip.contains("Bump nuxt is blocked"))
        // Two things one task asks are that task's one line, not a count.
        let both = [requests[0], request(.question, run, footer, "The Operator asks: Which retry policy?")]
        #expect(OperatorLine.broadcast(run, tasks: [footer], acting: nil, requests: both).text == "waiting on you · permission?")
    }

    @Test func noProgressWhilePlanning() {
        let run = OperatorUIFixtures.run(state: .planning, planRevision: 0)
        let planned = [task(run: run, .planned), task("Write the tests", run: run, .planned)]
        let line = OperatorLine.broadcast(run, tasks: planned, acting: nil, requests: [])
        #expect(line == OperatorLine("loading the construct", look: .acting), "planning is the Operator acting, and says nothing of progress")
        let checking = OperatorLine.broadcast(run, tasks: planned, acting: (.consultingTheOracle, task: nil), requests: [])
        #expect(checking.text == "consulting the Oracle" && checking.look == .acting && checking.oracle)
        #expect(checking.oracleAgent == .codex)
        for line in [line, checking] { #expect(!line.text.contains(" of "), "\(line.text)") }
    }

    @Test func waitingOnAPersonIsQuiet() {
        let run = OperatorUIFixtures.run()
        var reviewed = task(run: run, .inReview)
        reviewed.operated?.peopleReview = PeopleReview(reviewers: ["Jan"])
        let done = task("The schema", run: run, .accepted, sha: "4f2a91cdeadbeef")
        let line = OperatorLine.broadcast(run, tasks: [reviewed, done], acting: nil, requests: [])
        #expect(line == OperatorLine("in review · waiting on Jan"))
        #expect(OperatorLine.task(reviewed, run: run, acting: nil, requests: []) == OperatorLine("in review · waiting on Jan"))
        // With an agent at work it is working, by count.
        let working = [task(run: run, .working), task(run: run, .working), task(run: run, .working), reviewed]
        #expect(OperatorLine.broadcast(run, tasks: working, acting: nil, requests: []) == OperatorLine("working · 3 tasks"))
    }

    @Test func everyActHasItsWords() {
        let words: [OperatorAct: String] = [
            .loadingTheConstruct: "loading the construct", .consultingTheOracle: "consulting the Oracle",
            .starting: "starting Codex", .answering: "answering Codex", .checkingTheWork: "checking the work",
            .reviewingWith: "reviewing with Codex", .openingTheMR: "opening the MR", .assigning: "assigning Jan",
            .fixingReviewFeedback: "fixing review feedback", .merging: "merging", .filingATicket: "filing a ticket",
            .reopeningItsWindow: "reopening its window",
        ]
        #expect(Set(words.keys) == Set(OperatorAct.allCases), "the list is closed: every act has its words")
        for act in OperatorAct.allCases { #expect(act.words(agent: .codex, names: ["Jan"]) == words[act], "\(act)") }
        #expect(OperatorAct.assigning.words(agent: .claude, names: ["Jan", "Piet"]) == "assigning Jan and Piet")
        #expect(OperatorAct.assigning.words(agent: .claude) == "assigning reviewers")
        // On a task's line the act is the task's: its agent, the Oracle's mark only while it is consulted.
        let run = OperatorUIFixtures.run()
        let codex = task(agent: .codex, run: run, .working)
        #expect(OperatorLine.task(codex, run: run, acting: .starting, requests: []) == OperatorLine("starting Codex", look: .acting))
        #expect(OperatorLine.task(codex, run: run, acting: .consultingTheOracle, requests: [])?.oracle == true)
        #expect(OperatorLine.task(codex, run: run, acting: .merging, requests: [])?.oracle == false)
    }

    @Test func takenOverHasNoLine() {
        let run = OperatorUIFixtures.run()
        for state in [OperatedState.working, .queued, .accepted] {
            #expect(OperatorLine.task(task(run: run, state, takenOver: true), run: run, acting: .answering, requests: []) == nil, "\(state)")
        }
        // Nor does a task the Operator let go of, or one in a broadcast that ended.
        #expect(OperatorLine.task(task(run: run, .stopped), run: run, acting: nil, requests: []) == nil)
        let ended = OperatorUIFixtures.run(state: .stopped)
        #expect(OperatorLine.task(task(run: ended, .working), run: ended, acting: nil, requests: []) == nil)
        #expect(OperatorLine.task(OperatorUIFixtures.task("Mine", project: web.id, operated: nil), run: run, acting: nil, requests: []) == nil)
    }

    @Test func aTasksLineSaysWhereItIsInItsWorkflow() {
        let run = OperatorUIFixtures.run()
        let parent = task("The signup block schema", jira: "PAY-232", run: run, .accepted, sha: "4f2a91cdeadbeef")
        func line(_ task: TaskItem, _ requests: [BroadcastRequest] = []) -> String? {
            OperatorLine.task(task, run: run, acting: nil, requests: requests)?.text
        }
        #expect(line(task(run: run, .queued)) == "queued")
        #expect(line(task(run: run, .planned)) == "queued")
        #expect(line(task(run: run, .queued, dependsOn: [TaskDependency(task: parent.id, kind: .order)])) == "queued · after another task",
                "with no lookup the parent is named generically")
        #expect(line(task(run: run, .working)) == "working")
        #expect(line(task(run: run, .queued, revision: 3)) == "added by the Operator")
        #expect(line(task(run: run, .blocked, reason: "the tests fail on main")) == "blocked · the tests fail on main")
        #expect(OperatorLine.task(task(run: run, .blocked, reason: "the tests fail on main"), run: run, acting: nil, requests: [])?.look == .needsYou)
        #expect(line(task(run: run, .accepted, sha: "4f2a91cdeadbeef")) == "done · 4f2a91c")
        var draft = task(run: run, .published, end: .draftMR, sha: "11c5d2e00")
        draft.operated?.publication = TaskPublication(mergeRequestURL: "https://gitlab.example/a/b/-/merge_requests/412", mergeRequestNumber: 412)
        #expect(line(draft) == "draft MR · !412")
        #expect(line(task(run: run, .published, end: .merge, sha: "9b3e07d1234")) == "merged · 9b3e07d")
        #expect(line(task(run: run, .published, end: .mergeLocal, sha: "9b3e07d1234")) == "merged locally · 9b3e07d")
        #expect(line(task(run: run, .published, end: .commit, sha: "9b3e07d1234")) == "done · 9b3e07d")
    }

    @Test func aTaskWaitingItsTurnNamesWhatItWaitsFor() {
        let run = OperatorUIFixtures.run()
        let parent = task("The signup block schema", jira: "PAY-232", run: run, .working)
        let byKey = task(run: run, .queued, dependsOn: [TaskDependency(task: parent.id, kind: .code)], stackedOn: parent.id)
        #expect(OperatorLine.task(byKey, run: run, acting: nil, requests: [], tasks: [parent.id: parent])?.text == "queued · after PAY-232")
    }

    @Test func aDetailIsCutToFitAndTheTooltipKeepsTheWhole() throws {
        let run = OperatorUIFixtures.run()
        let asked = task(run: run, .working)
        let question = "The Operator asks: Should the signup block keep its subtitle on mobile, where the design leaves it out?"
        let line = try #require(OperatorLine.task(asked, run: run, acting: nil, requests: [request(.question, run, asked, question)]))
        #expect(line.text.hasPrefix("waiting on you · Should the signup"))
        #expect(line.text.count <= OperatorLine.maxLength && line.text.hasSuffix("…"), "\(line.text)")
        #expect(line.tooltip == question)
        let short = request(.question, run, asked, "The Operator asks: retry policy?")
        #expect(OperatorLine.task(asked, run: run, acting: nil, requests: [short])?.text == "waiting on you · retry policy?")
    }

    @Test func theBroadcastSaysItsOwnState() {
        func line(_ state: OperatorRunState) -> String {
            OperatorLine.broadcast(OperatorUIFixtures.run(state: state), tasks: [], acting: nil, requests: []).text
        }
        #expect(line(.paused) == "paused")
        #expect(line(.operatorOffline) == "paused · the Operator’s window is closed")
        #expect(line(.complete) == "done · debrief ready")
    }

    /// A quiet line cut to fit keeps the whole of it in the tooltip, as needs-you does.
    @Test func aCutQuietLineKeepsTheWholeInItsTooltip() throws {
        let run = OperatorUIFixtures.run()
        let because = "npm ci failed with a lockfile that no longer matches package.json"
        let failed = try #require(OperatorLine.task(task(run: run, .failed, reason: because), run: run, acting: nil, requests: []))
        #expect(failed.text.hasSuffix("…") && failed.text.count <= OperatorLine.maxLength, "\(failed.text)")
        #expect(failed.tooltip == "failed · " + because)
        let parent = task("Show the newsletter signup block on the homepage and the blog", run: run, .working)
        let child = task(run: run, .queued, dependsOn: [TaskDependency(task: parent.id, kind: .order)])
        let queued = try #require(OperatorLine.task(child, run: run, acting: nil, requests: [], tasks: [parent.id: parent]))
        #expect(queued.text.hasSuffix("…"), "\(queued.text)")
        #expect(queued.tooltip == "queued · after Show the newsletter signup block on the homepage and the blog")
        var reviewed = task(run: run, .inReview)
        reviewed.operated?.peopleReview = PeopleReview(reviewers: ["Jan Peeters", "An Vermeulen", "Piet Janssens"])
        let waiting = OperatorLine.broadcast(run, tasks: [reviewed], acting: nil, requests: [])
        #expect(waiting.text.hasSuffix("…"))
        #expect(waiting.tooltip == "in review · waiting on Jan Peeters, An Vermeulen and Piet Janssens")
    }

    /// A finished task's leftover request asks nothing on the broadcast's line either, as on its own.
    @Test func aFinishedTasksLeftoverRequestIsNotTheBroadcasts() {
        let run = OperatorUIFixtures.run()
        let done = task(run: run, .accepted, sha: "4f2a91cdeadbeef"), working = task("Bump nuxt", run: run, .working)
        let leftover = request(.question, run, done, "The Operator asks: retry policy?")
        #expect(OperatorLine.task(done, run: run, acting: nil, requests: [leftover])?.text == "done · 4f2a91c")
        #expect(OperatorLine.broadcast(run, tasks: [done, working], acting: nil, requests: [leftover]) == OperatorLine("working · 1 task"))
        // Beside another task's request it is not counted either.
        let asks = request(.permission, run, working, "Claude Code asks for permission in Bump nuxt.")
        #expect(OperatorLine.broadcast(run, tasks: [done, working], acting: nil, requests: [leftover, asks]).text == "waiting on you · permission?")
    }
}
