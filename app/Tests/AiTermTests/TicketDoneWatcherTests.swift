import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Answers which keys are done from a set the test changes as it goes, and records every list of
/// keys it was asked about. `failing` fails the next reads, as a Jira that does not answer does.
private final class DoneReader: DoneTicketsReading, @unchecked Sendable {
    private let table = Mutex<(done: Set<String>, failing: Bool, asked: [[String]])>(([], false, []))

    func done(_ keys: Set<String>) { table.withLock { $0.done = keys; $0.failing = false } }
    func fail() { table.withLock { $0.failing = true } }
    var asked: [[String]] { table.withLock { $0.asked } }

    func doneKeys(among keys: [String]) async throws -> Set<String> {
        let (done, failing) = table.withLock { table in
            table.asked.append(keys)
            return (table.done, table.failing)
        }
        if failing { throw URLError(.cannotConnectToHost) }
        return done.intersection(keys)
    }
}

@MainActor
struct TicketDoneWatcherTests {
    private let projectId = UUID()

    private func task(_ key: String, gitLabIssue: Bool = false) -> TaskItem {
        TaskItem.make(project: projectId, title: key, branch: "feat/\(key)",
                      jira: JiraRef(key: key, summary: key, url: "https://example/\(key)",
                                    source: gitLabIssue ? .gitLab(project: "acme/shop") : .jira))
    }

    private func make(_ tasks: [TaskItem], reader: DoneReader?) -> (watcher: TicketDoneWatcher, workspace: WorkspaceStore) {
        var state = AppState()
        state.tasks = tasks
        let workspace = WorkspaceStore.holding(state)
        return (TicketDoneWatcher(workspace: workspace, interval: .seconds(3600), connect: { reader }), workspace)
    }

    /// One read for every Jira ticket on a row, each key once; a GitLab issue and a row without a
    /// ticket are not asked.
    @Test func aPassAsksOnceForEveryJiraTicketAndNoOther() async {
        let open = task("SHOP-1"), done = task("SHOP-2"), twin = task("SHOP-2"), issue = task("#53", gitLabIssue: true)
        let plain = TaskItem.make(project: projectId)
        let reader = DoneReader()
        reader.done(["SHOP-2", "#53"])
        let (watcher, _) = make([open, done, issue, twin, plain], reader: reader)
        await watcher.refresh().value
        #expect(reader.asked == [["SHOP-1", "SHOP-2"]])
        #expect(!watcher.isDone(open.id))
        #expect(watcher.isDone(done.id))
        #expect(watcher.isDone(twin.id))
        #expect(!watcher.isDone(issue.id))
        #expect(!watcher.isDone(plain.id))
    }

    /// A network blip must not make a check flicker away: a failing read, or no Jira connection,
    /// leaves the last good answer; the next good read replaces it.
    @Test func aFailingReadOrNoConnectionKeepsTheLastGoodAnswer() async {
        let item = task("SHOP-1"), reader = DoneReader()
        reader.done(["SHOP-1"])
        let (watcher, workspace) = make([item], reader: reader)
        await watcher.refresh().value
        #expect(watcher.isDone(item.id))

        reader.fail()
        await watcher.refresh().value
        #expect(reader.asked.count == 2, "the failing read was made")
        #expect(watcher.isDone(item.id))

        reader.done([])
        await watcher.refresh().value
        #expect(!watcher.isDone(item.id))

        let unconnected = TicketDoneWatcher(workspace: workspace, interval: .seconds(3600), connect: { nil })
        unconnected.seedSnapshotDone(true, of: item.id)
        await unconnected.refresh().value
        #expect(unconnected.isDone(item.id))
    }

    /// A row whose task now carries another ticket loses its answer in the change that did it.
    @Test func aRowWhoseTicketChangesLosesItsAnswer() async {
        let item = task("SHOP-1"), reader = DoneReader()
        reader.done(["SHOP-1"])
        let (watcher, workspace) = make([item], reader: reader)
        await watcher.refresh().value
        #expect(watcher.isDone(item.id))
        workspace.mutate { state in
            state.tasks[0].jira = JiraRef(key: "SHOP-9", summary: "other", url: "https://example/SHOP-9")
        }
        #expect(!watcher.isDone(item.id))
    }

    /// An answer that lands after its row's ticket changed is not written to the row.
    @Test func anAnswerForATicketTheRowNoLongerCarriesIsDropped() async {
        let item = task("SHOP-1"), reader = DoneReader()
        reader.done(["SHOP-1"])
        let (watcher, workspace) = make([item], reader: reader)
        let pass = watcher.refresh()
        workspace.mutate { state in
            state.tasks[0].jira = JiraRef(key: "SHOP-9", summary: "other", url: "https://example/SHOP-9")
        }
        await pass.value
        #expect(!watcher.isDone(item.id))
    }
}
