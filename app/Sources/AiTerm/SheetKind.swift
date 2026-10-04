import Foundation
import AiTermCore

/// What the sidebar presents as a sheet, and the values those sheets are opened with.
extension AppController {
    /// What a rename sheet is pointed at. Each case carries its own copy so the sheet keeps showing
    /// the name it opened with while the workspace changes underneath it.
    enum RenameTarget: Identifiable, Equatable {
        case divider(SidebarDivider), task(TaskItem), terminal(TerminalItem)
        var id: UUID {
            switch self {
            case .divider(let d): return d.id
            case .task(let t): return t.id
            case .terminal(let t): return t.id
            }
        }
        var name: String {
            switch self {
            case .divider(let d): return d.name
            case .task(let t): return t.title
            case .terminal(let t): return t.name
            }
        }
        var title: String {
            switch self {
            case .divider: return "Rename divider"
            case .task: return "Rename task"
            case .terminal: return "Rename terminal"
            }
        }
        var fieldLabel: String {
            switch self {
            case .divider: return "Divider name"
            case .task: return "Task name"
            case .terminal: return "Terminal name"
            }
        }
        /// The band's one sentence: what the new name changes, and what keeps its own.
        var subtitle: String {
            switch self {
            case .divider: return "Changes the heading over the projects under it."
            case .task: return "The branch and worktree keep their names."
            // The row's name only: a tab is titled with its branch (`sessions.setTitles`), and
            // the window's profile name is set once, when it opens.
            case .terminal: return "Renames the row in the sidebar; its iTerm2 tabs keep their branch titles."
            }
        }
    }

    /// The New Task case carries its draft: building it costs a `git symbolic-ref` and a read of
    /// the agent's config, and SwiftUI re-creates a sheet's root view on every state change of the
    /// presenting view — so the draft is built once here instead of in `NewTaskSheet.init`.
    enum SheetKind: Identifiable {
        case jiraProjects(Project)
        case newTask(TaskCreationModel), newReview(ReviewCreationModel)
        case newTerminal(Project, name: String, branch: String)
        case newDivider, rename(RenameTarget)
        /// Settings opens on the saved credentials, read from the Keychain once when it is presented.
        case settings(jira: JiraConfig?, gitLab: GitLabConfig?, gitHub: GitHubConfig?, tab: SettingsTab?)
        var id: String {
            switch self {
            case .jiraProjects(let project): return "project-jira-\(project.id)"
            case .newTask(let model): return "task-\(model.id)"
            case .newReview(let model): return "review-\(model.id)"
            case .newTerminal(let p, _, _): return "terminal-\(p.id)"
            case .newDivider: return "divider-new"
            case .rename(let target): return "rename-\(target.id)"
            case .settings: return "settings"
            }
        }
    }
}

/// What the New Task and New Review models share that the controller keeps current while the sheet
/// is up, so it need not tell the two apart.
@MainActor
protocol OffersAgents: AnyObject {
    var availableAgents: Set<AgentKind> { get set }
}

extension CreationModel: OffersAgents {}

extension AppController.SheetKind {
    /// The model a New Task or New Review sheet was opened with; `nil` for every other sheet.
    var creationModel: (any OffersAgents)? {
        switch self {
        case .newTask(let model): return model
        case .newReview(let model): return model
        case .jiraProjects, .newTerminal, .newDivider, .rename, .settings: return nil
        }
    }
}
