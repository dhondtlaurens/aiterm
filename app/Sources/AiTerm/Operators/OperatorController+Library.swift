import Foundation
import AiTermCore

/// The operators themselves (spec §4.0, §10.1): one file each in `operators/`, written by the operator
/// sheet; Move to Trash puts the file in the Trash, so it can be put back. An operation already running
/// keeps the snapshot it started with: nothing here touches a run's `persona`.
extension OperatorController {
    /// The files read again, in the library's order (by name, then handle). One that cannot be read is
    /// left out, and the banner says which.
    func reloadOperators() {
        let loaded = ports.library.load()
        if loaded.operators != operators {
            operators = loaded.operators
            changed()
        }
        if let unreadable = loaded.unreadable.first {
            notices.report(OperationIssue(title: "Couldn’t read the operator in \(unreadable.file.lastPathComponent).", reason: unreadable.reason))
        }
    }

    func saveOperator(_ persona: OperatorPersona) throws {
        try ports.library.save(persona)
        reloadOperators()
    }

    /// A new operator's file: refused if one by that name is there by now, so Create never replaces
    /// another operator. `saveOperator` is for one that exists — Edit Operator….
    func createOperator(_ persona: OperatorPersona) throws {
        try ports.library.create(persona)
        reloadOperators()
    }

    func trashOperator(handle: String) throws {
        try ports.library.trash(handle: handle)
        reloadOperators()
    }

    /// A copy named "… copy", under a handle of its own.
    func duplicateOperator(handle: String) throws {
        guard var copy = operators.first(where: { $0.handle == handle }) else { throw ActionUnavailable("That operator is no longer in AiTerm.") }
        copy.name += " copy"
        copy.handle = ports.library.uniqueHandle(for: copy.name)
        try saveOperator(copy)
    }

    /// Keep, Edit or Dismiss in the overview (spec §4.5): a kept lesson — as edited — is appended to the
    /// operator's file under `## Lessons`; the running operation keeps its snapshot, and the next one
    /// starts with it. Decided once: a lesson already decided is left as it was, so a repeated click or a
    /// second call never appends twice.
    ///
    /// Serialised by the main actor: the append reads the operator's file and writes it back, and there is
    /// no suspension point between the two, so two decisions — for one operator, from one run or two —
    /// run one after the other and neither loses its line. Keep it synchronous.
    func decideLesson(run id: UUID, key: String, _ decision: LessonDecision, edited: String?) throws {
        guard let run = run(id: id), let proposed = run.lessons.first(where: { $0.key == key }), proposed.decided == nil else { return }
        let text = edited.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? proposed.lesson
        if decision == .kept {
            try ports.library.appendLesson(text, to: run.persona.handle)
            reloadOperators()
        }
        mutateRun(id) { run in
            guard let i = run.lessons.firstIndex(where: { $0.key == key }) else { return }
            run.lessons[i].lesson = text
            run.lessons[i].decided = decision
        }
    }
}
