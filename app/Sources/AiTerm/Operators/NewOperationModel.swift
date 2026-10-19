import Foundation
import Observation
import AiTermCore

/// The New operation sheet's state: the prompt, the optional Done, and the start, which the operator
/// controller runs on Settings › Operator's profile as it was when the sheet opened. The plan's Task 16
/// replaces it with New Broadcast.
@MainActor
@Observable
final class NewOperationModel: Identifiable {
    let id = UUID()
    /// What the broadcast freezes when it starts.
    let profile: OperatorProfile
    var prompt = ""
    var done = ""
    private(set) var starting = false
    /// Why the last start failed, in the footer.
    private(set) var error: String? = nil
    @ObservationIgnored private let start: @MainActor (OperatorProfile, String, String?) async throws -> UUID

    static let title = "New operation"
    static let promptHelp = "What to work on, as you would tell a colleague. A Jira key brings in its ticket."
    static let doneHelp = "What finished looks like. A draft MR or a merge happens only when this asks for it, as an end in the plan."
    static let donePlaceholder = "a commit per item, tests green, I review and push"
    /// The band's sentence: a submitted plan starts at once, with nothing to approve.
    static let subtitle = "The Operator plans it first, then starts the tasks at once."

    init(profile: OperatorProfile, start: @escaping @MainActor (OperatorProfile, String, String?) async throws -> UUID) {
        self.profile = profile
        self.start = start
    }

    var destination: Destination { .operatorWindow("The Operator") }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canStart: Bool { !trimmed(prompt).isEmpty && !starting }

    /// Starts the broadcast (its Operator's window opens with the prompt as its first message) and
    /// returns its id, or nil with the reason in `error`.
    func startOperation() async -> UUID? {
        guard canStart else { return nil }
        starting = true
        defer { starting = false }
        error = nil
        let done = trimmed(done)
        do { return try await start(profile, trimmed(prompt), done.isEmpty ? nil : done) }
        catch { self.error = error.localizedDescription; return nil }
    }
}
