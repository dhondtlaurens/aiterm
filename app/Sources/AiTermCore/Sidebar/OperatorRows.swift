import Foundation

/// The operator's mark in a task's avatar group: first, while the operator drives the task, and
/// wearing the breathing accent ring while it acts on it — a message on its way, a reply being read
/// (spec §10.4). Nil when the operator has let go: the task is done, stopped or taken over.
public enum OperatorPresence: Equatable, Sendable { case driving, acting }

/// The line under a driven task's badges: where it is in its workflow and what it waits on —
/// `queued · builds on PLUTO-231`, `waiting on you · Codex asks to run npm install`, `done · 4f2a91c`.
/// `warns` draws it amber, off the accent, as `RowCaption(warns:)` does.
public struct OperatedCaption: Equatable, Sendable {
    public var text: String
    public var warns: Bool
    public init(_ text: String, warns: Bool = false) { self.text = text; self.warns = warns }
}

public extension SidebarModel {
    /// The ends a task reaches by being done: accepted, no change needed, or published (M3).
    static func isFinished(_ state: OperatedState) -> Bool {
        state == .accepted || state == .noChange || state == .published
    }

    /// An agent as a caption names it: its vendor's short name, not its CLI's display name.
    static func agentName(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .pi: "PI"
        }
    }

    /// How a caption names the task another depends on: its ticket's key, or its title.
    static func dependencyLabel(_ id: UUID, tasks: [UUID: TaskItem]) -> String {
        guard let task = tasks[id] else { return "another task" }
        return task.jira?.key ?? task.title
    }

    /// Whether the operator's mark leads `task`'s avatars: while its operation runs and the task is
    /// neither done, stopped nor taken over — and breathing while the operator acts on it.
    static func operatorPresence(task: TaskItem, run: OperatorRun?, acting: Bool) -> OperatorPresence? {
        guard let operated = task.operated, let run, run.state != .stopped, !operated.takenOver,
              !isFinished(operated.state), operated.state != .stopped else { return nil }
        return acting ? .acting : .driving
    }

    /// The workflow line under a driven task's badges; nil for a task you made yourself. `tasks` names
    /// the tasks it depends on; `run`'s open questions say what one waiting on you is asked.
    static func operatedCaption(task: TaskItem, run: OperatorRun?, tasks: [UUID: TaskItem], acting: Bool) -> OperatedCaption? {
        guard let operated = task.operated else { return nil }
        if operated.takenOver { return OperatedCaption("taken over") }
        let agent = agentName(task.agent)
        if operated.flags.contains(.waitingOnYou), !isFinished(operated.state), operated.state != .stopped {
            let asked = run?.questions.first { $0.task == task.id && $0.resolution == nil }?.text
            return OperatedCaption("waiting on you · " + (asked ?? operated.blockedReason ?? "\(agent) needs you"), warns: true)
        }
        let sha = String((operated.acceptance?.resultSHA ?? "").prefix(7))
        switch operated.state {
        case .planned:
            return OperatedCaption("planned")
        case .queued:
            if let parent = operated.stackedOn ?? operated.dependsOn.first(where: { $0.kind == .code })?.task {
                return OperatedCaption("queued · builds on " + dependencyLabel(parent, tasks: tasks))
            }
            if let first = operated.dependsOn.first {
                return OperatedCaption("queued · after " + dependencyLabel(first.task, tasks: tasks))
            }
            return OperatedCaption("queued")
        case .working:
            if operated.flags.contains(.possiblyStalled) { return OperatedCaption("working · possibly stalled", warns: true) }
            return OperatedCaption(acting ? "working · the operator is answering \(agent)" : "working")
        case .blocked:
            return OperatedCaption("blocked · " + (operated.blockedReason ?? "waiting on you"), warns: true)
        case .failed:
            return OperatedCaption("failed" + (operated.blockedReason.map { " · " + $0 } ?? ""), warns: true)
        case .accepted:
            return OperatedCaption("done · " + sha)
        case .noChange:
            return OperatedCaption("done · no change")
        case .published:
            switch operated.end {
            case .merge: return OperatedCaption("merged · " + sha)
            case .draftMR: return OperatedCaption("draft MR · " + sha)
            case .commit: return OperatedCaption("done · " + sha)
            }
        case .stopped:
            return OperatedCaption("stopped")
        }
    }
}
