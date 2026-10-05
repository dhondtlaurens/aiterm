import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct ModelSettingsTests {
    let catalog = [
        AgentModel(id: "a", label: "A", detail: nil, efforts: ["low", "high"], defaultEffort: "high"),
        AgentModel(id: "b", label: "B", detail: nil, efforts: ["medium", "max"], defaultEffort: "medium"),
        AgentModel(id: "c", label: "C", detail: nil, efforts: [], defaultEffort: nil)
    ]

    func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let defaults = ScratchDefaults.make()
        try body(defaults)
    }

    @Test func preferencesRoundTripIndependentlyForEachProvider() {
        withDefaults { defaults in
            #expect(ModelSettings.load(for: .claude, defaults: defaults) == nil)
            #expect(ModelSettings.load(for: .codex, defaults: defaults) == nil)
            let claude = ModelPreference(model: "a", reasoning: "low")
            let codex = ModelPreference(model: "b", reasoning: "max")
            ModelSettings.save(claude, for: .claude, defaults: defaults)
            ModelSettings.save(codex, for: .codex, defaults: defaults)
            #expect(ModelSettings.load(for: .claude, defaults: defaults) == claude)
            #expect(ModelSettings.load(for: .codex, defaults: defaults) == codex)
            ModelSettings.save(ModelPreference(model: "c", reasoning: nil), for: .claude, defaults: defaults)
            #expect(ModelSettings.load(for: .claude, defaults: defaults)?.reasoning == nil)
            #expect(ModelSettings.load(for: .codex, defaults: defaults) == codex)
        }
    }

    @Test func savedDefaultsWinOverLastUsedModel() {
        withDefaults { defaults in
            #expect(ModelSettings.resolve(for: .claude, catalog: catalog, remembered: "b", defaults: defaults)
                == ModelPreference(model: "b", reasoning: "medium"))
            ModelSettings.save(ModelPreference(model: "a", reasoning: "low"), for: .claude, defaults: defaults)
            #expect(ModelSettings.resolve(for: .claude, catalog: catalog, remembered: "b", defaults: defaults)
                == ModelPreference(model: "a", reasoning: "low"))
        }
    }

    @Test func staleSavedModelsRemainMissingAndUnsupportedEffortsAreCorrected() {
        withDefaults { defaults in
            ModelSettings.save(ModelPreference(model: "retired", reasoning: "max"), for: .codex, defaults: defaults)
            #expect(ModelSettings.resolve(for: .codex, catalog: catalog, remembered: "b", defaults: defaults)
                == ModelPreference(model: "", reasoning: nil))
            #expect(ModelSettings.resolution(for: .codex, catalog: catalog, remembered: "b", defaults: defaults)
                == .missing(ModelPreference(model: "retired", reasoning: "max")))
            ModelSettings.save(ModelPreference(model: "a", reasoning: "max"), for: .codex, defaults: defaults)
            #expect(ModelSettings.resolve(for: .codex, catalog: catalog, defaults: defaults).reasoning == "high")
            ModelSettings.save(ModelPreference(model: "c", reasoning: "high"), for: .codex, defaults: defaults)
            #expect(ModelSettings.resolve(for: .codex, catalog: catalog, defaults: defaults).reasoning == nil)
            #expect(ModelSettings.resolve(for: .codex, catalog: [], defaults: defaults)
                == ModelPreference(model: "", reasoning: nil))
        }
    }

    @Test func missingSavedProviderModelNeverFallsAcrossProviders() {
        withDefaults { defaults in
            let saved = ModelPreference(model: "openai/model-x", reasoning: "high")
            ModelSettings.save(saved, for: .pi, defaults: defaults)
            let current = [AgentModel(id: "anthropic/model-x", label: "anthropic / model-x", detail: nil,
                                      efforts: ["high"], defaultEffort: "high")]
            #expect(ModelSettings.resolution(for: .pi, catalog: current, defaults: defaults) == .missing(saved))
            #expect(ModelSettings.load(for: .pi, defaults: defaults) == saved)
        }
    }

    @Test func switchingModelsKeepsSupportedEffortAndClearsItWhenUnsupported() {
        var preference = ModelPreference(model: "other", reasoning: "low")
        preference.select(catalog[0])
        #expect(preference == ModelPreference(model: "a", reasoning: "low"))
        preference.select(catalog[1])
        #expect(preference == ModelPreference(model: "b", reasoning: "medium"))
        preference.select(catalog[2])
        #expect(preference == ModelPreference(model: "c", reasoning: nil))
    }
}
