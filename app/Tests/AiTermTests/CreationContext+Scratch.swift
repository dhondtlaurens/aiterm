import Foundation
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

extension CreationContext {
    static func scratch(home: URL = ScratchHome.bare, claudeConfig: ClaudeConfig = ClaudeConfig(),
                        availableAgents: @escaping @MainActor () -> Set<AgentKind> = { Set(AgentKind.allCases) },
                        rememberedModels: [AgentKind: String] = [:],
                        catalogue: @escaping @Sendable (AgentKind) throws -> [AgentModel] = ScratchHome.catalogue,
                        initialCatalogue: [AgentModel]? = nil, initialCatalogueFailure: String? = nil,
                        defaults: UserDefaults = ScratchDefaults.make(), git: any GitRunning = GitRunner.hermetic(),
                        reservedSlugs: Set<String> = [], canChangeWorkspace: @escaping @MainActor () -> Bool = { true }) -> Self {
        Self(home: home, claudeConfig: claudeConfig, availableAgents: availableAgents, rememberedModels: rememberedModels,
             catalogue: catalogue, initialCatalogue: initialCatalogue, initialCatalogueFailure: initialCatalogueFailure,
             defaults: defaults, git: git, reservedSlugs: reservedSlugs, canChangeWorkspace: canChangeWorkspace)
    }
}
