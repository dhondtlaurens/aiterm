import SwiftUI
import Testing
@testable import AiTermUI

@MainActor
struct InputTests {
    /// AppKit hands a field's value back when editing begins and ends, not only when it changes.
    /// Only a real edit may reach the caller's binding: its setter can have a side effect — open
    /// the ticket list, mark the branch hand-edited — that clicking another field must not fire.
    @Test func onlyARealEditReachesTheBinding() {
        var value = "feat/login"
        var writes = 0
        let binding = Input.edits(to: Binding(get: { value }, set: { value = $0; writes += 1 }))

        binding.wrappedValue = "feat/login"
        #expect(writes == 0)

        binding.wrappedValue = "feat/logout"
        #expect(writes == 1)
        #expect(value == "feat/logout")
    }
}
