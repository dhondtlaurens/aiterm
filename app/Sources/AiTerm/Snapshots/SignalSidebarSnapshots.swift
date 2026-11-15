#if DEBUG
import SwiftUI
import AiTermCore

@MainActor enum SignalSidebarSnapshots {
    static var all: [Snapshot] {
        [Snapshot("signals-sidebar.png", hostedOnly: true) {
            let fixture = Fixture(), controller = fixture.controller()
            let signal = Signal(name: "Plan labelled tickets", createdAt: Snapshots.clock.now,
                source: .jira(JiraConditions(labels: ["operator"])), work: SignalWork(prompt: "/psg:plan"),
                agents: [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")],
                finish: SignalFinish(doneWhen: .operatorJudges, then: .keep))
            controller.workspace.mutate { state in
                state.signals = [signal]
                var record = SignalTask(signal: signal.id, item: .ticket(site: "https://jira.example", key: "PAY-142"), startedAt: Snapshots.clock.now)
                record.phase = .working; record.configuration = signal
                if let index = state.tasks.firstIndex(where: { $0.id == fixture.working.id }) { state.tasks[index].signalTask = record }
                state.operatorSession = OperatorSession(createdAt: Snapshots.clock.now)
            }
            return SidebarView(controller: controller).frame(width: 420, height: 900)
        }]
    }
}
#endif
