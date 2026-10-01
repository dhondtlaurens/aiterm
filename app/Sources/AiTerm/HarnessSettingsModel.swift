import Foundation
import SwiftUI
import AiTermCore

protocol HarnessServicing: Sendable {
    func probe(_ agent: AgentKind) async -> HarnessSnapshot
    func install(_ agent: AgentKind) async throws -> HarnessSnapshot
    /// Tests the driver of `snapshot`, the service's own latest answer for that agent.
    func test(_ snapshot: HarnessSnapshot) async -> HarnessSnapshot
}

extension HarnessService: HarnessServicing {}

/// Owns the asynchronous, process-backed state behind the Agents Settings tab. The view only
/// renders snapshots and starts these actions; configuration reads and writes stay on the service
/// actor and never become incidental SwiftUI work.
@MainActor
final class HarnessSettingsModel: ObservableObject {
    @Published private(set) var snapshots: [AgentKind: HarnessSnapshot] = [:]
    @Published private(set) var preferences: [AgentKind: ModelPreference] = [:]
    @Published private(set) var running: Set<AgentKind> = []

    private let service: any HarnessServicing
    /// The last model used with each agent, read whenever a card resolves its default: the model
    /// outlives any one Settings presentation, and tasks created meanwhile change the answer.
    /// Internal, not private, for `theSettingsModelReadsTheWorkspacesRememberedModels`.
    let rememberedModels: @MainActor () -> [AgentKind: String]
    private let defaults: UserDefaults
    private let integrationChanged: @MainActor (AgentKind) -> Void
    /// Internal, not private, for `anOpenCreationSheetOffersACLISettingsInstalled`.
    let cliInstalled: @MainActor (AgentKind) -> Void
    private var loaded: Set<AgentKind> = []
    /// The agents whose default the person picked since the card last read the saved one. Only
    /// these are saved: every other card shows a resolved default, and saving it would pin it.
    private var picked: Set<AgentKind> = []

    /// `cliInstalled` hears of an Install that put a missing CLI on the `PATH`, so the New Task and
    /// New Review sheets offer that agent without a relaunch.
    init(service: any HarnessServicing, rememberedModels: @escaping @MainActor () -> [AgentKind: String],
         defaults: UserDefaults = .standard,
         integrationChanged: @escaping @MainActor (AgentKind) -> Void = { _ in },
         cliInstalled: @escaping @MainActor (AgentKind) -> Void = { _ in }) {
        self.service = service
        self.rememberedModels = rememberedModels
        self.defaults = defaults
        self.integrationChanged = integrationChanged
        self.cliInstalled = cliInstalled
    }

    /// Every harness at once, so a slow one (PI launches its CLI twice) holds up only its own card.
    func load() async {
        await withTaskGroup(of: Void.self) { group in
            for agent in AgentKind.allCases {
                group.addTask { await self.refresh(agent) }
            }
        }
    }

    /// A probe draws the card; an installed driver is then tested too, so its status reports
    /// whether events arrive now rather than whatever an earlier opening found. The test installs
    /// nothing, so this stays as read-only as the probe.
    private func refresh(_ agent: AgentKind) async {
        guard !running.contains(agent) else { return }
        running.insert(agent)
        defer { running.remove(agent) }
        // `.task` runs once per Settings presentation. Re-resolve persisted defaults here so
        // reopening after Cancel drops unsaved picker edits; explicit actions within the same
        // presentation use the current preference below and therefore do not reset the form.
        let probed = await service.probe(agent)
        accept(probed, resolveStoredPreference: true)
        guard probed.health != .unavailable, probed.integrationState == .current else { return }
        accept(await service.test(probed), resolveStoredPreference: false)
    }

    /// Writes AiTerm's driver — fresh, over an outdated one, or over a working one — and then
    /// tests it, since there is no Test button to press afterwards. A missing CLI is installed
    /// first, by the service.
    func install(_ agent: AgentKind) async {
        guard !running.contains(agent) else { return }
        running.insert(agent)
        defer { running.remove(agent) }
        let cliWasMissing = snapshots[agent]?.health == .unavailable
        let installed: HarnessSnapshot
        do {
            installed = try await service.install(agent)
        } catch {
            let explanation = error.localizedDescription
            // The installer may have put the CLI on disk before the driver failed; only a probe
            // knows, and a card left saying "unavailable" would offer to install it again.
            let known = cliWasMissing ? await service.probe(agent) : snapshots[agent]
            if cliWasMissing, known?.health != .unavailable { cliInstalled(agent) }
            let current = known ?? HarnessSnapshot.reduce(
                agent: agent, cliAvailable: true, integrationState: .resourceUnavailable,
                models: [], checks: [])
            var checks = current.checks.filter { $0.id != "operation" }
            checks.insert(HarnessCheck(id: "operation", label: "Setup", passed: false,
                                       explanation: explanation), at: 0)
            snapshots[agent] = HarnessSnapshot.reduce(
                agent: agent, cliAvailable: current.health != .unavailable,
                integrationState: current.integrationState, models: current.models,
                modelsAreStale: current.modelsAreStale, checks: checks)
            return
        }
        accept(installed, resolveStoredPreference: !loaded.contains(agent))
        if cliWasMissing { cliInstalled(agent) }
        integrationChanged(agent)
        guard installed.integrationState == .current else { return }
        accept(await service.test(installed), resolveStoredPreference: false)
    }

    /// A picker change is local until Settings is saved. It can only clear a missing-model warning
    /// against a fresh catalogue; stale rows remain read-only and cannot bless an unverified id.
    func select(_ model: AgentModel, for agent: AgentKind) {
        guard let snapshot = snapshots[agent], !snapshot.modelsAreStale,
              snapshot.models.contains(model) else { return }
        var preference = preferences[agent] ?? ModelPreference(model: model.id, reasoning: nil)
        preference.select(model)
        preferences[agent] = preference
        picked.insert(agent)
        snapshots[agent] = applyingSelection(preference, to: snapshot)
    }

    func selectReasoning(_ reasoning: String, for agent: AgentKind) {
        guard let snapshot = snapshots[agent], !snapshot.modelsAreStale,
              let model = snapshot.models.first(where: { $0.id == preferences[agent]?.model }),
              model.efforts.contains(reasoning) else { return }
        preferences[agent]?.reasoning = reasoning
        picked.insert(agent)
    }

    func save() {
        for agent in AgentKind.allCases {
            guard picked.contains(agent), loaded.contains(agent), let snapshot = snapshots[agent], !snapshot.modelsAreStale,
                  let preference = preferences[agent],
                  snapshot.models.contains(where: { $0.id == preference.model }) else { continue }
            ModelSettings.save(preference, for: agent, defaults: defaults)
        }
        picked = []
    }

    private func accept(_ snapshot: HarnessSnapshot, resolveStoredPreference: Bool) {
        let preference: ModelPreference?
        if !resolveStoredPreference, let current = preferences[snapshot.agent] {
            preference = current
        } else {
            switch ModelSettings.resolution(for: snapshot.agent, catalog: snapshot.models,
                                            remembered: rememberedModels()[snapshot.agent], defaults: defaults) {
            case .valid(let resolved), .missing(let resolved): preference = resolved
            case .empty: preference = nil
            }
            picked.remove(snapshot.agent)
        }
        if let preference { preferences[snapshot.agent] = preference }
        else { preferences.removeValue(forKey: snapshot.agent) }
        snapshots[snapshot.agent] = applyingSelection(preference, to: snapshot)
        loaded.insert(snapshot.agent)
    }

    private func applyingSelection(_ preference: ModelPreference?,
                                   to snapshot: HarnessSnapshot) -> HarnessSnapshot {
        var checks = snapshot.checks.filter { $0.id != "selected-model" }
        // An absent CLI, failed discovery, empty provider list, or stale catalogue already has a
        // more fundamental explanation. A missing saved default is actionable only when a fresh,
        // non-empty catalogue proves that the id really disappeared.
        if let preference, !snapshot.models.isEmpty, !snapshot.modelsAreStale,
           !snapshot.models.contains(where: { $0.id == preference.model }) {
            // Keep concrete setup/Test failures ahead of this preference warning. When every
            // harness layer passes, this is the first (and only) failed check and still becomes
            // the card summary.
            checks.append(HarnessCheck(id: "selected-model", label: "Default model", passed: false,
                                       explanation: "The selected model is no longer available."))
        }
        return .reduce(agent: snapshot.agent, cliAvailable: snapshot.health != .unavailable,
                       integrationState: snapshot.integrationState, models: snapshot.models,
                       modelsAreStale: snapshot.modelsAreStale, checks: checks)
    }
}

extension HarnessSettingsModel {
    /// Deterministic Settings fixtures use the same model as the real view, without probing a
    /// developer's installed CLIs or configuration.
    static func preview() -> HarnessSettingsModel { preview(snapshots: previewSnapshots) }

    static func preview(snapshots: [AgentKind: HarnessSnapshot]) -> HarnessSettingsModel {
        let service = PreviewHarnessService(snapshots: snapshots)
        let model = HarnessSettingsModel(service: service, rememberedModels: { [:] },
                                         defaults: UserDefaults(suiteName: "AiTerm.HarnessPreview.\(UUID().uuidString)")!)
        for agent in AgentKind.allCases {
            if let snapshot = snapshots[agent] { model.accept(snapshot, resolveStoredPreference: true) }
        }
        return model
    }

    private static let previewSnapshots: [AgentKind: HarnessSnapshot] = {
        let claude = AgentModel(id: "opus", label: "Opus", detail: "Latest Claude model",
                                efforts: ["low", "medium", "high"], defaultEffort: "high")
        let codex = AgentModel(id: "gpt-5.6", label: "gpt-5.6", detail: "Latest Codex model",
                               efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium")
        let grok = AgentModel(id: "grok-4.7", label: "Grok 4.7", detail: "Latest Grok model",
                              efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "high")
        let pi = AgentModel(id: "openai-codex/gpt-5.6-sol", label: "openai-codex / gpt-5.6-sol",
                            detail: "128k context · images", efforts: ["off", "medium", "high"],
                            defaultEffort: "medium")
        func ready(_ agent: AgentKind, _ model: AgentModel) -> HarnessSnapshot {
            .reduce(agent: agent, cliAvailable: true, integrationState: .current, models: [model],
                    checks: [HarnessCheck(id: "cli", label: "CLI", passed: true, explanation: nil),
                             HarnessCheck(id: "integration", label: "Driver",
                                          passed: true, explanation: nil)])
        }
        return [
            .claude: ready(.claude, claude),
            .codex: ready(.codex, codex),
            .grok: ready(.grok, grok),
            .pi: .reduce(agent: .pi, cliAvailable: true, integrationState: .missing, models: [pi],
                         checks: [HarnessCheck(id: "cli", label: "CLI", passed: true, explanation: nil),
                                  HarnessCheck(id: "integration", label: "Driver", passed: false,
                                               explanation: "Driver is not installed.")]),
        ]
    }()
}

private actor PreviewHarnessService: HarnessServicing {
    let snapshots: [AgentKind: HarnessSnapshot]
    init(snapshots: [AgentKind: HarnessSnapshot]) { self.snapshots = snapshots }
    func probe(_ agent: AgentKind) async -> HarnessSnapshot { snapshots[agent]! }
    func install(_ agent: AgentKind) async throws -> HarnessSnapshot { snapshots[agent]! }
    func test(_ snapshot: HarnessSnapshot) async -> HarnessSnapshot { snapshots[snapshot.agent]! }
}
