import Foundation

// MARK: - A driven task that waits

public extension OperatorLine {
    /// A working task whose every worker ended its turn while the Operator does nothing of its own: the turn is the
    /// Operator's to read. Drawn with the waiting ring (`TaskStatus.waiting`), never as `working`.
    static let workerDone = OperatorLine("worker done · Operator to review",
                                         tooltip: "Every worker ended its turn. The Operator reads what it did and decides what follows.")

    /// What a task watching its Done trigger waits for: the trigger's description when it has one, else its query, cut
    /// to `maxLength` characters, the tooltip the whole of it. While merge when ready holds the task (`facts`), what the
    /// merge lacks; `request` names its merge or pull request (`!102`), else "the request".
    static func waiting(for done: SignalTrigger, facts: SignalWaitFacts?, request: String? = nil) -> OperatorLine {
        if let blockers = facts?.mergeBlockers { return merging(request ?? "the request", blockers) }
        let description = done.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = description.isEmpty ? done.query.trimmingCharacters(in: .whitespacesAndNewlines) : description
        return OperatorLine(fitted(words), tooltip: "Waiting for its Done trigger: " + words)
    }

    /// Merge when ready holds the task: `waiting to merge · checks`, naming what the merge still lacks.
    private static func merging(_ request: String, _ blockers: [SignalWaitFacts.MergeBlocker]) -> OperatorLine {
        guard !blockers.isEmpty else {
            return OperatorLine("waiting to merge", tooltip: "Waiting for \(request) to merge.")
        }
        let wanted = blockers.map { blocker in
            switch blocker {
            case .approval: "an approval"
            case .checks: "green checks"
            case .threads: "every thread resolved"
            case .push: "its local commits pushed"
            case .host: "the host’s go-ahead (no conflicts, nothing else it waits on)"
            }
        }
        let names = blockers.map { $0 == .host ? "host check" : $0.rawValue }
        let list = wanted.count == 1 ? wanted[0] : wanted.dropLast().joined(separator: ", ") + " and " + wanted[wanted.count - 1]
        return OperatorLine(fitted("waiting to merge · " + names.joined(separator: ", ")),
                            tooltip: "\(request.prefix(1).uppercased() + request.dropFirst()) merges once it has \(list).")
    }

    /// `text` cut to `maxLength` characters, its last one an ellipsis when anything was cut.
    static func fitted(_ text: String) -> String {
        text.count <= maxLength ? text : String(text.prefix(maxLength - 1)) + "…"
    }
}
