import Foundation
import AiTermUI
import AiTermCore

/// A project row's linked Jira project count and menu, testable without rendering the sidebar.
struct ProjectJiraBadge: Equatable {
    struct MenuItem: Equatable {
        let title: String
        let url: URL
    }

    /// The total count, unless the Interface tab has turned the detail off.
    let label: String?
    let help: String
    let accessibilityLabel: String
    /// Every linked project, in the order they were linked.
    let items: [MenuItem]

    /// The project's badge, or none when it links no Jira project.
    static func badge(for project: Project, showsCount: Bool = true) -> ProjectJiraBadge? {
        guard !project.jiraProjects.isEmpty else { return nil }
        return ProjectJiraBadge(jira: project.jiraProjects, showsCount: showsCount)
    }

    private init(jira: [JiraProjectRef], showsCount: Bool) {
        label = showsCount ? "\(jira.count)" : nil
        items = jira.map { .init(title: "\($0.key) · \($0.name)", url: $0.browseURL) }
        help = (["Jira"] + jira.map { "\($0.key) \($0.name)" }).joined(separator: " · ")
        accessibilityLabel = "\(jira.count) Jira \(jira.count == 1 ? "project" : "projects"): \(jira.map(\.key).sentenceList)"
    }
}

/// A task row's spoken label, hint and help, including what choosing its window does.
struct TaskRowAccessibility: Equatable {
    var label: String
    var hint: String
    var help: String

    /// From the row's title, saved branch, kind and window, and what the view observes of it.
    init(row: TaskRow, missing: Bool, removing: Bool = false) {
        let branch = row.savedBranch
        label = branch.isEmpty ? row.title : "\(row.title), \(branch)"
        let kindName = row.kindName
        let words: (hint: String, help: String) =
            removing ? ("", "")
            : missing ? ("Restore the worktree or use Remove \(kindName).", "Worktree missing. Restore it or use Remove \(kindName).")
            : !row.windowOpen ? ("Press Return to open its window.", "")
            : ("Press Return to focus the window.", "")
        hint = words.hint
        help = words.help
    }
}

/// The missing checkout below a task’s branch; removal progress takes precedence.
struct TaskRowCaption: Equatable {
    enum Note: Equatable {
        /// What the task is missing, its worktree, in the surface's secondary ink.
        case plain(String)
        /// Why a removal stopped, in `Palette.amber` — until the row is selected.
        case warning(String)

        var text: String {
            switch self {
            case .plain(let text), .warning(let text): text
            }
        }

        var warns: Bool {
            if case .warning = self { true } else { false }
        }
    }

    /// In place of the badge line, while the row is being removed.
    var progress: String?
    var note: Note?

    init(progress: String?, note: Note?) {
        self.progress = progress
        self.note = note
    }

    /// `removal` is the row's own: whatever the banner above the list is saying meanwhile.
    init(removal: TaskRemoval?, missing: Bool) {
        switch removal {
        case .removing: self.init(progress: "Removing…", note: nil)
        case .closing: self.init(progress: "Closing…", note: nil)
        case .archiving: self.init(progress: "Archiving…", note: nil)
        case .stopped(let note): self.init(progress: nil, note: .warning(note))
        case nil:
            if missing { self.init(progress: nil, note: .plain("Worktree missing")) }
            else { self.init(progress: nil, note: nil) }
        }
    }
}

/// The badges a task row wears, after the Interface tab's switches. A badge whose detail is off
/// keeps its mark and its link; the text it no longer prints leads its tooltip instead. A merge
/// request with a review thread that can be resolved also wears its count — `2/5` behind a bubble,
/// all resolved included — whether or not its number is switched off; one with none, or whose
/// threads have not been read, wears none.
struct TaskRowBadges: Equatable {
    struct Link: Equatable {
        var label: String?
        var help: String
        var url: String?
        var host: CodeHost? = nil
        /// The merge request's resolved review threads of all of them, behind a bubble.
        var threads: Badge.Suffix? = nil
        /// What VoiceOver reads when the badge says more than its label: the count, in words.
        var accessibilityLabel: String? = nil
        /// Finished: a Jira ticket in a Done lane, a merge request merged. The mark wears the corner check.
        var checked = false

        /// Marks it finished, `word` ("done", "merged") after the rest in the tooltip and for VoiceOver.
        mutating func finish(_ word: String) {
            checked = true
            accessibilityLabel = "\(accessibilityLabel ?? label ?? help), \(word)"
            help += " · \(word)"
        }
    }

    /// The SF Symbol a merge request's thread count stands behind.
    static let threadsSymbol = "bubble.left"

    /// A ticket's `host` is `.gitLab` for a GitLab issue, nil for a Jira ticket.
    var ticket: Link?
    var mergeRequest: Link?

    /// A GitLab issue beside a GitLab merge request: they share one mark (`gitLabPair`).
    var sharesGitLabMark: Bool { ticket?.host == .gitLab && (mergeRequest?.host ?? .gitLab) == .gitLab && mergeRequest != nil }
    /// The VS Code badge's `+12 −3`; `nil` draws the plain mark.
    var diff: Badge.Diff?
    /// Always names the counts when there are any, whether or not the badge prints them.
    var editorHelp: String
    /// The line's marks: in the ink of their words, or the vendor's colours once Settings asks.
    var markInk: Badge.MarkInk

    /// `threads` is the row's merge request's, as last read, with whether it merged; `nil` while there
    /// is no answer. `ticketDone` is whether its Jira ticket was last read in a Done lane; a GitLab
    /// issue is never asked.
    init(row: TaskRow, details: BadgeDetails, threads: ReviewThreads? = nil, ticketDone: Bool = false) {
        let ticketHost: CodeHost? = row.ticketIsGitLabIssue ? .gitLab : nil
        ticket = row.jiraKey.map { key in
            var link = details.jiraTicket
                ? Link(label: key, help: row.jiraUrl ?? key, url: row.jiraUrl, host: ticketHost)
                : Link(label: nil, help: row.jiraUrl.map { "\(key) · \($0)" } ?? key, url: row.jiraUrl, host: ticketHost)
            if ticketDone && ticketHost == nil { link.finish("done") }
            return link
        }
        mergeRequest = row.mr.map { mr in
            var link = details.mergeRequest
                ? Link(label: mr.reference, help: mr.title, url: mr.url, host: mr.host)
                : Link(label: nil, help: "\(mr.reference) · \(mr.title)", url: mr.url, host: mr.host)
            // Nothing until there is a thread to count; then it stays, all resolved included.
            if let threads, threads.total > 0 {
                let words = Self.words(threads)
                link.accessibilityLabel = "\(link.label ?? link.help), \(words)"
                link.help += " · \(words)"
                link.threads = Badge.Suffix(icon: .symbol(Self.threadsSymbol), text: "\(threads.resolved)/\(threads.total)")
            }
            if threads?.merged == true { link.finish("merged") }
            return link
        }
        diff = details.diff ? row.diff.map { Badge.Diff(added: $0.stat.added, removed: $0.stat.removed) } : nil
        editorHelp = row.diff?.help ?? "Open in VS Code"
        markInk = details.markInk
    }

    /// How a fit draws the VS Code badge: with its `+12 −3`, as the plain mark, or not at all.
    enum Editor: Hashable { case diff, plain, none }

    /// The badges one width of the row keeps.
    struct Fit: Hashable {
        var ticket: Bool, mergeRequest: Bool, editor: Editor
        var wearsNone: Bool { !ticket && !mergeRequest && editor == .none }
    }

    /// The badge line at every width, fullest first, each fit giving up one more thing than the last:
    /// the VS Code counts fold to the plain mark, then the editor, the merge request and the ticket drop
    /// in turn, from the end of the line, so what is left reads in the same order. Only what the row
    /// wears is given up, and the last fit wears nothing. `editor` is whether the row has a VS Code badge.
    func fits(editor: Bool) -> [Fit] {
        var fit = Fit(ticket: ticket != nil, mergeRequest: mergeRequest != nil,
                      editor: !editor ? .none : diff == nil ? .plain : .diff)
        var fits = [fit]
        func giveUp(_ change: (inout Fit) -> Void) {
            change(&fit)
            if fit != fits.last { fits.append(fit) }
        }
        giveUp { if $0.editor == .diff { $0.editor = .plain } }
        giveUp { $0.editor = .none }
        giveUp { $0.mergeRequest = false }
        giveUp { $0.ticket = false }
        return fits
    }

    /// The count as the tooltip and VoiceOver say it: "2 of 5 threads resolved", "1 of 1 thread resolved".
    static func words(_ threads: ReviewThreads) -> String {
        "\(threads.resolved) of \(threads.total) \(threads.total == 1 ? "thread" : "threads") resolved"
    }
}
