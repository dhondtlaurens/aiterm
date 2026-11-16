#if DEBUG
import SwiftUI
import AiTermCore
import AiTermUI

@MainActor enum SignalSidebarSnapshots {
    static var all: [Snapshot] {
        ["sidebar", "acting", "watching", "questions", "paused", "idle-paused", "folded", "taken-over", "fresh", "choosing", "blocked", "issue", "idle", "done", "window-closed", "off", "removed", "section-folded",
         "worker-done", "approval", "threads", "waiting-folded"].map { state in
            Snapshot("signals-" + state + ".png", hostedOnly: true) { make(state) }
        } + [Snapshot("signals-waiting-marks.png", hostedOnly: true) { waitingMarks() }]
    }
    /// What a driven task waits on, as the done check last read it, by pose.
    private static func waiting(_ pose: String) -> (TaskPhase, SignalWaitFacts?)? {
        switch pose {
        case "watching": (.watching(.hasReviewer), nil)
        case "approval", "waiting-folded": (.watching(.approved), SignalWaitFacts(reviewers: ["Lawrence De Spiegeleire"]))
        case "threads": (.watching(.threadsResolved), SignalWaitFacts(openThreads: 3))
        default: nil
        }
    }
    private static func make(_ pose: String) -> some View {
        let fixture = Fixture(), controller = fixture.controller()
        // An issue that kept failing: the Operator row's own "needs you", its source and reason as tooltip.
        if pose == "issue" { controller.rows.operatorIssue = { "Waking the Operator: The helper refused the wake: a wake line may not carry a digit" } }
        var signal = Signal(name: "Plan labelled tickets", createdAt: Snapshots.clock.now,
            source: .jira(JiraConditions(labels: ["operator"])), work: SignalWork(prompt: "/psg:plan"),
            agents: [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")],
            finish: SignalFinish(doneWhen: .hasReviewer, then: .keep))
        signal.collapsed = ["folded", "waiting-folded"].contains(pose)
        signal.enabled = pose != "off"
        controller.workspace.mutate { state in
            state.signals = [signal]
            var record = SignalTask(signal: signal.id, item: .ticket(site: "https://jira.example", key: "PAY-142"), startedAt: Snapshots.clock.now)
            record.phase = waiting(pose)?.0 ?? .working; record.waitingOn = waiting(pose)?.1; record.configuration = signal
            if pose == "acting" { record.currentAct = "answering its worker" }
            if pose == "choosing" { record.phase = .choosing; record.choosableRows = signal.agents + [AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")] }
            if pose == "blocked" { record.phase = .blocked; record.blockedReason = "Its worker did not start after its saved launch. Inspect its window before resuming." }
            if pose == "done" { record.phase = .done; record.thenApplied = true }
            if pose == "taken-over" { record.takenOver = true; record.ownership = 1 }
            if let index = state.tasks.firstIndex(where: { $0.id == fixture.working.id }) { state.tasks[index].signalTask = ["idle", "idle-paused"].contains(pose) ? nil : record
                if waiting(pose) != nil { state.tasks[index].mr = MergeRequestRef(iid: 102, title: "Apple Pay", url: "https://git.example/shop/web/-/merge_requests/102") }
                if pose == "window-closed" {
                    state.tasks[index].windowId = nil
                    state.tasks[index].conversations = [.init(agent: .claude, id: "saved-conversation")]
                }
            }
            if pose == "removed" { state.signals = [] }
            state.operatorSession = OperatorSession(createdAt: Snapshots.clock.now)
            if ["paused", "idle-paused"].contains(pose) { state.operatorSession?.paused = true }
            if pose == "fresh" { state.operatorSession?.startingFresh = true }
            // The Operator's section open, but where the pose is the projects': a taken-over task is theirs, and
            // section-folded is the default, OPERATOR folded with its amber count.
            state.operatorOpen = !["taken-over", "section-folded"].contains(pose)
            if ["questions", "section-folded"].contains(pose) { state.operatorSession?.questions = [.init(id: "vat", task: fixture.working.id,
                text: "Block orders without a VAT number, or export them with the field empty?", openedAt: Snapshots.clock.now)] }
        }
        if ["watching", "questions", "section-folded", "paused", "off", "choosing", "blocked", "done", "window-closed", "approval", "threads", "waiting-folded"].contains(pose) { controller.live.sessions.removeAll { $0.taskUUID == fixture.working.id } }
        // Every worker ended its turn and the Operator does nothing yet: the turn is the Operator's to read.
        if pose == "worker-done" { for index in controller.live.sessions.indices where controller.live.sessions[index].taskUUID == fixture.working.id { controller.live.sessions[index].state = .done } }
        return SidebarView(controller: controller).frame(width: 420, height: 900)
    }
    /// The waiting ring on a driven row: plain, selected, held still for Reduce Motion, and the mark on the accent
    /// beside the background and working marks it is told from.
    private static func waitingMarks() -> some View {
        let fixture = Fixture(), controller = fixture.controller()
        let signal = Signal(name: "Review requests", createdAt: Snapshots.clock.now, source: .jira(JiraConditions(labels: ["operator"])),
            work: SignalWork(prompt: "/psg:plan"), agents: [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")],
            finish: SignalFinish(doneWhen: .approved, then: .keep))
        controller.workspace.mutate { state in
            state.signals = [signal]; state.operatorSession = OperatorSession(createdAt: Snapshots.clock.now); state.operatorOpen = true
            for (offset, id) in [fixture.working.id, fixture.other.id].enumerated() {
                guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { continue }
                var record = SignalTask(signal: signal.id, item: .ticket(site: "https://jira.example", key: "PAY-14\(offset)"), startedAt: Snapshots.clock.now)
                record.configuration = signal
                record.phase = offset == 0 ? .watching(.approved) : .working
                record.waitingOn = SignalWaitFacts(reviewers: ["Lawrence De Spiegeleire", "Jan De Visscher"])
                state.tasks[index].signalTask = record
                state.tasks[index].mr = MergeRequestRef(iid: 102 + offset, title: "Work", url: "https://git.example/shop/web/-/merge_requests/\(102 + offset)")
            }
        }
        for index in controller.live.sessions.indices where [fixture.working.id, fixture.other.id].contains(controller.live.sessions[index].taskUUID) {
            controller.live.sessions[index].state = .idle
        }
        controller.focus.browse(.task(fixture.working.id))
        let rows = controller.rows.signalSections.flatMap(\.tasks)
        let selected = rows.first { $0.id == fixture.working.id }!, plain = rows.first { $0.id == fixture.other.id }!
        // Driven tasks use the ordinary two-line row under the same status-mark rules.
        let working = controller.workspace.state.task(id: fixture.working.id), other = controller.workspace.state.task(id: fixture.other.id)
        return SnapshotColumn(width: Size.sidebarWidth + 2 * Space.inset, spacing: Space.base, horizontalInset: Space.inset, verticalInset: Space.base) {
            TaskRowView(row: plain, task: other, controller: controller)
            TaskRowView(row: selected, task: working, controller: controller)
            TaskRowView(row: plain, task: other, controller: controller).environment(\.motionStill, .reduceMotion)
            HStack(spacing: Space.base) {
                ForEach([TaskStatus.working, .background, .waiting], id: \.self) { StatusMark(status: $0, size: Size.statusMark) }
            }
            .padding(Space.tight).background(Palette.accent).surface(.accent)
        }
        .surface(.sidebar)
    }
}
#endif
