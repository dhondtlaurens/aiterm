import Testing
import Foundation
@testable import AiTermCore

@Suite struct ArchiveStateTests {
    let project = Project(id: UUID(), name: "Repo", path: "/tmp/Repo", provider: .git, remoteUrl: nil,
                          addedAt: Date(timeIntervalSince1970: 0), collapsed: false)

    func task(_ title: String, created: TimeInterval, window: String? = "w") -> TaskItem {
        TaskItem(id: UUID(), projectId: project.id, title: title, branch: "feat/\(title)", worktreePath: "/tmp/Repo/.worktrees/\(title)",
                 baseBranch: "main", jira: nil, agent: .claude, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                 createdAt: Date(timeIntervalSince1970: created), windowId: window,
                 conversations: [TaskConversation(agent: .claude, id: "c-\(title)")])
    }

    func state(_ tasks: TaskItem...) -> AppState {
        var state = AppState.empty
        state.append(project: project)
        state.tasks = tasks
        return state
    }

    @Test func archivingMovesTheRowOutWindowlessOnItsActualBranchKeepingItsConversations() throws {
        let a = task("a", created: 1)
        var s = state(a)
        let moved = s.moveToArchive(taskId: a.id, branch: "feat/moved", at: Date(timeIntervalSince1970: 50))
        let entry = try #require(moved)
        #expect(s.tasks.isEmpty)
        #expect(s.archive == [entry])
        #expect(entry.task.windowId == nil)
        #expect(entry.task.branch == "feat/moved")
        #expect(entry.task.conversations == a.conversations)
        #expect(entry.archivedAt == Date(timeIntervalSince1970: 50))
    }

    @Test func restoringPutsTheRowBackInCreationOrderOwedItsWindow() throws {
        let a = task("a", created: 1), b = task("b", created: 2), c = task("c", created: 3)
        var s = state(a, b, c)
        s.moveToArchive(taskId: b.id, branch: b.branch, at: Date())
        let restored = s.moveFromArchive(id: b.id)
        let back = try #require(restored)
        #expect(s.tasks.map(\.id) == [a.id, b.id, c.id])
        #expect(back.windowId == nil)
        #expect(s.archive.isEmpty)
    }

    @Test func movingWhatIsNotThereChangesNothing() {
        var s = state(task("a", created: 1))
        let before = s
        #expect(s.moveToArchive(taskId: UUID(), branch: "x", at: Date()) == nil)
        #expect(s.moveFromArchive(id: UUID()) == nil)
        #expect(s == before)
    }

    @Test func removingAProjectForgetsItsArchivedRowsToo() {
        let a = task("a", created: 1), b = task("b", created: 2)
        var s = state(a, b)
        s.moveToArchive(taskId: b.id, branch: b.branch, at: Date())
        s.removeProject(id: project.id)
        #expect(s.tasks.isEmpty && s.archive.isEmpty && s.projects.isEmpty)
    }

    @Test func anArchivedRowReservesItsWorktreeFolder() {
        let a = task("a", created: 1)
        var s = state(a)
        s.moveToArchive(taskId: a.id, branch: a.branch, at: Date())
        #expect(s.reservedWorktreeSlugs(projectId: project.id) == ["a"])
        #expect(s.reservedWorktreeSlugs(projectId: UUID()).isEmpty)
    }

    @Test func theArchiveRoundTripsAndAnEmptyOneIsNotWritten() throws {
        let a = task("a", created: 1), b = task("b", created: 2)
        var s = state(a, b)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let empty = try JSONSerialization.jsonObject(with: encoder.encode(s)) as? [String: Any]
        #expect(empty?["archive"] == nil, "a workspace with nothing archived is written as it always was")
        s.moveToArchive(taskId: b.id, branch: b.branch, at: Date(timeIntervalSince1970: 9))
        #expect(try decoder.decode(AppState.self, from: encoder.encode(s)) == s)
    }

    @Test func theStoreRefusesAnArchivedRowWhoseProjectIsGoneOrWhoseIdIsAlsoATask() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let a = task("a", created: 1)
        var orphan = state()
        orphan.archive = [ArchivedTask(task: a, archivedAt: Date())]
        orphan.removeItem(id: project.id)
        #expect(throws: (any Error).self) { try store.save(orphan) }
        var twice = state(a)
        twice.archive = [ArchivedTask(task: a, archivedAt: Date())]
        #expect(throws: (any Error).self) { try store.save(twice) }
    }
}
