import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct InterfacePreferencesTests {
    /// One assignment is the whole change: the next launch — a new instance over the same
    /// defaults — reads it back.
    @Test func everyWriteIsSaved() throws {
        let defaults = ScratchDefaults.make()
        let preferences = InterfacePreferences(defaults: defaults)
        #expect(preferences.badgeDetails == BadgeDetails())
        #expect(preferences.interfaceSize == .standard)
        #expect(!preferences.matchItermBackground)

        let trimmed = BadgeDetails(jiraProject: false, jiraTicket: true, mergeRequest: false, diff: true)
        preferences.badgeDetails = trimmed
        preferences.interfaceSize = .extraLarge
        preferences.matchItermBackground = true

        let relaunched = InterfacePreferences(defaults: defaults)
        #expect(relaunched.badgeDetails == trimmed)
        #expect(relaunched.interfaceSize == .extraLarge)
        #expect(relaunched.matchItermBackground)
    }
}
