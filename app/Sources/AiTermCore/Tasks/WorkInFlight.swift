import Foundation

/// The work under way on the workspace's projects, tasks and terminals, one entry per piece of work.
/// It is what keeps two pieces of work from running at once where they would collide — two
/// removals of one task, two pulls of one project — and what a project's removal checks, so that
/// nothing lands in a project that is gone.
///
/// Work starts with `begin`, which refuses it (nil) while something it cannot run beside holds the
/// subject, and ends with `end` and the token `begin` handed out: one piece of work's end can never
/// end another's. Owners that draw from it hear of each change to a subject through `onChange`.
///
/// A class rather than a value: the owners that do the work — launches, removals, terminals, the
/// pull — each start and end work on the same subjects, and each must see the others'.
@MainActor
public final class WorkInFlight {
    public enum Subject: Hashable, Sendable {
        case project(UUID), task(UUID), terminal(UUID)
    }

    /// One piece of work, handed out by `begin` and ended by `end`.
    public struct Token: Hashable, Sendable {
        public let subject: Subject
        fileprivate let serial: Int
    }

    private var projects: [UUID: [Int: ProjectOperation]] = [:]
    private var tasks: [UUID: (serial: Int, operation: TaskOperation)] = [:]
    private var terminals: [UUID: (serial: Int, operation: TerminalOperation)] = [:]
    private var serial = 0
    private var hooks: [@MainActor (Subject) -> Void] = []

    public init() {}

    /// Adds `hook` to what hears that work on a subject began, changed or ended, after the ones
    /// added before it.
    public func onChange(_ hook: @escaping @MainActor (Subject) -> Void) {
        hooks.append(hook)
    }

    /// Starts `operation` on project `id`, unless it runs alone there and is already running: never
    /// nil for one that does not run alone.
    public func begin(_ operation: ProjectOperation, onProject id: UUID) -> Token? {
        if operation.runsAlone, projects[id]?.values.contains(operation) == true { return nil }
        let token = next(.project(id))
        projects[id, default: [:]][token.serial] = operation
        changed(token.subject)
        return token
    }

    /// Starts `operation` on task `id`, unless something else already is.
    public func begin(_ operation: TaskOperation, onTask id: UUID) -> Token? {
        guard tasks[id] == nil else { return nil }
        let token = next(.task(id))
        tasks[id] = (token.serial, operation)
        changed(token.subject)
        return token
    }

    /// Starts `operation` on terminal `id`, unless something else already is.
    public func begin(_ operation: TerminalOperation, onTerminal id: UUID) -> Token? {
        guard terminals[id] == nil else { return nil }
        let token = next(.terminal(id))
        terminals[id] = (token.serial, operation)
        changed(token.subject)
        return token
    }

    /// What the task's work is doing now, as it moves on: a removal that lets its window go.
    public func update(_ token: Token, to operation: TaskOperation) {
        guard case .task(let id) = token.subject, tasks[id]?.serial == token.serial, tasks[id]?.operation != operation else { return }
        tasks[id]?.operation = operation
        changed(token.subject)
    }

    /// Ends the work `token` names. Ending it twice ends nothing more.
    public func end(_ token: Token) {
        switch token.subject {
        case .project(let id):
            guard projects[id]?.removeValue(forKey: token.serial) != nil else { return }
            if projects[id]?.isEmpty == true { projects[id] = nil }
        case .task(let id):
            guard tasks[id]?.serial == token.serial else { return }
            tasks[id] = nil
        case .terminal(let id):
            guard terminals[id]?.serial == token.serial else { return }
            terminals[id] = nil
        }
        changed(token.subject)
    }

    /// Whether `operation` is running on project `id`.
    public func isRunning(_ operation: ProjectOperation, onProject id: UUID) -> Bool {
        projects[id]?.values.contains(operation) == true
    }

    /// What is running on task `id`, if anything.
    public func operation(onTask id: UUID) -> TaskOperation? { tasks[id]?.operation }

    /// What is running on terminal `id`, if anything.
    public func operation(onTerminal id: UUID) -> TerminalOperation? { terminals[id]?.operation }

    private func next(_ subject: Subject) -> Token {
        serial += 1
        return Token(subject: subject, serial: serial)
    }

    private func changed(_ subject: Subject) {
        for hook in hooks { hook(subject) }
    }
}

/// Work on a project.
public enum ProjectOperation: Equatable, Sendable {
    /// A task or a review being created in it — one at a time, so two creates cannot pick the same
    /// branch or worktree.
    case creatingTask
    /// A new terminal's window opening in it.
    case openingTerminal
    /// A task's window opening in it: a created task's, a reopened one's or a review's.
    case openingTaskWindow
    /// Its default branch being pulled or rebased, one at a time.
    case changingDefaultBranch

    /// Whether a second one is refused while the first runs; any number of windows can open at once.
    public var runsAlone: Bool {
        switch self {
        case .creatingTask, .changingDefaultBranch: true
        case .openingTerminal, .openingTaskWindow: false
        }
    }
}

/// Work on a task, one at a time. It is the task's lock, what its row says while it runs, and
/// whether a snapshot may give the task back a window it has let go.
public enum TaskOperation: Equatable, Sendable {
    /// Reopen Window, opening the task a window of its own.
    case reopening
    /// A review opening as a tab in the task's window.
    case reviewing
    /// Removed by the person: its window, its worktree, maybe its branch, then its row.
    /// `windowLetGo` once the row has dropped its window to close it (`TaskRemover`): the window's
    /// tab is the removal's to settle, and a snapshot must not hand it back to the row.
    case removing(windowLetGo: Bool)
    /// Its worktree went outside AiTerm, and its window is being closed.
    case closing

    /// What the row says while this runs, in place of what the task's last removal left it saying.
    public var removal: TaskRemoval? {
        switch self {
        case .removing: .removing
        case .closing: .closing
        case .reopening, .reviewing: nil
        }
    }
}

/// Work on a terminal's window, one at a time.
public enum TerminalOperation: Equatable, Sendable {
    case reopening, closing
}
