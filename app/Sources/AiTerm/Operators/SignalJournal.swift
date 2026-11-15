import Foundation
import AiTermCore

/// Serial append-only storage off the main actor; workspace state retains the bounded digest tail.
@MainActor final class SignalJournal {
    private let workspace: WorkspaceStore
    private let folder: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "AiTerm.signal-journals", qos: .utility)
    init(workspace: WorkspaceStore, folder: URL, now: @escaping () -> Date) {
        self.workspace = workspace; self.folder = folder; self.now = now
    }
    func append(_ text: JournalText, task id: UUID) async throws {
        guard let record = workspace.state.signalItem(id: id)?.signalTask else { return }
        let entry = TaskJournal.Entry(at: now(), stage: record.stage, text: text), folder = folder
        try await BackgroundWork.run(on: queue) { try TaskJournal.append(entry, task: id, folder: folder) }
        workspace.mutate { $0.updateSignalTask(id) { value in
            value.journal.append(entry)
            value.journal = Array(value.journal.suffix(TaskJournal.stateLimit))
        } }
        guard workspace.flush() else { throw ActionUnavailable("The task journal couldn’t be saved.") }
    }
}
