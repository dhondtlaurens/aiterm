import Foundation

// MARK: - A driven task that waits

public extension OperatorLine {
    /// A working task whose every worker ended its turn while the Operator does nothing of its own: the turn is the
    /// Operator's to read. Drawn with the waiting ring (`TaskStatus.waiting`), never as `working`.
    static let workerDone = OperatorLine("worker done · Operator to review",
                                         tooltip: "Every worker ended its turn. The Operator reads what it did and decides what follows.")

    /// What a task watching its done condition waits for, and on whom where its done check read it (`facts`): the line
    /// at most `maxLength` characters, the tooltip the whole sentence. `request` names its merge or pull request
    /// (`!102`), `ticket` its ticket's key; without them the sentence says "the request" or "the ticket". A fact the
    /// done check did not read gives the generic words, never a guess.
    static func waiting(for condition: DoneWhen, facts: SignalWaitFacts?, request: String? = nil, ticket: String? = nil) -> OperatorLine {
        let request = request ?? "the request"
        if let blockers = facts?.mergeBlockers { return merging(request, blockers) }
        switch condition {
        case .operatorJudges:
            return OperatorLine("waiting for the Operator", tooltip: "Waiting for the Operator to judge this stage done.")
        case .hasReviewer:
            return OperatorLine("waiting for a reviewer", tooltip: "Waiting for someone to be asked to review \(request).")
        case .approved:
            let names = (facts?.reviewers ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !names.isEmpty else {
                return OperatorLine("waiting on reviewer approval", tooltip: "Waiting for a reviewer to approve \(request).")
            }
            return OperatorLine(approvalLine(names), tooltip: "Waiting for \(Self.either(names)) to approve \(request).")
        case .threadsResolved:
            guard let open = facts?.openThreads, open > 0 else {
                return OperatorLine("waiting on review threads", tooltip: "Waiting for the review threads on \(request) to be resolved.")
            }
            let threads = open == 1 ? "1 open thread" : "\(open) open threads"
            return OperatorLine(fitted("waiting on " + threads),
                                tooltip: "Waiting for \(open == 1 ? "1 open review thread" : "\(open) open review threads") on \(request) to be resolved.")
        case .merged:
            return OperatorLine("waiting for the merge", tooltip: "Waiting for \(request) to be merged.")
        case .mergedOrClosed:
            return OperatorLine("waiting for merge or close", tooltip: "Waiting for \(request) to be merged or closed.")
        case .ticketStatus(let status):
            return OperatorLine(fitted("waiting for ticket to reach " + status),
                                tooltip: "Waiting for \(ticket ?? "the ticket") to move to “\(status)”.")
        case .myReviewPosted:
            return OperatorLine("waiting for you to post the review", tooltip: "Waiting for your review of \(request) to be posted.")
        case .unknown:
            return OperatorLine("unsupported done condition", tooltip: "This stage’s done condition is not one this version of AiTerm knows.")
        }
    }

    /// The done condition is met and merge when ready holds the task: `waiting to merge · checks`, naming what the
    /// merge still lacks.
    private static func merging(_ request: String, _ blockers: [SignalWaitFacts.MergeBlocker]) -> OperatorLine {
        guard !blockers.isEmpty else {
            return OperatorLine("waiting to merge", tooltip: "Its done condition is met. Waiting for \(request) to merge.")
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
                            tooltip: "Its done condition is met. \(request.prefix(1).uppercased() + request.dropFirst()) merges once it has \(list).")
    }

    /// `text` cut to `maxLength` characters, its last one an ellipsis when anything was cut.
    static func fitted(_ text: String) -> String {
        text.count <= maxLength ? text : String(text.prefix(maxLength - 1)) + "…"
    }

    /// `waiting on approval · Sam, Alex`: each reviewer's first name, as many as fit; else the first and how many
    /// more (`Sam +2`); a first name too long even alone is cut.
    private static func approvalLine(_ names: [String]) -> String {
        let lead = "waiting on approval · "
        let first = names.map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        let all = lead + first.joined(separator: ", ")
        if all.count <= maxLength { return all }
        let more = names.count > 1 ? " +\(names.count - 1)" : ""
        let room = maxLength - lead.count - more.count
        return lead + (first[0].count <= room ? first[0] : String(first[0].prefix(room - 1)) + "…") + more
    }

    /// `Ann`, `Ann or Ben`, `Ann, Ben or Cas`: any one approval is enough.
    private static func either(_ names: [String]) -> String {
        names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
    }
}
