import Foundation
import AiTermCore

/// The handler's four Oracle consumers share lifetime ownership, but settle their own records.
/// Every completion is numbered: a cancelled old job cannot remove or settle its replacement.
@MainActor
final class OracleJobs {
    enum Key: Hashable {
        case challenge(String), critique(OperatorToolHandler.CritiqueKey), gate(UUID)
    }
    private struct Job {
        let token: UUID, run: UUID
        let work: Task<SecondOpinionRunner.Verdict?, Never>
    }
    private var jobs: [Key: Job] = [:]
    private let work: OperatorWork
    init(work: OperatorWork) { self.work = work }

    func contains(_ key: Key) -> Bool { jobs[key] != nil }
    func running(_ key: Key) -> Task<SecondOpinionRunner.Verdict?, Never>? { jobs[key]?.work }

    func start(_ key: Key, run: UUID, runner: SecondOpinionRunner, opinion: OracleSetting,
               prompt: String, folder: URL, projects: [String], capped: Bool = true, keepCancelled: Bool = false,
               acting: @escaping @MainActor (Bool) -> Void,
               settle: @escaping @MainActor (SecondOpinionRunner.Verdict) -> Void = { _ in }) -> Task<SecondOpinionRunner.Verdict?, Never> {
        if let running = jobs[key] { return running.work }
        let token = UUID()
        acting(true)
        let started = work.start { [weak self] () -> SecondOpinionRunner.Verdict? in
            let raw = await runner.challenge(opinion, prompt: prompt, runFolder: folder, projects: projects)
            acting(false)
            guard let self else { return nil }
            let current = jobs[key]?.token == token
            if current { jobs[key] = nil }
            // The gate keeps the runner's cancellation verdict for its existing allow/deny construction.
            guard current, !Task.isCancelled else {
                guard keepCancelled else { return nil }
                if case .critique = raw { return SecondOpinionRunner.cancelled }
                return raw
            }
            let verdict = capped ? OperatorToolHandler.capped(raw) : raw
            settle(verdict)
            return verdict
        }
        jobs[key] = Job(token: token, run: run, work: started)
        return started
    }

    /// Removing first prevents a late, cancellation-insensitive completion from settling a record.
    func cancel(inRun run: UUID? = nil) {
        for (key, job) in jobs where run == nil || job.run == run {
            jobs[key] = nil
            job.work.cancel()
        }
    }

    /// Settings invalidate exactly the unacted challenge records that main invalidated. Relay
    /// jobs use the same challenge keys; thread critiques and shell gates finish normally.
    func cancelChallenges(_ ids: [String]) {
        for id in ids { jobs.removeValue(forKey: .challenge(id))?.work.cancel() }
    }
}
