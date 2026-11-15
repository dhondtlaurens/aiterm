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
    func note(_ text: String, key: String, task id: UUID) async throws {
        guard let task = workspace.state.signalItem(id: id), let claim = SignalClaim(task) else { throw ActionUnavailable("The task is no longer the Operator’s.") }
        let noteKey = "note:\(claim.stage):\(claim.ownership):" + key
        let entry = TaskJournal.Entry(at: now(), stage: claim.stage, text: .ours(text), key: noteKey), folder = folder
        let saved = try await BackgroundWork.run(on: queue) {
            if let old = try TaskJournal.read(task: id, folder: folder).first(where: { $0.key == noteKey }) {
                guard old.text == entry.text else { throw ActionUnavailable("That note key already names a different decision.") }; return old
            }
            try TaskJournal.append(entry, task: id, folder: folder); return entry
        }
        guard claim.holds(in: workspace.state), !Task.isCancelled else { throw ActionUnavailable("The task changed while its note was saved.") }
        workspace.mutate { $0.updateSignalTask(id) { value in
            if !value.journal.contains(where: { $0.id == saved.id }) { value.journal.append(saved) }
            value.journal = Array(value.journal.suffix(TaskJournal.stateLimit))
        } }
        guard workspace.flush() else { throw ActionUnavailable("The task note couldn’t be saved.") }
    }

}
