#if DEBUG
import SwiftUI
import AiTermCore

@MainActor enum SignalSidebarSnapshots {
    static var all: [Snapshot] {
        ["sidebar", "acting", "watching", "questions", "paused", "folded", "taken-over", "fresh", "choosing", "blocked", "issue", "done", "window-closed", "off", "removed", "section-folded"].map { state in
            Snapshot("signals-" + state + ".png", hostedOnly: true) { make(state) }
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
        signal.collapsed = pose == "folded"
        signal.enabled = pose != "off"
        controller.workspace.mutate { state in
            state.signals = [signal]
            var record = SignalTask(signal: signal.id, item: .ticket(site: "https://jira.example", key: "PAY-142"), startedAt: Snapshots.clock.now)
            record.phase = pose == "watching" ? .watching(.hasReviewer) : .working; record.configuration = signal
            if pose == "acting" { record.currentAct = "answering its worker" }
            if pose == "choosing" { record.phase = .choosing; record.choosableRows = signal.agents + [AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")] }
            if pose == "blocked" { record.phase = .blocked; record.blockedReason = "Its worker did not start after its saved launch. Inspect its window before resuming." }
            if pose == "done" { record.phase = .done }
            if pose == "taken-over" { record.takenOver = true; record.ownership = 1 }
            if let index = state.tasks.firstIndex(where: { $0.id == fixture.working.id }) { state.tasks[index].signalTask = record
                if pose == "window-closed" {
                    state.tasks[index].windowId = nil
                    state.tasks[index].conversations = [.init(agent: .claude, id: "saved-conversation")]
                }
            }
            if pose == "removed" { state.signals = [] }
            state.operatorSession = OperatorSession(createdAt: Snapshots.clock.now)
            if pose == "paused" { state.operatorSession?.paused = true }
            if pose == "fresh" { state.operatorSession?.startingFresh = true }
            // The Operator's section open, but where the pose is the projects': a taken-over task is theirs, and
            // section-folded is the default, OPERATOR folded with its amber count.
            state.operatorOpen = !["taken-over", "section-folded"].contains(pose)
            if ["questions", "section-folded"].contains(pose) { state.operatorSession?.questions = [.init(id: "vat", task: fixture.working.id,
                text: "Block orders without a VAT number, or export them with the field empty?", openedAt: Snapshots.clock.now)] }
        }
        if ["watching", "questions", "section-folded", "paused", "off", "choosing", "blocked", "done", "window-closed"].contains(pose) { controller.live.sessions.removeAll { $0.taskUUID == fixture.working.id } }
        return SidebarView(controller: controller).frame(width: 420, height: 900)
    }
}
#endif
