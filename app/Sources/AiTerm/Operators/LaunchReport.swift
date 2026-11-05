import Foundation
import AiTermCore

/// What `retry_task` answers of its task's launch (`OperatorController.launchNow`): `result` — `started`, `opened`,
/// `opening`, `failed` or `queued` — and a plain `note` saying what happened, or why it didn't.
struct LaunchReport: Equatable, Sendable {
    var result: String
    var note: String

    init(result: String, note: String) {
        self.result = result
        self.note = note
    }

    /// The answer had to go before the window or tab was confirmed.
    static let opening = LaunchReport(result: "opening", note: "AiTerm is still opening its worker. If no worker starts, AiTerm blocks the task "
                                          + "and says why; run_status shows where it is.")

    private static let threeMinutes = "If no agent starts there within 3 minutes, AiTerm blocks the task and says why."

    /// How this call's start ended.
    init(_ outcome: WorkerStarter.Outcome) {
        switch outcome {
        case .inPlace:
            self.init(result: "started", note: "Its worker was idle in its tab, and was told what failed and to try again there.")
        case .opened(let tab):
            self.init(result: "opened", note: "AiTerm opened its worker in \(tab ? "a new tab of its window" : "a new window"), behind your work, "
                          + "and typed its agent command there. " + Self.threeMinutes)
        case .adopted:
            self.init(result: "opened", note: "AiTerm found its worker’s window open already. " + Self.threeMinutes)
        case .opening: self = .opening
        case .failed(let reason): self.init(result: "failed", note: reason)
        case .notLaunched: self.init(result: "queued", note: "AiTerm didn’t start it: the task changed meanwhile. Read run_status.")
        }
    }

    /// The task as it stands, with no start of this call's to tell of: `connected`, whether a helper is there to open a window;
    /// `starting`, whether a start of it is under way.
    init(_ id: UUID, in state: AppState, connected: Bool = true, starting: Bool = false) {
        guard let operated = state.task(id: id)?.operated else {
            self.init(result: "queued", note: "It is no longer in AiTerm.")
            return
        }
        switch operated.state {
        case .blocked:
            self.init(result: "failed", note: operated.blockedReason ?? "It is blocked.")
        case .queued where !connected:
            self.init(result: "queued", note: "AiTerm isn’t connected to iTerm2 now; it starts the worker once it reconnects.")
        case .queued where state.run(id: operated.runId)?.state != .active:
            self.init(result: "queued", note: "Its broadcast isn’t active, so AiTerm starts nothing in it until it is.")
        case .queued where !RunScheduler.startable(in: state, run: operated.runId).contains(id):
            self.init(result: "queued", note: "It waits on a task it depends on; AiTerm starts it once that one is done.")
        case .queued:
            self.init(result: "queued", note: "AiTerm starts it in a moment: its last window isn’t listed in iTerm2 yet.")
        case .working where starting:
            self = .opening
        case .working where operated.launch?.openedAt == nil:
            self.init(result: "opening", note: "iTerm2 hasn’t confirmed its worker’s window yet. If none shows, AiTerm blocks the task and says why.")
        case .working where operated.launch?.workerPending == true:
            self.init(result: "opened", note: "Its worker’s window is open, and no agent is listed in it yet. " + Self.threeMinutes)
        case .working:
            self.init(result: "opened", note: "Its worker’s window is open; run_status shows whether its agent is at work.")
        default:
            self.init(result: "queued", note: "It is \(operated.state.rawValue) now; there is nothing to start.")
        }
    }

    var json: JSONValue { ["result": .string(result), "note": .string(note)] }
}
