import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// What hosts a project's remote. A raw value this build does not know — one a newer build saved —
/// decodes as `.git`: the project keeps working as a plain repository instead of failing the load.
public enum Provider: String, Codable, Equatable, Sendable {
    case gitlab, github, git, none
    public init(from decoder: Decoder) throws {
        self = Provider(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .git
    }
}
/// One step of an item along the sidebar, from its context menu.
public enum MoveStep: Sendable { case up, down }
public enum AgentKind: String, Codable, Equatable, Hashable, CaseIterable, Sendable { case claude, codex, grok, pi }

/// A skewed daemon (an app build adopting a worktree's daemon whose build is a different vintage)
/// can send a raw value this app has never heard of. Decoding it to `.shell` keeps that one session
/// from failing the whole `DaemonSnapshot`, instead of turning it into a reconnect loop.
public enum SessionAgent: String, Codable, Equatable, Sendable {
    case claude, codex, grok, pi, shell
    public init(from decoder: Decoder) throws {
        self = SessionAgent(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .shell
    }
}
/// See `SessionAgent`'s decoding note: an unrecognized raw value decodes to `.idle` rather than
/// failing the session, and with it the snapshot, it came in.
public enum SessionState: String, Codable, Equatable, Sendable {
    case idle, working, needsInput, done
    public init(from decoder: Decoder) throws {
        self = SessionState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .idle
    }
}

public extension SessionAgent {
    /// The agent behind a tab, or `nil` for a plain shell.
    var agentKind: AgentKind? {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .grok: return .grok
        case .pi: return .pi
        case .shell: return nil
        }
    }
}

public extension AgentKind {
    /// The mark a tab running this agent draws.
    var session: SessionAgent {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .grok: return .grok
        case .pi: return .pi
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok Build"
        case .pi: return "PI"
        }
    }
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
    /// The keys as a reader says them — "SHOP", "SHOP and PAY", "SHOP, PAY and WEB" — for the copy that
    /// names what a search covers.
    public var keyList: String {
        let keys = map(\.key)
        guard let last = keys.last else { return "" }
        return keys.count == 1 ? last : keys.dropLast().joined(separator: ", ") + " and " + last
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

    // `jiraProject` is where a workspace saved before a project could link several Jira projects
    // keeps its one. It is read only when `jiraProjects` is absent, and still written, as the first
    // link: a build of that vintage saving this file would otherwise drop the project's links.
    private enum CodingKeys: String, CodingKey {
        case id, name, path, provider, remoteUrl, addedAt, collapsed, jiraProjects, jiraProject
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        provider = try c.decode(Provider.self, forKey: .provider)
        remoteUrl = try c.decodeIfPresent(String.self, forKey: .remoteUrl)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        collapsed = try c.decode(Bool.self, forKey: .collapsed)
        jiraProjects = try c.decodeIfPresent([JiraProjectRef].self, forKey: .jiraProjects)
            ?? c.decodeIfPresent(JiraProjectRef.self, forKey: .jiraProject).map { [$0] }
            ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(remoteUrl, forKey: .remoteUrl)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(collapsed, forKey: .collapsed)
        try c.encode(jiraProjects, forKey: .jiraProjects)
        try c.encodeIfPresent(jiraProjects.first, forKey: .jiraProject)
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

public struct JiraRef: Codable, Equatable, Sendable {
    public var key: String, summary: String, url: String
    public init(key: String, summary: String, url: String) { self.key = key; self.summary = summary; self.url = url }
}

/// Which of the two branch-shaped flows made this item. `nil` is everything saved before reviews
/// existed and means the same as `.task`; only `== .review` is ever tested.
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

public struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID, projectId: UUID, title: String, branch: String, worktreePath: String, baseBranch: String
    public var jira: JiraRef?, kind: TaskKind?, mr: MergeRequestRef?
    public var agent: AgentKind, model: String, reasoning: String?, firstPrompt: String?, appendTicket: Bool
    public var createdAt: Date, windowId: String?
    public init(id: UUID, projectId: UUID, title: String, branch: String, worktreePath: String, baseBranch: String, jira: JiraRef?, kind: TaskKind? = nil, mr: MergeRequestRef? = nil, agent: AgentKind, model: String, reasoning: String?, firstPrompt: String?, appendTicket: Bool, createdAt: Date, windowId: String?) {
        self.id = id; self.projectId = projectId; self.title = title; self.branch = branch; self.worktreePath = worktreePath; self.baseBranch = baseBranch
        self.jira = jira; self.kind = kind; self.mr = mr; self.agent = agent; self.model = model; self.reasoning = reasoning; self.firstPrompt = firstPrompt; self.appendTicket = appendTicket
        self.createdAt = createdAt; self.windowId = windowId
    }

    /// "Task" or "Review": what the row's menu, its alerts and its banners call it.
    public var kindName: String { (kind ?? .task).displayName }
}

public struct TerminalItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID, projectId: UUID, name: String, windowId: String?, createdAt: Date
    public init(id: UUID, projectId: UUID, name: String, windowId: String?, createdAt: Date) { self.id = id; self.projectId = projectId; self.name = name; self.windowId = windowId; self.createdAt = createdAt }

    public static let defaultName = "Terminal"

    /// Preserve compatibility with workspaces saved before terminals had names.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? Self.defaultName
        windowId = try c.decodeIfPresent(String.self, forKey: .windowId)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

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
    public var sidebarFrame: CGRect? = nil
    public var lastAgentByProject: [UUID: AgentKind] = [:]
    public var lastModelByAgent: [AgentKind: String] = [:]
    public static let empty = AppState()
    public init() {}

    /// The projects in `items`, in order.
    ///
    /// The setter refills the project slots in place, so a reorder or an edit leaves every divider
    /// where the user put it and surplus projects land at the end. It exists so the sidebar's
    /// readers, the snapshot fixtures and the tests keep working unchanged; the app's own add,
    /// remove, edit and move paths go through the mutators below, which are exact.
    public var projects: [Project] {
        get { items.compactMap(\.project) }
        set {
            var incoming = newValue[...]
            var rebuilt: [SidebarItem] = []
            for item in items {
                switch item {
                case .divider: rebuilt.append(item)
                case .project: if let next = incoming.popFirst() { rebuilt.append(.project(next)) }
                }
            }
            items = rebuilt + incoming.map(SidebarItem.project)
        }
    }

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

    /// Swaps an item with its neighbour in the combined list, so a project directly below a divider
    /// moves above it on one press without reordering the projects around it.
    @discardableResult
    public mutating func move(id: UUID, _ step: MoveStep) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }), let n = neighbour(of: id, step) else { return false }
        items.swapAt(i, n)
        return true
    }

    private func neighbour(of id: UUID, _ step: MoveStep) -> Int? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let n = step == .up ? i - 1 : i + 1
        return items.indices.contains(n) ? n : nil
    }

    private enum CodingKeys: String, CodingKey {
        case items, projects, tasks, terminals, sidebarFrame, lastAgentByProject, lastModelByAgent
    }

    /// Workspaces written before dividers existed carry a flat `projects` array and no `items`;
    /// their projects become the list, in order. Same mechanism as `TerminalItem.init(from:)`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let stored = try c.decodeIfPresent([SidebarItem].self, forKey: .items) { items = stored }
        else { items = (try c.decodeIfPresent([Project].self, forKey: .projects) ?? []).map(SidebarItem.project) }
        tasks = try c.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
        terminals = try c.decodeIfPresent([TerminalItem].self, forKey: .terminals) ?? []
        sidebarFrame = try c.decodeIfPresent(CGRect.self, forKey: .sidebarFrame)
        // Only preferences, so an agent from a newer build is dropped rather than failing the load.
        lastAgentByProject = (try c.decodeIfPresent([UUID: SavedAgent].self, forKey: .lastAgentByProject) ?? [:]).compactMapValues(\.agent)
        lastModelByAgent = Dictionary(uniqueKeysWithValues: (try c.decodeIfPresent([SavedAgent: String].self, forKey: .lastModelByAgent) ?? [:])
            .compactMap { saved, model in saved.agent.map { ($0, model) } })
    }

    /// An agent as it was saved, known to this build or not. Neither a `String` nor
    /// `CodingKeyRepresentable`, like `AgentKind`, so a dictionary keyed by it is stored the same way.
    private struct SavedAgent: Decodable, Hashable {
        let raw: String
        var agent: AgentKind? { AgentKind(rawValue: raw) }
        init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
        try c.encode(tasks, forKey: .tasks)
        try c.encode(terminals, forKey: .terminals)
        try c.encodeIfPresent(sidebarFrame, forKey: .sidebarFrame)
        try c.encode(lastAgentByProject, forKey: .lastAgentByProject)
        try c.encode(lastModelByAgent, forKey: .lastModelByAgent)
    }

    /// The row in `projectId` whose worktree git reports `branch` checked out in — where a review
    /// of that branch opens, since git lets a branch be checked out in one worktree only. A task or
    /// an earlier review: whichever row that worktree belongs to.
    ///
    /// Decided by `worktrees` (`Worktrees.listed`), never by `TaskItem.branch`: that is the branch a
    /// row is bound to, and its worktree can drift onto another one. Routing by the saved name would
    /// open a review of one branch in a checkout of another. `nil` when no row's worktree has the
    /// branch — including when the project's own checkout or an untracked worktree has it, which
    /// `Worktrees.checkout` then refuses by path.
    public func task(checkingOut branch: String, in projectId: UUID, worktrees: [Worktree]) -> TaskItem? {
        guard !branch.isEmpty, let holder = worktrees.first(where: { $0.branch == branch }) else { return nil }
        let path = Worktrees.resolved(holder.path)
        return tasks.first { $0.projectId == projectId && Worktrees.resolved($0.worktreePath) == path }
    }

    @discardableResult
    public mutating func closeWindow(_ windowId: String) -> Bool {
        let taskCount = tasks.count
        tasks.removeAll { $0.windowId == windowId }
        let terminalCount = terminals.count
        terminals.removeAll { $0.windowId == windowId }
        return tasks.count != taskCount || terminals.count != terminalCount
    }
}
