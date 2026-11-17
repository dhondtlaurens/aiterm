import Foundation
import Observation
import AiTermCore

/// The Operator's activity log and its issues: each entry is written when it is recorded, in order,
/// to `activity.jsonl` in the Operator's folder, and each issue's start, change and recovery is
/// logged with it.
@Observable @MainActor final class ActivityWriter {
    /// One issue per source; each clears only on its own source's next success (`OperatorIssues`).
    private(set) var issues = OperatorIssues() { didSet { if oldValue != issues { changed() } } }
    /// Called when `issues` changes.
    @ObservationIgnored var changed: () -> Void = {}
    /// Whether the Operator still runs; a write that ends after it stopped reports nothing.
    @ObservationIgnored var enabled: @MainActor () -> Bool = { false }
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let work: OperatorWork
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let activity: OperatorActivityTracker
    @ObservationIgnored private var last: Task<Void, Never>?

    init(folder: URL, work: OperatorWork, now: @escaping () -> Date, activity: OperatorActivityTracker) {
        self.folder = folder; self.work = work; self.now = now; self.activity = activity
    }

    func record(tool: String, task: UUID?, arguments: JSONValue, outcome: ActivityEntry.Outcome, result: String, line: String) {
        activity.pulse()
        write(ActivityEntry(at: now(), tool: tool, task: task, arguments: arguments,
                            outcome: outcome, result: result, line: line, reason: outcome == .ok ? nil : result))
    }
    func fail(_ source: OperatorIssues.Source, _ text: String) { record(issues.fail(source, text, at: now())) }
    func succeed(_ source: OperatorIssues.Source) { record(issues.succeed(source, at: now())) }

    /// Attempts each entry once, in the order it was recorded; a failed entry is dropped.
    private func write(_ entry: ActivityEntry) {
        let previous = last, folder = folder
        last = work.start { [weak self] in
            await previous?.value
            guard let self else { return }
            let failure = await BackgroundWork.run { () -> String? in
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try ActivityLog.append(entry, folder: folder)
                    return nil
                } catch { return OperationIssue.reason(of: error) }
            }
            guard self.enabled() else { return }
            if let failure { self.fail(.activity, "Its activity could not be saved: " + failure) } else { self.succeed(.activity) }
        }
    }
    /// Logs each issue's start, changed reason and recovery, except the activity log's own failure:
    /// that write would fail too, so only its recovery is logged.
    private func record(_ transition: OperatorIssues.Transition?) {
        guard let transition else { return }
        let entry: ActivityEntry
        switch transition {
        case .started(let issue), .changed(let issue):
            guard issue.source != .activity else { return }
            entry = ActivityEntry(at: now(), tool: "app_issue", task: nil, arguments: ["source": .string(issue.source.rawValue)],
                                  outcome: .failed, result: issue.text, line: issue.source.label + " failed.", reason: issue.text)
        case .recovered(let issue):
            entry = ActivityEntry(at: now(), tool: "app_issue", task: nil, arguments: ["source": .string(issue.source.rawValue)],
                                  outcome: .ok, result: "Recovered after \(issue.attempts) failed \(issue.attempts == 1 ? "attempt" : "attempts") since \(issue.since.formatted(.iso8601)).",
                                  line: issue.source.label + " recovered.", reason: nil)
        }
        write(entry)
    }
}
