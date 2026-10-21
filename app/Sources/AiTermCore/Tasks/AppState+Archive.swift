import Foundation

public extension AppState {
    func archived(id: UUID) -> ArchivedTask? { archive.first { $0.id == id } }

    func archived(projectId: UUID) -> [ArchivedTask] { archive.filter { $0.task.projectId == projectId } }

    /// Task `id` out of the sidebar and into the archive: windowless, on `branch` — the one its
    /// worktree was on, which can differ from the one it was created on — and stamped `date`.
    @discardableResult
    mutating func moveToArchive(taskId id: UUID, branch: String, at date: Date) -> ArchivedTask? {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        var task = tasks.remove(at: i)
        task.windowId = nil
        task.branch = branch
        let entry = ArchivedTask(task: task, archivedAt: date)
        archive.append(entry)
        return entry
    }

    /// Archived row `id` back among the tasks, where its creation date puts it, owed its window.
    @discardableResult
    mutating func moveFromArchive(id: UUID) -> TaskItem? {
        guard let i = archive.firstIndex(where: { $0.id == id }) else { return nil }
        var task = archive.remove(at: i).task
        task.windowId = nil
        tasks.insert(task, at: tasks.firstIndex { $0.createdAt > task.createdAt } ?? tasks.endIndex)
        return task
    }

    /// The archive as the sheet searches it: each row with its project's name and host.
    var archiveEntries: [ArchiveSearch.Entry] {
        archive.compactMap { archived in
            project(id: archived.task.projectId).map {
                ArchiveSearch.Entry(archived: archived, projectName: $0.name, provider: $0.provider)
            }
        }
    }

    /// The ended broadcasts, as the Shelf lists them: each dated when it ended, or, ended before that was
    /// recorded, when it was made. The one live broadcast is the sidebar's.
    var shelvedBroadcasts: [ShelvedBroadcast] {
        runs.filter(\.hasEnded).map {
            ShelvedBroadcast(runId: $0.id, name: $0.name, asked: $0.prompt, endedAt: $0.endedAt ?? $0.createdAt)
        }
    }

    /// Everything on the Shelf: the archive's rows and the ended broadcasts.
    var shelfRows: [ShelfRow] { archiveEntries.map(ShelfRow.task) + shelvedBroadcasts.map(ShelfRow.broadcast) }

    mutating func removeArchived(id: UUID) { archive.removeAll { $0.id == id } }

    /// The project and everything AiTerm keeps for it — its tasks, terminals and archived rows — gone
    /// from the workspace. Nothing on disk changes.
    mutating func removeProject(id: UUID) {
        tasks.removeAll { $0.projectId == id }
        terminals.removeAll { $0.projectId == id }
        archive.removeAll { $0.task.projectId == id }
        removeItem(id: id)
    }

    /// The worktree folders the project's archived rows come back to, which no new task may take.
    func reservedWorktreeSlugs(projectId: UUID) -> Set<String> {
        Set(archived(projectId: projectId).map { URL(fileURLWithPath: $0.task.worktreePath).lastPathComponent })
    }
}
