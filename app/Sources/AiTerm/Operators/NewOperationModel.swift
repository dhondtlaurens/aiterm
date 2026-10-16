import Foundation
import Observation
import AiTermCore

/// The New operation sheet's state: the operator — picked already, from the header whose "+" was
/// used — the brief, the optional Done when, and the start, which the operator controller runs.
@MainActor
@Observable
final class NewOperationModel: Identifiable {
    let id = UUID()
    let operators: [OperatorPersona]
    var handle: String
    var brief = ""
    var doneWhen = ""
    private(set) var starting = false
    /// Why the last start failed, in the footer.
    private(set) var error: String? = nil
    @ObservationIgnored private let start: @MainActor (OperatorPersona, String, String?) async throws -> UUID

    static let title = "New operation"
    static let briefHelp = "What to work on, as you would tell a colleague. A Jira key brings in its ticket."
    static let doneWhenHelp = "What finished looks like. A draft MR or a merge happens only when this brief or the operator’s persona asks for it, as an end in the plan you approve."
    static let doneWhenPlaceholder = "a commit per item, tests green — I review and push"

    init(operators: [OperatorPersona], picked handle: String,
         start: @escaping @MainActor (OperatorPersona, String, String?) async throws -> UUID) {
        self.operators = operators
        self.handle = handle
        self.start = start
    }

    var picked: OperatorPersona? { operators.first { $0.handle == handle } }

    /// The band's sentence: a gated operator shows its plan first; an ungated one starts at once.
    var subtitle: String {
        guard let picked else { return "" }
        return SidebarModel.gatesPlans(picked.autonomy)
            ? "\(picked.name) plans it first; nothing starts before you see the plan."
            : "\(picked.name) plans it, then starts it at once; you watch the plan run."
    }

    var destination: Destination { .operatorWindow(picked?.name ?? "The operator") }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canStart: Bool { picked != nil && !trimmed(brief).isEmpty && !starting }

    /// Starts the operation — its operator's window opens with the brief as its first message — and
    /// returns its id, or nil with the reason in `error`.
    func startOperation() async -> UUID? {
        guard canStart, let picked else { return nil }
        starting = true
        defer { starting = false }
        error = nil
        let done = trimmed(doneWhen)
        do { return try await start(picked, trimmed(brief), done.isEmpty ? nil : done) }
        catch { self.error = error.localizedDescription; return nil }
    }
}
