import Foundation
import AiTermCore

/// The signal sheet reads each worker's latest probe as the Agents cards publish it.
@MainActor struct SignalContext {
    struct Worker {
        var choice: AgentChoice
        var reading: ModelCatalogue.Reading?
        var refreshing = false

        var unverified: Bool { reading == nil || reading?.failure != nil || refreshing }

        var help: String? {
            guard let reading else { return "Loading \(choice.agent.displayName) models…" }
            if let failure = reading.failure {
                let why = failure.localizedDescription
                return reading.stale ? why + "\nShowing the last known models." : why
            }
            if refreshing { return "Refreshing \(choice.agent.displayName) models…" }
            return reading.models.isEmpty ? choice.agent.harness.noModelsExplanation : nil
        }
    }

    let worker: (AgentKind) -> Worker?
    var offeredAgents: [AgentKind] { AgentCommand.workerAgents.filter { worker($0) != nil } }

    init(installed: @escaping @MainActor () -> Set<AgentKind>, harness: HarnessSettingsModel) {
        worker = { agent in
            let snapshot = harness.snapshots[agent]
            guard AgentCommand.workerAgents.contains(agent), installed().contains(agent), snapshot?.health != .unavailable else { return nil }
            let models = snapshot?.models ?? []
            var preference = harness.preferences[agent] ?? ModelPreference(model: "", reasoning: nil)
            if !models.contains(where: { $0.id == preference.model }) {
                preference = ModelPreference(model: "", reasoning: nil)
                if let first = models.first { preference.select(first) }
            }
            let reading = snapshot.map {
                ModelCatalogue.Reading(models: $0.models, stale: $0.modelsAreStale,
                                       failure: $0.checks.first { $0.id == .models }?.modelListFailure)
            }
            return Worker(choice: .init(agent: agent, model: preference.model, reasoning: preference.reasoning),
                          reading: reading, refreshing: harness.probing.contains(agent))
        }
    }

    #if DEBUG
    /// A snapshot or test with a known set of installed workers and completed model reads.
    init(models: [AgentKind: [AgentModel]], defaults: [AgentKind: AgentChoice]) {
        worker = { agent in
            defaults[agent].map { Worker(choice: $0, reading: .init(models: models[agent] ?? [])) }
        }
    }
    #endif
}
