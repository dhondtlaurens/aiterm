#if DEBUG
import SwiftUI
import AiTermCore
import AiTermUI

@MainActor enum SignalSidebarSnapshots {
    static var all: [Snapshot] {
        ["sidebar", "acting", "watching", "questions", "paused", "idle-paused", "folded", "taken-over", "fresh", "choosing", "blocked", "issue", "idle", "done", "window-closed", "off", "removed", "section-folded",
         "worker-done", "described", "merging", "waiting-folded", "finished-folded", "all-finished-folded", "finished-signal-folded", "divider"].map { state in
            Snapshot("signals-" + state + ".png", hostedOnly: true) { make(state) }
        } + [Snapshot("signals-waiting-marks.png", hostedOnly: true) { waitingMarks() }]
    }
    /// A watching task by pose: its line is the Done trigger's query, or its description, or what its merge lacks.
    private static func waiting(_ pose: String) -> (description: String, facts: SignalWaitFacts?)? {
        switch pose {
        case "watching": ("", nil)
        case "described", "waiting-folded", "finished-signal-folded": ("When a reviewer is asked on its merge request", nil)
        case "merging": ("", SignalWaitFacts(mergeBlockers: [.approval, .checks]))
        default: nil
        }
    }
    private static func make(_ pose: String) -> some View {
        let fixture = Fixture(), controller = fixture.controller()
        // An issue that kept failing: the Operator row's own "needs you", its source and reason as tooltip.
        if pose == "issue" { controller.rows.operatorIssue = { "Waking the Operator: The helper refused the wake: a wake line may not carry a digit" } }
        var signal = Signal(name: "Plan labelled tickets", createdAt: Snapshots.clock.now,
            start: SignalTrigger(source: .jira, query: "labels = operator"),
            done: SignalTrigger(source: .gitLab, description: waiting(pose)?.description ?? "", query: "reviewer:any"),
            work: SignalWork(prompt: "/psg:plan"), agents: [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")],
            finish: SignalFinish(then: .keep, mergesWhenReady: pose == "merging"))
        signal.collapsed = ["folded", "waiting-folded", "finished-signal-folded"].contains(pose)
        // A second task beside the first, finished: its Done trigger fired and its closeout is through.
        let finishing = ["finished-folded", "all-finished-folded", "finished-signal-folded", "paused"].contains(pose)
        signal.enabled = pose != "off"
        controller.workspace.mutate { state in
            state.signals = [signal]
            let stage = SignalStage(signal: signal.id, item: .ticket(site: "https://jira.example", key: "PAY-142"), matchedAt: Snapshots.clock.now, configuration: signal)
            var record = SignalTask(current: stage, startedAt: Snapshots.clock.now)
            record.phase = waiting(pose) == nil ? .working : .watching; record.waitingOn = waiting(pose)?.facts
            if pose == "choosing" { record.phase = .choosing; record.choosableRows = signal.agents + [AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")] }
            if pose == "blocked" { record.phase = .blocked; record.blockedReason = "Its worker did not start after its saved launch. Inspect its window before resuming." }
            if ["done", "all-finished-folded"].contains(pose) { record.phase = .done; record.thenApplied = true }
            if let index = state.tasks.firstIndex(where: { $0.id == fixture.working.id }) { state.tasks[index].signalTask = ["idle", "idle-paused"].contains(pose) ? nil : record
                if waiting(pose) != nil { state.tasks[index].mr = MergeRequestRef(iid: 102, title: "Apple Pay", url: "https://gitlab.example.com/shop/web/-/merge_requests/102") }
                if pose == "window-closed" {
                    state.tasks[index].windowId = nil
                    state.tasks[index].conversations = [.init(agent: .claude, id: "saved-conversation")]
                }
            }
            if finishing, let index = state.tasks.firstIndex(where: { $0.id == fixture.other.id }) {
                let item = SignalStage(signal: signal.id, item: .ticket(site: "https://jira.example", key: "PAY-139"),
                                       matchedAt: Snapshots.clock.now, configuration: signal)
                var finished = SignalTask(current: item, startedAt: Snapshots.clock.now)
                finished.phase = .done; finished.thenApplied = true
                state.tasks[index].signalTask = finished
            }
            if pose == "removed" { state.signals = [] }
            // Two more signals, which a named divider heads: the project divider's row, between signal headings.
            if pose == "divider" {
                for name in ["Review requests", "Stale merge requests"] {
                    state.signals.append(Signal(name: name, createdAt: Snapshots.clock.now, start: SignalTrigger(source: .gitLab, query: "reviewer:me"),
                        done: SignalTrigger(source: .gitLab, query: "state:merged"), work: SignalWork(prompt: "/psg:peer-review"),
                        agents: signal.agents, finish: SignalFinish(then: .keep)))
                }
                let divider = SignalDivider(id: UUID(), name: "Reviews")
                state.append(signalDivider: divider)
                state.move(signalDividerId: divider.id, .up); state.move(signalDividerId: divider.id, .up)
            }
            state.operatorSession = OperatorSession(createdAt: Snapshots.clock.now)
            if ["paused", "idle-paused"].contains(pose) { state.operatorSession?.paused = true }
            if pose == "fresh" { state.operatorSession?.lifecycle = .closing(then: .renew) }
            if pose == "taken-over" { state.takeOver(fixture.working.id) }
            // The Operator's section open, but where the pose is the projects': a taken-over task is theirs, and
            // section-folded is the default, OPERATOR folded with its status counts; every other pose folds the projects, whose
            // heading draws theirs.
            state.operatorOpen = !["taken-over", "section-folded", "finished-folded", "all-finished-folded"].contains(pose)
            if ["questions", "section-folded"].contains(pose) { state.operatorSession?.questions = [.init(id: "vat", task: fixture.working.id,
                text: "Block orders without a VAT number, or export them with the field empty?", openedAt: Snapshots.clock.now)] }
        }
        if pose == "acting" { _ = controller.signalController.activity.begin(task: fixture.working.id, act: "answering its worker") }
        if ["watching", "questions", "section-folded", "paused", "off", "choosing", "blocked", "done", "window-closed", "described", "merging", "waiting-folded",
            "all-finished-folded", "finished-signal-folded"].contains(pose) { controller.live.sessions.removeAll { $0.taskUUID == fixture.working.id } }
        if finishing { controller.live.sessions.removeAll { $0.taskUUID == fixture.other.id } }
        // Every worker ended its turn and the Operator does nothing yet: the turn is the Operator's to read.
        if pose == "worker-done" { for index in controller.live.sessions.indices where controller.live.sessions[index].taskUUID == fixture.working.id { controller.live.sessions[index].state = .done } }
        return SidebarView(controller: controller).frame(width: 420, height: 900)
    }
    /// The waiting ring on a driven row: plain, selected, held still for Reduce Motion, and the mark on the accent
    /// beside the background and working marks it is told from.
    private static func waitingMarks() -> some View {
        let fixture = Fixture(), controller = fixture.controller()
        let signal = Signal(name: "Review requests", createdAt: Snapshots.clock.now, start: SignalTrigger(source: .jira, query: "labels = operator"),
            done: SignalTrigger(source: .gitLab, description: "When it is approved", query: "review-state:approved"),
            work: SignalWork(prompt: "/psg:plan"), agents: [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")],
            finish: SignalFinish(then: .keep))
        controller.workspace.mutate { state in
            state.signals = [signal]; state.operatorSession = OperatorSession(createdAt: Snapshots.clock.now); state.operatorOpen = true
            for (offset, id) in [fixture.working.id, fixture.other.id].enumerated() {
                guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { continue }
                let stage = SignalStage(signal: signal.id, item: .ticket(site: "https://jira.example", key: "PAY-14\(offset)"), matchedAt: Snapshots.clock.now, configuration: signal)
                var record = SignalTask(current: stage, startedAt: Snapshots.clock.now)
                record.phase = offset == 0 ? .watching : .working
                state.tasks[index].signalTask = record
                state.tasks[index].mr = MergeRequestRef(iid: 102 + offset, title: "Work", url: "https://gitlab.example.com/shop/web/-/merge_requests/\(102 + offset)")
            }
        }
        for index in controller.live.sessions.indices where [fixture.working.id, fixture.other.id].contains(controller.live.sessions[index].taskUUID) {
            controller.live.sessions[index].state = .idle
        }
        controller.focus.browse(.task(fixture.working.id))
        let rows = controller.rows.signalSections.flatMap(\.tasks)
        let selected = rows.first { $0.id == fixture.working.id }!, plain = rows.first { $0.id == fixture.other.id }!
        // Driven tasks use the ordinary two-line row under the same status-mark rules.
        return SnapshotColumn(width: Size.sidebarWidth + 2 * Space.inset, spacing: Space.base, horizontalInset: Space.inset, verticalInset: Space.base) {
            TaskRowView(row: plain, controller: controller)
            TaskRowView(row: selected, controller: controller)
            TaskRowView(row: plain, controller: controller).environment(\.motionStill, .reduceMotion)
            HStack(spacing: Space.base) {
                ForEach([TaskStatus.working, .background, .waiting], id: \.self) { StatusMark(status: $0, size: Size.statusMark) }
            }
            .padding(Space.tight).background(Palette.accent).surface(.accent)
        }
        .surface(.sidebar)
    }
}
#endif
