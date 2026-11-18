import Foundation

public enum DoneCheck {
    /// What one complete host watch read found about a task's stage.
    public struct Facts: Equatable, Sendable {
        /// Whether the merge request's own read (approvals, threads, state) completed; a task without one never has it.
        public var hostReadComplete = false
        /// Whether the stage's Done query matches its item now.
        public var doneMatches = false
        public var approved = false
        public var threadsResolved = false
        public var merged = false
        public var closed = false
        public init() {}
    }

    /// Whether a complete read ends the stage: its merge request merged or closed, or its Done query matching now
    /// where it did not at the last observation (`before`). With no observation yet, a match is the baseline. A merge
    /// AiTerm made itself (`mergedByAiTerm`) hands the stage back to its worker, so only its Done query ends it.
    public static func reached(_ facts: Facts, before: Bool?, mergedByAiTerm: Bool = false) -> Bool {
        if facts.closed || (facts.merged && !mergedByAiTerm) { return true }
        return facts.doneMatches && before == false
    }
}

/// What a merge still lacks, kept on the task (`SignalTask.waitingOn`) so its line can say so (`OperatorLine.waiting`).
/// The host watch's own reads fill it.
public struct SignalWaitFacts: Codable, Equatable, Sendable {
    /// What a merge still lacks, in `MergeBlocker`'s words, while merge when ready holds a watching task.
    public enum MergeBlocker: String, Codable, Sendable {
        case approval, checks, threads, push
        /// The host would not merge it for a reason none of the others names: conflicts, a draft, its own rules.
        case host
    }
    public var mergeBlockers: [MergeBlocker]?
    public init(mergeBlockers: [MergeBlocker]? = nil) { self.mergeBlockers = mergeBlockers }
    public var isEmpty: Bool { mergeBlockers == nil }
}
