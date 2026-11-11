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
        let token: UUID, run: UUID, task: UUID?
        let work: Task<SecondOpinionRunner.Verdict?, Never>
    }
    private var jobs: [Key: Job] = [:]
    private let work: OperatorWork
    init(work: OperatorWork) { self.work = work }

    func contains(_ key: Key) -> Bool { jobs[key] != nil }
    func running(_ key: Key) -> Task<SecondOpinionRunner.Verdict?, Never>? { jobs[key]?.work }

    func start(_ key: Key, run: UUID, task: UUID?, runner: SecondOpinionRunner, opinion: OracleSetting,
               prompt: String, folder: URL, projects: [String], capped: Bool = true, keepCancelled: Bool = false,
               acting: @escaping @MainActor (Bool) -> Void,
               settle: @escaping @MainActor (SecondOpinionRunner.Verdict) -> Void = { _ in }) -> Task<SecondOpinionRunner.Verdict?, Never> {
        jobs.removeValue(forKey: key)?.work.cancel()
        let token = UUID()
        acting(true)
        let started = work.start { [weak self] () -> SecondOpinionRunner.Verdict? in
            let raw = await runner.challenge(opinion, prompt: prompt, runFolder: folder, projects: projects)
            acting(false)
            guard let self else { return nil }
            let current = jobs[key]?.token == token
            if current { jobs[key] = nil }
            // The gate keeps the runner's cancellation verdict for its existing allow/deny construction.
            guard current, !Task.isCancelled else { return keepCancelled ? raw : nil }
            let verdict = capped ? OperatorToolHandler.capped(raw) : raw
            settle(verdict)
            return verdict
        }
        jobs[key] = Job(token: token, run: run, task: task, work: started)
        return started
    }

    /// Removing first prevents a late, cancellation-insensitive completion from settling a record.
    func cancel(inRun run: UUID? = nil) {
        for (key, job) in jobs where run == nil || job.run == run {
            jobs[key] = nil
            job.work.cancel()
        }
    }

    /// A removed task or run owns no more jobs. Work already in a process is cancelled as well.
    func retain(in state: AppState) {
        let runs = Set(state.runs.map(\.id)), tasks = Set(state.tasks.map(\.id))
        for (key, job) in jobs where !runs.contains(job.run) || job.task.map({ !tasks.contains($0) }) == true {
            jobs[key] = nil
            job.work.cancel()
        }
    }
}
