import Testing
import AiTermCore
@testable import AiTerm

@Suite @MainActor struct PromptCompletionTests {
    /// One key for every agent, Codex included.
    @Test func completionHintAdvertisesSlashOnly() {
        #expect(CompletionHint.text == "Type / for commands and skills.")
    }
}
