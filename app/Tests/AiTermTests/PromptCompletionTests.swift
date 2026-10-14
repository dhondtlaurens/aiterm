import Testing
import AiTermCore
@testable import AiTerm

@Suite @MainActor struct PromptCompletionTests {
    /// One key for every agent's commands and skills, Codex included, and one for the files.
    @Test func completionHintAdvertisesSlashAndAt() {
        #expect(CompletionHint.text == "Type / for commands and skills, @ for files and folders.")
    }
}
