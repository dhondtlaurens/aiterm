import SwiftUI
import AiTermUI
import AiTermCore

/// Where a sheet's window opens, in the one format every such sheet uses:
/// `Opens in iTerm2 · <project>/<worktree path in it, if any> · <branch>`, or, for a review that
/// opens in a task that already has its branch, `Opens in iTerm2 · task “<title>” · <branch>`.
/// A branch not known — none named yet, or a detached checkout New Terminal asked git about before
/// the checkout monitor's first pass (after it, the monitor names one by its short sha) — is left
/// out rather than drawn empty.
struct Destination: Equatable {
    /// What stands between "Opens in iTerm2" and the branch.
    let place: String
    let branch: String

    /// A new worktree, `slug`, in the project's worktree directory: New Task and New Review.
    static func worktree(project: Project, slug: String, branch: String) -> Destination {
        Destination(place: "\(project.name)/\(Worktree.directoryName)/\(slug)", branch: branch)
    }

    /// The project folder itself: New Terminal.
    static func projectFolder(_ project: Project, branch: String) -> Destination {
        Destination(place: project.name, branch: branch)
    }

    /// A new tab in the window of the task — or review — that already has the branch.
    static func existing(_ owner: TaskItem) -> Destination {
        Destination(place: "\(owner.kind == .review ? "review" : "task") “\(owner.title)”", branch: owner.branch)
    }

    /// A broadcast's: the Operator's own window. Its tasks open wherever the Operator plans them, so no
    /// branch is named.
    static let operatorWindow = Destination(place: "the Operator’s window", branch: "")

    /// The New Task and New Review steps that end on the line: the first, which names the checkout,
    /// and the last, which creates it (`CreationSteps.showsDestination`).
    static func isShown(onStep step: Int, of steps: CreationSteps) -> Bool { steps.showsDestination(onStep: step) }

    var text: String {
        (["Opens in iTerm2", place] + (branch.isEmpty ? [] : [branch])).joined(separator: " · ")
    }
}

/// The line that ends the content of every sheet that opens a window — New Task and New Review on
/// steps 1 and 3, New Broadcast on steps 1 and 4, and New Terminal — saying where it opens. One `HelpText`, wrapping onto a second
/// line for a long worktree path and its branch; past that it is cut in the middle, so the branch
/// at its end survives, and the tooltip has the whole line.
struct DestinationLine: View {
    let destination: Destination
    init(_ destination: Destination) { self.destination = destination }

    var body: some View {
        HelpText(destination.text).lineLimit(2).truncationMode(.middle).help(destination.text)
    }
}
