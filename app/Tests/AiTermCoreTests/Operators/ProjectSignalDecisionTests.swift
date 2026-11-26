import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// How a project signal's match is decided, and how it shares an item with Operator signals: project signals rank
/// first, take an item for the pass, never hand a task to the Operator and never take one from it.
@Suite struct ProjectSignalDecisionTests {
    func match(_ world: SignalWorld, _ signal: UUID, item: ItemRef? = nil, project: UUID?? = nil, branch: String? = nil,
               fromFork: Bool = false) -> SignalMatch {
        SignalMatch(signal: signal, item: item ?? world.ticket().item, project: project ?? world.project.id, matchedAt: world.now,
                    branch: branch, fromFork: fromFork)
    }
    func decide(_ world: SignalWorld, _ matches: [SignalMatch], claimed: Set<String> = []) -> [MatchDecision] {
        MatchDecision.decide(matches: matches, signals: world.state.signals, tasks: world.state.tasks + world.state.archive.map(\.task),
                             projects: world.state.projects, seen: world.state.signalSeen, complete: true, claimed: claimed)
    }
    /// A task made by hand for the world's ticket.
    func handMade(_ world: inout SignalWorld) -> UUID {
        let task = TaskItem.make(project: world.project.id, jira: JiraRef(key: "PAY-1", summary: "Make retries safe",
                                                                          url: "https://jira.example/browse/PAY-1"))
        world.state.tasks.append(task)
        return task.id
    }

    @Test func anItemWithNoTaskInOneProjectStartsAnOrdinaryTask() {
        var world = SignalWorld(); let id = world.projectSignal()
        let found = match(world, id)
        #expect(decide(world, [found]) == [.startOrdinary(found)])
    }

    @Test func anItemNoProjectMatchesIsSkippedWithTodaysReason() {
        var world = SignalWorld(); let id = world.projectSignal()
        let lost = match(world, id, item: .ticket(site: "https://jira.example", key: "OPS-1"), project: .some(nil))
        #expect(decide(world, [lost]) == [.skip(lost, reason: "No project in AiTerm matches this item.")])
    }

    @Test func anItemSeveralProjectsMatchIsSkippedNamingThem() {
        var world = SignalWorld(); let id = world.projectSignal()
        world.state.append(project: .make(name: "shop-admin", path: "/synthetic/shop-admin", jiraProjects: world.project.jiraProjects))
        let found = match(world, id)
        #expect(decide(world, [found]) == [.skip(found, reason: "Several projects in AiTerm match this item: shop and shop-admin.")])
    }

    @Test func aRunStartsOrdinaryOrSkipsWhenItsProjectIsGone() {
        var world = SignalWorld(); let id = world.projectSignal()
        let run = SignalRunRef(signal: id, at: world.now)
        let due = match(world, id, item: .run(run))
        #expect(decide(world, [due]) == [.startOrdinary(due)])
        let lost = match(world, id, item: .run(run), project: .some(nil))
        #expect(decide(world, [lost]) == [.skip(lost, reason: "Its project is no longer in AiTerm.")])
    }

    @Test(arguments: [false, true]) func itsOwnTaskMatchesAgainAsARematch(archived: Bool) throws {
        var world = SignalWorld(); let id = world.projectSignal()
        let task = world.markedTask(signal: id)
        if archived {
            let branch = try #require(world.state.task(id: task)?.branch)
            _ = world.state.moveToArchive(taskId: task, branch: branch, at: world.now)
        }
        let again = match(world, id)
        #expect(decide(world, [again]) == [.rematch(task, again)])
    }

    /// O1: a task made by hand for the item is marked with the signal and gets its prompt.
    @Test func aTaskMadeByHandIsRematched() {
        var world = SignalWorld(); let id = world.projectSignal()
        let task = handMade(&world)
        let found = match(world, id)
        #expect(decide(world, [found]) == [.rematch(task, found)])
    }

    @Test func aTakenOverTaskYieldsNothing() {
        var world = SignalWorld(); let id = world.projectSignal()
        let task = handMade(&world)
        world.state.updateSignalItem(task) { $0.takenOver = true }
        #expect(decide(world, [match(world, id)]).isEmpty)
    }

    /// O2: the Operator keeps its task; the project signal shows the item as skipped.
    @Test func aTaskTheOperatorHoldsIsSkipped() {
        var world = SignalWorld(); let operatorSignal = world.signal()
        world.workingTask(signal: operatorSignal)
        let id = world.projectSignal()
        let found = match(world, id)
        #expect(decide(world, [found]) == [.skip(found, reason: "The Operator runs this item’s task.")])
    }

    /// The first project signal keeps the item: another one's match on its task leaves no decision and no record.
    @Test func anotherProjectSignalsTaskYieldsNothing() {
        var world = SignalWorld(); let first = world.projectSignal(name: "First"), second = world.projectSignal(name: "Second")
        world.markedTask(signal: first)
        #expect(decide(world, [match(world, second)]).isEmpty)
    }

    /// A fork's branch is not in the project's repository: it is skipped before any task is looked for, so a task on a
    /// same-named branch is never re-matched either.
    @Test func aForkedRequestIsSkippedBeforeAnyTask() {
        var world = SignalWorld(); let id = world.projectSignal(start: SignalTrigger(source: .gitLab, query: "reviewer:@me"))
        let request = ItemRef.request(remote: "https://git.example/shop/web", number: 7)
        let task = TaskItem.make(project: world.project.id, branch: "feature/retries")
        world.state.tasks.append(task)
        let own = match(world, id, item: request, branch: "feature/retries")
        #expect(decide(world, [own]) == [.rematch(task.id, own)])
        let fork = match(world, id, item: request, branch: "feature/retries", fromFork: true)
        #expect(decide(world, [fork]) == [.skip(fork, reason: "From a fork: AiTerm checks out only branches of the project’s own repository.")])
        world.state.tasks.removeAll()
        #expect(decide(world, [fork]) == [.skip(fork, reason: "From a fork: AiTerm checks out only branches of the project’s own repository.")])
    }

    @Test func ofTwoProjectSignalsOnOneItemTheHigherStartsAndTheLowerYieldsNothing() {
        var world = SignalWorld(); let higher = world.projectSignal(name: "Higher"), lower = world.projectSignal(name: "Lower")
        let first = match(world, higher), second = match(world, lower)
        #expect(decide(world, [second, first]) == [.startOrdinary(first)])
        let task = handMade(&world)
        #expect(decide(world, [second, first]) == [.rematch(task, first)])
    }

    /// Project signals rank above Operator signals whatever their places in `signals`; the Operator signal gets
    /// nothing for the item, neither a start, a pending stage nor a record.
    @Test func aProjectSignalWinsAnItemOverAnOperatorSignalInOnePass() {
        var world = SignalWorld(); let operatorSignal = world.signal(), projectSignal = world.projectSignal()
        let theirs = match(world, operatorSignal), ours = match(world, projectSignal)
        #expect(decide(world, [theirs, ours]) == [.startOrdinary(ours)])
        let task = handMade(&world)
        #expect(decide(world, [theirs, ours]) == [.rematch(task, ours)])
    }

    /// In separate passes the first read wins: the second signal meets the first one's task.
    @Test func inSeparatePassesTheFirstReadWins() {
        var operatorFirst = SignalWorld(); let operatorSignal = operatorFirst.signal()
        operatorFirst.workingTask(signal: operatorSignal)
        let projectSignal = operatorFirst.projectSignal()
        let late = match(operatorFirst, projectSignal)
        #expect(decide(operatorFirst, [late]) == [.skip(late, reason: "The Operator runs this item’s task.")])

        var projectFirst = SignalWorld(); let project = projectFirst.projectSignal(), operatorLate = projectFirst.signal()
        projectFirst.markedTask(signal: project)
        #expect(decide(projectFirst, [match(projectFirst, operatorLate)]).isEmpty)
    }

    /// An Operator signal never continues a task a project signal marked, in the sidebar or archived.
    @Test(arguments: [false, true]) func anOperatorSignalNeverContinuesAMarkedTask(archived: Bool) throws {
        var world = SignalWorld(); let projectSignal = world.projectSignal(), operatorSignal = world.signal()
        let task = world.markedTask(signal: projectSignal)
        world.state.signals.removeAll { $0.id == projectSignal }
        if archived {
            let branch = try #require(world.state.task(id: task)?.branch)
            _ = world.state.moveToArchive(taskId: task, branch: branch, at: world.now)
        }
        #expect(decide(world, [match(world, operatorSignal)]).isEmpty)
    }

    /// A claimed identity, a project pick-up queued or under way, is out of an Operator signal's reach; a project
    /// signal still decides it (its queue drops the duplicate).
    @Test func aClaimedIdentityYieldsNothingForAnOperatorSignal() throws {
        var world = SignalWorld(); let operatorSignal = world.signal(), projectSignal = world.projectSignal()
        let identity = try #require(world.ticket().item.identity)
        #expect(decide(world, [match(world, operatorSignal)], claimed: [identity]).isEmpty)
        let ours = match(world, projectSignal)
        #expect(decide(world, [ours], claimed: [identity]) == [.startOrdinary(ours)])
        let other = match(world, operatorSignal, item: world.ticket("PAY-2").item)
        #expect(decide(world, [other], claimed: [identity]) == [.start(other, pending: [])])
    }

    /// A marked task is found by its origin's item, whatever its ticket and request links say.
    @Test func aMarkedTaskMatchesItsOriginsItem() throws {
        var world = SignalWorld(); let id = world.projectSignal()
        let request = ItemRef.request(remote: "https://git.example/shop/web", number: 7)
        let marked = world.markedTask(signal: id, item: request)
        let task = try #require(world.state.task(id: marked))
        #expect(task.jira == nil && task.mr == nil)
        #expect(MatchDecision.matchesItem(request, task: task))
        #expect(!MatchDecision.matchesItem(.request(remote: "https://git.example/shop/web", number: 8), task: task))
        #expect(!MatchDecision.matchesItem(world.ticket().item, task: task))
    }

    /// A marked task's item is live: its records stay whatever their age.
    @Test func aMarkedTasksItemKeepsItsRecords() {
        var world = SignalWorld(); let id = world.projectSignal()
        world.markedTask(signal: id)
        var record = SignalSeen(signal: id, item: world.ticket().item, disposition: .started, at: world.now.addingTimeInterval(-91 * 86400))
        record.isMatching = false
        world.state.signalSeen = [record]
        world.state.pruneOperator(at: world.now)
        #expect(world.state.signalSeen == [record])
    }
}
