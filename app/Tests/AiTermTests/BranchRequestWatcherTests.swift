import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Answers each branch from a table the test changes as it goes, and records every branch it was
/// asked for. A branch not in the table fails, as a host that does not answer does; one answered
/// `nil` has no request, or a host that is not connected.
private final class BranchTable: BranchRequestReading, @unchecked Sendable {
    private let table = Mutex<(answers: [String: MergeRequestRef?], asked: [String], remotes: [String?])>(([:], [], []))

    func answer(_ branch: String, _ request: MergeRequestRef?) { table.withLock { _ = $0.answers.updateValue(request, forKey: branch) } }
    var asked: [String] { table.withLock { $0.asked } }
    var remotes: [String?] { table.withLock { $0.remotes } }

    func request(remoteUrl: String?, branch: String) async throws -> MergeRequestRef? {
        let answer: MergeRequestRef?? = table.withLock { table in
            table.asked.append(branch)
            table.remotes.append(remoteUrl)
            return table.answers[branch]
        }
        guard let answer else { throw URLError(.cannotConnectToHost) }
        return answer
    }
}

/// Holds every read until `open()`, then answers `request`.
private final class GatedTable: BranchRequestReading, @unchecked Sendable {
    private let gate: AsyncStream<Void>
    private let opener: AsyncStream<Void>.Continuation
    private let started = Mutex(0)
    let answer: MergeRequestRef

    init(_ answer: MergeRequestRef) {
        let made = AsyncStream<Void>.makeStream()
        gate = made.stream; opener = made.continuation; self.answer = answer
    }

    var reads: Int { started.withLock { $0 } }
    func open() { opener.finish() }

    func request(remoteUrl: String?, branch: String) async throws -> MergeRequestRef? {
        started.withLock { $0 += 1 }
        for await _ in gate {}
        return answer
    }
}

@MainActor
struct BranchRequestWatcherTests {
    private let project = Project(id: UUID(), name: "shop", path: "/shop", provider: .gitlab,
                                  remoteUrl: "git@gitlab.example.net:web/shop.git", addedAt: Date(), collapsed: false)

    private func request(_ iid: Int) -> MergeRequestRef {
        MergeRequestRef(iid: iid, title: "MR \(iid)", url: "https://gitlab.example.net/web/shop/-/merge_requests/\(iid)")
    }

    private func task(_ branch: String, kind: TaskKind = .task, checkout: Bool = true, base: String = "main",
                      mr: MergeRequestRef? = nil) -> TaskItem {
        TaskItem.make(project: project.id, title: branch, branch: branch, worktreePath: checkout ? "/wt/\(branch)" : "",
                      baseBranch: base, kind: kind, mr: mr)
    }

    private func make(_ tasks: [TaskItem], reader: any BranchRequestReading, interval: Duration = .seconds(3600))
        -> (watcher: BranchRequestWatcher, workspace: WorkspaceStore, focus: RowFocus) {
        var state = AppState()
        state.items = [.project(project)]
        state.tasks = tasks
        let workspace = WorkspaceStore.holding(state)
        let focus = RowFocus(workspace: workspace, daemon: { nil }, taskFrame: { Frame(x: 0, y: 0, w: 0, h: 0) },
                             activateIterm: {}, isRemoving: { _ in false },
                             notices: Notices(toastLifetime: .seconds(10), isStale: { _ in false }))
        let watcher = BranchRequestWatcher(workspace: workspace, focus: focus, interval: interval, connect: { reader })
        return (watcher, workspace, focus)
    }

    /// A task and a review without a request are asked, with their project's remote; a Signal's
    /// task, a row without a checkout, one with a request, and one on its base branch are not.
    @Test func aPassAsksOnlyForRowsThatCanStillGainARequest() async {
        var signal = task("feat/signal")
        signal.signalTask = SignalTask.make(item: .request(remote: "git@gitlab.example.net:web/shop.git", number: 1), startedAt: Date())
        let tasks = [task("feat/plain"), task("feat/review", kind: .review), signal, task("feat/planned", checkout: false),
                     task("feat/known", mr: request(1)), task("main"), task("")]
        let reader = BranchTable()
        let (watcher, _, _) = make(tasks, reader: reader)
        await watcher.refresh().value
        #expect(reader.asked == ["feat/plain", "feat/review"])
        #expect(reader.remotes == [project.remoteUrl, project.remoteUrl])
    }

    /// An answer goes on the task; from then on it is not asked again.
    @Test func aFoundRequestIsSavedAndNotAskedAgain() async {
        let plain = task("feat/plain"), reader = BranchTable()
        reader.answer("feat/plain", request(7))
        let (watcher, workspace, _) = make([plain], reader: reader)
        await watcher.refresh().value
        #expect(workspace.state.task(id: plain.id)?.mr == request(7))
        await watcher.refresh().value
        #expect(reader.asked == ["feat/plain"])
    }

    /// No request, or a read that fails, changes nothing, and the task is asked again next pass.
    @Test func noAnswerOrAFailedReadChangesNothing() async {
        let none = task("feat/none"), failing = task("feat/failing"), reader = BranchTable()
        reader.answer("feat/none", nil)
        let (watcher, workspace, _) = make([none, failing], reader: reader)
        await watcher.refresh().value
        await watcher.refresh().value
        #expect(workspace.state.tasks.allSatisfy { $0.mr == nil })
        #expect(reader.asked == ["feat/none", "feat/failing", "feat/none", "feat/failing"])
    }

    /// A review opened meanwhile put its own request on the task, or the task moved to another
    /// branch: the answer for the old state is dropped.
    @Test func anAnswerForATaskThatChangedMeanwhileIsDropped() async {
        let given = task("feat/given"), moved = task("feat/moved")
        let reader = GatedTable(request(7))
        let (watcher, workspace, _) = make([given, moved], reader: reader)
        let pass = watcher.refresh()
        await eventually { reader.reads == 1 }
        workspace.mutate { state in
            state.tasks[0].mr = request(3)
            state.tasks[1].branch = "feat/elsewhere"
        }
        reader.open()
        await pass.value
        #expect(workspace.state.task(id: given.id)?.mr == request(3))
        #expect(workspace.state.task(id: moved.id)?.mr == nil)
    }

    /// The project's remote was adopted anew while the read was out: the answer names the old
    /// repository's request, and is dropped.
    @Test func anAnswerFromAProjectsOldRemoteIsDropped() async {
        let plain = task("feat/plain")
        let reader = GatedTable(request(7))
        let (watcher, workspace, _) = make([plain], reader: reader)
        let pass = watcher.refresh()
        await eventually { reader.reads == 1 }
        workspace.mutate { state in
            if case .project(var moved) = state.items[0] { moved.remoteUrl = "git@gitlab.example.net:web/other.git"; state.items[0] = .project(moved) }
        }
        reader.open()
        await pass.value
        #expect(workspace.state.project(id: project.id)?.remoteUrl == "git@gitlab.example.net:web/other.git")
        #expect(workspace.state.task(id: plain.id)?.mr == nil)
    }

    /// Selecting a row without a request reads it at once, only while the watcher runs.
    @Test func selectingARowReadsItAtOnceWhileStarted() async {
        let plain = task("feat/plain"), known = task("feat/known", mr: request(1)), reader = BranchTable()
        reader.answer("feat/plain", nil)
        let (watcher, workspace, focus) = make([plain, known], reader: reader)
        focus.browse(.task(plain.id))
        #expect(watcher.selectionRead == nil, "stopped, a selection reads nothing")
        focus.browse(nil)

        watcher.start()
        defer { watcher.stop() }
        await eventually { reader.asked.count == 1 }
        reader.answer("feat/plain", request(9))
        focus.browse(.task(plain.id))
        await watcher.selectionRead?.value
        #expect(workspace.state.task(id: plain.id)?.mr == request(9))

        let before = watcher.selectionRead
        focus.browse(.task(known.id))
        #expect(watcher.selectionRead == before, "a row with a request is not read")
    }
}
