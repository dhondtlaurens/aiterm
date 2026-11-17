import Foundation
import AiTermCore

@MainActor @Observable final class ProjectSheetModel {
    let id = UUID()
    let editing: Bool
    private(set) var preparation: ProjectPreparation
    var linked: [JiraProjectRef]
    var importWorktrees: Bool
    private(set) var projects: [JiraProjectRef] = []
    private(set) var loading = true
    private(set) var loadingError: String?
    private(set) var error: String?
    private(set) var saving = false
    private(set) var preparing = false
    private let git: any GitRunning
    private let canChange: @MainActor () -> Bool
    private let inspect: @MainActor (String) async throws -> ProjectPreparation
    private let choose: @MainActor () async -> URL?
    private let load: @MainActor () async throws -> [JiraProjectRef]
    private let commit: @MainActor (ProjectPreparation, [JiraProjectRef], Bool) async throws -> Void

    init(preparation: ProjectPreparation, editing: Bool, git: any GitRunning, canChange: @escaping @MainActor () -> Bool,
         inspect: @escaping @MainActor (String) async throws -> ProjectPreparation,
         chooseFolder: @escaping @MainActor () async -> URL?, loadProjects: @escaping @MainActor () async throws -> [JiraProjectRef],
         commit: @escaping @MainActor (ProjectPreparation, [JiraProjectRef], Bool) async throws -> Void) {
        self.preparation = preparation; self.editing = editing; self.canChange = canChange
        self.git = git
        self.inspect = inspect; self.choose = chooseFolder; self.load = loadProjects; self.commit = commit
        linked = preparation.project.jiraProjects
        importWorktrees = preparation.canImport
    }
    var canSave: Bool { canChange() && !saving && !preparing }
    var title: String { editing ? "Edit \(preparation.project.name)" : "Add project" }
    var closing: String {
        if editing { return "Saves the Jira projects of \(preparation.project.name). Its folder, name and tasks stay as they are." }
        let count = importWorktrees && preparation.canImport ? preparation.worktrees.count : 0
        let imports = count == 0 ? "" : count == 1 ? ", with its existing worktree as a task" : ", with \(count) existing worktrees as tasks"
        return "Adds \(preparation.project.name) under Projects\(imports). Nothing in the folder changes."
    }
    func matches(_ query: String) -> [JiraProjectRef] { JiraProjectSearch.rank(projects, query: query, excluding: linked) }
    func loadDefaultBranchName() async {
        guard editing else { return }
        let git = git, path = preparation.project.path
        do {
            let name = try await BackgroundWork.run { try Repository(path, git: git).detectDefaultBranch() }
            guard !Task.isCancelled else { return }
            preparation.defaultBranch = name
        } catch {}
    }
    func chooseFolder() async {
        guard let url = await choose(), !Task.isCancelled else { return }
        preparing = true; error = nil; defer { preparing = false }
        do {
            let found = try await inspect(url.path)
            guard !Task.isCancelled else { return }
            preparation = found; importWorktrees = found.canImport
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
    func loadProjects() async {
        do {
            let values = try await load()
            guard !Task.isCancelled else { return }
            projects = values; loadingError = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadingError = error.localizedDescription
        }
        loading = false
    }
    func save() async -> Bool {
        guard canSave else { return false }
        saving = true; error = nil; defer { saving = false }
        do { try await commit(preparation, linked.linkedOnce, !editing && importWorktrees && preparation.canImport); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}

#if DEBUG
extension ProjectSheetModel {
    func seedProjects(_ values: [JiraProjectRef]) { projects = values; loading = false; loadingError = nil }
}
#endif
