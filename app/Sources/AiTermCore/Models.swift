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

/// What a tab runs: an agent — one case for each `AgentKind`, of the same name, so each is the
/// other's by its raw value — or a plain shell.
///
/// A skewed daemon (an app build adopting a worktree's daemon whose build is a different vintage)
/// can send a raw value this app has never heard of. Decoding it to `.shell` keeps that one session
/// from failing the whole `DaemonSnapshot`, instead of turning it into a reconnect loop.
public enum SessionAgent: String, Codable, Equatable, CaseIterable, Sendable {
    case claude, codex, grok, pi, shell
    public init(from decoder: Decoder) throws {
        self = SessionAgent(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .shell
    }
}
/// See `SessionAgent`'s decoding note: an unrecognized raw value decodes to `.idle` rather than
/// failing the session, and with it the snapshot, it came in.
public enum SessionState: String, Codable, Equatable, CaseIterable, Sendable {
    case idle, working, needsInput, done
    public init(from decoder: Decoder) throws {
        self = SessionState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .idle
    }
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
    /// The keys as a reader says them — "SHOP", "SHOP and PAY", "SHOP, PAY and WEB" — for the copy that
    /// names what a search covers.
    public var keyList: String {
        let keys = map(\.key)
        guard let last = keys.last else { return "" }
        return keys.count == 1 ? last : keys.dropLast().joined(separator: ", ") + " and " + last
    }

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

/// Any JSON value, kept as read so a row this build does not understand can be written back as it
/// came. Integers stay integers: a number routed through `Double` would not survive a resave.
indirect enum StoredJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([StoredJSON]), object([String: StoredJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([StoredJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: StoredJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// A sidebar row of a kind only a newer build knows, held as it was read. It is not drawn and no
/// action reaches it, but it stays in `AppState.items` where it was, so a save writes it back.
public struct UnknownSidebarItem: Equatable, Sendable {
    /// Per load: the row has no id this build can read, and nothing looks it up.
    public let id = UUID()
    let raw: StoredJSON
    public static func == (a: Self, b: Self) -> Bool { a.raw == b.raw }
}

/// One row of the sidebar's top level. `AppState.items` is the order the sidebar is drawn in.
///
/// `.unknown` is a kind a newer build added — or a row with no `kind` this build can read, missing
/// or not a string. Like `Provider`, it lets an older build open the workspace instead of refusing
/// it, but a row cannot be defaulted into something else, so it is kept whole, left undrawn, and
/// written back unchanged.
public enum SidebarItem: Codable, Identifiable, Equatable, Sendable {
    case project(Project)
    case divider(SidebarDivider)
    case unknown(UnknownSidebarItem)

    public var id: UUID {
        switch self {
        case .project(let p): return p.id
        case .divider(let d): return d.id
        case .unknown(let u): return u.id
        }
    }
    /// Whether the sidebar draws it, and so whether a move can land beside it.
    public var isDrawn: Bool { if case .unknown = self { return false } else { return true } }
    public var project: Project? { if case .project(let p) = self { return p } else { return nil } }
    public var divider: SidebarDivider? { if case .divider(let d) = self { return d } else { return nil } }

    // Written by hand rather than synthesised: the synthesised form nests the payload under `_0`,
    // and `state.json` is a file a person opens.
    private enum CodingKeys: String, CodingKey { case kind, project, divider }
    private enum Kind: String, Codable { case project, divider }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A kind that is missing, not a string, or one this build does not know is kept as it came.
        let kind = (try? c.decode(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:))
        switch kind {
        case .project: self = .project(try c.decode(Project.self, forKey: .project))
        case .divider: self = .divider(try c.decode(SidebarDivider.self, forKey: .divider))
        case nil: self = .unknown(UnknownSidebarItem(raw: try decoder.singleValueContainer().decode(StoredJSON.self)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .project(let p): try c.encode(Kind.project, forKey: .kind); try c.encode(p, forKey: .project)
        case .divider(let d): try c.encode(Kind.divider, forKey: .kind); try c.encode(d, forKey: .divider)
        case .unknown(let u): try u.raw.encode(to: encoder)
        }
    }
}

public struct JiraRef: Codable, Equatable, Sendable {
    public var key: String, summary: String, url: String
    public init(key: String, summary: String, url: String) { self.key = key; self.summary = summary; self.url = url }
}

/// Which of the two branch-shaped flows made this item; only `== .review` is ever tested. A task
/// saved without one — every task is, as was everything saved before reviews existed — reads as
/// `.task`. A raw value this build does not know decodes as `.task` too, like `Provider`;
/// `TaskItem` keeps what the file had for the resave.
/// So a row of a kind only a newer build knows is removed here as a task is: its Remove offers
/// "Also delete branch" — unticked, the person's to tick — where a review's never does.
public enum TaskKind: String, Codable, Equatable, Sendable {
    case task, review
    public init(from decoder: Decoder) throws {
        self = TaskKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .task
    }

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
}

public struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID, projectId: UUID, title: String, branch: String, worktreePath: String, baseBranch: String
    public var jira: JiraRef?, mr: MergeRequestRef?
    /// Assigning one replaces what the file had: the new value is what is saved from then on.
    public var kind: TaskKind { didSet { savedKind = kind.rawValue } }
    /// Assigning one drops `unrecognizedAgent`, as for `kind`.
    public var agent: AgentKind { didSet { unrecognizedAgent = nil } }
    public var model: String, reasoning: String?, firstPrompt: String?, appendTicket: Bool
    public var createdAt: Date, windowId: String?
    /// The agent conversations its window's tabs last showed, in tab order (`AppState.rememberingConversations`):
    /// what reopening the window resumes. Empty until an agent names one, and for a workspace saved before.
    public var conversations: [TaskConversation]
    /// The raw `agent` a newer build saved, when this build has no case for it. The task reads as a
    /// `.claude` task meanwhile, and a save writes the raw value back, so a downgrade and a later
    /// upgrade lose nothing. Nothing launches from a saved `agent`: a task's tabs are started by
    /// the daemon from the draft, at creation.
    public private(set) var unrecognizedAgent: String?
    /// `kind` as the file has it, written back as it was: none for a task saved without one, and a
    /// raw value a newer build saved, which this build reads as `.task`.
    private var savedKind: String?
    /// A `.task` is made with no `kind` to save, as every task has been: only a review is stamped.
    public init(id: UUID, projectId: UUID, title: String, branch: String, worktreePath: String, baseBranch: String, jira: JiraRef?, kind: TaskKind = .task, mr: MergeRequestRef? = nil, agent: AgentKind, model: String, reasoning: String?, firstPrompt: String?, appendTicket: Bool, createdAt: Date, windowId: String?, conversations: [TaskConversation] = []) {
        self.id = id; self.projectId = projectId; self.title = title; self.branch = branch; self.worktreePath = worktreePath; self.baseBranch = baseBranch
        self.jira = jira; self.kind = kind; self.mr = mr; self.agent = agent; self.model = model; self.reasoning = reasoning; self.firstPrompt = firstPrompt; self.appendTicket = appendTicket
        self.createdAt = createdAt; self.windowId = windowId; self.conversations = conversations
        savedKind = kind == .task ? nil : kind.rawValue
    }

    /// "Task" or "Review": what the row's menu, its alerts and its banners call it.
    public var kindName: String { kind.displayName }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, branch, worktreePath, baseBranch, jira, kind, mr, agent, model
        case reasoning, firstPrompt, appendTicket, createdAt, windowId, conversations
    }

    /// Written by hand so a `kind` or `agent` this build has no case for is kept instead of failing
    /// the whole workspace load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        title = try c.decode(String.self, forKey: .title)
        branch = try c.decode(String.self, forKey: .branch)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        baseBranch = try c.decode(String.self, forKey: .baseBranch)
        jira = try c.decodeIfPresent(JiraRef.self, forKey: .jira)
        savedKind = try c.decodeIfPresent(String.self, forKey: .kind)
        kind = savedKind.flatMap(TaskKind.init(rawValue:)) ?? .task
        mr = try c.decodeIfPresent(MergeRequestRef.self, forKey: .mr)
        let rawAgent = try c.decode(String.self, forKey: .agent)
        agent = AgentKind(rawValue: rawAgent) ?? .claude
        unrecognizedAgent = AgentKind(rawValue: rawAgent) == nil ? rawAgent : nil
        model = try c.decode(String.self, forKey: .model)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        firstPrompt = try c.decodeIfPresent(String.self, forKey: .firstPrompt)
        appendTicket = try c.decode(Bool.self, forKey: .appendTicket)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        windowId = try c.decodeIfPresent(String.self, forKey: .windowId)
        // Only what a reopen resumes: an entry for an agent this build does not know is dropped, and a
        // list it cannot read at all is none, rather than failing the whole workspace load.
        conversations = (try? c.decodeIfPresent([SavedConversation].self, forKey: .conversations))?
            .compactMap(\.conversation) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(title, forKey: .title)
        try c.encode(branch, forKey: .branch)
        try c.encode(worktreePath, forKey: .worktreePath)
        try c.encode(baseBranch, forKey: .baseBranch)
        try c.encodeIfPresent(jira, forKey: .jira)
        try c.encodeIfPresent(savedKind, forKey: .kind)
        try c.encodeIfPresent(mr, forKey: .mr)
        try c.encode(unrecognizedAgent ?? agent.rawValue, forKey: .agent)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
        try c.encodeIfPresent(firstPrompt, forKey: .firstPrompt)
        try c.encode(appendTicket, forKey: .appendTicket)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(windowId, forKey: .windowId)
        // Left out while empty, so a workspace with none is written as it always was.
        if !conversations.isEmpty { try c.encode(conversations, forKey: .conversations) }
    }

    /// A conversation as the file has it, its agent's raw value read whether or not this build knows it.
    private struct SavedConversation: Decodable {
        let agent: String, id: String
        var conversation: TaskConversation? {
            id.isEmpty ? nil : AgentKind(rawValue: agent).map { TaskConversation(agent: $0, id: id) }
        }
    }
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

    /// Whether `move` would do anything: the first drawn item has no "up", the last no "down".
    public func canMove(id: UUID, _ step: MoveStep) -> Bool { neighbour(of: id, step) != nil }

    /// Moves an item past its drawn neighbour in the combined list, so a project directly below a
    /// divider moves above it on one press without reordering the projects around it. A row an
    /// older build cannot draw is stepped over, and stays where it was relative to the rest.
    @discardableResult
    public mutating func move(id: UUID, _ step: MoveStep) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }), let n = neighbour(of: id, step) else { return false }
        items.insert(items.remove(at: i), at: n)
        return true
    }

    private func neighbour(of id: UUID, _ step: MoveStep) -> Int? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let direction = step == .up ? -1 : 1
        var n = i + direction
        while items.indices.contains(n) {
            if items[n].isDrawn { return n }
            n += direction
        }
        return nil
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

    /// A window iTerm2 no longer has: a task keeps its row, windowless — its row says "Window closed",
    /// and choosing it reopens the window — and a terminal's row goes. True if a row had it.
    @discardableResult
    public mutating func closeWindow(_ windowId: String) -> Bool {
        var changed = false
        for index in tasks.indices where tasks[index].windowId == windowId {
            tasks[index].windowId = nil
            changed = true
        }
        let terminalCount = terminals.count
        terminals.removeAll { $0.windowId == windowId }
        return changed || terminals.count != terminalCount
    }
}
