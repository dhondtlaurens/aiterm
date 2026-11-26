import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// What hosts a project's remote.
public enum Provider: String, Codable, Equatable, Sendable {
    case gitlab, github, git, none
}
/// One step of an item along the sidebar, from its context menu.
public enum MoveStep: Sendable { case up, down }
public enum AgentKind: String, Codable, Equatable, Hashable, CaseIterable, Sendable { case claude, codex, pi, agy }

/// What a tab runs: an agent — one case for each `AgentKind`, of the same name, so each is the
/// other's by its raw value — or a plain shell.
///
/// An unrecognized raw value decodes to `.shell` so one session cannot make the whole
/// `DaemonSnapshot` unreadable.
public enum SessionAgent: String, Codable, LenientRawDecodable, Equatable, CaseIterable, Sendable {
    case claude, codex, pi, agy, shell
    static var unrecognized: Self { .shell }
}
/// See `SessionAgent`'s decoding note: an unrecognized raw value decodes to `.idle` rather than
/// failing the session, and with it the snapshot, it came in.
public enum SessionState: String, Codable, LenientRawDecodable, Equatable, CaseIterable, Sendable {
    case idle, working, needsInput, done
    static var unrecognized: Self { .idle }

    /// Its turn ended: idle at its prompt, or done.
    public var turnEnded: Bool { self == .idle || self == .done }
}

public extension SessionAgent {
    /// The agent behind a tab, or `nil` for a plain shell: each agent's tab has its name.
    var agentKind: AgentKind? { AgentKind(rawValue: rawValue) }
}

public extension AgentKind {
    /// The mark a tab running this agent draws: the session agent of its name. Every agent has one
    /// (`ModelsTests`); `.shell` is only what a missing one would read as.
    var session: SessionAgent { SessionAgent(rawValue: rawValue) ?? .shell }
}

/// A Jira project whose tickets belong to an AiTerm project.
public struct JiraProjectRef: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String, key: String, name: String
    public var siteURL: URL
    public init(id: String, key: String, name: String, siteURL: URL) {
        self.id = id; self.key = key; self.name = name; self.siteURL = siteURL
    }

    /// The project's own page on its site. `/browse/<KEY>` is the one path that works for every
    /// project type — Jira redirects it to whatever board or backlog the project actually has —
    /// and it is the same shape `JiraClient` already gives a ticket.
    public var browseURL: URL { siteURL.appendingPathComponent("browse/\(key)") }
}

extension Array where Element == JiraProjectRef {
    /// The list with every repeat of a project after its first dropped: what a project links.
    public var linkedOnce: [JiraProjectRef] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID, name: String, path: String, provider: Provider, remoteUrl: String?, addedAt: Date, collapsed: Bool
    /// The Jira projects whose tickets belong to this one, in the order they were linked. Empty
    /// means none: New Task then searches every project the account can see.
    public var jiraProjects: [JiraProjectRef]
    public init(id: UUID, name: String, path: String, provider: Provider, remoteUrl: String?, addedAt: Date,
                collapsed: Bool, jiraProjects: [JiraProjectRef] = []) {
        self.id = id; self.name = name; self.path = path; self.provider = provider; self.remoteUrl = remoteUrl; self.addedAt = addedAt; self.collapsed = collapsed
        self.jiraProjects = jiraProjects
    }
}

/// A named rule between projects in the sidebar. A label, not a container: nothing nests under it
/// and deleting one destroys nothing else. An empty name draws a plain rule.
public struct SidebarDivider: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID, name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

/// One row of the sidebar's top level. `AppState.items` is the order the sidebar is drawn in.
public enum SidebarItem: Codable, Identifiable, Equatable, Sendable {
    case project(Project)
    case divider(SidebarDivider)

    public var id: UUID {
        switch self {
        case .project(let p): return p.id
        case .divider(let d): return d.id
        }
    }
    public var project: Project? { if case .project(let p) = self { return p } else { return nil } }
    public var divider: SidebarDivider? { if case .divider(let d) = self { return d } else { return nil } }

    // Written by hand rather than synthesised: the synthesised form nests the payload under `_0`,
    // and `state.json` is a file a person opens.
    private enum CodingKeys: String, CodingKey { case kind, project, divider }
    private enum Kind: String, Codable { case project, divider }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .project: self = .project(try c.decode(Project.self, forKey: .project))
        case .divider: self = .divider(try c.decode(SidebarDivider.self, forKey: .divider))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .project(let p): try c.encode(Kind.project, forKey: .kind); try c.encode(p, forKey: .project)
        case .divider(let d): try c.encode(Kind.divider, forKey: .kind); try c.encode(d, forKey: .divider)
        }
    }
}

/// A task's ticket as saved: a Jira issue, or a GitLab issue (`source`).
public struct JiraRef: Codable, Equatable, Sendable {
    public var key: String, summary: String, url: String
    public var source: TicketSource
    public init(key: String, summary: String, url: String, source: TicketSource = .jira) {
        self.key = key; self.summary = summary; self.url = url; self.source = source
    }

    public init(_ ticket: JiraTicket) { self.init(key: ticket.key, summary: ticket.summary, url: ticket.url, source: ticket.source) }

    /// Whether it is a GitLab issue rather than a Jira ticket.
    public var isGitLabIssue: Bool { if case .gitLab = source { true } else { false } }
}

/// Which of the two branch-shaped flows made this item; only `== .review` is ever tested.
public enum TaskKind: String, Codable, Equatable, Sendable {
    case task, review

    /// The kind as copy names it — "Remove Review…", "Review removed." — capitalised, as a menu
    /// item has it; a sentence lowercases it.
    public var displayName: String { self == .review ? "Review" : "Task" }
}

public struct MergeRequestRef: Codable, Equatable, Sendable {
    public var iid: Int, title: String, url: String
    public init(iid: Int, title: String, url: String) { self.iid = iid; self.title = title; self.url = url }
}

public extension MergeRequestRef {
    var host: CodeHost { CodeHost(webURL: url) }
    var reference: String { host.reference(iid) }
}

/// One agent conversation a task's window showed in a tab: what reopening the window resumes, by the
/// agent's own resume arguments (`Harness.resumeArguments`).
public struct TaskConversation: Codable, Equatable, Sendable {
    public var agent: AgentKind, id: String
    public init(agent: AgentKind, id: String) { self.agent = agent; self.id = id }

    /// Whether `id` can name a conversation to resume: not empty — a resume without one opens the
    /// CLI's picker — and not starting with "-", which the CLI would read as a flag.
    public static func isResumable(_ id: String) -> Bool { !id.isEmpty && !id.hasPrefix("-") }
}

public struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID, projectId: UUID, title: String, branch: String, worktreePath: String, baseBranch: String
    public var jira: JiraRef?, mr: MergeRequestRef?
    public var kind: TaskKind
    public var agent: AgentKind
    public var model: String, reasoning: String?, firstPrompt: String?, appendTicket: Bool
    public var createdAt: Date, windowId: String?
    /// The agent conversations its window's tabs last showed, in tab order (`AppState.rememberingConversations`):
    /// what reopening the window resumes. Empty until an agent names one.
    public var conversations: [TaskConversation]
    /// What an operator adds to the task; nil for every task you made yourself.
    public var signalTask: SignalTask?
    /// That a person took this task over from a signal (`AppState.takeOver`): it is theirs, and no later
    /// match continues it.
    public var takenOver = false
    /// The signal that started or last ran this task as an ordinary one, or that the Operator handed it from on Take
    /// Over; nil for a task no signal touched.
    public var signalOrigin: SignalOrigin?
    public init(id: UUID, projectId: UUID, title: String, branch: String, worktreePath: String, baseBranch: String, jira: JiraRef?, kind: TaskKind = .task, mr: MergeRequestRef? = nil, agent: AgentKind, model: String, reasoning: String?, firstPrompt: String?, appendTicket: Bool, createdAt: Date, windowId: String?, conversations: [TaskConversation] = []) {
        self.id = id; self.projectId = projectId; self.title = title; self.branch = branch; self.worktreePath = worktreePath; self.baseBranch = baseBranch
        self.jira = jira; self.kind = kind; self.mr = mr; self.agent = agent; self.model = model; self.reasoning = reasoning; self.firstPrompt = firstPrompt; self.appendTicket = appendTicket
        self.createdAt = createdAt; self.windowId = windowId; self.conversations = conversations
    }

    /// "Task" or "Review": what the row's menu, its alerts and its banners call it.
    public var kindName: String { kind.displayName }
}

/// A task or review put away: its worktree deleted and its window closed, its branch untouched, and
/// everything it takes to come back kept — the ticket, the merge request, the agent and model, and
/// each conversation its tabs last showed. Restoring it puts `task` back in the sidebar without a
/// window; choosing it opens one, resuming those conversations.
public struct ArchivedTask: Codable, Identifiable, Equatable, Sendable {
    /// The row as it left the sidebar: windowless, on the branch its worktree was actually on.
    public var task: TaskItem
    public var archivedAt: Date
    public var id: UUID { task.id }

    public init(task: TaskItem, archivedAt: Date) {
        self.task = task
        self.archivedAt = archivedAt
    }
}

public struct TerminalItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID, projectId: UUID, name: String, windowId: String?, createdAt: Date
    public init(id: UUID, projectId: UUID, name: String, windowId: String?, createdAt: Date) { self.id = id; self.projectId = projectId; self.name = name; self.windowId = windowId; self.createdAt = createdAt }

    public static let defaultName = "Terminal"

    /// "Terminal", then the lowest free "Terminal n" — the prefill for the New Terminal sheet.
    public static func suggestedName(existing: [TerminalItem]) -> String {
        let taken = Set(existing.map(\.name))
        guard taken.contains(defaultName) else { return defaultName }
        var n = 2
        while taken.contains("\(defaultName) \(n)") { n += 1 }
        return "\(defaultName) \(n)"
    }
}

public struct AppState: Codable, Equatable, Sendable {
    /// The sidebar's top level, in the order it is drawn: the projects and the dividers between them.
    public var items: [SidebarItem] = []
    public var tasks: [TaskItem] = [], terminals: [TerminalItem] = []
    /// The tasks and reviews archived: out of the sidebar, their worktrees gone, kept to be restored.
    /// A list of its own, so nothing that reads `tasks` — the window plan, the checkout monitor, the
    /// rows, the Dock badge — ever meets one.
    public var archive: [ArchivedTask] = []
    public var sidebarFrame: CGRect? = nil
    public var lastAgentByProject: [UUID: AgentKind] = [:]
    public var lastModelByAgent: [AgentKind: String] = [:]
    /// The signals in their sheets' order, which is also their priority within their kind (`MatchDecision`): a new
    /// one is appended, and Move Up / Move Down swap neighbours of one kind. The app is their only writer.
    public var signals: [Signal] = []
    public var signalSeen: [SignalSeen] = []
    /// Per scheduled signal, the last scheduled time it fired or skipped: a time at or before it never fires again.
    /// Saved in the same flush as the task a firing starts, and never pruned with `signalSeen`.
    public var scheduleCursors: [UUID: Date] = [:]
    public var operatorSession: OperatorSession?
    /// Whether the sidebar shows the Operator's section, the projects folded under their heading. The
    /// two fold into each other, one open at a time; the projects are the default.
    public var operatorOpen = false
    /// The projects folded in the Operator's section, apart from `Project.collapsed`, which folds them under Projects.
    public var operatorFolded: Set<UUID> = []
    public static let empty = AppState()
    public init() {}

    /// The projects in `items`, in order. Read-only: a project is added, edited, moved and removed
    /// through the mutators below, which leave every divider where the person put it.
    public var projects: [Project] { items.compactMap(\.project) }

    /// Whether the sidebar has a project, without building the list to ask.
    public var hasProjects: Bool { items.contains { $0.project != nil } }

    /// The project with `id`, found in `items` directly rather than through ``projects``, which
    /// rebuilds the whole list to answer.
    public func project(id: UUID) -> Project? {
        for case .project(let project) in items where project.id == id { return project }
        return nil
    }
    public func task(id: UUID) -> TaskItem? { tasks.first { $0.id == id } }
    public func terminal(id: UUID) -> TerminalItem? { terminals.first { $0.id == id } }

    public mutating func append(project: Project) { items.append(.project(project)) }
    public mutating func append(divider: SidebarDivider) { items.append(.divider(divider)) }
    public mutating func removeItem(id: UUID) { items.removeAll { $0.id == id } }

    public mutating func updateProject(id: UUID, _ change: (inout Project) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }), case .project(var p) = items[i] else { return }
        change(&p)
        items[i] = .project(p)
    }

    public mutating func renameDivider(id: UUID, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), case .divider(var d) = items[i] else { return }
        d.name = name
        items[i] = .divider(d)
    }

    /// Whether `move` would do anything: the first item has no "up", the last no "down".
    public func canMove(id: UUID, _ step: MoveStep) -> Bool { neighbour(of: id, step) != nil }

    /// Moves an item past its neighbour in the combined list, so a project directly below a
    /// divider moves above it on one press without reordering the projects around it.
    @discardableResult
    public mutating func move(id: UUID, _ step: MoveStep) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }), let n = neighbour(of: id, step) else { return false }
        items.swapAt(i, n)
        return true
    }

    private func neighbour(of id: UUID, _ step: MoveStep) -> Int? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let n = i + (step == .up ? -1 : 1)
        return items.indices.contains(n) ? n : nil
    }

    /// Tasks and reviews move within their own project and kind group. Operator-owned rows belong
    /// under signals, so they are neither a movable project row nor a neighbour to move past.
    public func canMove(taskId: UUID, _ step: MoveStep) -> Bool { taskNeighbour(of: taskId, step) != nil }

    @discardableResult
    public mutating func move(taskId: UUID, _ step: MoveStep) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }), let n = taskNeighbour(of: taskId, step) else { return false }
        tasks.swapAt(i, n)
        return true
    }

    private func taskNeighbour(of id: UUID, _ step: MoveStep) -> Int? {
        guard let i = tasks.firstIndex(where: { $0.id == id }), !tasks[i].isUnderOperator,
              project(id: tasks[i].projectId) != nil else { return nil }
        let task = tasks[i], review = task.kind == .review
        let direction = step == .up ? -1 : 1
        var n = i + direction
        while tasks.indices.contains(n) {
            let candidate = tasks[n]
            if candidate.projectId == task.projectId, (candidate.kind == .review) == review, !candidate.isUnderOperator { return n }
            n += direction
        }
        return nil
    }

    /// Signals move one place among the signals of their own kind, stepping over those of the other kind, which keep
    /// their places. That order is their priority within their kind (`MatchDecision`).
    public func canMove(signalId: UUID, _ step: MoveStep) -> Bool { signalNeighbour(of: signalId, step) != nil }

    @discardableResult
    public mutating func move(signalId: UUID, _ step: MoveStep) -> Bool {
        guard let i = signals.firstIndex(where: { $0.id == signalId }), let n = signalNeighbour(of: signalId, step) else { return false }
        signals.swapAt(i, n)
        return true
    }

    private func signalNeighbour(of id: UUID, _ step: MoveStep) -> Int? {
        guard let i = signals.firstIndex(where: { $0.id == id }) else { return nil }
        let kind = signals[i].isProject, direction = step == .up ? -1 : 1
        var n = i + direction
        while signals.indices.contains(n) {
            if signals[n].isProject == kind { return n }
            n += direction
        }
        return nil
    }

    public mutating func removeSignal(id: UUID) { signals.removeAll { $0.id == id } }

    private enum CodingKeys: String, CodingKey {
        case items, tasks, terminals, archive, sidebarFrame, lastAgentByProject, lastModelByAgent
        case signals, signalSeen, scheduleCursors, operatorSession, operatorOpen, operatorFolded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([SidebarItem].self, forKey: .items)
        tasks = try c.decode([TaskItem].self, forKey: .tasks)
        terminals = try c.decode([TerminalItem].self, forKey: .terminals)
        archive = try c.decode([ArchivedTask].self, forKey: .archive)
        sidebarFrame = try c.decodeIfPresent(CGRect.self, forKey: .sidebarFrame)
        lastAgentByProject = try c.decode([UUID: AgentKind].self, forKey: .lastAgentByProject)
        lastModelByAgent = try c.decode([AgentKind: String].self, forKey: .lastModelByAgent)
        signals = try c.decode([Signal].self, forKey: .signals)
        signalSeen = try c.decode([SignalSeen].self, forKey: .signalSeen)
        scheduleCursors = try c.decode([UUID: Date].self, forKey: .scheduleCursors)
        operatorSession = try c.decodeIfPresent(OperatorSession.self, forKey: .operatorSession)
        operatorOpen = try c.decode(Bool.self, forKey: .operatorOpen)
        operatorFolded = Set(try c.decode([UUID].self, forKey: .operatorFolded))
    }

    /// Synthesised but for `operatorFolded`, written as a sorted list so a save of the same workspace
    /// writes the same bytes.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
        try c.encode(tasks, forKey: .tasks)
        try c.encode(terminals, forKey: .terminals)
        try c.encode(archive, forKey: .archive)
        try c.encodeIfPresent(sidebarFrame, forKey: .sidebarFrame)
        try c.encode(lastAgentByProject, forKey: .lastAgentByProject)
        try c.encode(lastModelByAgent, forKey: .lastModelByAgent)
        try c.encode(signals, forKey: .signals)
        try c.encode(signalSeen, forKey: .signalSeen)
        try c.encode(scheduleCursors, forKey: .scheduleCursors)
        try c.encodeIfPresent(operatorSession, forKey: .operatorSession)
        try c.encode(operatorOpen, forKey: .operatorOpen)
        try c.encode(operatorFolded.sorted { $0.uuidString < $1.uuidString }, forKey: .operatorFolded)
    }

    /// A window iTerm2 no longer has: its row, a task's, a terminal's or the Operator's chat, stays
    /// without a window until it is chosen or takes one by its tag. The chat's is left be while its
    /// lifecycle changes (opening, closing, revoking): the keeper writes it then. True if a row had it.
    @discardableResult
    public mutating func closeWindow(_ windowId: String) -> Bool {
        var changed = false
        for index in tasks.indices where tasks[index].windowId == windowId {
            tasks[index].windowId = nil
            changed = true
        }
        for index in terminals.indices where terminals[index].windowId == windowId {
            terminals[index].windowId = nil
            changed = true
        }
        if operatorSession?.window == windowId, operatorSession?.lifecycle.isChanging == false {
            operatorSession?.window = nil
            changed = true
        }
        return changed
    }
}
