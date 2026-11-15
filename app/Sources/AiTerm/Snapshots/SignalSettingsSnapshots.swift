#if DEBUG
import SwiftUI
import AiTermCore
import AiTermUI

@MainActor enum SignalSettingsSnapshots {
    static var all: [Snapshot] {
        [false, true].map { off in
            Snapshot(off ? "settings-operator-oracle-off.png" : "settings-operator-full.png", hostedOnly: true) {
                OperatorSettingsPane(model: model(off: off)).padding(Space.margin)
                    .frame(width: Sheet.width).background(Palette.surface)
            }
        }
    }
    static func model(off: Bool) -> OperatorSettingsModel {
        var profile = OperatorProfile(model: "claude-opus-5-5", reasoning: "high")
        profile.oracle.isOn = !off
        let loaded = OperatorSettingsModel.Loaded(profile: profile, models: [
            .claude: [AgentModel(id: profile.model, label: "Opus 5.5", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "high")],
            .codex: [AgentModel(id: profile.oracle.model, label: "gpt-6-astra", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "medium")],
        ], agentDefaults: [:], skills: [])
        let model = OperatorSettingsModel(load: { loaded }, save: { _ in })
        model.received(loaded); return model
    }
}
#endif
