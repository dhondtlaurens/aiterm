import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Answers each merge request by its address from a table the test changes as it goes, and records
/// every address it was asked for. An address not in the table fails, as a host that does not
/// answer does; one answered `nil` is a host that is not connected.
private final class TableReader: ReviewThreadsReading, @unchecked Sendable {
    private let table = Mutex<(answers: [String: ReviewThreads?], asked: [String])>(([:], []))

    func answer(_ url: String, _ threads: ReviewThreads?) { table.withLock { _ = $0.answers.updateValue(threads, forKey: url) } }
    func fail(_ url: String) { table.withLock { _ = $0.answers.removeValue(forKey: url) } }
    var asked: [String] { table.withLock { $0.asked } }

    func threads(of mr: MergeRequestRef) async throws -> ReviewThreads? {
        let answer: ReviewThreads?? = table.withLock { table in
            table.asked.append(mr.url)
            return table.answers[mr.url]
        }
        guard let answer else { throw URLError(.cannotConnectToHost) }
        return answer
    }
}

/// Holds every read until `open()`, then answers 2 of 5.
private final class GatedReader: ReviewThreadsReading, @unchecked Sendable {
    private let gate: AsyncStream<Void>
    private let opener: AsyncStream<Void>.Continuation
    private let started = Mutex(0)

    init() {
        let made = AsyncStream<Void>.makeStream()
        gate = made.stream
        opener = made.continuation
    }

    var reads: Int { started.withLock { $0 } }
    func open() { opener.finish() }

    func threads(of mr: MergeRequestRef) async throws -> ReviewThreads? {
        started.withLock { $0 += 1 }
        for await _ in gate {}
        return ReviewThreads(resolved: 2, total: 5)
    }
}

@MainActor
struct ReviewThreadsWatcherTests {
    private let projectId = UUID()

    private func task(_ number: Int, mr url: String? = nil) -> TaskItem {
        TaskItem(id: UUID(), projectId: projectId, title: "Task \(number)", branch: "feat/\(number)", worktreePath: "/wt\(number)",
                 baseBranch: "main", jira: nil, kind: url == nil ? .task : .review,
                 mr: url.map { MergeRequestRef(iid: number, title: "MR \(number)", url: $0) },
                 agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: nil)
    }

    private func review(_ number: Int) -> TaskItem {
        task(number, mr: "https://gitlab.example.net/web/shop/-/merge_requests/\(number)")
    }

    private func make(_ tasks: [TaskItem], reader: any ReviewThreadsReading, interval: Duration = .seconds(3600))
        -> (watcher: ReviewThreadsWatcher, workspace: WorkspaceStore, focus: RowFocus) {
        var state = AppState()
        state.tasks = tasks
        let workspace = WorkspaceStore.holding(state)
        let focus = RowFocus(workspace: workspace, daemon: { nil }, taskFrame: { Frame(x: 0, y: 0, w: 0, h: 0) },
                             activateIterm: {}, isRemoving: { _ in false },
                             notices: Notices(toastLifetime: .seconds(10), isStale: { _ in false }))
        let watcher = ReviewThreadsWatcher(workspace: workspace, focus: focus, interval: interval, connect: { reader })
        return (watcher, workspace, focus)
    }

    @Test func theSelectionTellsItsHooksOfEachNewRowOnly() {
        let item = review(87)
        let (_, _, focus) = make([item], reader: TableReader())
        let heard = Mutex<[RowSelection?]>([])
        focus.onSelectionChanged { selection in heard.withLock { $0.append(selection) } }
        focus.browse(.task(item.id))
        focus.browse(.task(item.id))
        focus.browse(nil)
        #expect(heard.withLock { $0 } == [.task(item.id), nil])
    }

    @Test func aPassReadsEveryRowWithAMergeRequestAndNoOther() async {
        let a = review(87), b = review(91), plain = task(3)
        let reader = TableReader()
        reader.answer(a.mr!.url, ReviewThreads(resolved: 2, total: 5))
        reader.answer(b.mr!.url, ReviewThreads(resolved: 0, total: 0))
        let (watcher, _, _) = make([a, plain, b], reader: reader)
        await watcher.refresh().value
        #expect(reader.asked.sorted() == [a.mr!.url, b.mr!.url].sorted())
        #expect(watcher.threads(of: a.id) == ReviewThreads(resolved: 2, total: 5))
        // Kept as read; the badge decides that none is shown (`TaskRowBadges`).
        #expect(watcher.threads(of: b.id) == ReviewThreads(resolved: 0, total: 0))
        #expect(watcher.threads(of: plain.id) == nil)
    }

    /// Before any good read there is no count to keep: a read that fails, and a host that is not
    /// connected, both leave the row without one.
    @Test func beforeAGoodReadAFailingReadAndANilAnswerLeaveNoCount() async {
        let item = review(87), reader = TableReader(), url = item.mr!.url
        let (watcher, _, _) = make([item], reader: reader)
        await watcher.refresh().value
        #expect(reader.asked == [url], "the failing read was made")
        #expect(watcher.threads(of: item.id) == nil)
        reader.answer(url, nil)
        await watcher.refresh().value
        #expect(reader.asked == [url, url], "the unconnected host was asked")
        #expect(watcher.threads(of: item.id) == nil)
    }

    /// A network blip must not make a count flicker away: a read that fails, or a host that is not
    /// connected, leaves the last good count; the next good read replaces it.
    @Test func aFailingReadAndANilAnswerKeepTheLastGoodCountUntilAGoodReadReplacesIt() async {
        let item = review(87), reader = TableReader(), url = item.mr!.url
        let (watcher, _, _) = make([item], reader: reader)
        reader.answer(url, ReviewThreads(resolved: 2, total: 5))
        await watcher.refresh().value
        #expect(watcher.threads(of: item.id) == ReviewThreads(resolved: 2, total: 5))

        reader.fail(url)
        await watcher.refresh().value
        #expect(reader.asked.count == 2, "the failing read was made")
        #expect(watcher.threads(of: item.id) == ReviewThreads(resolved: 2, total: 5))

        reader.answer(url, nil)
        await watcher.refresh().value
        #expect(reader.asked.count == 3, "the unconnected host was asked")
        #expect(watcher.threads(of: item.id) == ReviewThreads(resolved: 2, total: 5))

        reader.answer(url, ReviewThreads(resolved: 5, total: 5))
        await watcher.refresh().value
        #expect(watcher.threads(of: item.id) == ReviewThreads(resolved: 5, total: 5))
    }

    /// Review focus 1: a row that went, or now carries another merge request (a review opened in
    /// the task that had its branch), loses the count it had, in the same change.
    @Test func aCountGoesWithItsRowOrItsMergeRequest() async {
        let gone = review(87), moved = review(91), reader = TableReader()
        reader.answer(gone.mr!.url, ReviewThreads(resolved: 1, total: 2))
        reader.answer(moved.mr!.url, ReviewThreads(resolved: 3, total: 4))
        let (watcher, workspace, _) = make([gone, moved], reader: reader)
        await watcher.refresh().value
        workspace.mutate { state in
            state.tasks.removeAll { $0.id == gone.id }
            state.tasks[0].mr = MergeRequestRef(iid: 95, title: "Other", url: "https://gitlab.example.net/web/shop/-/merge_requests/95")
        }
        #expect(watcher.threads(of: gone.id) == nil)
        #expect(watcher.threads(of: moved.id) == nil)
    }

    /// Review focus 1: a read that lands after its row went writes nothing for it.
    @Test func aCountReadForARowThatWentMeanwhileIsDropped() async {
        let gone = review(87), reader = GatedReader()
        let (watcher, workspace, _) = make([gone], reader: reader)
        let pass = watcher.refresh()
        await eventually { reader.reads == 1 }
        workspace.mutate { $0.tasks = [] }
        reader.open()
        await pass.value
        #expect(watcher.threads(of: gone.id) == nil)
    }

    /// Review focus 5: a selection reads its row again only while the watcher runs — never in a
    /// process that only renders, or before launch — and only a row with a merge request.
    @Test func selectingARowWithAMergeRequestReadsItAgainWhileStarted() async {
        let item = review(87), plain = task(3), reader = TableReader()
        reader.answer(item.mr!.url, ReviewThreads(resolved: 1, total: 5))
        let (watcher, _, focus) = make([item, plain], reader: reader)
        focus.browse(.task(item.id))
        #expect(watcher.selectionRead == nil, "stopped, a selection reads nothing")
        focus.browse(nil)

        watcher.start()
        defer { watcher.stop() }
        await eventually { watcher.threads(of: item.id) == ReviewThreads(resolved: 1, total: 5) }
        reader.answer(item.mr!.url, ReviewThreads(resolved: 2, total: 5))
        focus.browse(.task(item.id))
        await watcher.selectionRead?.value
        #expect(watcher.threads(of: item.id) == ReviewThreads(resolved: 2, total: 5))

        let before = watcher.selectionRead
        focus.browse(.task(plain.id))
        #expect(watcher.selectionRead == before, "a row without a merge request is not read")
    }

    @Test func startReadsEveryIntervalUntilStopped() async throws {
        let item = review(87), reader = TableReader()
        reader.answer(item.mr!.url, ReviewThreads(resolved: 0, total: 1))
        let (watcher, _, _) = make([item], reader: reader, interval: .milliseconds(10))
        watcher.start()
        watcher.start()
        await eventually { reader.asked.count >= 3 }
        watcher.stop()
        let asked = reader.asked.count
        try await Task.sleep(for: .milliseconds(60))
        // A read already off the main actor as `stop()` ran may still land; no pass starts after it.
        #expect(reader.asked.count <= asked + 1)
    }

    /// The controller's watcher reads with the connections it was built with; a test's are none,
    /// so a review is read and wears no count.
    @Test func theControllerReadsWithItsConnections() async {
        let controller = AppController(preferences: .scratch())
        let item = review(87)
        controller.workspace.mutate { $0.tasks = [item] }
        await controller.reviewThreads.refresh().value
        #expect(controller.reviewThreads.threads(of: item.id) == nil)
    }
}
